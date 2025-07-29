package proofs

import (
	"testing"

	actionsHelpers "github.com/ethereum-optimism/optimism/op-e2e/actions/helpers"
	"github.com/ethereum-optimism/optimism/op-e2e/actions/proofs/helpers"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/stretchr/testify/require"
)

const (
	BadSignature int64 = iota
	NotEnoughBalance
)

func runBadTxInBatchTest(gt *testing.T, testCfg *helpers.TestCfg[int64]) {
	t := actionsHelpers.NewDefaultTesting(gt)
	env := helpers.NewL2FaultProofEnv(t, testCfg, helpers.NewTestParams(), helpers.NewBatcherCfg())

	// Build a block on L2 with 1 tx.
	env.Alice.L2.ActResetTxOpts(t)
	env.Alice.L2.ActSetTxToAddr(&env.Dp.Addresses.Bob)
	env.Alice.L2.ActMakeTx(t)

	env.Sequencer.ActL2StartBlock(t)
	env.Engine.ActL2IncludeTx(env.Alice.Address())(t)
	env.Sequencer.ActL2EndBlock(t)
	env.Alice.L2.ActCheckReceiptStatusOfLastTx(true)(t)

	// Instruct the batcher to submit a faulty channel, with an invalid tx.
	env.Batcher.ActL2BatchBuffer(t, actionsHelpers.WithBlockModifier(func(block *types.Block) *types.Block {
		// Replace the tx with one that has a bad signature.
		txs := block.Transactions()

		var newTx *types.Transaction
		if testCfg.Custom == BadSignature {
			txCopy, err := txs[1].WithSignature(env.Alice.L2.Signer(), make([]byte, 65))
			require.NoError(t, err)

			newTx = txCopy
		} else if testCfg.Custom == NotEnoughBalance {
			pkey, err := crypto.GenerateKey()
			require.NoError(t, err)
			signer := types.LatestSigner(env.Sd.L2Cfg.Config)

			txCopy, err := types.SignTx(txs[1], signer, pkey)
			require.NoError(t, err)

			newTx = txCopy
		}

		txs[1] = newTx
		return block
	}))
	env.Batcher.ActL2ChannelClose(t)
	env.Batcher.ActL2BatchSubmit(t)

	// Include the batcher transaction.
	env.Miner.ActL1StartBlock(12)(t)
	env.Miner.ActL1IncludeTxByHash(env.Batcher.LastSubmitted.Hash())(t)
	env.Miner.ActL1EndBlock(t)
	env.Miner.ActL1SafeNext(t)

	// Instruct the sequencer to derive the L2 chain from the data on L1 that the batcher just posted.
	env.Sequencer.ActL1HeadSignal(t)
	env.Sequencer.ActL2PipelineFull(t)

	// Ensure the safe head has not advanced if pre-Holocene - the batch is invalid.
	// If post-holocene, the block should be reduced to deposits only.
	l2SafeHead := env.Engine.L2Chain().CurrentSafeBlock()
	if !env.Sd.RollupCfg.IsHolocene(l2SafeHead.Time) {
		require.Equal(t, uint64(0), l2SafeHead.Number.Uint64())

		// Reset the batcher and submit a valid batch.
		env.Batcher.Reset()
		env.Batcher.ActSubmitAll(t)
		env.Miner.ActL1StartBlock(12)(t)
		env.Miner.ActL1IncludeTxByHash(env.Batcher.LastSubmitted.Hash())(t)
		env.Miner.ActL1EndBlock(t)
		env.Miner.ActL1SafeNext(t)

		// Instruct the sequencer to derive the L2 chain from the data on L1 that the batcher just posted.
		env.Sequencer.ActL1HeadSignal(t)
		env.Sequencer.ActL2PipelineFull(t)

		l1Head := env.Miner.L1Chain().CurrentBlock()
		require.Equal(t, uint64(2), l1Head.Number.Uint64())
	}

	// Ensure the safe head has advanced.
	l2SafeHead = env.Engine.L2Chain().CurrentSafeBlock()
	require.Equal(t, uint64(1), l2SafeHead.Number.Uint64())

	env.RunFaultProofProgramFromGenesis(t, l2SafeHead.Number.Uint64(), testCfg.CheckResult, testCfg.InputParams...)
}

func runBadTxInBatch_ResubmitBadFirstFrame_Test(gt *testing.T, testCfg *helpers.TestCfg[int64]) {
	t := actionsHelpers.NewDefaultTesting(gt)
	env := helpers.NewL2FaultProofEnv(t, testCfg, helpers.NewTestParams(), helpers.NewBatcherCfg())

	// Build 2 blocks on L2 with 1 tx each.
	for i := 0; i < 2; i++ {
		env.Alice.L2.ActResetTxOpts(t)
		env.Alice.L2.ActSetTxToAddr(&env.Dp.Addresses.Bob)
		env.Alice.L2.ActMakeTx(t)

		env.Sequencer.ActL2StartBlock(t)
		env.Engine.ActL2IncludeTx(env.Alice.Address())(t)
		env.Sequencer.ActL2EndBlock(t)
		env.Alice.L2.ActCheckReceiptStatusOfLastTx(true)(t)
	}

	// Instruct the batcher to submit a faulty channel, with an invalid tx in the second block
	// within the span batch.
	env.Batcher.ActL2BatchBuffer(t)
	err := env.Batcher.Buffer(t, actionsHelpers.WithBlockModifier(func(block *types.Block) *types.Block {
		txs := block.Transactions()

		var newTx *types.Transaction
		if testCfg.Custom == BadSignature {
			txCopy, err := txs[1].WithSignature(env.Alice.L2.Signer(), make([]byte, 65))
			require.NoError(t, err)

			newTx = txCopy
		} else if testCfg.Custom == NotEnoughBalance {
			pkey, err := crypto.GenerateKey()
			require.NoError(t, err)
			signer := types.LatestSigner(env.Sd.L2Cfg.Config)

			txCopy, err := types.SignTx(txs[1], signer, pkey)
			require.NoError(t, err)

			newTx = txCopy
		}

		txs[1] = newTx
		return block
	}))
	require.NoError(t, err)
	env.Batcher.ActL2ChannelClose(t)
	env.Batcher.ActL2BatchSubmit(t)

	// Include the batcher transaction.
	env.Miner.ActL1StartBlock(12)(t)
	env.Miner.ActL1IncludeTxByHash(env.Batcher.LastSubmitted.Hash())(t)
	env.Miner.ActL1EndBlock(t)
	env.Miner.ActL1SafeNext(t)

	// Instruct the sequencer to derive the L2 chain from the data on L1 that the batcher just posted.
	env.Sequencer.ActL1HeadSignal(t)
	env.Sequencer.ActL2PipelineFull(t)

	// Ensure the safe head has not advanced if pre-Holocene - the batch is invalid.
	// If post-holocene, the block should be reduced to deposits only.
	l2SafeHead := env.Engine.L2Chain().CurrentSafeBlock()
	if !env.Sd.RollupCfg.IsHolocene(l2SafeHead.Time) {
		require.Equal(t, uint64(0), l2SafeHead.Number.Uint64())

		// Reset the batcher and submit a valid batch.
		env.Batcher.Reset()
		env.Batcher.ActSubmitAll(t)
		env.Miner.ActL1StartBlock(12)(t)
		env.Miner.ActL1IncludeTxByHash(env.Batcher.LastSubmitted.Hash())(t)
		env.Miner.ActL1EndBlock(t)
		env.Miner.ActL1SafeNext(t)

		// Instruct the sequencer to derive the L2 chain from the data on L1 that the batcher just posted.
		env.Sequencer.ActL1HeadSignal(t)
		env.Sequencer.ActL2PipelineFull(t)

		l1Head := env.Miner.L1Chain().CurrentBlock()
		require.Equal(t, uint64(2), l1Head.Number.Uint64())
	}

	// Ensure the safe head has advanced.
	l2SafeHead = env.Engine.L2Chain().CurrentSafeBlock()
	require.Equal(t, uint64(2), l2SafeHead.Number.Uint64())

	env.RunFaultProofProgramFromGenesis(t, l2SafeHead.Number.Uint64(), testCfg.CheckResult, testCfg.InputParams...)
}

func Test_ProgramAction_BadTxInBatch(gt *testing.T) {
	matrix := helpers.NewMatrix[int64]()
	defer matrix.Run(gt)

	matrix.AddDefaultTestCasesWithName(
		"BadSignature",
		BadSignature,
		helpers.NewForkMatrix(helpers.Granite, helpers.Holocene, helpers.Isthmus),
		runBadTxInBatchTest,
	)
	matrix.AddDefaultTestCasesWithName(
		"NotEnoughBalance",
		NotEnoughBalance,
		helpers.NewForkMatrix(helpers.Granite, helpers.Holocene, helpers.Isthmus),
		runBadTxInBatchTest,
	)
	matrix.AddDefaultTestCasesWithName(
		"ResubmitBadFirstFrame-BadSignature",
		BadSignature,
		helpers.NewForkMatrix(helpers.Granite, helpers.Holocene, helpers.Isthmus),
		runBadTxInBatch_ResubmitBadFirstFrame_Test,
	)
	matrix.AddDefaultTestCasesWithName(
		"ResubmitBadFirstFrame-NotEnoughBalance",
		NotEnoughBalance,
		helpers.NewForkMatrix(helpers.Granite, helpers.Holocene, helpers.Isthmus),
		runBadTxInBatch_ResubmitBadFirstFrame_Test,
	)
}
