package logs

import (
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/log"

	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/db/entrydb"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/reads"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/types"
)

const (
	searchCheckpointFrequency    = 256
	eventFlagHasExecutingMessage = byte(1)
)

var (
	errIteratorStoppedButNoSealedBlock = errors.New("iterator stopped but no sealed block found")
	errUnexpectedLogSkip               = errors.New("unexpected log-skip")
)

type Metrics interface {
	RecordDBEntryCount(kind string, count int64)
	RecordDBSearchEntriesRead(count int64)
}

// DB implements an append only database for log data and cross-chain dependencies.
//
// To keep the append-only format, reduce data size, and support reorg detection and registering of executing-messages:
//
// Use a fixed 24 bytes per entry.
//
// Data is an append-only log, that can be binary searched for any necessary event data.
type DB struct {
	log    log.Logger
	m      Metrics
	store  entrydb.EntryStore[EntryType, Entry]
	rwLock sync.RWMutex

	chainID eth.ChainID

	lastEntryContext logContext
}

func NewFromFile(logger log.Logger, m Metrics, chainID eth.ChainID, path string, trimToLastSealed bool) (*DB, error) {
	store, err := entrydb.NewEntryDB[EntryType, Entry, EntryBinary](logger, path)
	if err != nil {
		return nil, fmt.Errorf("failed to open DB: %w", err)
	}
	return NewFromEntryStore(logger, m, chainID, store, trimToLastSealed)
}

func NewFromEntryStore(logger log.Logger, m Metrics, chainID eth.ChainID, store entrydb.EntryStore[EntryType, Entry], trimToLastSealed bool) (*DB, error) {
	db := &DB{
		log:     logger,
		m:       m,
		store:   store,
		chainID: chainID,
	}
	if err := db.init(trimToLastSealed); err != nil {
		return nil, fmt.Errorf("failed to init database: %w", err)
	}
	return db, nil
}

func (db *DB) lastEntryIdx() entrydb.EntryIdx {
	return db.store.LastEntryIdx()
}

func (db *DB) init(trimToLastSealed bool) error {
	defer db.updateEntryCountMetric() // Always update the entry count metric after init completes
	if trimToLastSealed {
		if err := db.trimToLastSealed(); err != nil {
			return fmt.Errorf("failed to trim invalid trailing entries: %w", err)
		}
	}
	if db.lastEntryIdx() < 0 {
		// Database is empty.
		// Make a state that is ready to apply the genesis block on top of as first entry.
		// This will infer into a checkpoint (half of the block seal here)
		// and is then followed up with canonical-hash entry of genesis.
		db.lastEntryContext = logContext{
			nextEntryIndex: 0,
			blockHash:      common.Hash{},
			blockNum:       0,
			timestamp:      0,
			logsSince:      0,
			logHash:        common.Hash{},
			execMsg:        nil,
			out:            nil,
		}
		return nil
	}
	// start at the last checkpoint,
	// and then apply any remaining changes on top, to hydrate the state.
	lastCheckpoint := (db.lastEntryIdx() / searchCheckpointFrequency) * searchCheckpointFrequency
	i := db.newIterator(lastCheckpoint)
	i.current.need.Add(FlagCanonicalHash)
	if err := i.End(); err != nil {
		return fmt.Errorf("failed to init from remaining trailing data: %w", err)
	}
	db.lastEntryContext = i.current
	return nil
}

func (db *DB) trimToLastSealed() error {
	i := db.lastEntryIdx()
	for ; i >= 0; i-- {
		entry, err := db.store.Read(i)
		if err != nil {
			return fmt.Errorf("failed to read %v to check for trailing entries: %w", i, err)
		}
		if entry.Type() == TypeCanonicalHash {
			// only an executing hash, indicating a sealed block, is a valid point for restart
			break
		}
	}
	if i < db.lastEntryIdx() {
		db.log.Warn("Truncating unexpected trailing entries", "prev", db.lastEntryIdx(), "new", i)
		// trim such that the last entry is the canonical-hash we identified
		return db.store.Truncate(i)
	}
	return nil
}

func (db *DB) updateEntryCountMetric() {
	db.m.RecordDBEntryCount("log", db.store.Size())
}

func (db *DB) IsEmpty() bool {
	db.rwLock.RLock()
	defer db.rwLock.RUnlock()
	return db.lastEntryContext.nextEntryIndex == 0
}

func (db *DB) IteratorStartingAt(sealedNum uint64, logsSince uint32) (Iterator, error) {
	db.rwLock.RLock()
	defer db.rwLock.RUnlock()
	return db.newIteratorAt(sealedNum, logsSince)
}

// FindSealedBlock finds the requested block, to check if it exists,
// returning the next index after it where things continue from.
// returns ErrFuture if the block is too new to be able to tell
// returns ErrDifferent if the known block does not match
func (db *DB) FindSealedBlock(number uint64) (seal types.BlockSeal, err error) {
	db.rwLock.RLock()
	defer db.rwLock.RUnlock()
	iter, err := db.newIteratorAt(number, 0)
	if errors.Is(err, types.ErrFuture) {
		return types.BlockSeal{}, fmt.Errorf("block %d is not known yet: %w", number, types.ErrFuture)
	} else if err != nil {
		return types.BlockSeal{}, fmt.Errorf("failed to find sealed block %d: %w", number, err)
	}
	h, n, ok := iter.SealedBlock()
	if !ok {
		panic("expected block")
	}
	if n != number {
		panic(fmt.Sprintf("found block seal %s %d does not match expected block number %d", h, n, number))
	}
	timestamp, ok := iter.SealedTimestamp()
	if !ok {
		panic("expected timestamp")
	}
	return types.BlockSeal{
		Hash:      h,
		Number:    n,
		Timestamp: timestamp,
	}, nil
}

// FirstSealedBlock returns the first block seal in the DB, if any.
func (db *DB) FirstSealedBlock() (seal types.BlockSeal, err error) {
	db.rwLock.RLock()
	defer db.rwLock.RUnlock()
	iter := db.newIterator(0)
	if err := iter.NextBlock(); err != nil {
		return types.BlockSeal{}, err
	}
	h, n, _ := iter.SealedBlock()
	t, _ := iter.SealedTimestamp()
	return types.BlockSeal{
		Hash:      h,
		Number:    n,
		Timestamp: t,
	}, nil
}

// OpenBlock returns the Executing Messages for the block at the given number.
// it returns identification of the block, the parent block, and the executing messages.
func (db *DB) OpenBlock(blockNum uint64) (ref eth.BlockRef, logCount uint32, execMsgs map[uint32]*types.ExecutingMessage, retErr error) {
	db.rwLock.RLock()
	defer db.rwLock.RUnlock()

	// Note: newIteratorAt below handles the not-at-genesis interop start case.
	// But here we explicitly handle blockNum 0 to avoid a block number underflow.
	if blockNum == 0 {
		seal, err := db.FirstSealedBlock()
		if err != nil {
			retErr = err
			return
		}
		if seal.Number != 0 {
			return eth.BlockRef{}, 0, nil, fmt.Errorf("looked for block 0 but got %s: %w", seal, types.ErrSkipped)
		}
		ref = eth.BlockRef{
			Hash:       seal.Hash,
			Number:     seal.Number,
			ParentHash: common.Hash{},
			Time:       seal.Timestamp,
		}
		logCount = 0
		execMsgs = nil
		return
	}

	// start at the first log (if any) after the block-seal of the parent block
	blockIter, err := db.newIteratorAt(blockNum-1, 0)
	if err != nil {
		retErr = err
		return
	}
	// register the parent block
	parentHash, _, ok := blockIter.SealedBlock()
	if ok {
		ref.ParentHash = parentHash
	}
	// walk to the end of the block, and remember what we see in the block.
	logCount = 0
	execMsgs = make(map[uint32]*types.ExecutingMessage, 0)
	retErr = blockIter.TraverseConditional(func(state IteratorState) error {
		_, logIndex, ok := state.InitMessage()
		if ok {
			logCount = logIndex + 1
		}
		if m := state.ExecMessage(); m != nil {
			execMsgs[logIndex] = m
		}
		h, n, ok := state.SealedBlock()
		if !ok {
			return nil
		}
		if n == blockNum {
			ref.Number = n
			ref.Hash = h
			ref.Time, _ = state.SealedTimestamp()
			return types.ErrStop
		}
		if n > blockNum {
			return fmt.Errorf("expected to run into block %d, but did not find it, found %d: %w", blockNum, n, types.ErrDataCorruption)
		}
		return nil
	})
	if errors.Is(retErr, types.ErrStop) {
		retErr = nil
	}
	return
}

// LatestSealedBlock returns the block ID of the block that was last sealed,
// or ok=false if there is no sealed block (i.e. empty DB)
func (db *DB) LatestSealedBlock() (id eth.BlockID, ok bool) {
	db.rwLock.RLock()
	defer db.rwLock.RUnlock()
	if db.lastEntryContext.nextEntryIndex == 0 {
		return eth.BlockID{}, false // empty DB, time to add the first seal
	}
	if !db.lastEntryContext.hasCompleteBlock() {
		db.log.Debug("New block is already in progress", "num", db.lastEntryContext.blockNum)
		// TODO: is the hash invalid here. When we have a read-lock, can this ever happen?
	}
	return eth.BlockID{
		Hash:   db.lastEntryContext.blockHash,
		Number: db.lastEntryContext.blockNum,
	}, true
}

// Contains returns no error iff the specified logHash is recorded in the specified blockNum and logIdx.
// If the log is out of reach and the block is complete, an ErrConflict is returned.
// If the log is out of reach and the block is not complete, an ErrFuture is returned.
// If the log is determined to conflict with the canonical chain, then ErrConflict is returned.
// logIdx is the index of the log in the array of all logs in the block.
// This can be used to check the validity of cross-chain interop events.
// The block-seal of the blockNum block, that the log was included in, is returned.
// This seal may be fully zeroed, without error, if the block isn't fully known yet.
func (db *DB) Contains(query types.ContainsQuery) (types.BlockSeal, error) {
	blockNum, logIdx, timestamp := query.BlockNum, query.LogIdx, query.Timestamp
	db.rwLock.RLock()
	defer db.rwLock.RUnlock()
	db.log.Trace("Checking for log", "blockNum", blockNum, "logIdx", logIdx)

	// Hot-path: check if we have the block
	if db.lastEntryContext.hasCompleteBlock() && db.lastEntryContext.blockNum < blockNum {
		// it is possible that while the included Block Number is beyond the end of the database,
		// the included timestamp is within the database. In this case we know the request is not just a ErrFuture,
		// but a ErrConflict, as we know the request will not be included in the future.
		if db.lastEntryContext.timestamp > timestamp {
			return types.BlockSeal{}, types.ErrConflict
		}
		return types.BlockSeal{}, types.ErrFuture
	}

	entryLogHash, iter, err := db.findLogInfo(blockNum, logIdx)
	if err != nil {
		// if we get an ErrFuture but have a complete block, then we really have a conflict
		if errors.Is(err, types.ErrFuture) && db.lastEntryContext.hasCompleteBlock() {
			return types.BlockSeal{}, types.ErrConflict
		}
		return types.BlockSeal{}, err // may be ErrConflict if the block does not have as many logs
	}
	db.log.Trace("Found initiatingEvent", "blockNum", blockNum, "logIdx", logIdx, "hash", entryLogHash)
	// Now find the block seal after the log, to identify where the log was included in.
	err = iter.TraverseConditional(func(state IteratorState) error {
		_, n, ok := state.SealedBlock()
		if !ok { // incomplete block data
			return nil
		}
		if n == blockNum {
			return types.ErrStop
		}
		if n > blockNum {
			return types.ErrDataCorruption
		}
		return nil
	})
	if err == nil {
		panic("expected iterator to stop with error")
	}
	// ErrStop indicates we've found the block, and the iterator is positioned at it.
	if errors.Is(err, types.ErrStop) {
		h, n, ok := iter.SealedBlock()
		if !ok {
			return types.BlockSeal{}, errIteratorStoppedButNoSealedBlock
		}
		t, _ := iter.SealedTimestamp()
		// check the timestamp invariant on the result
		if t != timestamp {
			return types.BlockSeal{}, fmt.Errorf("timestamp mismatch: expected %d, got %d %w", timestamp, t, types.ErrConflict)
		}
		entryChecksum := types.ChecksumArgs{
			BlockNumber: n,
			LogIndex:    logIdx,
			Timestamp:   t,
			ChainID:     db.chainID,
			LogHash:     entryLogHash,
		}.Checksum()
		// Found the requested block and log index, check if the hash matches
		if entryChecksum != query.Checksum {
			return types.BlockSeal{}, fmt.Errorf("payload hash mismatch: expected %s, got %s %w", query.Checksum, entryChecksum, types.ErrConflict)
		}
		// construct a block seal with the found data now that we know it's correct
		return types.BlockSeal{
			Hash:      h,
			Number:    n,
			Timestamp: t,
		}, nil
	}
	return types.BlockSeal{}, err
}

// findLogInfo returns the hash of the log at the specified block number and log index.
// If a log isn't found at the index we return an ErrFuture, even if the block is complete.
func (db *DB) findLogInfo(blockNum uint64, logIdx uint32) (common.Hash, Iterator, error) {
	if blockNum == 0 {
		return common.Hash{}, nil, types.ErrConflict // no logs in block 0
	}
	// blockNum-1, such that we find a log that came after the parent num-1 was sealed.
	// logIdx, such that all entries before logIdx can be skipped, but logIdx itself is still readable.
	iter, err := db.newIteratorAt(blockNum-1, logIdx)
	if errors.Is(err, types.ErrFuture) {
		db.log.Trace("Could not find log yet", "blockNum", blockNum, "logIdx", logIdx)
		return common.Hash{}, nil, err
	} else if err != nil {
		db.log.Error("Failed searching for log", "blockNum", blockNum, "logIdx", logIdx)
		return common.Hash{}, nil, err
	}
	if err := iter.NextInitMsg(); err != nil {
		return common.Hash{}, nil, fmt.Errorf("failed to read initiating message %d, on top of block %d: %w", logIdx, blockNum, err)
	}
	if _, x, ok := iter.SealedBlock(); !ok {
		panic("expected block")
	} else if x < blockNum-1 {
		panic(fmt.Sprintf("bug in newIteratorAt, expected to have found parent block %d but got %d", blockNum-1, x))
	} else if x > blockNum-1 {
		return common.Hash{}, nil, fmt.Errorf("log does not exist, found next block already: %w", types.ErrConflict)
	}
	logHash, x, ok := iter.InitMessage()
	if !ok {
		panic("expected init message")
	} else if x != logIdx {
		panic(fmt.Sprintf("bug in newIteratorAt, expected to have found log %d but got %d", logIdx, x))
	}
	return logHash, iter, nil
}

// newIteratorAt returns an iterator ready after the given sealed block number,
// and positioned such that the next log-read on the iterator return the log with logIndex, if any.
// It may return an ErrNotFound if the block number is unknown,
// or if there are just not that many seen log events after the block as requested.
func (db *DB) newIteratorAt(blockNum uint64, logIndex uint32) (*iterator, error) {
	// find a checkpoint before or exactly when blockNum was sealed,
	// and have processed up to but not including [logIndex] number of logs (i.e. all prior logs, if any).
	searchCheckpointIndex, err := db.searchCheckpoint(blockNum, logIndex)
	if errors.Is(err, io.EOF) {
		// Did not find a checkpoint to start reading from so the log cannot be present.
		return nil, types.ErrFuture
	} else if err != nil {
		return nil, err
	}
	// The iterator did not consume the checkpoint yet, it's positioned right at it.
	// So we can call NextBlock() and get the checkpoint itself as first entry.
	iter := db.newIterator(searchCheckpointIndex)
	iter.current.need.Add(FlagCanonicalHash)
	defer func() {
		db.m.RecordDBSearchEntriesRead(iter.entriesRead)
	}()
	// First walk up to the block that we are sealed up to (incl.)
	for {
		if _, n, ok := iter.SealedBlock(); ok && n == blockNum { // we may already have it exactly
			break
		}
		if err := iter.NextBlock(); errors.Is(err, types.ErrFuture) {
			db.log.Trace("ran out of data, could not find block", "nextIndex", iter.NextIndex(), "target", blockNum)
			return nil, types.ErrFuture
		} else if err != nil {
			db.log.Error("failed to read next block", "nextIndex", iter.NextIndex(), "target", blockNum, "err", err)
			return nil, err
		}
		h, num, ok := iter.SealedBlock()
		if !ok {
			panic("expected sealed block")
		}
		db.log.Trace("found sealed block", "num", num, "hash", h)
		if num < blockNum {
			continue
		}
		if num != blockNum { // block does not contain
			return nil, fmt.Errorf("looking for %d, but already at %d: %w", blockNum, num, types.ErrConflict)
		}
		break
	}
	// Now walk up to the number of seen logs that we want to have processed.
	// E.g. logIndex == 2, need to have processed index 0 and 1,
	// so two logs before quitting (and not 3 to then quit after).
	for iter.current.logsSince < logIndex {
		if err := iter.NextInitMsg(); err == io.EOF {
			return nil, types.ErrFuture
		} else if err != nil {
			return nil, err
		}
		_, num, ok := iter.SealedBlock()
		if !ok {
			panic("expected sealed block")
		}
		if num > blockNum {
			// we overshot, the block did not contain as many seen log events as requested
			return nil, types.ErrConflict
		}
		_, idx, ok := iter.InitMessage()
		if !ok {
			panic("expected initializing message")
		}
		if idx+1 < logIndex {
			continue
		}
		if idx+1 == logIndex {
			break // the NextInitMsg call will position the iterator at the re
		}
		return nil, fmt.Errorf("%w: at block %d log %d", errUnexpectedLogSkip, blockNum, idx)
	}
	return iter, nil
}

// newIterator creates an iterator at the given index.
// None of the iterator attributes will be ready for reads,
// but the entry at the given index will be first read when using the iterator.
func (db *DB) newIterator(index entrydb.EntryIdx) *iterator {
	return &iterator{
		db: db,
		current: logContext{
			nextEntryIndex: index,
		},
	}
}

// searchCheckpoint performs a binary search of the searchCheckpoint entries
// to find the closest one with an equal or lower block number and equal or lower amount of seen logs.
// Returns the index of the searchCheckpoint to begin reading from or an error.
func (db *DB) searchCheckpoint(sealedBlockNum uint64, logsSince uint32) (entrydb.EntryIdx, error) {
	if db.lastEntryContext.nextEntryIndex == 0 {
		return 0, types.ErrFuture // empty DB, everything is in the future
	}
	n := (db.lastEntryIdx() / searchCheckpointFrequency) + 1
	// Define: x is the array of known checkpoints
	// Invariant: x[i] <= target, x[j] > target.
	i, j := entrydb.EntryIdx(0), n
	for i+1 < j { // i is inclusive, j is exclusive.
		// Get the checkpoint exactly in-between,
		// bias towards a higher value if an even number of checkpoints.
		// E.g. i=3 and j=4 would not run, since i + 1 < j
		// E.g. i=3 and j=5 leaves checkpoints 3, 4, and we pick 4 as pivot
		// E.g. i=3 and j=6 leaves checkpoints 3, 4, 5, and we pick 4 as pivot
		//
		// The following holds: i ≤ h < j
		h := entrydb.EntryIdx((uint64(i) + uint64(j)) >> 1)
		checkpoint, err := db.readSearchCheckpoint(h * searchCheckpointFrequency)
		if err != nil {
			return 0, fmt.Errorf("failed to read entry %v: %w", h, err)
		}
		if checkpoint.blockNum < sealedBlockNum ||
			(checkpoint.blockNum == sealedBlockNum && checkpoint.logsSince < logsSince) {
			i = h
		} else {
			j = h
		}
	}
	if i+1 != j {
		panic("expected to have 1 checkpoint left")
	}
	result := i * searchCheckpointFrequency
	checkpoint, err := db.readSearchCheckpoint(result)
	if err != nil {
		return 0, fmt.Errorf("failed to read final search checkpoint result: %w", err)
	}
	if checkpoint.blockNum > sealedBlockNum ||
		(checkpoint.blockNum == sealedBlockNum && checkpoint.logsSince > logsSince) {
		return 0, fmt.Errorf("missing data, earliest search checkpoint is %d with %d logs, cannot find something before or at %d with %d logs: %w",
			checkpoint.blockNum, checkpoint.logsSince, sealedBlockNum, logsSince, types.ErrSkipped)
	}
	return result, nil
}

// debug util to log the last 10 entries of the chain
func (db *DB) debugTip() {
	for x := 0; x < 10; x++ {
		index := db.lastEntryIdx() - entrydb.EntryIdx(x)
		if index < 0 {
			continue
		}
		e, err := db.store.Read(index)
		if err == nil {
			db.log.Debug("tip", "index", index, "type", e.Type())
		}
	}
}

func (db *DB) flush() error {
	for i, e := range db.lastEntryContext.out {
		db.log.Trace("appending entry", "type", e.Type(), "entry", hexutil.Bytes(e[:]),
			"next", int(db.lastEntryContext.nextEntryIndex)-len(db.lastEntryContext.out)+i)
	}
	if err := db.store.Append(db.lastEntryContext.out...); err != nil {
		return fmt.Errorf("failed to append entries: %w", err)
	}
	db.lastEntryContext.out = db.lastEntryContext.out[:0]
	db.updateEntryCountMetric()
	return nil
}

func (db *DB) SealBlock(parentHash common.Hash, block eth.BlockID, timestamp uint64) error {
	db.rwLock.Lock()
	defer db.rwLock.Unlock()

	if err := db.lastEntryContext.SealBlock(parentHash, block, timestamp); err != nil {
		return fmt.Errorf("failed to seal block: %w", err)
	}
	db.log.Trace("Sealed block", "parent", parentHash, "block", block, "timestamp", timestamp)
	return db.flush()
}

func (db *DB) AddLog(logHash common.Hash, parentBlock eth.BlockID, logIdx uint32, execMsg *types.ExecutingMessage) error {
	db.rwLock.Lock()
	defer db.rwLock.Unlock()

	if err := db.lastEntryContext.ApplyLog(parentBlock, logIdx, logHash, execMsg); err != nil {
		return fmt.Errorf("failed to apply log: %w", err)
	}
	db.log.Trace("Applied log", "parentBlock", parentBlock, "logIndex", logIdx, "logHash", logHash, "executing", execMsg != nil)
	return db.flush()
}

// Rewind the database to remove any blocks after headBlockNum
// The block at newHead.Number itself is not removed.
func (db *DB) Rewind(inv reads.Invalidator, newHead eth.BlockID) error {
	db.rwLock.Lock()
	defer db.rwLock.Unlock()
	// Even if the last fully-processed block matches headBlockNum,
	// we might still have trailing log events to get rid of.
	iter, err := db.newIteratorAt(newHead.Number, 0)
	if err != nil {
		return err
	}
	if hash, num, ok := iter.SealedBlock(); !ok {
		return fmt.Errorf("expected sealed block for rewind reference-point: %w", types.ErrDataCorruption)
	} else if hash != newHead.Hash {
		return fmt.Errorf("cannot rewind to %s, have %s: %w", newHead, eth.BlockID{Hash: hash, Number: num}, types.ErrConflict)
	}
	t, ok := iter.SealedTimestamp()
	if !ok {
		panic("expected timestamp in block seal")
	}
	release, err := inv.TryInvalidate(reads.DerivedInvalidation{Timestamp: t})
	if err != nil {
		return err
	}
	defer release()
	// Truncate to contain idx entries. The Truncate func keeps the given index as last index.
	if err := db.store.Truncate(iter.NextIndex() - 1); err != nil {
		return fmt.Errorf("failed to truncate to block %s: %w", newHead, err)
	}
	// Use db.init() to find the log context for the new latest log entry
	if err := db.init(true); err != nil {
		return fmt.Errorf("failed to find new last entry context: %w", err)
	}
	return nil
}

func (db *DB) readSearchCheckpoint(entryIdx entrydb.EntryIdx) (searchCheckpoint, error) {
	data, err := db.store.Read(entryIdx)
	if err != nil {
		return searchCheckpoint{}, fmt.Errorf("failed to read entry %v: %w", entryIdx, err)
	}
	return newSearchCheckpointFromEntry(data)
}

func (db *DB) Close() error {
	return db.store.Close()
}
