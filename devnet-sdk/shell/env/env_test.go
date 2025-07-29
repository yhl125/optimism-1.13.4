package env

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ethereum-optimism/optimism/devnet-sdk/descriptors"
	"github.com/ethereum/go-ethereum/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLoadDevnetEnv(t *testing.T) {
	// Create a temporary test file
	content := `{
		"l1": {
			"name": "l1",
			"id": "1",
			"nodes": [{
				"services": {
					"el": {
						"endpoints": {
							"rpc": {
								"host": "localhost",
								"port": 8545
							}
						}
					}
				}
			}],
			"jwt": "0x1234567890abcdef",
			"addresses": {
				"deployer": "0x1234567890123456789012345678901234567890"
			}
		},
		"l2": [{
			"name": "op",
			"id": "2",
			"nodes": [{
				"services": {
					"el": {
						"endpoints": {
							"rpc": {
								"host": "localhost",
								"port": 9545
							}
						}
					}
				}
			}],
			"jwt": "0xdeadbeef",
			"addresses": {
				"deployer": "0x2345678901234567890123456789012345678901"
			}
		}]
	}`

	tmpfile, err := os.CreateTemp("", "devnet-*.json")
	require.NoError(t, err)
	defer os.Remove(tmpfile.Name())

	_, err = tmpfile.Write([]byte(content))
	require.NoError(t, err)
	err = tmpfile.Close()
	require.NoError(t, err)

	// Test successful load
	t.Run("successful load", func(t *testing.T) {
		env, err := LoadDevnetFromURL(tmpfile.Name())
		require.NoError(t, err)
		assert.Equal(t, "l1", env.Env.L1.Name)
		assert.Equal(t, "op", env.Env.L2[0].Name)
	})

	// Test loading non-existent file
	t.Run("non-existent file", func(t *testing.T) {
		_, err := LoadDevnetFromURL("non-existent.json")
		assert.Error(t, err)
	})

	// Test loading invalid JSON
	t.Run("invalid JSON", func(t *testing.T) {
		invalidFile := filepath.Join(t.TempDir(), "invalid.json")
		err := os.WriteFile(invalidFile, []byte("{invalid json}"), 0644)
		require.NoError(t, err)

		_, err = LoadDevnetFromURL(invalidFile)
		assert.Error(t, err)
	})
}

func TestGetChain(t *testing.T) {
	devnet := &DevnetEnv{
		Env: &descriptors.DevnetEnvironment{
			L1: &descriptors.Chain{
				Name: "l1",
				Nodes: []descriptors.Node{
					{
						Services: descriptors.ServiceMap{
							"el": {
								Endpoints: descriptors.EndpointMap{
									"rpc": {
										Host: "localhost",
										Port: 8545,
									},
								},
							},
						},
					},
				},
				JWT: "0x1234",
				Addresses: descriptors.AddressMap{
					"deployer": common.HexToAddress("0x1234567890123456789012345678901234567890"),
				},
			},
			L2: []*descriptors.L2Chain{
				{
					Chain: &descriptors.Chain{
						Name: "op",
						Nodes: []descriptors.Node{
							{
								Services: descriptors.ServiceMap{
									"el": {
										Endpoints: descriptors.EndpointMap{
											"rpc": {
												Host: "localhost",
												Port: 9545,
											},
										},
									},
								},
							},
						},
						JWT: "0x5678",
						Addresses: descriptors.AddressMap{
							"deployer": common.HexToAddress("0x2345678901234567890123456789012345678901"),
						},
					},
					L1Addresses: descriptors.AddressMap{
						"deployer": common.HexToAddress("0x2345678901234567890123456789012345678901"),
					},
					L1Wallets: descriptors.WalletMap{
						"deployer": &descriptors.Wallet{
							Address:    common.HexToAddress("0x2345678901234567890123456789012345678901"),
							PrivateKey: "0x2345678901234567890123456789012345678901",
						},
					},
				},
			},
		},
		URL: "test.json",
	}

	// Test getting L1 chain
	t.Run("get L1 chain", func(t *testing.T) {
		chain, err := devnet.GetChain("l1")
		require.NoError(t, err)
		assert.Equal(t, "l1", chain.name)
		assert.Equal(t, "0x1234", chain.chain.JWT)
	})

	// Test getting L2 chain
	t.Run("get L2 chain", func(t *testing.T) {
		chain, err := devnet.GetChain("op")
		require.NoError(t, err)
		assert.Equal(t, "op", chain.name)
		assert.Equal(t, "0x5678", chain.chain.JWT)
	})

	// Test getting non-existent chain
	t.Run("get non-existent chain", func(t *testing.T) {
		_, err := devnet.GetChain("invalid")
		assert.Error(t, err)
	})
}

func TestChainConfig(t *testing.T) {
	chain := &ChainConfig{
		chain: &descriptors.Chain{
			Name: "test",
			Nodes: []descriptors.Node{
				{
					Services: descriptors.ServiceMap{
						"el": {
							Endpoints: descriptors.EndpointMap{
								"rpc": {
									Host:   "localhost",
									Port:   8545,
									Scheme: "https",
								},
							},
						},
					},
				},
			},
			JWT: "0x1234",
			Addresses: descriptors.AddressMap{
				"deployer": common.HexToAddress("0x1234567890123456789012345678901234567890"),
			},
		},
		devnetURL: "test.json",
		name:      "test",
	}

	// Test getting environment variables
	t.Run("get environment variables", func(t *testing.T) {
		env, err := chain.GetEnv(
			WithCastIntegration(true, 0),
		)
		require.NoError(t, err)

		assert.Equal(t, "https://localhost:8545", env.envVars["ETH_RPC_URL"])
		assert.Equal(t, "1234", env.envVars["ETH_RPC_JWT_SECRET"])
		assert.Equal(t, "test.json", filepath.Base(env.envVars[EnvURLVar]))
		assert.Equal(t, "test", env.envVars[ChainNameVar])
		assert.Contains(t, env.motd, "deployer")
		assert.Contains(t, env.motd, "0x1234567890123456789012345678901234567890")
	})

	// Test chain with no nodes
	t.Run("chain with no nodes", func(t *testing.T) {
		noNodesChain := &ChainConfig{
			chain: &descriptors.Chain{
				Name:  "test",
				Nodes: []descriptors.Node{},
			},
		}
		_, err := noNodesChain.GetEnv(
			WithCastIntegration(true, 0),
		)
		assert.Error(t, err)
	})

	// Test chain with missing service
	t.Run("chain with missing service", func(t *testing.T) {
		missingServiceChain := &ChainConfig{
			chain: &descriptors.Chain{
				Name: "test",
				Nodes: []descriptors.Node{
					{
						Services: descriptors.ServiceMap{},
					},
				},
			},
		}
		_, err := missingServiceChain.GetEnv(
			WithCastIntegration(true, 0),
		)
		assert.Error(t, err)
	})

	// Test chain with missing endpoint
	t.Run("chain with missing endpoint", func(t *testing.T) {
		missingEndpointChain := &ChainConfig{
			chain: &descriptors.Chain{
				Name: "test",
				Nodes: []descriptors.Node{
					{
						Services: descriptors.ServiceMap{
							"el": {
								Endpoints: descriptors.EndpointMap{},
							},
						},
					},
				},
			},
		}
		_, err := missingEndpointChain.GetEnv(
			WithCastIntegration(true, 0),
		)
		assert.Error(t, err)
	})
}

func TestChainEnv_ApplyToEnv(t *testing.T) {
	originalEnv := []string{
		"KEEP_ME=old_value",
		"OVERRIDE_ME=old_value",
		"REMOVE_ME=old_value",
	}

	env := &ChainEnv{
		envVars: map[string]string{
			"OVERRIDE_ME": "new_value",
			"REMOVE_ME":   "",
		},
	}

	result := env.ApplyToEnv(originalEnv)

	// Convert result to map for easier testing
	resultMap := make(map[string]string)
	for _, v := range result {
		parts := strings.SplitN(v, "=", 2)
		resultMap[parts[0]] = parts[1]
	}

	// Test that KEEP_ME was overridden with new value
	assert.Equal(t, "old_value", resultMap["KEEP_ME"])

	// Test that OVERRIDE_ME was overridden with new value
	assert.Equal(t, "new_value", resultMap["OVERRIDE_ME"])

	// Test that REMOVE_ME was removed (not present in result)
	_, exists := resultMap["REMOVE_ME"]
	assert.False(t, exists, "REMOVE_ME should have been removed")

	// Test that we have exactly 3 variables in the result
	assert.Equal(t, 2, len(result), "Result should have exactly 3 variables")
}
