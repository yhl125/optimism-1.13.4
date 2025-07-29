package contract

import (
	"fmt"

	"github.com/ethereum-optimism/optimism/op-devstack/dsl"
	"github.com/ethereum-optimism/optimism/op-service/txintent/bindings"
	"github.com/ethereum-optimism/optimism/op-service/txintent/contractio"
	"github.com/ethereum-optimism/optimism/op-service/txplan"
	"github.com/ethereum/go-ethereum/core/types"
)

// TestCallView is used in devstack for wrapping errors
type TestCallView[O any] interface {
	Test() bindings.BaseTest
}

// checkTestable checks whether the TypedCall can be used as a DSL using the testing context
func checkTestable[O any](call bindings.TypedCall[O]) {
	callTest, ok := any(call).(TestCallView[O])
	if !ok || callTest.Test() == nil {
		panic(fmt.Sprintf("call of type %T does not support testing", call))
	}
}

// Read executes a new message call without creating a transaction on the blockchain
func Read[O any](call bindings.TypedCall[O], opts ...txplan.Option) O {
	checkTestable(call)
	o, err := contractio.Read(call, call.Test().Ctx(), opts...)
	call.Test().Require().NoError(err)
	return o
}

// Write makes a user to write a tx by using the planned contract bindings
func Write[O any](user *dsl.EOA, call bindings.TypedCall[O], opts ...txplan.Option) *types.Receipt {
	checkTestable(call)
	finalOpts := txplan.Combine(user.Plan(), txplan.Combine(opts...))
	o, err := contractio.Write(call, call.Test().Ctx(), finalOpts)
	call.Test().Require().NoError(err)
	return o
}

var _ TestCallView[any] = (*bindings.TypedCall[any])(nil)
