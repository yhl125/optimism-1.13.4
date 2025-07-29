package kurtosis

import (
	"context"
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/ethereum-optimism/optimism/devnet-sdk/descriptors"
	"github.com/ethereum-optimism/optimism/kurtosis-devnet/pkg/kurtosis/api/fake"
	"github.com/ethereum-optimism/optimism/kurtosis-devnet/pkg/kurtosis/api/interfaces"
	"github.com/ethereum-optimism/optimism/kurtosis-devnet/pkg/kurtosis/sources/deployer"
	"github.com/ethereum-optimism/optimism/kurtosis-devnet/pkg/kurtosis/sources/inspect"
	"github.com/ethereum-optimism/optimism/kurtosis-devnet/pkg/kurtosis/sources/jwt"
	"github.com/ethereum-optimism/optimism/kurtosis-devnet/pkg/kurtosis/sources/spec"
	"github.com/ethereum/go-ethereum/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestKurtosisDeployer(t *testing.T) {
	tests := []struct {
		name        string
		opts        []KurtosisDeployerOptions
		wantBaseDir string
		wantPkg     string
		wantDryRun  bool
		wantEnclave string
	}{
		{
			name:        "default values",
			opts:        nil,
			wantBaseDir: ".",
			wantPkg:     DefaultPackageName,
			wantDryRun:  false,
			wantEnclave: DefaultEnclave,
		},
		{
			name: "with options",
			opts: []KurtosisDeployerOptions{
				WithKurtosisBaseDir("/custom/dir"),
				WithKurtosisPackageName("custom-package"),
				WithKurtosisDryRun(true),
				WithKurtosisEnclave("custom-enclave"),
			},
			wantBaseDir: "/custom/dir",
			wantPkg:     "custom-package",
			wantDryRun:  true,
			wantEnclave: "custom-enclave",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create a fake Kurtosis context
			fakeCtx := &fake.KurtosisContext{
				EnclaveCtx: &fake.EnclaveContext{
					Responses: []interfaces.StarlarkResponse{
						&fake.StarlarkResponse{
							IsSuccessful: true,
						},
					},
				},
			}

			// Add the fake context to the options
			opts := append(tt.opts, WithKurtosisKurtosisContext(fakeCtx))

			d, err := NewKurtosisDeployer(opts...)
			require.NoError(t, err)
			assert.Equal(t, tt.wantBaseDir, d.baseDir)
			assert.Equal(t, tt.wantPkg, d.packageName)
			assert.Equal(t, tt.wantDryRun, d.dryRun)
			assert.Equal(t, tt.wantEnclave, d.enclave)
		})
	}
}

// fakeEnclaveInspecter implements EnclaveInspecter for testing
type fakeEnclaveInspecter struct {
	result *inspect.InspectData
	err    error
}

func (f *fakeEnclaveInspecter) EnclaveInspect(ctx context.Context, enclave string) (*inspect.InspectData, error) {
	return f.result, f.err
}

// fakeEnclaveObserver implements EnclaveObserver for testing
type fakeEnclaveObserver struct {
	state *deployer.DeployerData
	err   error
}

func (f *fakeEnclaveObserver) EnclaveObserve(ctx context.Context, enclave string) (*deployer.DeployerData, error) {
	return f.state, f.err
}

// fakeEnclaveSpecifier implements EnclaveSpecifier for testing
type fakeEnclaveSpecifier struct {
	spec *spec.EnclaveSpec
	err  error
}

func (f *fakeEnclaveSpecifier) EnclaveSpec(r io.Reader) (*spec.EnclaveSpec, error) {
	return f.spec, f.err
}

// fakeJWTExtractor implements interfaces.JWTExtractor for testing
type fakeJWTExtractor struct {
	data *jwt.Data
	err  error
}

func (f *fakeJWTExtractor) ExtractData(ctx context.Context, enclave string) (*jwt.Data, error) {
	return f.data, f.err
}

type fakeDepsetExtractor struct {
	data map[string]descriptors.DepSet
	err  error
}

func (f *fakeDepsetExtractor) ExtractData(ctx context.Context, enclave string) (map[string]descriptors.DepSet, error) {
	return f.data, f.err
}

// mockKurtosisContext implements interfaces.KurtosisContextInterface for testing
type mockKurtosisContext struct {
	enclaveCtx interfaces.EnclaveContext
	getErr     error
	createErr  error
	cleanErr   error
	destroyErr error
}

func (m *mockKurtosisContext) GetEnclave(ctx context.Context, name string) (interfaces.EnclaveContext, error) {
	if m.getErr != nil {
		return nil, m.getErr
	}
	return m.enclaveCtx, nil
}

func (m *mockKurtosisContext) GetEnclaveStatus(ctx context.Context, name string) (interfaces.EnclaveStatus, error) {
	if m.getErr != nil {
		return "", m.getErr
	}
	return interfaces.EnclaveStatusRunning, nil
}

func (m *mockKurtosisContext) CreateEnclave(ctx context.Context, name string) (interfaces.EnclaveContext, error) {
	if m.createErr != nil {
		return nil, m.createErr
	}
	return m.enclaveCtx, nil
}

func (m *mockKurtosisContext) Clean(ctx context.Context, destroyAll bool) ([]interfaces.EnclaveNameAndUuid, error) {
	if m.cleanErr != nil {
		return nil, m.cleanErr
	}
	return []interfaces.EnclaveNameAndUuid{}, nil
}

func (m *mockKurtosisContext) DestroyEnclave(ctx context.Context, name string) error {
	if m.destroyErr != nil {
		return m.destroyErr
	}
	return nil
}

func TestDeploy(t *testing.T) {
	testSpec := &spec.EnclaveSpec{
		Chains: []*spec.ChainSpec{
			{
				Name:      "op-kurtosis",
				NetworkID: "1234",
			},
		},
	}

	testServices := make(inspect.ServiceMap)
	testServices["el-1-geth-lighthouse"] = &inspect.Service{
		Ports: inspect.PortMap{
			"rpc": {Port: 52645},
		},
	}

	testWallets := deployer.WalletList{
		{
			Name:       "test-wallet",
			Address:    common.HexToAddress("0x123"),
			PrivateKey: "0xabc",
		},
	}

	tests := []struct {
		name        string
		specErr     error
		inspectErr  error
		deployerErr error
		kurtosisErr error
		wantErr     bool
	}{
		{
			name: "successful deployment",
		},
		{
			name:    "spec error",
			specErr: fmt.Errorf("spec failed"),
			wantErr: true,
		},
		{
			name:       "inspect error",
			inspectErr: fmt.Errorf("inspect failed"),
			wantErr:    true,
		},
		{
			name:        "kurtosis error",
			kurtosisErr: fmt.Errorf("kurtosis failed"),
			wantErr:     true,
		},
		{
			name:        "deployer error",
			deployerErr: fmt.Errorf("deployer failed"),
			wantErr:     true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create a fake Kurtosis context that will return the test error
			fakeCtx := &fake.KurtosisContext{
				EnclaveCtx: &fake.EnclaveContext{
					RunErr: tt.kurtosisErr,
					// Send a successful run finished event for successful cases
					Responses: []interfaces.StarlarkResponse{
						&fake.StarlarkResponse{
							IsSuccessful: !tt.wantErr,
						},
					},
				},
			}

			d, err := NewKurtosisDeployer(
				WithKurtosisEnclaveSpec(&fakeEnclaveSpecifier{
					spec: testSpec,
					err:  tt.specErr,
				}),
				WithKurtosisEnclaveInspecter(&fakeEnclaveInspecter{
					result: &inspect.InspectData{
						UserServices: testServices,
					},
					err: tt.inspectErr,
				}),
				WithKurtosisEnclaveObserver(&fakeEnclaveObserver{
					state: &deployer.DeployerData{
						L1ValidatorWallets: testWallets,
					},
					err: tt.deployerErr,
				}),
				WithKurtosisKurtosisContext(fakeCtx),
			)
			require.NoError(t, err)

			_, err = d.Deploy(context.Background(), strings.NewReader("test input"))
			if tt.wantErr {
				assert.Error(t, err)
				return
			}

			require.NoError(t, err)
		})
	}
}

func TestGetEnvironmentInfo(t *testing.T) {
	testSpec := &spec.EnclaveSpec{
		Chains: []*spec.ChainSpec{
			{
				Name:      "op-kurtosis",
				NetworkID: "1234",
			},
		},
	}

	// Create test services map with the expected structure
	testServices := make(inspect.ServiceMap)
	testServices["el-1-geth-lighthouse"] = &inspect.Service{
		Ports: inspect.PortMap{
			"rpc": &descriptors.PortInfo{Port: 52645},
		},
	}

	testWallet := &deployer.Wallet{
		Name:       "test-wallet",
		Address:    common.HexToAddress("0x123"),
		PrivateKey: "0xabc",
	}
	testWallets := deployer.WalletList{testWallet}

	testJWTs := &jwt.Data{
		L1JWT: "test-l1-jwt",
		L2JWT: "test-l2-jwt",
	}

	// Create expected L1 services
	l1Services := make(descriptors.ServiceMap)
	l1Services["el"] = &descriptors.Service{
		Name: "el-1-geth-lighthouse",
		Endpoints: descriptors.EndpointMap{
			"rpc": &descriptors.PortInfo{Port: 52645},
		},
	}

	tests := []struct {
		name    string
		spec    *spec.EnclaveSpec
		inspect *inspect.InspectData
		deploy  *deployer.DeployerData
		jwt     *jwt.Data
		want    *KurtosisEnvironment
		wantErr bool
		err     error
	}{
		{
			name:    "successful environment info with JWT",
			spec:    testSpec,
			inspect: &inspect.InspectData{UserServices: testServices},
			deploy: &deployer.DeployerData{
				L1ValidatorWallets: testWallets,
				State: &deployer.DeployerState{
					Addresses: deployer.DeploymentAddresses{
						"0x123": common.HexToAddress("0x123"),
					},
				},
				L1ChainID: "1234",
			},
			jwt: testJWTs,
			want: &KurtosisEnvironment{
				DevnetEnvironment: &descriptors.DevnetEnvironment{
					Name:            DefaultEnclave,
					ReverseProxyURL: defaultKurtosisReverseProxyURL,
					L1: &descriptors.Chain{
						ID:       "1234",
						Name:     "Ethereum",
						Services: make(descriptors.RedundantServiceMap),
						Nodes: []descriptors.Node{
							{
								Services: l1Services,
							},
						},
						JWT: testJWTs.L1JWT,
						Addresses: descriptors.AddressMap{
							"0x123": common.HexToAddress("0x123"),
						},
						Wallets: descriptors.WalletMap{
							testWallet.Name: {
								Address:    testWallet.Address,
								PrivateKey: testWallet.PrivateKey,
							},
						},
					},
					L2: []*descriptors.L2Chain{
						{
							Chain: &descriptors.Chain{
								Name:     "op-kurtosis",
								ID:       "1234",
								Services: make(descriptors.RedundantServiceMap),
								JWT:      testJWTs.L2JWT,
							},
						},
					},
					DepSets: nil,
				},
			},
		},
		{
			name:    "inspect error",
			spec:    testSpec,
			err:     fmt.Errorf("inspect failed"),
			wantErr: true,
		},
		{
			name:    "deploy error",
			spec:    testSpec,
			inspect: &inspect.InspectData{UserServices: testServices},
			err:     fmt.Errorf("deploy failed"),
			wantErr: true,
		},
		{
			name:    "jwt error",
			spec:    testSpec,
			inspect: &inspect.InspectData{UserServices: testServices},
			deploy:  &deployer.DeployerData{},
			err:     fmt.Errorf("jwt failed"),
			wantErr: true,
		},
		{
			name: "with interop feature - depset fetched",
			spec: &spec.EnclaveSpec{
				Chains: []*spec.ChainSpec{
					{
						Name:      "op-kurtosis",
						NetworkID: "1234",
					},
				},
				Features: spec.FeatureList{spec.FeatureInterop},
			},
			inspect: &inspect.InspectData{UserServices: testServices},
			deploy: &deployer.DeployerData{
				L1ValidatorWallets: testWallets,
				State: &deployer.DeployerState{
					Addresses: deployer.DeploymentAddresses{
						"0x123": common.HexToAddress("0x123"),
					},
				},
				L1ChainID: "1234",
			},
			jwt: testJWTs,
			want: &KurtosisEnvironment{
				DevnetEnvironment: &descriptors.DevnetEnvironment{
					Name:            DefaultEnclave,
					ReverseProxyURL: defaultKurtosisReverseProxyURL,
					L1: &descriptors.Chain{
						ID:       "1234",
						Name:     "Ethereum",
						Services: make(descriptors.RedundantServiceMap),
						Nodes: []descriptors.Node{
							{
								Services: l1Services,
							},
						},
						JWT: testJWTs.L1JWT,
						Addresses: descriptors.AddressMap{
							"0x123": common.HexToAddress("0x123"),
						},
						Wallets: descriptors.WalletMap{
							testWallet.Name: {
								Address:    testWallet.Address,
								PrivateKey: testWallet.PrivateKey,
							},
						},
					},
					L2: []*descriptors.L2Chain{
						{
							Chain: &descriptors.Chain{
								Name:     "op-kurtosis",
								ID:       "1234",
								Services: make(descriptors.RedundantServiceMap),
								JWT:      testJWTs.L2JWT,
							},
						},
					},
					Features: spec.FeatureList{spec.FeatureInterop},
					DepSets:  map[string]descriptors.DepSet{"test-dep-set": descriptors.DepSet(`{}`)},
				},
			},
		},
		{
			name: "without interop feature - depset not fetched",
			spec: &spec.EnclaveSpec{
				Chains: []*spec.ChainSpec{
					{
						Name:      "op-kurtosis",
						NetworkID: "1234",
					},
				},
				Features: spec.FeatureList{},
			},
			inspect: &inspect.InspectData{UserServices: testServices},
			deploy: &deployer.DeployerData{
				L1ValidatorWallets: testWallets,
				State: &deployer.DeployerState{
					Addresses: deployer.DeploymentAddresses{
						"0x123": common.HexToAddress("0x123"),
					},
				},
				L1ChainID: "1234",
			},
			jwt: testJWTs,
			want: &KurtosisEnvironment{
				DevnetEnvironment: &descriptors.DevnetEnvironment{
					Name:            DefaultEnclave,
					ReverseProxyURL: defaultKurtosisReverseProxyURL,
					L1: &descriptors.Chain{
						ID:       "1234",
						Name:     "Ethereum",
						Services: make(descriptors.RedundantServiceMap),
						Nodes: []descriptors.Node{
							{
								Services: l1Services,
							},
						},
						JWT: testJWTs.L1JWT,
						Addresses: descriptors.AddressMap{
							"0x123": common.HexToAddress("0x123"),
						},
						Wallets: descriptors.WalletMap{
							testWallet.Name: {
								Address:    testWallet.Address,
								PrivateKey: testWallet.PrivateKey,
							},
						},
					},
					L2: []*descriptors.L2Chain{
						{
							Chain: &descriptors.Chain{
								Name:     "op-kurtosis",
								ID:       "1234",
								Services: make(descriptors.RedundantServiceMap),
								JWT:      testJWTs.L2JWT,
							},
						},
					},
					Features: spec.FeatureList{},
					DepSets:  nil,
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create a mock Kurtosis context that won't try to connect to a real engine
			mockCtx := &mockKurtosisContext{
				enclaveCtx: &fake.EnclaveContext{},
			}

			// Create depset data based on whether interop is enabled
			var depsets map[string]descriptors.DepSet
			if tt.spec != nil && tt.spec.Features.Contains(spec.FeatureInterop) {
				depsets = map[string]descriptors.DepSet{"test-dep-set": descriptors.DepSet(`{}`)}
			}

			deployer, err := NewKurtosisDeployer(
				WithKurtosisKurtosisContext(mockCtx),
				WithKurtosisEnclaveInspecter(&fakeEnclaveInspecter{
					result: tt.inspect,
					err:    tt.err,
				}),
				WithKurtosisEnclaveObserver(&fakeEnclaveObserver{
					state: tt.deploy,
					err:   tt.err,
				}),
				WithKurtosisJWTExtractor(&fakeJWTExtractor{
					data: tt.jwt,
					err:  tt.err,
				}),
				WithKurtosisDepsetExtractor(&fakeDepsetExtractor{
					data: depsets,
					err:  tt.err,
				}),
			)
			require.NoError(t, err)

			got, err := deployer.GetEnvironmentInfo(context.Background(), tt.spec)
			if tt.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			require.Equal(t, tt.want, got)
		})
	}
}
