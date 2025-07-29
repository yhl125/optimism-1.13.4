package interfaces

import (
	"fmt"

	"github.com/ethereum-optimism/optimism/devnet-sdk/types"
	"github.com/ethereum/go-ethereum/accounts/abi"
)

// ErrContractNotFound indicates that a contract is not available at the requested address
type ErrContractNotFound struct {
	ContractType string
	Address      types.Address
}

func (e *ErrContractNotFound) Error() string {
	return fmt.Sprintf("%s contract not found at %s", e.ContractType, e.Address)
}

// ContractsRegistry provides access to all supported contract instances
type ContractsRegistry interface {
	WETH(address types.Address) (WETH, error)
	L2ToL2CrossDomainMessenger(address types.Address) (L2ToL2CrossDomainMessenger, error)
}

// WETH represents the interface for interacting with the WETH contract
type WETH interface {
	BalanceOf(user types.Address) types.ReadInvocation[types.Balance]
}

type L2ToL2CrossDomainMessenger interface {
	ABI() *abi.ABI
}
