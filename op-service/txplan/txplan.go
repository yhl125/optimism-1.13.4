package txplan

import (
	"context"
	"crypto/ecdsa"
	"errors"
	"fmt"
	"math/big"

	"github.com/ethereum-optimism/optimism/op-service/retry"
	"github.com/holiman/uint256"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"

	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-service/plan"
)

type PlannedTx struct {
	// Read is the result of reading the blockchain
	Read plan.Lazy[[]byte]

	// Block that we schedule against
	AgainstBlock  plan.Lazy[eth.BlockInfo]
	Unsigned      plan.Lazy[types.TxData]
	Signed        plan.Lazy[*types.Transaction]
	Submitted     plan.Lazy[struct{}]
	Included      plan.Lazy[*types.Receipt]
	IncludedBlock plan.Lazy[eth.BlockRef]
	Success       plan.Lazy[struct{}]

	Signer plan.Lazy[types.Signer]
	Priv   plan.Lazy[*ecdsa.PrivateKey]

	Sender plan.Lazy[common.Address]

	// How much more gas to use as limit than estimated
	GasRatio plan.Lazy[float64]

	Type       plan.Lazy[uint8]
	Data       plan.Lazy[hexutil.Bytes]
	ChainID    plan.Lazy[eth.ChainID]
	Nonce      plan.Lazy[uint64]
	GasTipCap  plan.Lazy[*big.Int]
	GasFeeCap  plan.Lazy[*big.Int]
	Gas        plan.Lazy[uint64]
	To         plan.Lazy[*common.Address]
	Value      plan.Lazy[*big.Int]
	AccessList plan.Lazy[types.AccessList]             // resolves to nil if not an attribute
	AuthList   plan.Lazy[[]types.SetCodeAuthorization] // resolves to nil if not a 7702 tx
}

func (ptx *PlannedTx) String() string {
	// success case should capture all contents
	return "PlannedTx:\n" + ptx.Success.String()
}

type Option func(tx *PlannedTx)

func Combine(opts ...Option) Option {
	return func(tx *PlannedTx) {
		for _, opt := range opts {
			opt(tx)
		}
	}
}

func NewPlannedTx(opts ...Option) *PlannedTx {
	tx := &PlannedTx{}
	tx.Defaults()
	Combine(opts...)(tx)
	return tx
}

func WithTo(to *common.Address) Option {
	return func(tx *PlannedTx) {
		tx.To.Set(to)
	}
}

func WithValue(val *big.Int) Option {
	return func(tx *PlannedTx) {
		tx.Value.Set(val)
	}
}

func WithData(data []byte) Option {
	return func(tx *PlannedTx) {
		tx.Data.Set(data)
	}
}

func WithNonce(nonce uint64) Option {
	return func(tx *PlannedTx) {
		tx.Nonce.Set(nonce)
	}
}

func WithSender(sender common.Address) Option {
	return func(tx *PlannedTx) {
		tx.Sender.Set(sender)
	}
}

func WithGasRatio(ratio float64) Option {
	return func(tx *PlannedTx) {
		tx.GasRatio.Set(ratio)
	}
}

func WithStaticNonce(nonce uint64) Option {
	return func(tx *PlannedTx) {
		tx.Nonce.Set(nonce)
		tx.Nonce.Fn(func(ctx context.Context) (uint64, error) {
			return nonce, nil
		})
	}
}

func WithAccessList(al types.AccessList) Option {
	return func(tx *PlannedTx) {
		tx.AccessList.Set(al)
	}
}

func WithAuthorizations(auths []types.SetCodeAuthorization) Option {
	return func(tx *PlannedTx) {
		tx.AuthList.Set(auths)
	}
}

func WithType(t uint8) Option {
	return func(tx *PlannedTx) {
		tx.Type.Set(t)
	}
}

func WithGasLimit(limit uint64) Option {
	return func(tx *PlannedTx) {
		tx.Gas.Set(limit)
	}
}

func WithGasFeeCap(feeCap *big.Int) Option {
	return func(tx *PlannedTx) {
		tx.GasFeeCap.Set(feeCap)
	}
}

func WithGasTipCap(tipCap *big.Int) Option {
	return func(tx *PlannedTx) {
		tx.GasTipCap.Set(tipCap)
	}
}

func WithPrivateKey(priv *ecdsa.PrivateKey) Option {
	return func(tx *PlannedTx) {
		tx.Priv.Set(priv)
	}
}

func WithEth(value *big.Int) Option {
	return func(tx *PlannedTx) {
		tx.Value.Set(value)
	}
}

func WithUnsigned(tx types.TxData) Option {
	return func(ptx *PlannedTx) {
		ptx.Unsigned.Set(tx)
	}
}

type Estimator interface {
	EstimateGas(ctx context.Context, msg ethereum.CallMsg) (uint64, error)
}

func WithEstimator(cl Estimator, invalidateOnNewBlock bool) Option {
	return func(tx *PlannedTx) {
		tx.Gas.DependOn(
			&tx.Sender,
			&tx.To,
			&tx.GasFeeCap,
			&tx.GasTipCap,
			&tx.Value,
			&tx.Data,
			&tx.AccessList,
			&tx.GasRatio,
		)
		if invalidateOnNewBlock {
			tx.Gas.DependOn(&tx.AgainstBlock)
		}
		tx.Gas.Fn(func(ctx context.Context) (uint64, error) {
			msg := ethereum.CallMsg{
				From:       tx.Sender.Value(),
				To:         tx.To.Value(),
				Gas:        0, // infinite gas, will be estimated
				GasPrice:   nil,
				GasFeeCap:  tx.GasFeeCap.Value(),
				GasTipCap:  tx.GasTipCap.Value(),
				Value:      tx.Value.Value(),
				Data:       tx.Data.Value(),
				AccessList: tx.AccessList.Value(),
			}
			gas, err := cl.EstimateGas(ctx, msg)
			if err != nil {
				return 0, err
			}
			ratio := tx.GasRatio.Value()
			gas = uint64(float64(gas) * ratio)
			return gas, nil
		})
	}
}

type TransactionSubmitter interface {
	SendTransaction(ctx context.Context, tx *types.Transaction) error
}

func WithTransactionSubmitter(cl TransactionSubmitter) Option {
	return func(tx *PlannedTx) {
		tx.Submitted.DependOn(&tx.Signed)
		tx.Submitted.Fn(func(ctx context.Context) (struct{}, error) {
			return struct{}{}, cl.SendTransaction(ctx, tx.Signed.Value())
		})
	}
}

func WithRetrySubmission(cl TransactionSubmitter, maxAttempts int, strategy retry.Strategy) Option {
	return func(tx *PlannedTx) {
		tx.Submitted.DependOn(&tx.Signed)
		tx.Submitted.Fn(func(ctx context.Context) (struct{}, error) {
			return struct{}{}, retry.Do0(ctx, maxAttempts, strategy, func() error {
				return cl.SendTransaction(ctx, tx.Signed.Value())
			})
		})
	}
}

type ReceiptGetter interface {
	TransactionReceipt(ctx context.Context, txHash common.Hash) (*types.Receipt, error)
}

// WithAssumedInclusion assumes inclusion at the time of evaluation,
// and simply looks up the tx without blocking on inclusion.
func WithAssumedInclusion(cl ReceiptGetter) Option {
	return func(tx *PlannedTx) {
		tx.Included.DependOn(&tx.Signed, &tx.Submitted)
		tx.Included.Fn(func(ctx context.Context) (*types.Receipt, error) {
			return cl.TransactionReceipt(ctx, tx.Signed.Value().Hash())
		})
	}
}

func WithRetryInclusion(cl ReceiptGetter, maxAttempts int, strategy retry.Strategy) Option {
	return func(tx *PlannedTx) {
		tx.Included.DependOn(&tx.Signed, &tx.Submitted)
		tx.Included.Fn(func(ctx context.Context) (*types.Receipt, error) {
			return cl.TransactionReceipt(ctx, tx.Signed.Value().Hash())
		})
		tx.Included.Wrap(func(fn plan.Fn[*types.Receipt]) plan.Fn[*types.Receipt] {
			return func(ctx context.Context) (*types.Receipt, error) {
				return retry.Do(ctx, maxAttempts, strategy, func() (*types.Receipt, error) {
					return fn(ctx)
				})
			}
		})
	}
}

type BlockGetter interface {
	BlockRefByHash(ctx context.Context, hash common.Hash) (eth.BlockRef, error)
}

func WithBlockInclusionInfo(cl BlockGetter) Option {
	return func(tx *PlannedTx) {
		tx.IncludedBlock.DependOn(&tx.Included)
		tx.IncludedBlock.Fn(func(ctx context.Context) (eth.BlockRef, error) {
			return cl.BlockRefByHash(ctx, tx.Included.Value().BlockHash)
		})
	}
}

type PendingNonceAt interface {
	PendingNonceAt(ctx context.Context, account common.Address) (uint64, error)
}

func WithPendingNonce(cl PendingNonceAt) Option {
	return func(tx *PlannedTx) {
		tx.Nonce.DependOn(&tx.AgainstBlock, &tx.Sender)
		tx.Nonce.Fn(func(ctx context.Context) (uint64, error) {
			return cl.PendingNonceAt(ctx, tx.Sender.Value())
		})
	}
}

type AgainstLatestBlock interface {
	InfoByLabel(ctx context.Context, label eth.BlockLabel) (eth.BlockInfo, error)
}

func WithAgainstLatestBlock(cl AgainstLatestBlock) Option {
	return func(tx *PlannedTx) {
		tx.AgainstBlock.Fn(func(ctx context.Context) (eth.BlockInfo, error) {
			return cl.InfoByLabel(ctx, eth.Unsafe)
		})
	}
}

// Reader uses eth_call to view(read) the blockchain, and does not write persistent changes to the chain.
// A call will return a byte string (that may be ABI-decoded), and does not have a receipt, as it was only simulated and not a persistent transaction.
type Reader interface {
	Call(ctx context.Context, msg ethereum.CallMsg) ([]byte, error)
}

func WithReader(cl Reader) Option {
	return func(tx *PlannedTx) {
		tx.Read.DependOn(
			&tx.Sender,
			&tx.To,
			&tx.GasFeeCap,
			&tx.GasTipCap,
			&tx.Value,
			&tx.Data,
			&tx.AccessList,
		)
		tx.Read.Fn(func(ctx context.Context) ([]byte, error) {
			msg := ethereum.CallMsg{
				From:       tx.Sender.Value(),
				To:         tx.To.Value(),
				Gas:        0, // auto estimated by the node
				GasPrice:   nil,
				GasFeeCap:  tx.GasFeeCap.Value(),
				GasTipCap:  tx.GasTipCap.Value(),
				Value:      tx.Value.Value(),
				Data:       tx.Data.Value(),
				AccessList: tx.AccessList.Value(),
			}
			return cl.Call(ctx, msg)
		})
	}
}

type ChainID interface {
	ChainID(ctx context.Context) (*big.Int, error)
}

func WithChainID(cl ChainID) Option {
	return func(tx *PlannedTx) {
		tx.ChainID.Fn(func(ctx context.Context) (eth.ChainID, error) {
			chainID, err := cl.ChainID(ctx)
			if err != nil {
				return eth.ChainID{}, err
			}
			return eth.ChainIDFromBig(chainID), nil
		})
	}
}

func (tx *PlannedTx) Defaults() {
	tx.Type.Set(types.DynamicFeeTxType)
	tx.To.Set(nil)
	tx.Data.Set([]byte{})
	tx.ChainID.Set(eth.ChainIDFromUInt64(1))
	tx.GasRatio.Set(1.0)
	tx.GasTipCap.Set(big.NewInt(1e9)) // 1 gwei
	tx.Gas.Set(params.TxGas)
	tx.Value.Set(big.NewInt(0))
	tx.Nonce.Set(0)
	tx.AccessList.Set(types.AccessList{})
	tx.AuthList.Set([]types.SetCodeAuthorization{})

	// Bump the fee-cap to be at least as high as the tip-cap,
	// and as high as the basefee.
	tx.GasFeeCap.DependOn(&tx.GasTipCap, &tx.AgainstBlock)
	tx.GasFeeCap.Fn(func(ctx context.Context) (*big.Int, error) {
		tip := tx.GasTipCap.Value()
		basefee := tx.AgainstBlock.Value().BaseFee()
		feeCap := big.NewInt(0)
		feeCap = feeCap.Add(tip, basefee)
		return feeCap, nil
	})

	// Automatically determine tx-signer from chainID
	tx.Signer.DependOn(&tx.ChainID)
	tx.Signer.Fn(func(ctx context.Context) (types.Signer, error) {
		chainID := tx.ChainID.Value()
		return types.LatestSignerForChainID(chainID.ToBig()), nil
	})

	// Automatically determine sender from private key
	tx.Sender.DependOn(&tx.Priv)
	tx.Sender.Fn(func(ctx context.Context) (common.Address, error) {
		return crypto.PubkeyToAddress(tx.Priv.Value().PublicKey), nil
	})

	// Automatically build tx from the individual attributes
	tx.Unsigned.DependOn(
		&tx.Sender,
		&tx.Type,
		&tx.Data,
		&tx.ChainID,
		&tx.Nonce,
		&tx.GasTipCap,
		&tx.GasFeeCap,
		&tx.Gas,
		&tx.To,
		&tx.Value,
		&tx.AccessList,
		&tx.AuthList,
	)
	tx.Unsigned.Fn(func(ctx context.Context) (types.TxData, error) {
		chainID := tx.ChainID.Value()
		switch tx.Type.Value() {
		case types.LegacyTxType:
			return &types.LegacyTx{
				Nonce:    tx.Nonce.Value(),
				GasPrice: tx.GasFeeCap.Value(),
				Gas:      tx.Gas.Value(),
				To:       tx.To.Value(),
				Value:    tx.Value.Value(),
				Data:     tx.Data.Value(),
				V:        nil,
				R:        nil,
				S:        nil,
			}, nil
		case types.AccessListTxType:
			return &types.AccessListTx{
				ChainID:    chainID.ToBig(),
				Nonce:      tx.Nonce.Value(),
				GasPrice:   tx.GasFeeCap.Value(),
				Gas:        tx.Gas.Value(),
				To:         tx.To.Value(),
				Value:      tx.Value.Value(),
				Data:       tx.Data.Value(),
				AccessList: tx.AccessList.Value(),
				V:          nil,
				R:          nil,
				S:          nil,
			}, nil
		case types.DynamicFeeTxType:
			return &types.DynamicFeeTx{
				ChainID:    chainID.ToBig(),
				Nonce:      tx.Nonce.Value(),
				GasTipCap:  tx.GasTipCap.Value(),
				GasFeeCap:  tx.GasFeeCap.Value(),
				Gas:        tx.Gas.Value(),
				To:         tx.To.Value(),
				Value:      tx.Value.Value(),
				Data:       tx.Data.Value(),
				AccessList: tx.AccessList.Value(),
				V:          nil,
				R:          nil,
				S:          nil,
			}, nil
		case types.SetCodeTxType:
			if tx.To.Value() == nil {
				return nil, errors.New("to address required for SetCodeTx")
			}

			return &types.SetCodeTx{
				ChainID:    uint256.MustFromBig(chainID.ToBig()),
				Nonce:      tx.Nonce.Value(),
				GasTipCap:  uint256.MustFromBig(tx.GasTipCap.Value()),
				GasFeeCap:  uint256.MustFromBig(tx.GasFeeCap.Value()),
				Gas:        tx.Gas.Value(),
				To:         *tx.To.Value(),
				Value:      uint256.MustFromBig(tx.Value.Value()),
				Data:       tx.Data.Value(),
				AccessList: tx.AccessList.Value(),
				AuthList:   tx.AuthList.Value(),
				V:          nil,
				R:          nil,
				S:          nil,
			}, nil
		case types.BlobTxType:
			return nil, errors.New("blob tx not supported")
		case types.DepositTxType:
			return nil, errors.New("deposit tx not supported")
		default:
			return nil, fmt.Errorf("unrecognized tx type: %d", tx.Type.Value())
		}
	})
	// Sign with the available key
	tx.Signed.DependOn(&tx.Priv, &tx.Signer, &tx.Unsigned)
	tx.Signed.Fn(func(ctx context.Context) (*types.Transaction, error) {
		innerTx := tx.Unsigned.Value()
		signer := tx.Signer.Value()
		prv := tx.Priv.Value()
		return types.SignNewTx(prv, signer, innerTx)
	})

	tx.Success.DependOn(&tx.Included)
	tx.Success.Fn(func(ctx context.Context) (struct{}, error) {
		rec, err := tx.Included.Get()
		if err != nil {
			return struct{}{}, err
		}
		if rec.Status == types.ReceiptStatusSuccessful {
			return struct{}{}, nil
		} else {
			return struct{}{}, errors.New("tx failed")
		}
	})
}
