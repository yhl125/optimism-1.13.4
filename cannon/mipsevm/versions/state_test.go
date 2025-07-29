package versions

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/ethereum-optimism/optimism/cannon/mipsevm"
	"github.com/ethereum-optimism/optimism/cannon/mipsevm/multithreaded"
	"github.com/ethereum-optimism/optimism/op-service/serialize"
)

func TestNewFromState(t *testing.T) {
	for _, version := range StateVersionTypes {
		if !IsSupportedMultiThreaded64(version) {
			t.Run(version.String()+"-unsupported", func(t *testing.T) {
				_, err := NewFromState(version, multithreaded.CreateEmptyState())
				require.ErrorIs(t, err, ErrUnsupportedVersion)
			})
		} else {
			t.Run(version.String(), func(t *testing.T) {
				actual, err := NewFromState(version, multithreaded.CreateEmptyState())
				require.NoError(t, err)
				require.IsType(t, &multithreaded.State{}, actual.FPVMState)
				require.Equal(t, version, actual.Version)
			})
		}
	}
}

func TestLoadStateFromFile(t *testing.T) {
	for _, version := range StateVersionTypes {
		if !IsSupportedMultiThreaded64(version) {
			continue
		}
		t.Run(version.String(), func(t *testing.T) {
			expected, err := NewFromState(version, multithreaded.CreateEmptyState())
			require.NoError(t, err)

			path := writeToFile(t, "state.bin.gz", expected)
			actual, err := LoadStateFromFile(path)
			require.NoError(t, err)
			require.Equal(t, expected, actual)
		})
	}
}

type versionAndStateCreator struct {
	version     StateVersion
	createState func() mipsevm.FPVMState
}

func TestVersionsOtherThanZeroDoNotSupportJSON(t *testing.T) {
	var tests []struct {
		version     StateVersion
		createState func() mipsevm.FPVMState
	}
	for _, version := range StateVersionTypes {
		if !IsSupportedMultiThreaded64(version) {
			continue
		}
		tests = append(tests, versionAndStateCreator{version: version, createState: func() mipsevm.FPVMState { return multithreaded.CreateEmptyState() }})
	}
	for _, test := range tests {
		test := test
		t.Run(test.version.String(), func(t *testing.T) {
			state, err := NewFromState(test.version, test.createState())
			require.NoError(t, err)

			dir := t.TempDir()
			path := filepath.Join(dir, "test.json")
			err = serialize.Write(path, state, 0o644)
			require.ErrorIs(t, err, ErrJsonNotSupported)
		})
	}
}
