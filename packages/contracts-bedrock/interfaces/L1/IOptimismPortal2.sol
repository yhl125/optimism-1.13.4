// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Types } from "src/libraries/Types.sol";
import { GameType } from "src/dispute/lib/LibUDT.sol";
import { IDisputeGame } from "interfaces/dispute/IDisputeGame.sol";
import { IDisputeGameFactory } from "interfaces/dispute/IDisputeGameFactory.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";
import { IAnchorStateRegistry } from "interfaces/dispute/IAnchorStateRegistry.sol";
import { IProxyAdminOwnedBase } from "interfaces/L1/IProxyAdminOwnedBase.sol";
import { IETHLockbox } from "interfaces/L1/IETHLockbox.sol";

interface IOptimismPortal2 is IProxyAdminOwnedBase {
    error OptimismPortal_Unauthorized();
    error ContentLengthMismatch();
    error EmptyItem();
    error InvalidDataRemainder();
    error InvalidHeader();
    error ReinitializableBase_ZeroInitVersion();
    error OptimismPortal_AlreadyFinalized();
    error OptimismPortal_BadTarget();
    error OptimismPortal_CallPaused();
    error OptimismPortal_CalldataTooLarge();
    error OptimismPortal_GasEstimation();
    error OptimismPortal_GasLimitTooLow();
    error OptimismPortal_ImproperDisputeGame();
    error OptimismPortal_InvalidDisputeGame();
    error OptimismPortal_InvalidMerkleProof();
    error OptimismPortal_InvalidOutputRootProof();
    error OptimismPortal_InvalidProofTimestamp();
    error OptimismPortal_InvalidRootClaim();
    error OptimismPortal_NoReentrancy();
    error OptimismPortal_ProofNotOldEnough();
    error OptimismPortal_Unproven();
    error OptimismPortal_InvalidOutputRootIndex();
    error OptimismPortal_InvalidSuperRootProof();
    error OptimismPortal_InvalidOutputRootChainId();
    error OptimismPortal_WrongProofMethod();
    error OptimismPortal_MigratingToSameRegistry();
    error Encoding_EmptySuperRoot();
    error Encoding_InvalidSuperRootVersion();
    error OutOfGas();
    error UnexpectedList();
    error UnexpectedString();

    event Initialized(uint8 version);
    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);
    event WithdrawalFinalized(bytes32 indexed withdrawalHash, bool success);
    event WithdrawalProven(bytes32 indexed withdrawalHash, address indexed from, address indexed to);
    event WithdrawalProvenExtension1(bytes32 indexed withdrawalHash, address indexed proofSubmitter);
    event ETHMigrated(address indexed lockbox, uint256 ethBalance);
    event PortalMigrated(IETHLockbox oldLockbox, IETHLockbox newLockbox, IAnchorStateRegistry oldAnchorStateRegistry, IAnchorStateRegistry newAnchorStateRegistry);

    receive() external payable;

    function anchorStateRegistry() external view returns (IAnchorStateRegistry);
    function ethLockbox() external view returns (IETHLockbox);
    function checkWithdrawal(bytes32 _withdrawalHash, address _proofSubmitter) external view;
    function depositTransaction(
        address _to,
        uint256 _value,
        uint64 _gasLimit,
        bool _isCreation,
        bytes memory _data
    )
        external
        payable;
    function disputeGameBlacklist(IDisputeGame _disputeGame) external view returns (bool);
    function disputeGameFactory() external view returns (IDisputeGameFactory);
    function disputeGameFinalityDelaySeconds() external view returns (uint256);
    function donateETH() external payable;
    function superchainConfig() external view returns (ISuperchainConfig);
    function migrateToSuperRoots(IETHLockbox _newLockbox, IAnchorStateRegistry _newAnchorStateRegistry) external;
    function finalizeWithdrawalTransaction(Types.WithdrawalTransaction memory _tx) external;
    function finalizeWithdrawalTransactionExternalProof(
        Types.WithdrawalTransaction memory _tx,
        address _proofSubmitter
    )
        external;
    function finalizedWithdrawals(bytes32) external view returns (bool);
    function guardian() external view returns (address);
    function initialize(
        ISystemConfig _systemConfig,
        IAnchorStateRegistry _anchorStateRegistry,
        IETHLockbox _ethLockbox
    )
        external;
    function initVersion() external view returns (uint8);
    function l2Sender() external view returns (address);
    function minimumGasLimit(uint64 _byteCount) external pure returns (uint64);
    function numProofSubmitters(bytes32 _withdrawalHash) external view returns (uint256);
    function params() external view returns (uint128 prevBaseFee, uint64 prevBoughtGas, uint64 prevBlockNum); // nosemgrep
    function paused() external view returns (bool);
    function proofMaturityDelaySeconds() external view returns (uint256);
    function proofSubmitters(bytes32, uint256) external view returns (address);
    function proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        uint256 _disputeGameIndex,
        Types.OutputRootProof memory _outputRootProof,
        bytes[] memory _withdrawalProof
    )
        external;
    function proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        IDisputeGame _disputeGameProxy,
        uint256 _outputRootIndex,
        Types.SuperRootProof memory _superRootProof,
        Types.OutputRootProof memory _outputRootProof,
        bytes[] memory _withdrawalProof
    )
        external;
    function provenWithdrawals(
        bytes32,
        address
    )
        external
        view
        returns (IDisputeGame disputeGameProxy, uint64 timestamp);
    function respectedGameType() external view returns (GameType);
    function respectedGameTypeUpdatedAt() external view returns (uint64);
    function superRootsActive() external view returns (bool);
    function systemConfig() external view returns (ISystemConfig);
    function upgrade(IAnchorStateRegistry _anchorStateRegistry, IETHLockbox _ethLockbox) external;
    function version() external pure returns (string memory);
    function migrateLiquidity() external;

    function __constructor__(uint256 _proofMaturityDelaySeconds) external;
}
