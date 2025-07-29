package system

import (
	"context"
	"fmt"
	"math/big"
	"testing"

	"github.com/ethereum-optimism/optimism/devnet-sdk/contracts/bindings"
	"github.com/ethereum-optimism/optimism/devnet-sdk/interfaces"
	"github.com/ethereum-optimism/optimism/devnet-sdk/types"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-service/sources"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto/kzg4844"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/params"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
)

var (
	_ Chain  = (*mockChain)(nil)
	_ Node   = (*mockNode)(nil)
	_ Wallet = (*mockWallet)(nil)
)

// mockWallet implements types.Wallet for testing
type mockWallet struct {
	mock.Mock
}

func (m *mockWallet) PrivateKey() types.Key {
	args := m.Called()
	return args.Get(0).(types.Key)
}

func (m *mockWallet) Address() types.Address {
	args := m.Called()
	return args.Get(0).(common.Address)
}

func (m *mockWallet) Send(ctx context.Context, tx Transaction) error {
	return nil
}

func (m *mockWallet) Sign(tx Transaction) (Transaction, error) {
	return tx, nil
}

func (m *mockWallet) SendETH(to types.Address, amount types.Balance) types.WriteInvocation[any] {
	args := m.Called(to, amount)
	return args.Get(0).(types.WriteInvocation[any])
}

func (m *mockWallet) InitiateMessage(chainID types.ChainID, target common.Address, message []byte) types.WriteInvocation[any] {
	args := m.Called(chainID, target, message)
	return args.Get(0).(types.WriteInvocation[any])
}

func (m *mockWallet) ExecuteMessage(identifier bindings.Identifier, sentMessage []byte) types.WriteInvocation[any] {
	args := m.Called(identifier, sentMessage)
	return args.Get(0).(types.WriteInvocation[any])
}

func (m *mockWallet) Balance() types.Balance {
	args := m.Called()
	return args.Get(0).(types.Balance)
}

func (m *mockWallet) Nonce() uint64 {
	args := m.Called()
	return args.Get(0).(uint64)
}

func (m *mockWallet) Transactor() *bind.TransactOpts {
	return nil
}

// mockChain implements the Chain interface for testing
type mockChain struct {
	mock.Mock
	wallet *mockWallet
}

func newMockChain() *mockChain {
	return &mockChain{
		wallet: new(mockWallet),
	}
}

func (m *mockChain) Nodes() []Node {
	args := m.Called()
	return args.Get(0).([]Node)
}

func (m *mockChain) ID() types.ChainID {
	args := m.Called()
	return args.Get(0).(types.ChainID)
}

func (m *mockChain) SupportsEIP(ctx context.Context, eip uint64) bool {
	args := m.Called(ctx, eip)
	return args.Bool(0)
}

func (m *mockChain) ContractsRegistry() interfaces.ContractsRegistry {
	args := m.Called()
	return args.Get(0).(interfaces.ContractsRegistry)
}

func (m *mockChain) RPCURL() string {
	args := m.Called()
	return args.String(0)
}

func (m *mockChain) Client() (*sources.EthClient, error) {
	args := m.Called()
	return args.Get(0).(*sources.EthClient), nil
}

func (m *mockChain) Wallets() WalletMap {
	return nil
}

func (m *mockChain) Config() (*params.ChainConfig, error) {
	return nil, fmt.Errorf("not implemented for mock chain")
}

func (m *mockChain) Addresses() AddressMap {
	args := m.Called()
	return args.Get(0).(AddressMap)
}

type mockNode struct {
	mock.Mock
}

func newMockNode() *mockNode {
	return &mockNode{}
}

func (m *mockNode) GasPrice(ctx context.Context) (*big.Int, error) {
	args := m.Called(ctx)
	return args.Get(0).(*big.Int), args.Error(1)
}

func (m *mockNode) GasLimit(ctx context.Context, tx TransactionData) (uint64, error) {
	args := m.Called(ctx, tx)
	return args.Get(0).(uint64), args.Error(1)
}

func (m *mockNode) PendingNonceAt(ctx context.Context, addr common.Address) (uint64, error) {
	args := m.Called(ctx, addr)
	return args.Get(0).(uint64), args.Error(1)
}

func (m *mockNode) BlockByNumber(ctx context.Context, number *big.Int) (eth.BlockInfo, error) {
	args := m.Called(ctx, number)
	return args.Get(0).(eth.BlockInfo), args.Error(1)
}

func (m *mockNode) Client() (*sources.EthClient, error) {
	args := m.Called()
	return args.Get(0).(*sources.EthClient), args.Error(1)
}

func (m *mockNode) ContractsRegistry() interfaces.ContractsRegistry {
	args := m.Called()
	return args.Get(0).(interfaces.ContractsRegistry)
}

func (m *mockNode) GethClient() (*ethclient.Client, error) {
	args := m.Called()
	return args.Get(0).(*ethclient.Client), args.Error(1)
}

func (m *mockNode) RPCURL() string {
	args := m.Called()
	return args.Get(0).(string)
}

func (m *mockNode) SupportsEIP(ctx context.Context, eip uint64) bool {
	args := m.Called(ctx, eip)
	return args.Bool(0)
}

func (m *mockNode) Name() string {
	args := m.Called()
	return args.String(0)
}

func TestNewTxBuilder(t *testing.T) {
	ctx := context.Background()

	var node *mockNode
	var chain *mockChain
	tests := []struct {
		name           string
		setupMock      func()
		opts           []TxBuilderOption
		expectedTypes  []uint8
		expectedMargin uint64
	}{
		{
			name: "legacy only",
			setupMock: func() {
				chain = newMockChain()
				node = newMockNode()
				chain.On("Nodes").Return([]Node{node})
				node.On("SupportsEIP", ctx, uint64(1559)).Return(false).Once()
				node.On("SupportsEIP", ctx, uint64(4844)).Return(false).Once()
			},
			opts:           nil,
			expectedTypes:  []uint8{ethtypes.LegacyTxType},
			expectedMargin: DefaultGasLimitMarginPercent,
		},
		{
			name: "with EIP-1559",
			setupMock: func() {
				chain = newMockChain()
				node = newMockNode()
				chain.On("Nodes").Return([]Node{node})
				node.On("SupportsEIP", ctx, uint64(1559)).Return(true).Once()
				node.On("SupportsEIP", ctx, uint64(4844)).Return(false).Once()
			},
			opts:           nil,
			expectedTypes:  []uint8{ethtypes.LegacyTxType, ethtypes.DynamicFeeTxType, ethtypes.AccessListTxType},
			expectedMargin: DefaultGasLimitMarginPercent,
		},
		{
			name: "with EIP-4844",
			setupMock: func() {
				chain = newMockChain()
				node = newMockNode()
				chain.On("Nodes").Return([]Node{node})
				node.On("SupportsEIP", ctx, uint64(1559)).Return(true).Once()
				node.On("SupportsEIP", ctx, uint64(4844)).Return(true).Once()
			},
			opts:           nil,
			expectedTypes:  []uint8{ethtypes.LegacyTxType, ethtypes.DynamicFeeTxType, ethtypes.AccessListTxType, ethtypes.BlobTxType},
			expectedMargin: DefaultGasLimitMarginPercent,
		},
		{
			name: "forced tx type",
			setupMock: func() {
				// No EIP checks needed when type is forced
			},
			opts: []TxBuilderOption{
				WithTxType(ethtypes.DynamicFeeTxType),
			},
			expectedTypes:  []uint8{ethtypes.DynamicFeeTxType},
			expectedMargin: DefaultGasLimitMarginPercent,
		},
		{
			name: "custom margin",
			setupMock: func() {
				chain = newMockChain()
				node = newMockNode()
				chain.On("Nodes").Return([]Node{node})
				node.On("SupportsEIP", ctx, uint64(1559)).Return(false).Once()
				node.On("SupportsEIP", ctx, uint64(4844)).Return(false).Once()
			},
			opts: []TxBuilderOption{
				WithGasLimitMargin(50),
			},
			expectedTypes:  []uint8{ethtypes.LegacyTxType},
			expectedMargin: 50,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tt.setupMock()
			builder := NewTxBuilder(ctx, chain, tt.opts...)

			assert.Equal(t, tt.expectedTypes, builder.supportedTxTypes)
			assert.Equal(t, tt.expectedMargin, builder.gasLimitMarginPercent)
			chain.AssertExpectations(t)
		})
	}
}

func TestBuildTx(t *testing.T) {
	ctx := context.Background()
	chain := newMockChain()
	node := newMockNode()
	addr := common.HexToAddress("0x1234567890123456789012345678901234567890")
	to := common.HexToAddress("0x0987654321098765432109876543210987654321")
	chainID := big.NewInt(1)
	gasPrice := big.NewInt(1000000000) // 1 gwei
	nonce := uint64(1)

	tests := []struct {
		name      string
		setupMock func()
		opts      []TxOption
		wantType  uint8
		wantErr   bool
	}{
		{
			name: "legacy tx",
			setupMock: func() {
				chain.On("Nodes").Return([]Node{node})
				node.On("SupportsEIP", ctx, uint64(1559)).Return(false).Once()
				node.On("SupportsEIP", ctx, uint64(4844)).Return(false).Once()
				node.On("PendingNonceAt", ctx, addr).Return(nonce, nil).Once()
				node.On("GasPrice", ctx).Return(gasPrice, nil).Once()
				node.On("GasLimit", ctx, mock.Anything).Return(uint64(21000), nil).Once()
			},
			opts: []TxOption{
				WithFrom(addr),
				WithTo(to),
				WithValue(big.NewInt(100000000000000000)), // 0.1 ETH
			},
			wantType: ethtypes.LegacyTxType,
			wantErr:  false,
		},
		{
			name: "dynamic fee tx",
			setupMock: func() {
				chain.On("Nodes").Return([]Node{node})
				node.On("SupportsEIP", ctx, uint64(1559)).Return(true).Once()
				node.On("SupportsEIP", ctx, uint64(4844)).Return(false).Once()
				node.On("PendingNonceAt", ctx, addr).Return(nonce, nil).Once()
				node.On("GasPrice", ctx).Return(gasPrice, nil).Once()
				chain.On("ID").Return(chainID).Once()
				node.On("GasLimit", ctx, mock.Anything).Return(uint64(21000), nil).Once()
			},
			opts: []TxOption{
				WithFrom(addr),
				WithTo(to),
				WithValue(big.NewInt(100000000000000000)), // 0.1 ETH
			},
			wantType: ethtypes.DynamicFeeTxType,
			wantErr:  false,
		},
		{
			name: "access list tx",
			setupMock: func() {
				chain.On("Nodes").Return([]Node{node})
				node.On("SupportsEIP", ctx, uint64(1559)).Return(true).Once()
				node.On("SupportsEIP", ctx, uint64(4844)).Return(false).Once()
				node.On("PendingNonceAt", ctx, addr).Return(nonce, nil).Once()
				node.On("GasPrice", ctx).Return(gasPrice, nil).Once()
				chain.On("ID").Return(chainID).Once()
				node.On("GasLimit", ctx, mock.Anything).Return(uint64(21000), nil).Once()
			},
			opts: []TxOption{
				WithFrom(addr),
				WithTo(to),
				WithValue(big.NewInt(100000000000000000)), // 0.1 ETH
				WithAccessList(ethtypes.AccessList{
					{
						Address: common.HexToAddress("0x1234567890123456789012345678901234567890"),
						StorageKeys: []common.Hash{
							common.HexToHash("0x0000000000000000000000000000000000000000000000000000000000000001"),
						},
					},
				}),
			},
			wantType: ethtypes.AccessListTxType,
			wantErr:  false,
		},
		{
			name: "blob tx",
			setupMock: func() {
				chain.On("Nodes").Return([]Node{node})
				node.On("SupportsEIP", ctx, uint64(1559)).Return(true).Once()
				node.On("SupportsEIP", ctx, uint64(4844)).Return(true).Once()
				node.On("PendingNonceAt", ctx, addr).Return(nonce, nil).Once()
				node.On("GasPrice", ctx).Return(gasPrice, nil).Once()
				chain.On("ID").Return(chainID).Once()
				node.On("GasLimit", ctx, mock.Anything).Return(uint64(21000), nil).Once()
			},
			opts: []TxOption{
				WithFrom(addr),
				WithTo(to),
				WithValue(big.NewInt(100000000000000000)), // 0.1 ETH
				WithBlobs([]kzg4844.Blob{{}}),
				WithBlobCommitments([]kzg4844.Commitment{{}}),
				WithBlobProofs([]kzg4844.Proof{{}}),
				WithBlobHashes([]common.Hash{{}}),
			},
			wantType: ethtypes.BlobTxType,
			wantErr:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tt.setupMock()
			builder := NewTxBuilder(ctx, chain)
			tx, err := builder.BuildTx(tt.opts...)

			if tt.wantErr {
				assert.Error(t, err)
				return
			}

			assert.NoError(t, err)
			assert.Equal(t, tt.wantType, tx.Type())
			chain.AssertExpectations(t)
		})
	}
}

func TestCalculateGasLimit(t *testing.T) {
	ctx := context.Background()
	addr := common.HexToAddress("0x1234567890123456789012345678901234567890")

	tests := []struct {
		name           string
		opts           *TxOpts
		margin         uint64
		estimatedGas   uint64
		expectedLimit  uint64
		expectEstimate bool
		wantErr        bool
	}{
		{
			name: "explicit gas limit",
			opts: &TxOpts{
				from:     addr,
				to:       &addr,
				value:    big.NewInt(0),
				gasLimit: 21000,
			},
			margin:         20,
			estimatedGas:   0,
			expectedLimit:  21000,
			expectEstimate: false,
			wantErr:        false,
		},
		{
			name: "estimated with margin",
			opts: &TxOpts{
				from:  addr,
				to:    &addr,
				value: big.NewInt(0),
			},
			margin:         20,
			estimatedGas:   21000,
			expectedLimit:  25200, // 21000 * 1.2
			expectEstimate: true,
			wantErr:        false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Set up EIP support expectations for NewTxBuilder
			chain := newMockChain()
			node := newMockNode()
			chain.On("Nodes").Return([]Node{node})
			node.On("SupportsEIP", ctx, uint64(1559)).Return(false)
			node.On("SupportsEIP", ctx, uint64(4844)).Return(false)
			node.On("GasLimit", ctx, tt.opts).Return(tt.estimatedGas, nil).Once()

			builder := NewTxBuilder(ctx, chain, WithGasLimitMargin(tt.margin))
			limit, err := builder.calculateGasLimit(tt.opts)

			if tt.wantErr {
				assert.Error(t, err)
				return
			}

			assert.NoError(t, err)
			assert.Equal(t, tt.expectedLimit, limit)
			chain.AssertExpectations(t)
		})
	}
}
