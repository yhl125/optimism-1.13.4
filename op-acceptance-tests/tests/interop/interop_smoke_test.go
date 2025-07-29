package interop

import (
	"context"
	"math/big"
	"testing"

	"github.com/ethereum-optimism/optimism/devnet-sdk/contracts/constants"
	"github.com/ethereum-optimism/optimism/devnet-sdk/system"
	"github.com/ethereum-optimism/optimism/devnet-sdk/testing/systest"
	"github.com/ethereum-optimism/optimism/devnet-sdk/testing/testlib/validators"
	sdktypes "github.com/ethereum-optimism/optimism/devnet-sdk/types"
	"github.com/ethereum-optimism/optimism/op-service/testlog"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/log"
	"github.com/stretchr/testify/require"
)

func smokeTestScenario(chainIdx uint64, walletGetter validators.WalletGetter) systest.SystemTestFunc {
	return func(t systest.T, sys system.System) {
		ctx := t.Context()

		logger := testlog.Logger(t, log.LevelInfo)
		logger = logger.With("test", "TestMinimal", "devnet", sys.Identifier())

		chain := sys.L2s()[chainIdx]
		logger = logger.With("chain", chain.ID())
		logger.Info("starting test")

		funds := sdktypes.NewBalance(big.NewInt(1 * constants.ETH))
		user := walletGetter(ctx)

		wethAddr := constants.WETH
		weth, err := chain.Nodes()[0].ContractsRegistry().WETH(wethAddr)
		require.NoError(t, err)
		initialBalance, err := weth.BalanceOf(user.Address()).Call(ctx)
		require.NoError(t, err)
		logger = logger.With("user", user.Address())
		logger.Info("initial balance retrieved", "balance", initialBalance)

		logger.Info("sending ETH to contract", "amount", funds)
		require.NoError(t, user.SendETH(wethAddr, funds).Send(ctx).Wait())

		balance, err := weth.BalanceOf(user.Address()).Call(ctx)
		require.NoError(t, err)
		logger.Info("final balance retrieved", "balance", balance)

		require.Equal(t, initialBalance.Add(funds), balance)
	}
}

func TestInteropSystemNoop(t *testing.T) {
	systest.InteropSystemTest(t, func(t systest.T, sys system.InteropSystem) {
		testlog.Logger(t, log.LevelInfo).Info("noop")
	})
}

func TestInteropSystemSupervisor(t *testing.T) {
	systest.InteropSystemTest(t, func(t systest.T, sys system.InteropSystem) {
		ctx := t.Context()
		supervisor, err := sys.Supervisor(ctx)
		require.NoError(t, err)
		block, err := supervisor.FinalizedL1(ctx)
		require.NoError(t, err)
		require.NotNil(t, block)
		testlog.Logger(t, log.LevelInfo).Info("finalized l1 block", "block", block)
	})
}

func TestSmokeTestFailure(t *testing.T) {
	// Create mock failing system
	mockAddr := common.HexToAddress("0x1234567890123456789012345678901234567890")
	mockWallet := &mockFailingWallet{
		addr: mockAddr,
		bal:  sdktypes.NewBalance(big.NewInt(0.1 * constants.ETH)),
	}
	mockL1Chain := newMockFailingL1Chain(
		sdktypes.ChainID(big.NewInt(1234)),
		system.WalletMap{
			"user1": mockWallet,
		},
		[]system.Node{&mockFailingNode{
			reg: &mockContractsRegistry{},
		}},
	)
	mockL2Chain := newMockFailingL2Chain(
		sdktypes.ChainID(big.NewInt(1234)),
		system.WalletMap{"user1": mockWallet},
		[]system.Node{&mockFailingNode{
			reg: &mockContractsRegistry{},
		}},
	)
	mockSys := &mockFailingSystem{l1Chain: mockL1Chain, l2Chain: mockL2Chain}

	// Run the smoke test logic and capture failures
	getter := func(ctx context.Context) system.Wallet {
		return mockWallet
	}
	rt := NewRecordingT(context.TODO())
	rt.TestScenario(
		smokeTestScenario(0, getter),
		mockSys,
	)

	// Verify that the test failed due to SendETH error
	require.True(t, rt.Failed(), "test should have failed")
	require.Contains(t, rt.Logs(), "transaction failure", "unexpected failure message")
}
