package cross

import (
	"errors"
	"fmt"

	"github.com/ethereum/go-ethereum/log"

	"github.com/ethereum-optimism/optimism/op-node/rollup/event"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/depset"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/reads"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/superevents"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/types"
)

type CrossUnsafeDeps interface {
	reads.Acquirer

	CrossUnsafe(chainID eth.ChainID) (types.BlockSeal, error)

	UnsafeStartDeps
	UnsafeFrontierCheckDeps

	OpenBlock(chainID eth.ChainID, blockNum uint64) (block eth.BlockRef, logCount uint32, execMsgs map[uint32]*types.ExecutingMessage, err error)

	UpdateCrossUnsafe(chain eth.ChainID, crossUnsafe types.BlockSeal) error
}

func CrossUnsafeUpdate(logger log.Logger, chainID eth.ChainID, d CrossUnsafeDeps, linker depset.LinkChecker) error {
	h := d.AcquireHandle()
	defer h.Release()

	var candidate types.BlockSeal

	// fetch cross-head to determine next cross-unsafe candidate
	if crossUnsafe, err := d.CrossUnsafe(chainID); err != nil {
		if errors.Is(err, types.ErrFuture) {
			// If genesis / no cross-safe block yet, then defer update
			logger.Debug("No cross-unsafe starting point yet")
			return nil
		} else {
			return err
		}
	} else {
		// Open block N+1: this is a local-unsafe block,
		// just after cross-safe, that can be promoted if it passes the dependency checks.
		bl, _, _, err := d.OpenBlock(chainID, crossUnsafe.Number+1)
		if err != nil {
			return fmt.Errorf("failed to open block %d: %w", crossUnsafe.Number+1, err)
		}
		if bl.ParentHash != crossUnsafe.Hash {
			return fmt.Errorf("cannot use block %s, it does not build on cross-unsafe block %s: %w", bl, crossUnsafe, types.ErrConflict)
		}
		candidate = types.BlockSealFromRef(bl)
	}
	h.DependOnDerivedTime(candidate.Timestamp)

	hazards, err := CrossUnsafeHazards(d, linker, logger, chainID, candidate)
	if err != nil {
		return fmt.Errorf("failed to check for cross-chain hazards: %w", err)
	}

	if err := HazardUnsafeFrontierChecks(d, hazards); err != nil {
		return fmt.Errorf("failed to verify block %s in cross-unsafe frontier: %w", candidate, err)
	}
	if err := HazardCycleChecks(d, candidate.Timestamp, hazards); err != nil {
		return fmt.Errorf("failed to verify block %s in cross-unsafe check for cycle hazards: %w", candidate, err)
	}

	if !h.IsValid() {
		logger.Warn("Reads were inconsistent, aborting cross-unsafe update", "aborted", candidate)
		return types.ErrInvalidatedRead
	}

	// promote the candidate block to cross-unsafe
	if err := d.UpdateCrossUnsafe(chainID, candidate); err != nil {
		return fmt.Errorf("failed to update cross-unsafe head to %s: %w", candidate, err)
	}
	return nil
}

type CrossUnsafeWorker struct {
	logger  log.Logger
	chainID eth.ChainID
	d       CrossUnsafeDeps
	linker  depset.LinkChecker
}

func (c *CrossUnsafeWorker) OnEvent(ev event.Event) bool {
	switch ev.(type) {
	case superevents.UpdateCrossUnsafeRequestEvent:
		if err := CrossUnsafeUpdate(c.logger, c.chainID, c.d, c.linker); err != nil {
			if errors.Is(err, types.ErrFuture) {
				c.logger.Debug("Worker awaits additional blocks", "err", err)
			} else {
				c.logger.Warn("Failed to process work", "err", err)
			}
		}
	default:
		return false
	}
	return true
}

var _ event.Deriver = (*CrossUnsafeWorker)(nil)

func NewCrossUnsafeWorker(logger log.Logger, chainID eth.ChainID, d CrossUnsafeDeps, linker depset.LinkChecker) *CrossUnsafeWorker {
	logger = logger.New("chain", chainID, "worker", "cross-unsafe")
	return &CrossUnsafeWorker{
		logger:  logger,
		chainID: chainID,
		d:       d,
		linker:  linker,
	}
}
