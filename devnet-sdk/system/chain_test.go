package system

import (
	"context"
	"math/big"
	"testing"

	"github.com/ethereum-optimism/optimism/devnet-sdk/contracts/registry/empty"
	"github.com/ethereum-optimism/optimism/devnet-sdk/descriptors"
	"github.com/ethereum/go-ethereum/common"
	"github.com/stretchr/testify/assert"
)

func TestClientManager(t *testing.T) {
	manager := newClientManager()

	t.Run("returns error for invalid URL", func(t *testing.T) {
		_, err := manager.Client("invalid://url")
		assert.Error(t, err)
	})

	t.Run("caches client for same URL", func(t *testing.T) {
		// Use a hostname that's guaranteed to fail DNS resolution
		url := "http://this.domain.definitely.does.not.exist:8545"

		// First call should create new client
		client1, err1 := manager.Client(url)
		// Second call should return cached client
		client2, err2 := manager.Client(url)

		// Both calls should succeed in creating a client
		assert.NoError(t, err1)
		assert.NoError(t, err2)
		assert.NotNil(t, client1)
		assert.NotNil(t, client2)

		// But the client should fail when used
		ctx := context.Background()
		_, err := client1.ChainID(ctx)
		assert.Error(t, err)

		// And both clients should be the same instance
		assert.Same(t, client1, client2)
	})
}

func TestChainFromDescriptor(t *testing.T) {
	descriptor := &descriptors.Chain{
		ID: "1",
		Nodes: []descriptors.Node{
			{
				Services: descriptors.ServiceMap{
					"el": &descriptors.Service{
						Endpoints: descriptors.EndpointMap{
							"rpc": &descriptors.PortInfo{
								Host: "localhost",
								Port: 8545,
							},
						},
					},
				},
			},
		},
		Wallets: descriptors.WalletMap{
			"user1": &descriptors.Wallet{
				PrivateKey: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
				Address:    common.HexToAddress("0x1234567890123456789012345678901234567890"),
			},
		},
		Addresses: descriptors.AddressMap{
			"user1": common.HexToAddress("0x1234567890123456789012345678901234567890"),
		},
	}

	chain, err := newChainFromDescriptor(descriptor)
	assert.Nil(t, err)
	assert.NotNil(t, chain)
	assert.Equal(t, "http://localhost:8545", chain.Nodes()[0].RPCURL())

	// Compare the underlying big.Int values
	chainID := chain.ID()
	expectedID := big.NewInt(1)
	assert.Equal(t, 0, expectedID.Cmp(chainID))
}

func TestL2ChainFromDescriptor(t *testing.T) {
	descriptor := &descriptors.L2Chain{
		Chain: &descriptors.Chain{
			ID: "1",
			Nodes: []descriptors.Node{
				{
					Services: descriptors.ServiceMap{
						"el": &descriptors.Service{
							Endpoints: descriptors.EndpointMap{
								"rpc": &descriptors.PortInfo{
									Host: "localhost",
									Port: 8545,
								},
							},
						},
					},
				},
			},
			Wallets: descriptors.WalletMap{
				"user1": &descriptors.Wallet{
					PrivateKey: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
					Address:    common.HexToAddress("0x1234567890123456789012345678901234567890"),
				},
			},
			Addresses: descriptors.AddressMap{
				"user2": common.HexToAddress("0x1234567890123456789012345678901234567891"),
			},
		},
		L1Addresses: descriptors.AddressMap{
			"user1": common.HexToAddress("0x1234567890123456789012345678901234567890"),
		},
		L1Wallets: descriptors.WalletMap{
			"user1": &descriptors.Wallet{
				PrivateKey: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
				Address:    common.HexToAddress("0x1234567890123456789012345678901234567890"),
			},
		},
	}

	chain, err := newL2ChainFromDescriptor(descriptor)
	assert.Nil(t, err)
	assert.NotNil(t, chain)
	assert.Equal(t, "http://localhost:8545", chain.Nodes()[0].RPCURL())

	// Compare the underlying big.Int values
	chainID := chain.ID()
	expectedID := big.NewInt(1)
	assert.Equal(t, 0, expectedID.Cmp(chainID))
}

func TestChainWallet(t *testing.T) {
	testAddr := common.HexToAddress("0x1234567890123456789012345678901234567890")

	wallet, err := NewWallet("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", testAddr, nil)
	assert.Nil(t, err)

	l1Chain := newChain("1", WalletMap{"user1": wallet}, nil, map[string]common.Address{}, []Node{})

	t.Run("finds wallet meeting constraints", func(t *testing.T) {
		constraint := &addressConstraint{addr: testAddr}
		wallets := l1Chain.Wallets()

		for _, w := range wallets {
			if constraint.CheckWallet(w) {
				assert.NotNil(t, w)
				assert.Equal(t, testAddr, w.Address())
				return
			}
		}
		t.Fatalf("wallet not found")
	})

	t.Run("returns error when no wallet meets constraints", func(t *testing.T) {
		wrongAddr := common.HexToAddress("0x0987654321098765432109876543210987654321")
		constraint := &addressConstraint{addr: wrongAddr}
		wallets := l1Chain.Wallets()

		for _, w := range wallets {
			if constraint.CheckWallet(w) {
				t.Fatalf("wallet found")
			}
		}
	})
}

// addressConstraint implements constraints.WalletConstraint for testing
type addressConstraint struct {
	addr common.Address
}

func (c *addressConstraint) CheckWallet(w Wallet) bool {
	return w.Address() == c.addr
}

func TestChainID(t *testing.T) {
	tests := []struct {
		name     string
		idString string
		want     *big.Int
	}{
		{
			name:     "valid chain ID",
			idString: "1",
			want:     big.NewInt(1),
		},
		{
			name:     "empty chain ID",
			idString: "",
			want:     big.NewInt(0),
		},
		{
			name:     "invalid chain ID",
			idString: "not a number",
			want:     big.NewInt(0),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			chain := newChain(tt.idString, WalletMap{}, nil, AddressMap{}, []Node{})
			got := chain.ID()
			// Compare the underlying big.Int values
			assert.Equal(t, 0, tt.want.Cmp(got))
		})
	}
}

func TestSupportsEIP(t *testing.T) {
	ctx := context.Background()
	chain := newChain("1", WalletMap{}, nil, AddressMap{}, []Node{})

	// Since we can't reliably test against a live node, we're just testing the error case
	t.Run("returns false for connection error", func(t *testing.T) {
		assert.False(t, chain.SupportsEIP(ctx, 1559))
		assert.False(t, chain.SupportsEIP(ctx, 4844))
	})
}

// mockContractsRegistry extends empty.EmptyRegistry to provide mock contract instances
type mockContractsRegistry struct {
	empty.EmptyRegistry
}

func TestContractsRegistry(t *testing.T) {
	node := &mockNode{}
	// Create a mock for testing
	mockRegistry := &mockContractsRegistry{}

	// Set up the mock to return the registry when ContractsRegistry() is called
	node.On("ContractsRegistry").Return(mockRegistry)

	chain := newChain("1", WalletMap{}, nil, AddressMap{}, []Node{node})

	t.Run("returns empty registry on error", func(t *testing.T) {
		registry := chain.Nodes()[0].ContractsRegistry()
		assert.NotNil(t, registry)
	})

	t.Run("caches registry", func(t *testing.T) {
		registry1 := chain.Nodes()[0].ContractsRegistry()
		registry2 := chain.Nodes()[0].ContractsRegistry()
		assert.Same(t, registry1, registry2)
	})
}
