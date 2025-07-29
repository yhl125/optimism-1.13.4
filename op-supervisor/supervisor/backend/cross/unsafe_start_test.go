package cross

import (
	"errors"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/stretchr/testify/require"

	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/depset"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/types"
)

func TestCrossUnsafeHazards(t *testing.T) {
	t.Run("empty execMsgs", func(t *testing.T) {
		usd := &mockUnsafeStartDeps{}
		chainID := eth.ChainIDFromUInt64(123)
		candidate := types.BlockSeal{}
		// when there are no execMsgs,
		// no work is done, and no error is returned
		hazards, err := CrossUnsafeHazards(usd, linkerAny{}, newTestLogger(t), chainID, candidate)
		require.NoError(t, err)
		require.Empty(t, hazards.Entries())
	})
	t.Run("CanExecute returns false", func(t *testing.T) {
		usd := &mockUnsafeStartDeps{}
		chainID := eth.ChainIDFromUInt64(123)
		candidate := types.BlockSeal{}
		usd.openBlockFn = newOpenBlockFn(&types.ExecutingMessage{})
		// when there is one execMsg, and CanExecuteAt returns false,
		// no work is done and an error is returned
		hazards, err := CrossUnsafeHazards(usd, linkerNone{}, newTestLogger(t), chainID, candidate)
		require.ErrorIs(t, err, types.ErrConflict)
		require.Empty(t, hazards.Entries())
	})
	t.Run("executing msg does bad link", func(t *testing.T) {
		usd := &mockUnsafeStartDeps{}
		done := false
		linker := depset.LinkCheckFn(func(execInChain eth.ChainID, execInTimestamp uint64, initChainID eth.ChainID, initTimestamp uint64) bool {
			done = true
			require.Equal(t, execInChain, eth.ChainIDFromUInt64(123))
			require.Equal(t, execInTimestamp, uint64(9000))
			require.Equal(t, initChainID, eth.ChainIDFromUInt64(0xbad))
			require.Equal(t, initTimestamp, uint64(42))
			// doesn't matter what is bad, we checked we have all the inputs for all possible cases.
			return false
		})
		chainID := eth.ChainIDFromUInt64(123)
		candidate := types.BlockSeal{Timestamp: uint64(9000)}
		usd.openBlockFn = newOpenBlockFn(&types.ExecutingMessage{
			ChainID:   eth.ChainIDFromUInt64(0xbad),
			Timestamp: 42,
		})
		// when there is one execMsg, and CanInitiateAt returns false,
		// the error is returned as a ErrConflict
		hazards, err := CrossUnsafeHazards(usd, linker, newTestLogger(t), chainID, candidate)
		require.ErrorIs(t, err, types.ErrConflict)
		require.Empty(t, hazards.Entries())
		require.True(t, done)
	})
	t.Run("timestamp is greater than candidate", func(t *testing.T) {
		usd := &mockUnsafeStartDeps{}
		chainID := eth.ChainIDFromUInt64(123)
		candidate := types.BlockSeal{Timestamp: 2}
		em1 := &types.ExecutingMessage{ChainID: chainID, Timestamp: 10}
		usd.openBlockFn = newOpenBlockFn(em1)
		// when there is one execMsg, and the timestamp is greater than the candidate,
		// an error is returned
		hazards, err := CrossUnsafeHazards(usd, linkerAny{}, newTestLogger(t), chainID, candidate)
		require.ErrorContains(t, err, "breaks timestamp invariant")
		require.Empty(t, hazards.Entries())
	})
	t.Run("timestamp is equal, Check returns error", func(t *testing.T) {
		usd := &mockUnsafeStartDeps{}
		usd.checkFn = func() (includedIn types.BlockSeal, err error) {
			return types.BlockSeal{}, errors.New("some error")
		}
		chainID := eth.ChainIDFromUInt64(123)
		candidate := types.BlockSeal{Timestamp: 2}
		em1 := &types.ExecutingMessage{ChainID: chainID, Timestamp: 2}
		usd.openBlockFn = newOpenBlockFn(em1)
		// when there is one execMsg, and the timestamp is equal to the candidate,
		// and check returns an error,
		// that error is returned
		hazards, err := CrossUnsafeHazards(usd, linkerAny{}, newTestLogger(t), chainID, candidate)
		require.ErrorContains(t, err, "some error")
		require.Empty(t, hazards.Entries())
	})
	t.Run("timestamp is equal, same hazard twice", func(t *testing.T) {
		usd := &mockUnsafeStartDeps{}
		sampleBlockSeal := types.BlockSeal{Number: 3, Hash: common.BytesToHash([]byte{0x03}), Timestamp: 1}
		usd.checkFn = func() (includedIn types.BlockSeal, err error) {
			return sampleBlockSeal, nil
		}
		chainID := eth.ChainIDFromUInt64(123)
		candidate := types.BlockSeal{Hash: common.BytesToHash([]byte{0x04}), Number: 4, Timestamp: 2}
		em1 := &types.ExecutingMessage{ChainID: chainID, Timestamp: 2}
		em2 := &types.ExecutingMessage{ChainID: chainID, Timestamp: 2}
		usd.openBlockFn = func(chainID eth.ChainID, blockNum uint64) (ref eth.BlockRef, logCount uint32, execMsgs map[uint32]*types.ExecutingMessage, err error) {
			if blockNum == 4 {
				return eth.BlockRef{
					Hash:   candidate.Hash,
					Number: candidate.Number,
					Time:   candidate.Timestamp,
				}, 2, map[uint32]*types.ExecutingMessage{0: em1, 1: em2}, nil
			}
			return eth.BlockRef{
				Hash:   sampleBlockSeal.Hash,
				Number: sampleBlockSeal.Number,
				Time:   sampleBlockSeal.Timestamp,
			}, 0, nil, nil
		}
		// when there are two execMsgs, and both are equal time to the candidate,
		// and check returns the same includedIn for both
		// they load the hazards once, and return no error
		hazards, err := CrossUnsafeHazards(usd, linkerAny{}, newTestLogger(t), chainID, candidate)
		require.NoError(t, err)
		require.Equal(t, map[eth.ChainID]types.BlockSeal{chainID: sampleBlockSeal}, hazards.Entries())
	})
	t.Run("timestamp is equal, different hazards", func(t *testing.T) {
		usd := &mockUnsafeStartDeps{}
		// set the check function to return a different BlockSeal for the second call
		sampleBlockSeal := types.BlockSeal{Number: 3, Hash: common.BytesToHash([]byte{0x02})}
		sampleBlockSeal2 := types.BlockSeal{Number: 333, Hash: common.BytesToHash([]byte{0x22})}
		calls := 0
		usd.checkFn = func() (includedIn types.BlockSeal, err error) {
			defer func() { calls++ }()
			if calls == 0 {
				return sampleBlockSeal, nil
			}
			return sampleBlockSeal2, nil
		}
		chainID := eth.ChainIDFromUInt64(123)
		candidate := types.BlockSeal{Timestamp: 2}
		em1 := &types.ExecutingMessage{ChainID: chainID, Timestamp: 2}
		em2 := &types.ExecutingMessage{ChainID: chainID, Timestamp: 2}
		usd.openBlockFn = newOpenBlockFn(em1, em2)
		// when there are two execMsgs, and both are equal time to the candidate,
		// and check returns different includedIn for the two,
		// an error is returned
		hazards, err := CrossUnsafeHazards(usd, linkerAny{}, newTestLogger(t), chainID, candidate)
		require.ErrorContains(t, err, "but already depend on")
		require.Empty(t, hazards.Entries())
	})
	t.Run("timestamp is less, check returns error", func(t *testing.T) {
		usd := &mockUnsafeStartDeps{}
		usd.checkFn = func() (includedIn types.BlockSeal, err error) {
			return types.BlockSeal{}, errors.New("some error")
		}
		chainID := eth.ChainIDFromUInt64(123)
		candidate := types.BlockSeal{Timestamp: 2}
		em1 := &types.ExecutingMessage{ChainID: chainID, Timestamp: 1}
		usd.openBlockFn = newOpenBlockFn(em1)
		// when there is one execMsg, and the timestamp is less than the candidate,
		// and check returns an error,
		// that error is returned
		hazards, err := CrossUnsafeHazards(usd, linkerAny{}, newTestLogger(t), chainID, candidate)
		require.ErrorContains(t, err, "some error")
		require.Empty(t, hazards.Entries())
	})
	t.Run("timestamp is less, IsCrossUnsafe returns error", func(t *testing.T) {
		usd := &mockUnsafeStartDeps{}
		sampleBlockSeal := types.BlockSeal{Number: 3, Hash: common.BytesToHash([]byte{0x02})}
		usd.checkFn = func() (includedIn types.BlockSeal, err error) {
			return sampleBlockSeal, nil
		}
		usd.isCrossUnsafeFn = func() error {
			return errors.New("some error")
		}
		chainID := eth.ChainIDFromUInt64(123)
		candidate := types.BlockSeal{Timestamp: 2}
		em1 := &types.ExecutingMessage{ChainID: chainID, Timestamp: 1}
		usd.openBlockFn = newOpenBlockFn(em1)
		// when there is one execMsg, and the timestamp is less than the candidate,
		// and IsCrossUnsafe returns an error,
		// that error is returned
		hazards, err := CrossUnsafeHazards(usd, linkerAny{}, newTestLogger(t), chainID, candidate)
		require.ErrorContains(t, err, "some error")
		require.Empty(t, hazards.Entries())
	})
	t.Run("timestamp is less, IsCrossUnsafe", func(t *testing.T) {
		usd := &mockUnsafeStartDeps{}
		sampleBlockSeal := types.BlockSeal{Number: 3, Hash: common.BytesToHash([]byte{0x02})}
		usd.checkFn = func() (includedIn types.BlockSeal, err error) {
			return sampleBlockSeal, nil
		}
		usd.isCrossUnsafeFn = func() error {
			return nil
		}
		chainID := eth.ChainIDFromUInt64(123)
		candidate := types.BlockSeal{Timestamp: 2}
		em1 := &types.ExecutingMessage{ChainID: chainID, Timestamp: 0}
		usd.openBlockFn = newOpenBlockFn(em1)
		// when there is one execMsg, and the timestamp is less than the candidate,
		// and IsCrossUnsafe returns no error,
		// no error is returned
		hazards, err := CrossUnsafeHazards(usd, linkerAny{}, newTestLogger(t), chainID, candidate)
		require.NoError(t, err)
		require.Empty(t, hazards.Entries())
	})
	t.Run("message near expiry", func(t *testing.T) {
		logger := newTestLogger(t)
		usd := &mockUnsafeStartDeps{}
		sampleBlockSeal := types.BlockSeal{Timestamp: 1}
		usd.checkFn = func() (includedIn types.BlockSeal, err error) {
			return sampleBlockSeal, nil
		}
		chainID := eth.ChainIDFromUInt64(123)
		candidate := types.BlockSeal{Timestamp: 11}
		em1 := &types.ExecutingMessage{ChainID: chainID, Timestamp: 1}
		usd.openBlockFn = newOpenBlockFn(em1)
		linker := depset.LinkCheckFn(func(execInChain eth.ChainID, execInTimestamp uint64, initChainID eth.ChainID, initTimestamp uint64) bool {
			require.Equal(t, uint64(11), execInTimestamp)
			require.Equal(t, uint64(1), initTimestamp)
			return true
		})
		// when there is one execMsg that is near expiry, then no error is returned
		hazards, err := CrossUnsafeHazards(usd, linker, logger, chainID, candidate)
		require.NoError(t, err)
		require.Empty(t, hazards.Entries())
	})
}

type mockUnsafeStartDeps struct {
	checkFn         func() (includedIn types.BlockSeal, err error)
	isCrossUnsafeFn func() error
	openBlockFn     func(chainID eth.ChainID, blockNum uint64) (ref eth.BlockRef, logCount uint32, execMsgs map[uint32]*types.ExecutingMessage, err error)
}

func (m *mockUnsafeStartDeps) Contains(chain eth.ChainID, q types.ContainsQuery) (includedIn types.BlockSeal, err error) {
	if m.checkFn != nil {
		return m.checkFn()
	}
	return types.BlockSeal{}, nil
}

func (m *mockUnsafeStartDeps) IsCrossUnsafe(chainID eth.ChainID, derived eth.BlockID) error {
	if m.isCrossUnsafeFn != nil {
		return m.isCrossUnsafeFn()
	}
	return nil
}

func (m *mockUnsafeStartDeps) OpenBlock(chainID eth.ChainID, blockNum uint64) (ref eth.BlockRef, logCount uint32, execMsgs map[uint32]*types.ExecutingMessage, err error) {
	if m.openBlockFn != nil {
		return m.openBlockFn(chainID, blockNum)
	}
	// Default implementation returns block with matching timestamp to avoid invariant errors
	// Return timestamp matching the candidate timestamp
	execMsgs = make(map[uint32]*types.ExecutingMessage)
	return eth.BlockRef{Number: blockNum}, uint32(len(execMsgs)), execMsgs, nil
}

func newOpenBlockFn(ems ...*types.ExecutingMessage) func(chainID eth.ChainID, blockNum uint64) (ref eth.BlockRef, logCount uint32, execMsgs map[uint32]*types.ExecutingMessage, err error) {
	execMsgs := make(map[uint32]*types.ExecutingMessage)
	for i, em := range ems {
		execMsgs[uint32(i)] = em
	}
	return func(chainID eth.ChainID, blockNum uint64) (eth.BlockRef, uint32, map[uint32]*types.ExecutingMessage, error) {
		return eth.BlockRef{}, uint32(len(execMsgs)), execMsgs, nil
	}
}
