package db

import (
	"errors"
	"fmt"

	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/db/logs"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/types"
)

func (db *ChainsDB) FindSealedBlock(chain eth.ChainID, number uint64) (seal types.BlockSeal, err error) {
	logDB, ok := db.logDBs.Get(chain)
	if !ok {
		return types.BlockSeal{}, fmt.Errorf("%w: %v", types.ErrUnknownChain, chain)
	}
	return logDB.FindSealedBlock(number)
}

func (db *ChainsDB) FindBlockID(chain eth.ChainID, number uint64) (id eth.BlockID, err error) {
	sealed, err := db.FindSealedBlock(chain, number)
	if err != nil {
		return eth.BlockID{}, err
	}
	return sealed.ID(), nil
}

// LatestBlockNum returns the latest fully-sealed block number that has been recorded to the logs db
// for the given chain. It does not contain safety guarantees.
// The block number might not be available (empty database, or non-existent chain).
func (db *ChainsDB) LatestBlockNum(chain eth.ChainID) (num uint64, ok bool) {
	logDB, knownChain := db.logDBs.Get(chain)
	if !knownChain {
		return 0, false
	}
	bl, ok := logDB.LatestSealedBlock()
	return bl.Number, ok
}

// IsCrossUnsafe checks if the given block is less than the cross-unsafe block number.
// It does not check if the block is actually cross-unsafe (ie, known in the database).
func (db *ChainsDB) IsCrossUnsafe(chainID eth.ChainID, block eth.BlockID) error {
	xU, ok := db.crossUnsafe.Get(chainID)
	if !ok {
		return types.ErrUnknownChain
	}
	crossUnsafe := xU.Get()
	if crossUnsafe == (types.BlockSeal{}) {
		return types.ErrFuture
	}
	if block.Number > crossUnsafe.Number {
		return types.ErrFuture
	}
	// now we know it's within the cross-unsafe range
	// check if it's consistent with unsafe data
	lU, ok := db.logDBs.Get(chainID)
	if !ok {
		return types.ErrUnknownChain
	}
	unsafeBlock, err := lU.FindSealedBlock(block.Number)
	if err != nil {
		return fmt.Errorf("failed to find sealed block %d: %w", block.Number, err)
	}
	if unsafeBlock.ID() != block {
		return fmt.Errorf("found %s but was looking for unsafe block %s: %w", unsafeBlock.ID(), block, types.ErrConflict)
	}
	return nil
}

func (db *ChainsDB) IsLocalUnsafe(chainID eth.ChainID, block eth.BlockID) error {
	logDB, ok := db.logDBs.Get(chainID)
	if !ok {
		return types.ErrUnknownChain
	}
	got, err := logDB.FindSealedBlock(block.Number)
	if err != nil {
		return err
	}
	if got.ID() != block {
		return fmt.Errorf("found %s but was looking for unsafe block %s: %w", got, block, types.ErrConflict)
	}
	return nil
}

func (db *ChainsDB) IsCrossSafe(chainID eth.ChainID, block eth.BlockID) error {
	xdb, ok := db.crossDBs.Get(chainID)
	if !ok {
		return types.ErrUnknownChain
	}
	return xdb.ContainsDerived(block, types.RevisionAny)
}

// findRevision determines what the given block needs as revision for DB lookups.
// This uses the cross-safe DB as canonical-chain reference.
// If the block is not in the cross-safe DB (e.g. a newer local-safe block),
// then the last known revision is used, and kept open-ended, to capture the invalidated-entry block.
func (db *ChainsDB) findRevision(chainID eth.ChainID, block eth.BlockID) (types.Revision, error) {
	xdb, ok := db.crossDBs.Get(chainID)
	if !ok {
		return types.Revision(0), types.ErrUnknownChain
	}
	rev, err := xdb.DerivedToRevision(block)
	if errors.Is(err, types.ErrFuture) {
		ldb, ok := db.localDBs.Get(chainID)
		if !ok {
			return types.Revision(0), types.ErrUnknownChain
		}
		rev, err := ldb.LastRevision()
		// During non-Genesis Interop activation, there may not be any safe data yet.
		if errors.Is(err, types.ErrFuture) {
			return types.Revision(0), nil
		}
		return rev, err
	}
	return rev, nil
}

func (db *ChainsDB) IsLocalSafe(chainID eth.ChainID, block eth.BlockID) error {
	ldb, ok := db.localDBs.Get(chainID)
	if !ok {
		return types.ErrUnknownChain
	}
	revision, err := db.findRevision(chainID, block)
	if err != nil {
		return err
	}
	return ldb.ContainsDerived(block, revision)
}

func (db *ChainsDB) IsFinalized(chainID eth.ChainID, block eth.BlockID) error {
	finL1 := db.FinalizedL1()
	if finL1 == (eth.BlockRef{}) {
		return types.ErrUninitialized
	}
	source, err := db.CrossDerivedToSource(chainID, block)
	if err != nil {
		return fmt.Errorf("failed to get cross-safe source: %w", err)
	}
	if finL1.Number >= source.Number {
		return nil
	}
	return fmt.Errorf("cross-safe source block is not finalized: %w", types.ErrFuture)
}

func (db *ChainsDB) LocalSafeDerivedAt(chainID eth.ChainID, source eth.BlockID) (types.BlockSeal, error) {
	lDB, ok := db.localDBs.Get(chainID)
	if !ok {
		return types.BlockSeal{}, types.ErrUnknownChain
	}
	derived, err := lDB.SourceToLastDerived(source)
	if err != nil {
		return types.BlockSeal{}, fmt.Errorf("failed to find derived block %s: %w", source, err)
	}
	return derived, nil
}

func (db *ChainsDB) LocalUnsafe(chainID eth.ChainID) (types.BlockSeal, error) {
	eventsDB, ok := db.logDBs.Get(chainID)
	if !ok {
		return types.BlockSeal{}, types.ErrUnknownChain
	}
	head, ok := eventsDB.LatestSealedBlock()
	if !ok {
		return types.BlockSeal{}, types.ErrFuture
	}
	return eventsDB.FindSealedBlock(head.Number)
}

func (db *ChainsDB) CrossUnsafe(chainID eth.ChainID) (types.BlockSeal, error) {
	result, ok := db.crossUnsafe.Get(chainID)
	if !ok {
		return types.BlockSeal{}, types.ErrUnknownChain
	}
	crossUnsafe := result.Get()
	// Fall back to cross-safe if cross-unsafe is not known yet
	if crossUnsafe == (types.BlockSeal{}) {
		crossSafe, err := db.CrossSafe(chainID)
		if err != nil {
			return types.BlockSeal{}, fmt.Errorf("no cross-unsafe known for chain %s, and failed to fall back to cross-safe value: %w", chainID, err)
		}
		return crossSafe.Derived, nil
	}
	return crossUnsafe, nil
}

func (db *ChainsDB) AcceptedBlock(chainID eth.ChainID, id eth.BlockID) error {
	localDB, ok := db.localDBs.Get(chainID)
	if !ok {
		return types.ErrUnknownChain
	}
	revision, err := db.findRevision(chainID, id)
	if err != nil {
		return fmt.Errorf("failed to get revision: %w", err)
	}
	db.logger.Info("Checking if accepted", "chain", chainID, "id", id, "revision", revision)
	// If the block is not cross-safe, then the revision will be the latest
	// (assuming the trailing local-safe data only has 1 revision;
	//  the same or something net-new exactly starting after cross-safe).
	// If the block was invalidated, then ContainsDerived will error with types.ErrAwaitReplacementBlock.
	if err := localDB.ContainsDerived(id, revision); err != nil {
		if errors.Is(err, types.ErrFuture) {
			return nil // Optimistically accept blocks that we haven't seen as local-derived yet.
		}
		return fmt.Errorf("failed to check older local-safe db entry %s: %w", revision, err)
	}
	return err
}

func (db *ChainsDB) LocalSafe(chainID eth.ChainID) (pair types.DerivedBlockSealPair, err error) {
	localDB, ok := db.localDBs.Get(chainID)
	if !ok {
		return types.DerivedBlockSealPair{}, types.ErrUnknownChain
	}
	return localDB.Last()
}

func (db *ChainsDB) CrossSafe(chainID eth.ChainID) (pair types.DerivedBlockSealPair, err error) {
	crossDB, ok := db.crossDBs.Get(chainID)
	if !ok {
		return types.DerivedBlockSealPair{}, types.ErrUnknownChain
	}
	return crossDB.Last()
}

func (db *ChainsDB) FinalizedL1() eth.BlockRef {
	return db.finalizedL1.Get()
}

func (db *ChainsDB) Finalized(chainID eth.ChainID) (types.BlockSeal, error) {
	finalizedL1 := db.finalizedL1.Get()
	if finalizedL1 == (eth.L1BlockRef{}) {
		return types.BlockSeal{}, fmt.Errorf("no finalized L1 signal, cannot determine L2 finality of chain %s yet: %w", chainID, types.ErrFuture)
	}

	// compare the finalized L1 block with the last derived block in the cross DB
	xDB, ok := db.crossDBs.Get(chainID)
	if !ok {
		return types.BlockSeal{}, types.ErrUnknownChain
	}
	latest, err := xDB.Last()
	if err != nil {
		return types.BlockSeal{}, fmt.Errorf("could not get the latest derived pair for chain %s: %w", chainID, err)
	}
	// if the finalized L1 block is newer than the latest L1 block used to derive L2 blocks,
	// the finality signal automatically applies to all previous blocks, including the latest derived block
	if finalizedL1.Number > latest.Source.Number {
		db.logger.Warn("Finalized L1 block is newer than the latest L1 for this chain. Assuming latest L2 is finalized",
			"chain", chainID,
			"finalizedL1", finalizedL1.Number,
			"latestSource", latest.Source,
			"latestDerived", latest.Derived)
		return latest.Derived, nil
	}

	// otherwise, use the finalized L1 block to determine the final L2 block that was derived from it
	derived, err := db.CrossSourceToLastDerived(chainID, finalizedL1.ID())
	if err != nil {
		return types.BlockSeal{}, fmt.Errorf("could not find what was last derived in L2 chain %s from the finalized L1 block %s: %w", chainID, finalizedL1, err)
	}
	return derived, nil
}

func (db *ChainsDB) CrossSourceToLastDerived(chainID eth.ChainID, source eth.BlockID) (derived types.BlockSeal, err error) {
	crossDB, ok := db.crossDBs.Get(chainID)
	if !ok {
		return types.BlockSeal{}, types.ErrUnknownChain
	}
	return crossDB.SourceToLastDerived(source)
}

// CrossDerivedToSourceRef returns the block that the given block was derived from, if it exists in the cross derived-from storage.
// This call requires the block to have a parent to be turned into a Ref. Use CrossDerivedToSource if the parent is not needed.
func (db *ChainsDB) CrossDerivedToSourceRef(chainID eth.ChainID, derived eth.BlockID) (source eth.BlockRef, err error) {
	xdb, ok := db.crossDBs.Get(chainID)
	if !ok {
		return eth.BlockRef{}, types.ErrUnknownChain
	}
	res, err := xdb.DerivedToFirstSource(derived, types.RevisionAny)
	if err != nil {
		return eth.BlockRef{}, err
	}
	parent, err := xdb.PreviousSource(res.ID())
	// if we are working with the first item in the database, PreviousSource will return ErrPreviousToFirst
	// in which case we can attach a zero parent to the block, as the parent block is unknown
	if errors.Is(err, types.ErrPreviousToFirst) {
		return res.ForceWithParent(eth.BlockID{}), nil
	} else if err != nil {
		return eth.BlockRef{}, err
	}
	return res.MustWithParent(parent.ID()), nil
}

// Contains calls the underlying logDB to determine if the given log entry exists at the given location.
// If the block-seal of the block that includes the log is known, it is returned. It is fully zeroed otherwise, if the block is in-progress.
func (db *ChainsDB) Contains(chain eth.ChainID, q types.ContainsQuery) (includedIn types.BlockSeal, err error) {
	logDB, ok := db.logDBs.Get(chain)
	if !ok {
		return types.BlockSeal{}, fmt.Errorf("%w: %v", types.ErrUnknownChain, chain)
	}
	return logDB.Contains(q)
}

// OpenBlock returns the Executing Messages for the block at the given number on the given chain.
// it routes the request to the appropriate logDB.
func (db *ChainsDB) OpenBlock(chainID eth.ChainID, blockNum uint64) (seal eth.BlockRef, logCount uint32, execMsgs map[uint32]*types.ExecutingMessage, err error) {
	logDB, ok := db.logDBs.Get(chainID)
	if !ok {
		return eth.BlockRef{}, 0, nil, types.ErrUnknownChain
	}
	return logDB.OpenBlock(blockNum)
}

// LocalDerivedToSource returns the block that the given block was derived from, if it exists in the local derived-from storage.
// it routes the request to the appropriate localDB.
func (db *ChainsDB) LocalDerivedToSource(chain eth.ChainID, derived eth.BlockID) (source types.BlockSeal, err error) {
	lDB, ok := db.localDBs.Get(chain)
	if !ok {
		return types.BlockSeal{}, types.ErrUnknownChain
	}
	revision, err := db.findRevision(chain, derived)
	if err != nil {
		return types.BlockSeal{}, err
	}
	return lDB.DerivedToFirstSource(derived, revision)
}

// CrossDerivedToSource returns the block that the given block was derived from, if it exists in the cross derived-from storage.
// it routes the request to the appropriate crossDB.
func (db *ChainsDB) CrossDerivedToSource(chain eth.ChainID, derived eth.BlockID) (source types.BlockSeal, err error) {
	xDB, ok := db.crossDBs.Get(chain)
	if !ok {
		return types.BlockSeal{}, types.ErrUnknownChain
	}
	return xDB.DerivedToFirstSource(derived, types.RevisionAny)
}

// CandidateCrossSafe returns the candidate local-safe block that may become cross-safe,
// and what L1 block it may potentially be cross-safe derived from.
//
// This returns ErrFuture if no block is known yet.
//
// Or ErrConflict if there is an inconsistency between the local-safe and cross-safe DB.
//
// Or ErrOutOfScope, with non-zero sourceScope,
// if additional L1 data is needed to cross-verify the candidate L2 block.
func (db *ChainsDB) CandidateCrossSafe(chain eth.ChainID) (result types.DerivedBlockRefPair, err error) {
	xDB, ok := db.crossDBs.Get(chain)
	if !ok {
		return types.DerivedBlockRefPair{}, types.ErrUnknownChain
	}

	lDB, ok := db.localDBs.Get(chain)
	if !ok {
		return types.DerivedBlockRefPair{}, types.ErrUnknownChain
	}
	crossSafe, err := xDB.Last()
	if err != nil {
		if errors.Is(err, types.ErrFuture) {
			// If we do not have any cross-safe block yet, then return the first local-safe block.
			first, err := lDB.First()
			if err != nil {
				return types.DerivedBlockRefPair{}, fmt.Errorf("failed to find first local-safe block: %w", err)
			}
			// the first source (L1 block) is unlikely to be the genesis block,
			sourceRef, err := first.Source.WithParent(eth.BlockID{})
			if err != nil {
				// if the first source isn't the genesis block, just warn and continue anyway
				db.logger.Warn("First Source is not genesis block")
				sourceRef = first.Source.ForceWithParent(eth.BlockID{})
			}
			// the first derived must be the genesis block, panic otherwise
			derivedRef := first.Derived.MustWithParent(eth.BlockID{})
			return types.DerivedBlockRefPair{
				Source:  sourceRef,
				Derived: derivedRef,
			}, nil
		}
		return types.DerivedBlockRefPair{}, err
	}

	revision, err := xDB.SourceToRevision(crossSafe.Source.ID())
	if err != nil {
		return types.DerivedBlockRefPair{}, err
	}
	candidate, err := lDB.Candidate(crossSafe.Source.ID(), crossSafe.Derived.ID(), revision)
	if err != nil {
		// forward candidate value, even if error, in case a scope-bump is needed
		return candidate, err
	}
	db.logger.Debug("Determined cross-safe candidate block revision", "crossSafe", crossSafe)

	if candidate.Source.Number < crossSafe.Source.Number {
		db.logger.Error("Candidate block has lower source", "crossSafe", crossSafe, "candidate", candidate)
		return candidate, types.ErrDataCorruption
	}
	return candidate, nil
}

func (db *ChainsDB) PreviousCrossDerived(chain eth.ChainID, derived eth.BlockID) (prevDerived types.BlockSeal, err error) {
	xDB, ok := db.crossDBs.Get(chain)
	if !ok {
		return types.BlockSeal{}, types.ErrUnknownChain
	}
	revision, err := db.findRevision(chain, derived)
	if err != nil {
		return types.BlockSeal{}, err
	}
	return xDB.PreviousDerived(derived, revision)
}

func (db *ChainsDB) PreviousSource(chain eth.ChainID, source eth.BlockID) (prevSource types.BlockSeal, err error) {
	lDB, ok := db.localDBs.Get(chain)
	if !ok {
		return types.BlockSeal{}, types.ErrUnknownChain
	}
	return lDB.PreviousSource(source)
}

func (db *ChainsDB) NextSource(chain eth.ChainID, source eth.BlockID) (after eth.BlockRef, err error) {
	lDB, ok := db.localDBs.Get(chain)
	if !ok {
		return eth.BlockRef{}, types.ErrUnknownChain
	}
	v, err := lDB.NextSource(source)
	if err != nil {
		return eth.BlockRef{}, err
	}
	return v.MustWithParent(source), nil
}

func (db *ChainsDB) IteratorStartingAt(chain eth.ChainID, sealedNum uint64, logIndex uint32) (logs.Iterator, error) {
	logDB, ok := db.logDBs.Get(chain)
	if !ok {
		return nil, fmt.Errorf("%w: %v", types.ErrUnknownChain, chain)
	}
	return logDB.IteratorStartingAt(sealedNum, logIndex)
}

// AnchorPoint returns the first cross-safe block as anchor-point for interop.
func (db *ChainsDB) AnchorPoint(chainID eth.ChainID) (types.DerivedBlockSealPair, error) {
	xdb, ok := db.crossDBs.Get(chainID)
	if !ok {
		return types.DerivedBlockSealPair{}, types.ErrUnknownChain
	}
	return xdb.First()
}
