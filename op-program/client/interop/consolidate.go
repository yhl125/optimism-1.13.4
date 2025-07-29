package interop

import (
	"errors"
	"fmt"

	"github.com/ethereum-optimism/optimism/op-program/client/boot"
	"github.com/ethereum-optimism/optimism/op-program/client/interop/types"
	"github.com/ethereum-optimism/optimism/op-program/client/l1"
	"github.com/ethereum-optimism/optimism/op-program/client/l2"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/cross"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/depset"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/processors"
	supervisortypes "github.com/ethereum-optimism/optimism/op-supervisor/supervisor/types"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/rawdb"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/log"
)

var ErrInvalidBlockReplacement = errors.New("invalid block replacement error")

// ReceiptsToExecutingMessages returns the executing messages in the receipts indexed by their position in the log.
func ReceiptsToExecutingMessages(receipts ethtypes.Receipts) (map[uint32]*supervisortypes.ExecutingMessage, uint32, error) {
	execMsgs := make(map[uint32]*supervisortypes.ExecutingMessage)
	var curr uint32
	for _, rcpt := range receipts {
		for _, l := range rcpt.Logs {
			execMsg, err := processors.DecodeExecutingMessageLog(l)
			if err != nil {
				return nil, 0, err
			}
			if execMsg != nil {
				execMsgs[curr] = execMsg
			}
			curr++
		}
	}
	return execMsgs, curr, nil
}

type execMessageCacheEntry struct {
	execMsgs map[uint32]*supervisortypes.ExecutingMessage
	logCount uint32
}

type consolidateState struct {
	*types.TransitionState
	replacedChains map[eth.ChainID]bool

	// execMessageCache is used to memoize iteration of logs in blocks to speed up executing message retrieval
	execMessageCache map[common.Hash]execMessageCacheEntry
}

func newConsolidateState(transitionState *types.TransitionState) *consolidateState {
	s := &consolidateState{
		TransitionState: &types.TransitionState{
			PendingProgress: make([]types.OptimisticBlock, len(transitionState.PendingProgress)),
			SuperRoot:       transitionState.SuperRoot,
			Step:            transitionState.Step,
		},
		replacedChains:   make(map[eth.ChainID]bool),
		execMessageCache: make(map[common.Hash]execMessageCacheEntry),
	}
	// We will be updating the transition state as blocks are replaced, so make a copy
	copy(s.PendingProgress, transitionState.PendingProgress)
	return s
}

func (s *consolidateState) isReplaced(chainID eth.ChainID) bool {
	return s.replacedChains[chainID]
}

func (s *consolidateState) setReplaced(transitionStateIndex int, chainID eth.ChainID, outputRoot eth.Bytes32, replacementBlockHash common.Hash) {
	s.PendingProgress[transitionStateIndex].OutputRoot = outputRoot
	s.PendingProgress[transitionStateIndex].BlockHash = replacementBlockHash
	s.replacedChains[chainID] = true
}

func (s *consolidateState) getCachedExecMsgs(blockHash common.Hash) (map[uint32]*supervisortypes.ExecutingMessage, uint32, bool) {
	entry, ok := s.execMessageCache[blockHash]
	if !ok {
		return nil, 0, false
	}
	return entry.execMsgs, entry.logCount, true
}

func (s *consolidateState) setCachedExecMsgs(blockHash common.Hash, execMsgs map[uint32]*supervisortypes.ExecutingMessage, logCount uint32) {
	s.execMessageCache[blockHash] = execMessageCacheEntry{
		execMsgs: execMsgs,
		logCount: logCount,
	}
}

func RunConsolidation(
	logger log.Logger,
	bootInfo *boot.BootInfoInterop,
	l1PreimageOracle l1.Oracle,
	l2PreimageOracle l2.Oracle,
	transitionState *types.TransitionState,
	superRoot *eth.SuperV1,
	tasks taskExecutor,
) (eth.Bytes32, error) {
	consolidateState := newConsolidateState(transitionState)
	// Use a reference to the transition state so the consolidate oracle has a recent view.
	// The TransitionStateByRoot method isn't expected to be used during consolidation,
	// but we pass the state for safety in case this changes in the future.
	consolidateOracle := NewConsolidateOracle(l2PreimageOracle, consolidateState.TransitionState)

	// Keep consolidating until there are no more invalid blocks to replace
loop:
	for {
		err := singleRoundConsolidation(logger, bootInfo, l1PreimageOracle, consolidateOracle, consolidateState, superRoot, tasks)
		switch {
		case err == nil:
			break loop
		case errors.Is(err, ErrInvalidBlockReplacement):
			continue
		default:
			return eth.Bytes32{}, err
		}
	}

	var consolidatedChains []eth.ChainIDAndOutput
	for i, chain := range superRoot.Chains {
		consolidatedChains = append(consolidatedChains, eth.ChainIDAndOutput{
			ChainID: chain.ChainID,
			Output:  consolidateState.PendingProgress[i].OutputRoot,
		})
	}
	consolidatedSuper := &eth.SuperV1{
		Timestamp: superRoot.Timestamp + 1,
		Chains:    consolidatedChains,
	}
	return eth.SuperRoot(consolidatedSuper), nil
}

func singleRoundConsolidation(
	logger log.Logger,
	bootInfo *boot.BootInfoInterop,
	l1PreimageOracle l1.Oracle,
	l2PreimageOracle *ConsolidateOracle,
	consolidateState *consolidateState,
	superRoot *eth.SuperV1,
	tasks taskExecutor,
) error {
	// The depset is the same for all chains. So it suffices to use any chain ID
	depSet, err := bootInfo.Configs.DependencySet(superRoot.Chains[0].ChainID)
	if err != nil {
		return fmt.Errorf("failed to get dependency set: %w", err)
	}
	deps, err := newConsolidateCheckDeps(depSet, bootInfo.Configs, consolidateState.TransitionState, superRoot.Chains, l2PreimageOracle, consolidateState)
	if err != nil {
		return fmt.Errorf("failed to create consolidate check deps: %w", err)
	}
	fullConfig, err := getFullConfig(bootInfo.Configs, l1PreimageOracle, depSet)
	if err != nil {
		return fmt.Errorf("failed to get full config set: %w", err)
	}
	linker := depset.LinkerFromConfig(fullConfig)
	for i, chain := range superRoot.Chains {
		// Do not check chains that have been replaced with a deposits-only block.
		// They are already cross-safe because deposits-only blocks cannot contain executing messages.
		if consolidateState.isReplaced(chain.ChainID) {
			continue
		}

		progress := consolidateState.PendingProgress[i]
		optimisticBlock, _ := l2PreimageOracle.ReceiptsByBlockHash(progress.BlockHash, chain.ChainID)

		candidate := supervisortypes.BlockSeal{
			Hash:      progress.BlockHash,
			Number:    optimisticBlock.NumberU64(),
			Timestamp: optimisticBlock.Time(),
		}
		if err := checkHazards(logger, deps, linker, candidate, chain.ChainID); err != nil {
			if !isInvalidMessageError(err) {
				return err
			}
			// Invalid executing message found. Replace with a deposit only block
			replacementBlockHash, outputRoot, err := buildDepositOnlyBlock(
				logger,
				bootInfo,
				l1PreimageOracle,
				l2PreimageOracle,
				chain,
				tasks,
				optimisticBlock,
				// Update the preimage oracle database with the replaced block data
				l2PreimageOracle.KeyValueStore(),
			)
			if err != nil {
				return err
			}
			logger.Info(
				"Replaced block",
				"chain", chain.ChainID,
				"replacedBlock", eth.ToBlockID(optimisticBlock),
				"replacementBlockHash", replacementBlockHash,
				"outputRoot", outputRoot,
				"replacedOutputRoot", chain.Output,
			)
			superRoot.Chains[i].Output = outputRoot
			consolidateState.setReplaced(i, chain.ChainID, outputRoot, replacementBlockHash)
			// Indicate that there was an invalid block so we have to re-check all chains.
			// The re-check will pick up invalid messages in any chains we haven't gotten to yet so don't waste time now.
			return ErrInvalidBlockReplacement
		}
	}
	return nil
}

func isInvalidMessageError(err error) bool {
	return errors.Is(err, supervisortypes.ErrConflict) || errors.Is(err, supervisortypes.ErrUnknownChain)
}

type ConsolidateCheckDeps interface {
	cross.UnsafeFrontierCheckDeps
	cross.CycleCheckDeps
	cross.UnsafeStartDeps
}

func checkHazards(logger log.Logger, deps ConsolidateCheckDeps, linker depset.LinkChecker, candidate supervisortypes.BlockSeal, chainID eth.ChainID) error {
	hazards, err := cross.CrossUnsafeHazards(deps, linker, logger, chainID, candidate)
	if err != nil {
		return err
	}
	if err := cross.HazardCycleChecks(deps, candidate.Timestamp, hazards); err != nil {
		return err
	}
	return nil
}

type consolidateCheckDeps struct {
	oracle      l2.Oracle
	depset      depset.DependencySet
	canonBlocks map[eth.ChainID]*l2.FastCanonicalBlockHeaderOracle

	consolidateState *consolidateState
}

func newConsolidateCheckDeps(
	depset depset.DependencySet,
	configSource boot.ConfigSource,
	transitionState *types.TransitionState,
	chains []eth.ChainIDAndOutput,
	oracle l2.Oracle,
	consolidateState *consolidateState,
) (*consolidateCheckDeps, error) {
	// TODO(#14415): handle case where dep set changes in a given timestamp
	canonBlocks := make(map[eth.ChainID]*l2.FastCanonicalBlockHeaderOracle)
	for i, chain := range chains {
		progress := transitionState.PendingProgress[i]
		// This is the optimistic head. It's OK if it's replaced by a deposits-only block.
		// Because by then the replacement block won't be used for hazard checks.
		head, err := fetchOptimisticBlock(oracle, progress.BlockHash, chain)
		if err != nil {
			return nil, fmt.Errorf("failed to fetch optimistic block for chain %v: %w", chain.ChainID, err)
		}
		blockByHash := func(hash common.Hash) *ethtypes.Block {
			return oracle.BlockByHash(hash, chain.ChainID)
		}
		l2ChainConfig, err := configSource.ChainConfig(chain.ChainID)
		if err != nil {
			return nil, fmt.Errorf("no chain config available for chain ID %v: %w", chain.ChainID, err)
		}
		fallback := l2.NewCanonicalBlockHeaderOracle(head.Header(), blockByHash)
		canonBlocks[chain.ChainID] = l2.NewFastCanonicalBlockHeaderOracle(head.Header(), blockByHash, l2ChainConfig, oracle, rawdb.NewMemoryDatabase(), fallback)
	}

	return &consolidateCheckDeps{
		oracle:           oracle,
		depset:           depset,
		canonBlocks:      canonBlocks,
		consolidateState: consolidateState,
	}, nil
}

func fetchOptimisticBlock(oracle l2.Oracle, blockHash common.Hash, chain eth.ChainIDAndOutput) (*ethtypes.Block, error) {
	agreedOutput := oracle.OutputByRoot(common.Hash(chain.Output), chain.ChainID)
	agreedOutputV0, ok := agreedOutput.(*eth.OutputV0)
	if !ok {
		return nil, fmt.Errorf("%w: version: %d", l2.ErrUnsupportedL2Output, agreedOutput.Version())
	}
	return oracle.BlockDataByHash(agreedOutputV0.BlockHash, blockHash, chain.ChainID), nil
}

func (d *consolidateCheckDeps) Contains(chain eth.ChainID, query supervisortypes.ContainsQuery) (includedIn supervisortypes.BlockSeal, err error) {
	// We can assume the oracle has the block the executing message is in
	block, err := d.CanonBlockByNumber(d.oracle, query.BlockNum, chain)
	if err != nil {
		return supervisortypes.BlockSeal{}, err
	}
	if block.Time() != query.Timestamp {
		return supervisortypes.BlockSeal{}, fmt.Errorf("block timestamp mismatch: %d != %d: %w", block.Time(), query.Timestamp, supervisortypes.ErrConflict)
	}
	_, receipts := d.oracle.ReceiptsByBlockHash(block.Hash(), chain)
	var current uint32
	for _, receipt := range receipts {
		for i, log := range receipt.Logs {
			if current+uint32(i) == query.LogIdx {
				checksum := supervisortypes.ChecksumArgs{
					BlockNumber: query.BlockNum,
					LogIndex:    query.LogIdx,
					Timestamp:   query.Timestamp,
					ChainID:     chain,
					LogHash:     logToLogHash(log),
				}.Checksum()
				if checksum != query.Checksum {
					return supervisortypes.BlockSeal{}, fmt.Errorf("checksum mismatch: %s != %s: %w", checksum, query.Checksum, supervisortypes.ErrConflict)
				} else {
					return supervisortypes.BlockSeal{
						Hash:      block.Hash(),
						Number:    block.NumberU64(),
						Timestamp: block.Time(),
					}, nil
				}
			}
		}
		current += uint32(len(receipt.Logs))
	}
	return supervisortypes.BlockSeal{}, fmt.Errorf("log not found: %w", supervisortypes.ErrConflict)
}

func logToLogHash(l *ethtypes.Log) common.Hash {
	payloadHash := crypto.Keccak256Hash(supervisortypes.LogToMessagePayload(l))
	return supervisortypes.PayloadHashToLogHash(payloadHash, l.Address)
}

func (d *consolidateCheckDeps) IsCrossUnsafe(chainID eth.ChainID, block eth.BlockID) error {
	// Assumed to be cross-unsafe. And hazard checks will catch any future blocks prior to calling this
	return nil
}

func (d *consolidateCheckDeps) IsLocalUnsafe(chainID eth.ChainID, block eth.BlockID) error {
	// Always assumed to be local-unsafe
	return nil
}

func (d *consolidateCheckDeps) FindBlockID(chainID eth.ChainID, num uint64) (blockID eth.BlockID, err error) {
	block, err := d.CanonBlockByNumber(d.oracle, num, chainID)
	if err != nil {
		return eth.BlockID{}, err
	}
	return eth.BlockID{
		Hash:   block.Hash(),
		Number: block.NumberU64(),
	}, nil
}

func (d *consolidateCheckDeps) OpenBlock(
	chainID eth.ChainID,
	blockNum uint64,
) (ref eth.BlockRef, logCount uint32, execMsgs map[uint32]*supervisortypes.ExecutingMessage, err error) {
	block, err := d.CanonBlockByNumber(d.oracle, blockNum, chainID)
	if err != nil {
		return eth.BlockRef{}, 0, nil, err
	}
	ref = eth.BlockRef{
		Hash:   block.Hash(),
		Number: block.NumberU64(),
	}
	if execMsgs, logCount, ok := d.consolidateState.getCachedExecMsgs(block.Hash()); ok {
		return ref, logCount, execMsgs, nil
	}

	_, receipts := d.oracle.ReceiptsByBlockHash(block.Hash(), chainID)
	execMsgs, logCount, err = ReceiptsToExecutingMessages(receipts)
	if err != nil {
		return eth.BlockRef{}, 0, nil, err
	}
	d.consolidateState.setCachedExecMsgs(block.Hash(), execMsgs, logCount)
	return ref, logCount, execMsgs, nil
}

func (d *consolidateCheckDeps) CanonBlockByNumber(oracle l2.Oracle, blockNum uint64, chainID eth.ChainID) (*ethtypes.Block, error) {
	head := d.canonBlocks[chainID].GetHeaderByNumber(blockNum)
	if head == nil {
		return nil, fmt.Errorf("head not found for chain %v: %w", chainID, supervisortypes.ErrConflict)
	}
	return d.oracle.BlockByHash(head.Hash(), chainID), nil
}

var _ ConsolidateCheckDeps = (*consolidateCheckDeps)(nil)

func buildDepositOnlyBlock(
	logger log.Logger,
	bootInfo *boot.BootInfoInterop,
	l1PreimageOracle l1.Oracle,
	l2PreimageOracle l2.Oracle,
	chainAgreedPrestate eth.ChainIDAndOutput,
	tasks taskExecutor,
	optimisticBlock *ethtypes.Block,
	db l2.KeyValueStore,
) (common.Hash, eth.Bytes32, error) {
	rollupCfg, err := bootInfo.Configs.RollupConfig(chainAgreedPrestate.ChainID)
	if err != nil {
		return common.Hash{}, eth.Bytes32{}, fmt.Errorf("no rollup config available for chain ID %v: %w", chainAgreedPrestate.ChainID, err)
	}
	l2ChainConfig, err := bootInfo.Configs.ChainConfig(chainAgreedPrestate.ChainID)
	if err != nil {
		return common.Hash{}, eth.Bytes32{}, fmt.Errorf("no chain config available for chain ID %v: %w", chainAgreedPrestate.ChainID, err)
	}
	blockHash, outputRoot, err := tasks.BuildDepositOnlyBlock(
		logger,
		rollupCfg,
		l2ChainConfig,
		bootInfo.L1Head,
		chainAgreedPrestate.Output,
		l1PreimageOracle,
		l2PreimageOracle,
		optimisticBlock,
		db,
	)
	if err != nil {
		return common.Hash{}, eth.Bytes32{}, err
	}
	return blockHash, outputRoot, nil
}
