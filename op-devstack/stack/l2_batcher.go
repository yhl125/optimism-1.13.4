package stack

import (
	"log/slog"

	"github.com/ethereum-optimism/optimism/op-service/apis"
	"github.com/ethereum-optimism/optimism/op-service/eth"
)

// L2BatcherID identifies a L2Batcher by name and chainID, is type-safe, and can be value-copied and used as map key.
type L2BatcherID idWithChain

var _ IDWithChain = (*L2BatcherID)(nil)

const L2BatcherKind Kind = "L2Batcher"

func NewL2BatcherID(key string, chainID eth.ChainID) L2BatcherID {
	return L2BatcherID{
		key:     key,
		chainID: chainID,
	}
}

func (id L2BatcherID) String() string {
	return idWithChain(id).string(L2BatcherKind)
}

func (id L2BatcherID) ChainID() eth.ChainID {
	return id.chainID
}

func (id L2BatcherID) Kind() Kind {
	return L2BatcherKind
}

func (id L2BatcherID) Key() string {
	return id.key
}

func (id L2BatcherID) LogValue() slog.Value {
	return slog.StringValue(id.String())
}

func (id L2BatcherID) MarshalText() ([]byte, error) {
	return idWithChain(id).marshalText(L2BatcherKind)
}

func (id *L2BatcherID) UnmarshalText(data []byte) error {
	return (*idWithChain)(id).unmarshalText(L2BatcherKind, data)
}

func SortL2BatcherIDs(ids []L2BatcherID) []L2BatcherID {
	return copyAndSort(ids, func(a, b L2BatcherID) bool {
		return lessIDWithChain(idWithChain(a), idWithChain(b))
	})
}

func SortL2Batchers(elems []L2Batcher) []L2Batcher {
	return copyAndSort(elems, func(a, b L2Batcher) bool {
		return lessIDWithChain(idWithChain(a.ID()), idWithChain(b.ID()))
	})
}

var _ L2BatcherMatcher = L2BatcherID{}

func (id L2BatcherID) Match(elems []L2Batcher) []L2Batcher {
	return findByID(id, elems)
}

// L2Batcher represents an L2 batch-submission service, posting L2 data of an L2 to L1.
type L2Batcher interface {
	Common
	ID() L2BatcherID
	ActivityAPI() apis.BatcherActivity
}
