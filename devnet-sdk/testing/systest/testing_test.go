package systest

import (
	"context"
	"fmt"
	"math/big"
	"os"
	"testing"

	"github.com/ethereum-optimism/optimism/devnet-sdk/shell/env"
	"github.com/ethereum-optimism/optimism/devnet-sdk/system"
	"github.com/ethereum-optimism/optimism/devnet-sdk/types"
	"github.com/ethereum-optimism/optimism/op-service/eth"
	supervisorTypes "github.com/ethereum-optimism/optimism/op-supervisor/supervisor/types"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/params"
	"github.com/stretchr/testify/require"
)

var (
	_ system.Chain   = (*mockChain[system.Node])(nil)
	_ system.L2Chain = (*mockL2Chain[system.Node])(nil)
)

// mockTB implements a minimal testing.TB for testing
type mockTB struct {
	testing.TB
	name      string
	failed    bool
	lastError string
}

func (m *mockTB) Helper()               {}
func (m *mockTB) Name() string          { return m.name }
func (m *mockTB) Cleanup(func())        {}
func (m *mockTB) Error(args ...any)     {}
func (m *mockTB) Errorf(string, ...any) {}
func (m *mockTB) Fail()                 {}
func (m *mockTB) FailNow()              {}
func (m *mockTB) Failed() bool          { return false }
func (m *mockTB) Fatal(args ...any) {
	m.failed = true
	m.lastError = fmt.Sprint(args...)
}
func (m *mockTB) Fatalf(format string, args ...any) {
	m.failed = true
	m.lastError = fmt.Sprintf(format, args...)
}
func (m *mockTB) Log(args ...any)          {}
func (m *mockTB) Logf(string, ...any)      {}
func (m *mockTB) Skip(args ...any)         {}
func (m *mockTB) SkipNow()                 {}
func (m *mockTB) Skipf(string, ...any)     {}
func (m *mockTB) Skipped() bool            { return false }
func (m *mockTB) TempDir() string          { return "" }
func (m *mockTB) Setenv(key, value string) {}

// mockTBRecorder extends mockTB to record test outcomes
type mockTBRecorder struct {
	mockTB
	skipped  bool
	failed   bool
	skipMsg  string
	fatalMsg string
}

func (m *mockTBRecorder) Skip(args ...any) { m.skipped = true }
func (m *mockTBRecorder) Skipf(f string, args ...any) {
	m.skipped = true
	m.skipMsg = fmt.Sprintf(f, args...)
}
func (m *mockTBRecorder) Fatal(args ...any) { m.failed = true }
func (m *mockTBRecorder) Fatalf(f string, args ...any) {
	m.failed = true
	m.fatalMsg = fmt.Sprintf(f, args...)
}
func (m *mockTBRecorder) Failed() bool  { return m.failed }
func (m *mockTBRecorder) Skipped() bool { return m.skipped }

// mockChain implements a minimal system.Chain for testing
type mockChain[T system.Node] struct {
	nodes []T
}

func (m *mockChain[T]) ID() types.ChainID { return types.ChainID(big.NewInt(1)) }
func (m *mockChain[T]) Wallets() system.WalletMap {
	return nil
}
func (m *mockChain[T]) Config() (*params.ChainConfig, error) {
	return nil, fmt.Errorf("not implemented on lowLevelMockChain")
}
func (m *mockChain[T]) Addresses() system.AddressMap {
	return system.AddressMap{}
}
func (m *mockChain[T]) Nodes() []T {
	return m.nodes
}

// mockL2Chain implements a minimal system.L2Chain for testing
type mockL2Chain[T system.Node] struct {
	mockChain[T]
}

func (m *mockL2Chain[T]) L1Addresses() system.AddressMap {
	return system.AddressMap{}
}
func (m *mockL2Chain[T]) L1Wallets() system.WalletMap {
	return system.WalletMap{}
}

// mockSystem implements a minimal system.System for testing
type mockSystem struct{}

func (m *mockSystem) Identifier() string { return "mock" }
func (m *mockSystem) L1() system.Chain   { return &mockChain[system.Node]{} }
func (m *mockSystem) L2s() []system.L2Chain {
	return []system.L2Chain{&mockL2Chain[system.Node]{}}
}
func (m *mockSystem) Close() error { return nil }

// mockInteropSet implements a minimal system.InteropSet for testing
type mockInteropSet struct{}

func (m *mockInteropSet) L2s() []system.L2Chain {
	return []system.L2Chain{&mockL2Chain[system.Node]{}}
}

// mockSupervisor implements the system.Supervisor interface for testing
type mockSupervisor struct{}

func (m *mockSupervisor) LocalUnsafe(ctx context.Context, chainID eth.ChainID) (eth.BlockID, error) {
	return eth.BlockID{}, nil
}

func (m *mockSupervisor) CrossSafe(ctx context.Context, chainID eth.ChainID) (supervisorTypes.DerivedIDPair, error) {
	return supervisorTypes.DerivedIDPair{}, nil
}

func (m *mockSupervisor) Finalized(ctx context.Context, chainID eth.ChainID) (eth.BlockID, error) {
	return eth.BlockID{}, nil
}

func (m *mockSupervisor) FinalizedL1(ctx context.Context) (eth.BlockRef, error) {
	return eth.BlockRef{}, nil
}

func (m *mockSupervisor) CrossDerivedToSource(ctx context.Context, chainID eth.ChainID, blockID eth.BlockID) (eth.BlockRef, error) {
	return eth.BlockRef{}, nil
}

func (m *mockSupervisor) UpdateLocalUnsafe(ctx context.Context, chainID eth.ChainID, blockRef eth.BlockRef) error {
	return nil
}

func (m *mockSupervisor) UpdateLocalSafe(ctx context.Context, chainID eth.ChainID, l1BlockRef eth.L1BlockRef, blockRef eth.BlockRef) error {
	return nil
}

func (m *mockSupervisor) SuperRootAtTimestamp(ctx context.Context, timestamp hexutil.Uint64) (eth.SuperRootResponse, error) {
	return eth.SuperRootResponse{}, nil
}

func (m *mockSupervisor) AllSafeDerivedAt(ctx context.Context, blockID eth.BlockID) (map[eth.ChainID]eth.BlockID, error) {
	return nil, nil
}

func (m *mockSupervisor) SyncStatus(ctx context.Context) (eth.SupervisorSyncStatus, error) {
	return eth.SupervisorSyncStatus{}, nil
}

// mockInteropSystem implements a minimal system.InteropSystem for testing
type mockInteropSystem struct {
	mockSystem
}

func (m *mockInteropSystem) InteropSet() system.InteropSet { return &mockInteropSet{} }

// Supervisor implements the system.InteropSystem interface
func (m *mockInteropSystem) Supervisor(ctx context.Context) (system.Supervisor, error) {
	return &mockSupervisor{}, nil
}

// newMockSystem creates a new mock system for testing
func newMockSystem() system.System {
	return &mockSystem{}
}

// newMockInteropSystem creates a new mock interop system for testing
func newMockInteropSystem() system.InteropSystem {
	return &mockInteropSystem{}
}

// testSystemCreator is a function that creates a system for testing
type testSystemCreator func() (system.System, error)

// testPackage is a test-specific implementation of the package
type testPackage struct {
	creator testSystemCreator
}

func (p *testPackage) NewSystemFromURL(string) (system.System, error) {
	return p.creator()
}

// TestNewT tests the creation and basic functionality of the test wrapper
func TestNewT(t *testing.T) {
	t.Run("wraps *testing.T correctly", func(t *testing.T) {
		wrapped := NewT(t)
		require.NotNil(t, wrapped)
		require.NotNil(t, wrapped.Context())
	})

	t.Run("preserves existing T implementation", func(t *testing.T) {
		original := NewT(t)
		wrapped := NewT(original)
		require.Equal(t, original, wrapped)
	})
}

// TestTWrapper tests the tbWrapper functionality
func TestTWrapper(t *testing.T) {
	t.Run("context operations", func(t *testing.T) {
		wrapped := NewT(t)
		key := &struct{}{}
		ctx := context.WithValue(context.Background(), key, "value")
		newWrapped := wrapped.WithContext(ctx)

		require.NotEqual(t, wrapped, newWrapped)
		require.Equal(t, "value", newWrapped.Context().Value(key))
	})

	t.Run("deadline", func(t *testing.T) {
		mock := &mockTB{name: "mock"}
		wrapped := NewT(mock)
		deadline, ok := wrapped.Deadline()
		require.False(t, ok, "deadline should not be set")
		require.True(t, deadline.IsZero(), "deadline should be zero time")
	})

	t.Run("parallel execution", func(t *testing.T) {
		wrapped := NewT(t)
		// Should not panic
		wrapped.Parallel()
	})

	t.Run("sub-tests", func(t *testing.T) {
		wrapped := NewT(t)
		subTestCalled := false
		wrapped.Run("sub-test", func(t T) {
			subTestCalled = true
			require.NotNil(t, t)
			require.NotNil(t, t.Context())
		})
		require.True(t, subTestCalled)
	})

	t.Run("nested sub-tests", func(t *testing.T) {
		wrapped := NewT(t)
		level1Called := false
		level2Called := false

		wrapped.Run("level-1", func(t T) {
			level1Called = true
			t.Run("level-2", func(t T) {
				level2Called = true
			})
		})

		require.True(t, level1Called)
		require.True(t, level2Called)
	})
}

// mockAcquirer creates a SystemAcquirer that returns the given system and error
func mockAcquirer(sys system.System, err error) SystemAcquirer {
	return func(t BasicT) (system.System, error) {
		return sys, err
	}
}

// TestTryAcquirers tests the tryAcquirers helper function directly
func TestTryAcquirers(t *testing.T) {
	t.Run("empty acquirers list", func(t *testing.T) {
		sys, err := tryAcquirers(t, nil)
		require.EqualError(t, err, "no acquirer was able to create a system")
		require.Nil(t, sys)
	})

	t.Run("skips nil,nil results", func(t *testing.T) {
		sys1 := newMockSystem()
		acquirers := []SystemAcquirer{
			mockAcquirer(nil, nil),  // skipped
			mockAcquirer(nil, nil),  // skipped
			mockAcquirer(sys1, nil), // selected and succeeds
		}
		sys, err := tryAcquirers(t, acquirers)
		require.NoError(t, err)
		require.Equal(t, sys1, sys)
	})

	t.Run("returns first non-skip result (success)", func(t *testing.T) {
		sys1, sys2 := newMockSystem(), newMockSystem()
		acquirers := []SystemAcquirer{
			mockAcquirer(nil, nil),  // skipped
			mockAcquirer(sys1, nil), // selected and succeeds
			mockAcquirer(sys2, nil), // not reached
		}
		sys, err := tryAcquirers(t, acquirers)
		require.NoError(t, err)
		require.Equal(t, sys1, sys)
	})

	t.Run("returns first non-skip result (failure)", func(t *testing.T) {
		expectedErr := fmt.Errorf("selected acquirer failed")
		sys1 := newMockSystem()
		acquirers := []SystemAcquirer{
			mockAcquirer(nil, nil),         // skipped
			mockAcquirer(nil, expectedErr), // selected and fails
			mockAcquirer(sys1, nil),        // not reached
		}
		sys, err := tryAcquirers(t, acquirers)
		require.ErrorIs(t, err, expectedErr)
		require.Nil(t, sys)
	})

	t.Run("all acquirers skip", func(t *testing.T) {
		acquirers := []SystemAcquirer{
			mockAcquirer(nil, nil),
			mockAcquirer(nil, nil),
		}
		sys, err := tryAcquirers(t, acquirers)
		require.EqualError(t, err, "no acquirer was able to create a system")
		require.Nil(t, sys)
	})
}

// TestSystemAcquisition tests the system acquisition functionality
func TestSystemAcquisition(t *testing.T) {
	t.Run("uses first non-skip acquirer (success)", func(t *testing.T) {
		sys1, sys2 := newMockSystem(), newMockSystem()
		acquirers := []SystemAcquirer{
			mockAcquirer(nil, nil),  // skipped
			mockAcquirer(sys1, nil), // selected and succeeds
			mockAcquirer(sys2, nil), // not reached
		}

		helper := newBasicSystemTestHelper(&mockEnvGetter{}).
			WithAcquirers(acquirers)

		var acquiredSys system.System
		helper.SystemTest(t, func(t T, sys system.System) {
			acquiredSys = sys
		})
		require.Equal(t, sys1, acquiredSys)
	})

	t.Run("fails when selected acquirer fails", func(t *testing.T) {
		testCases := []struct {
			name        string
			expectMet   bool
			expectSkip  bool
			expectFatal bool
		}{
			{
				name:        "preconditions not expected skips test",
				expectMet:   false,
				expectSkip:  true,
				expectFatal: false,
			},
			{
				name:        "preconditions expected fails test",
				expectMet:   true,
				expectSkip:  false,
				expectFatal: true,
			},
		}

		for _, tc := range testCases {
			t.Run(tc.name, func(t *testing.T) {
				expectedErr := fmt.Errorf("selected acquirer failed")
				acquirers := []SystemAcquirer{
					mockAcquirer(nil, nil),         // skipped
					mockAcquirer(nil, expectedErr), // selected and fails
				}

				// Create a new helper with the right configuration
				helper := newBasicSystemTestHelper(&mockEnvGetter{}).
					WithAcquirers(acquirers)
				helper.expectPreconditionsMet = tc.expectMet

				recorder := &mockTBRecorder{mockTB: mockTB{name: "test"}}
				helper.SystemTest(recorder, func(t T, sys system.System) {
					require.Fail(t, "should not reach here")
				})

				require.Equal(t, tc.expectSkip, recorder.skipped, "unexpected skip state")
				require.Equal(t, tc.expectFatal, recorder.failed, "unexpected fatal state")
				if tc.expectSkip {
					require.Contains(t, recorder.skipMsg, expectedErr.Error())
				}
				if tc.expectFatal {
					require.Contains(t, recorder.fatalMsg, expectedErr.Error())
				}
			})
		}
	})

	t.Run("fails when all acquirers skip", func(t *testing.T) {
		testCases := []struct {
			name        string
			expectMet   bool
			expectSkip  bool
			expectFatal bool
		}{
			{
				name:        "preconditions not expected skips test",
				expectMet:   false,
				expectSkip:  true,
				expectFatal: false,
			},
			{
				name:        "preconditions expected fails test",
				expectMet:   true,
				expectSkip:  false,
				expectFatal: true,
			},
		}

		for _, tc := range testCases {
			t.Run(tc.name, func(t *testing.T) {
				acquirers := []SystemAcquirer{
					mockAcquirer(nil, nil),
					mockAcquirer(nil, nil),
				}

				// Create a new helper with the right configuration
				helper := newBasicSystemTestHelper(&mockEnvGetter{}).
					WithAcquirers(acquirers)
				helper.expectPreconditionsMet = tc.expectMet

				recorder := &mockTBRecorder{mockTB: mockTB{name: "test"}}
				helper.SystemTest(recorder, func(t T, sys system.System) {
					require.Fail(t, "should not reach here")
				})

				require.Equal(t, tc.expectSkip, recorder.skipped, "unexpected skip state")
				require.Equal(t, tc.expectFatal, recorder.failed, "unexpected fatal state")
				if tc.expectSkip {
					require.Contains(t, recorder.skipMsg, "no acquirer was able to create a system")
				}
				if tc.expectFatal {
					require.Contains(t, recorder.fatalMsg, "no acquirer was able to create a system")
				}
			})
		}
	})

	t.Run("acquireFromEnvURL behavior", func(t *testing.T) {
		// Create a mockEnvGetter with the original env value
		origEnv := &mockEnvGetter{
			values: map[string]string{
				env.EnvURLVar: os.Getenv(env.EnvURLVar),
			},
		}

		t.Run("skips when env var not set", func(t *testing.T) {
			helper := newBasicSystemTestHelper(&mockEnvGetter{
				values: make(map[string]string),
			})
			sys, err := helper.acquireFromEnvURL(t)
			require.NoError(t, err)
			require.Nil(t, sys)
		})

		t.Run("fails with error for invalid URL", func(t *testing.T) {
			helper := newBasicSystemTestHelper(&mockEnvGetter{
				values: map[string]string{
					env.EnvURLVar: "invalid://url",
				},
			}).WithProvider(&testPackage{
				creator: func() (system.System, error) {
					return nil, fmt.Errorf("invalid URL")
				},
			})
			sys, err := helper.acquireFromEnvURL(t)
			require.Error(t, err)
			require.Nil(t, sys)
		})

		t.Run("succeeds with valid URL", func(t *testing.T) {
			mockSys := newMockSystem()
			helper := newBasicSystemTestHelper(&mockEnvGetter{
				values: map[string]string{
					env.EnvURLVar: "file:///valid/url",
				},
			}).WithProvider(&testPackage{
				creator: func() (system.System, error) {
					return mockSys, nil
				},
			})
			sys, err := helper.acquireFromEnvURL(t)
			require.NoError(t, err)
			require.Equal(t, mockSys, sys)
		})

		// Verify original environment is preserved by running a test with the original env
		t.Run("preserves original environment", func(t *testing.T) {
			helper := newBasicSystemTestHelper(origEnv)
			sys, err := helper.acquireFromEnvURL(t)
			if origEnv.values[env.EnvURLVar] == "" {
				require.NoError(t, err)
				require.Nil(t, sys)
			} else {
				// If there was a value, we'd need a provider to handle it properly
				helper = helper.WithProvider(&testPackage{
					creator: func() (system.System, error) {
						return newMockSystem(), nil
					},
				})
				sys, err = helper.acquireFromEnvURL(t)
				require.NoError(t, err)
				require.NotNil(t, sys)
			}
		})
	})
}
