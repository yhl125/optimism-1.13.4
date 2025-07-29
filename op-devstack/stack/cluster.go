package stack

import (
	"log/slog"

	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/depset"
)

// ClusterID identifies a Cluster by name, is type-safe, and can be value-copied and used as map key.
type ClusterID genericID

var _ GenericID = (*ClusterID)(nil)

const ClusterKind Kind = "Cluster"

func (id ClusterID) String() string {
	return genericID(id).string(ClusterKind)
}

func (id ClusterID) Kind() Kind {
	return ClusterKind
}

func (id ClusterID) LogValue() slog.Value {
	return slog.StringValue(id.String())
}

func (id ClusterID) MarshalText() ([]byte, error) {
	return genericID(id).marshalText(ClusterKind)
}

func (id *ClusterID) UnmarshalText(data []byte) error {
	return (*genericID)(id).unmarshalText(ClusterKind, data)
}

func SortClusterIDs(ids []ClusterID) []ClusterID {
	return copyAndSortCmp(ids)
}

func SortClusters(elems []Cluster) []Cluster {
	return copyAndSort(elems, lessElemOrdered[ClusterID, Cluster])
}

var _ ClusterMatcher = ClusterID("")

func (id ClusterID) Match(elems []Cluster) []Cluster {
	return findByID(id, elems)
}

// Cluster represents a set of chains that interop with each other.
// This may include L1 chains (although potentially not two-way interop due to consensus-layer limitations).
type Cluster interface {
	Common
	ID() ClusterID

	DependencySet() depset.DependencySet
}
