package reorgs

import (
	"testing"
	"time"

	"github.com/ethereum-optimism/optimism/op-devstack/devtest"
	"github.com/ethereum-optimism/optimism/op-devstack/presets"
	"github.com/ethereum-optimism/optimism/op-e2e/e2eutils/wait"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-service/txplan"
	"github.com/ethereum-optimism/optimism/op-test-sequencer/sequencer/seqtypes"
	"github.com/stretchr/testify/require"
)

// TestReorgUnsafeHead starts an interop chain with an op-test-sequencer, which takes control over sequencing the L2 chain and introduces a reorg on the unsafe head
func TestReorgUnsafeHead(gt *testing.T) {
	t := devtest.SerialT(gt)
	ctx := t.Ctx()

	sys := presets.NewSimpleInterop(t)
	l := sys.Log

	ia := sys.TestSequencer.Escape().ControlAPI(sys.L2ChainA.ChainID())

	// stop batcher on chain A
	sys.L2BatcherA.Stop()

	// two EOAs for a sample transfer tx used later in a conflicting block
	alice := sys.FunderA.NewFundedEOA(eth.OneEther)
	bob := sys.Wallet.NewEOA(sys.L2ELA)

	sys.L1Network.WaitForBlock()

	sys.L2ChainA.WaitForBlock()
	// waiting for two blocks in order to make sure we are not jumping ahead of a L1 origin (i.e. can't build a chain with L1Origin gaps)
	sys.L2ChainA.WaitForBlock()
	sys.L2ChainA.WaitForBlock()

	unsafeHead := sys.L2CLA.StopSequencer()

	var divergenceBlockNumber_A uint64
	var originalRef_A eth.L2BlockRef
	// prepare and sequence a conflicting block for the L2A chain
	{
		unsafeHeadRef := sys.L2ELA.BlockRefByLabel(eth.Unsafe)

		l.Info("Current unsafe ref", "unsafeHead", unsafeHead, "parent", unsafeHeadRef.ParentID().Hash, "l1_origin", unsafeHeadRef.L1Origin)

		l.Info("Expect to reorg the chain on current unsafe block", "number", unsafeHeadRef.Number, "head", unsafeHead, "parent", unsafeHeadRef.ParentID().Hash)
		divergenceBlockNumber_A = unsafeHeadRef.Number
		originalRef_A = unsafeHeadRef

		sys.L2ChainA.PrintChain()

		parentOfUnsafeHead := unsafeHeadRef.ParentID()

		l.Info("Sequencing a conflicting block", "unsafeHead", unsafeHeadRef, "parent", parentOfUnsafeHead)

		// sequence a conflicting block with a simple transfer tx, based on the parent of the parent of the unsafe head
		{
			err := ia.New(ctx, seqtypes.BuildOpts{
				Parent:   parentOfUnsafeHead.Hash,
				L1Origin: nil,
			})
			require.NoError(t, err, "Expected to be able to create a new block job for sequencing on op-test-sequencer, but got error")

			// include simple transfer tx in opened block
			{
				to := alice.PlanTransfer(bob.Address(), eth.OneGWei)
				opt := txplan.Combine(to)
				ptx := txplan.NewPlannedTx(opt)
				signed_tx, err := ptx.Signed.Eval(ctx)
				require.NoError(t, err, "Expected to be able to evaluate a planned transaction on op-test-sequencer, but got error")
				txdata, err := signed_tx.MarshalBinary()
				require.NoError(t, err, "Expected to be able to marshal a signed transaction on op-test-sequencer, but got error")

				err = ia.IncludeTx(ctx, txdata)
				require.NoError(t, err, "Expected to be able to include a signed transaction on op-test-sequencer, but got error")
			}

			err = ia.Next(ctx)
			require.NoError(t, err, "Expected to be able to call Next() after New() on op-test-sequencer, but got error")
		}
	}

	// start batcher on chain A
	sys.L2BatcherA.Start()

	// sequence a second block with op-test-sequencer (no L1 origin override)
	{
		l.Info("Sequencing with op-test-sequencer (no L1 origin override)")
		err := ia.New(ctx, seqtypes.BuildOpts{
			Parent:   sys.L2ELA.BlockRefByLabel(eth.Unsafe).Hash,
			L1Origin: nil,
		})
		require.NoError(t, err, "Expected to be able to create a new block job for sequencing on op-test-sequencer, but got error")
		time.Sleep(2 * time.Second)

		err = ia.Next(ctx)
		require.NoError(t, err, "Expected to be able to call Next() after New() on op-test-sequencer, but got error")
		time.Sleep(2 * time.Second)
	}

	// continue sequencing with consensus node (op-node)
	sys.L2CLA.StartSequencer()

	sys.L2ChainA.WaitForBlock()

	reorgedRef_A, err := sys.L2ELA.Escape().EthClient().BlockRefByNumber(ctx, divergenceBlockNumber_A)
	require.NoError(t, err, "Expected to be able to call BlockRefByNumber API, but got error")

	sys.L2ChainA.PrintChain()

	l.Info("Reorged chain A on divergence block number (prior the reorg)", "number", divergenceBlockNumber_A, "head", originalRef_A.Hash, "parent", originalRef_A.ParentID().Hash)
	l.Info("Reorged chain A on divergence block number (after the reorg)", "number", divergenceBlockNumber_A, "head", reorgedRef_A.Hash, "parent", reorgedRef_A.ParentID().Hash)
	require.NotEqual(t, originalRef_A.Hash, reorgedRef_A.Hash, "Expected to get different heads on divergence block number, but got the same hash, so no reorg happened on chain A")
	require.Equal(t, originalRef_A.ParentID().Hash, reorgedRef_A.ParentHash, "Expected to get same parent hashes on divergence block number, but got different hashes")

	err = wait.For(ctx, 5*time.Second, func() (bool, error) {
		safeL2Head_A_supervisor := sys.Supervisor.SafeBlockID(sys.L2ChainA.ChainID()).Hash
		safeL2Head_A_sequencer := sys.L2CLA.SafeL2BlockRef()

		if safeL2Head_A_sequencer.Number <= divergenceBlockNumber_A {
			l.Info("Safe ref number is still behind divergence block number", "divergence", divergenceBlockNumber_A, "safe", safeL2Head_A_sequencer.Number)
			return false, nil
		}
		if safeL2Head_A_sequencer.Hash.Cmp(safeL2Head_A_supervisor) != 0 {
			l.Info("Safe ref still not the same on supervisor and sequencer", "supervisor", safeL2Head_A_supervisor, "sequencer", safeL2Head_A_sequencer.Hash)
			return false, nil
		}
		l.Info("Safe ref is the same on both supervisor and sequencer", "supervisor", safeL2Head_A_supervisor, "sequencer", safeL2Head_A_sequencer.Hash)

		return true, nil
	})
	require.NoError(t, err, "Expected to get same safe ref on both supervisor and sequencer eventually")
	sys.L2ChainA.PrintChain()
}
