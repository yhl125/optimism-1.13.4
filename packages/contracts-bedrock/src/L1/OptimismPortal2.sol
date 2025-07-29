// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Contracts
import { ProxyAdminOwnedBase } from "src/L1/ProxyAdminOwnedBase.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { ResourceMetering } from "src/L1/ResourceMetering.sol";
import { ReinitializableBase } from "src/universal/ReinitializableBase.sol";

// Libraries
import { EOA } from "src/libraries/EOA.sol";
import { SafeCall } from "src/libraries/SafeCall.sol";
import { Constants } from "src/libraries/Constants.sol";
import { Types } from "src/libraries/Types.sol";
import { Hashing } from "src/libraries/Hashing.sol";
import { SecureMerkleTrie } from "src/libraries/trie/SecureMerkleTrie.sol";
import { AddressAliasHelper } from "src/vendor/AddressAliasHelper.sol";
import { GameStatus, GameType } from "src/dispute/lib/Types.sol";

// Interfaces
import { ISemver } from "interfaces/universal/ISemver.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { IResourceMetering } from "interfaces/L1/IResourceMetering.sol";
import { IDisputeGameFactory } from "interfaces/dispute/IDisputeGameFactory.sol";
import { IDisputeGame } from "interfaces/dispute/IDisputeGame.sol";
import { IAnchorStateRegistry } from "interfaces/dispute/IAnchorStateRegistry.sol";
import { IETHLockbox } from "interfaces/L1/IETHLockbox.sol";
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";

/// @custom:proxied true
/// @title OptimismPortal2
/// @notice The OptimismPortal is a low-level contract responsible for passing messages between L1
///         and L2. Messages sent directly to the OptimismPortal have no form of replayability.
///         Users are encouraged to use the L1CrossDomainMessenger for a higher-level interface.
contract OptimismPortal2 is Initializable, ResourceMetering, ReinitializableBase, ProxyAdminOwnedBase, ISemver {
    /// @notice Represents a proven withdrawal.
    /// @custom:field disputeGameProxy Game that the withdrawal was proven against.
    /// @custom:field timestamp        Timestamp at which the withdrawal was proven.
    struct ProvenWithdrawal {
        IDisputeGame disputeGameProxy;
        uint64 timestamp;
    }

    /// @notice The delay between when a withdrawal is proven and when it may be finalized.
    uint256 internal immutable PROOF_MATURITY_DELAY_SECONDS;

    /// @notice Version of the deposit event.
    uint256 internal constant DEPOSIT_VERSION = 0;

    /// @notice The L2 gas limit set when eth is deposited using the receive() function.
    uint64 internal constant RECEIVE_DEFAULT_GAS_LIMIT = 100_000;

    /// @notice Address of the L2 account which initiated a withdrawal in this transaction.
    ///         If the value of this variable is the default L2 sender address, then we are NOT
    ///         inside of a call to finalizeWithdrawalTransaction.
    address public l2Sender;

    /// @notice A list of withdrawal hashes which have been successfully finalized.
    mapping(bytes32 => bool) public finalizedWithdrawals;

    /// @custom:legacy
    /// @custom:spacer provenWithdrawals
    /// @notice Spacer taking up the legacy `provenWithdrawals` mapping slot.
    bytes32 private spacer_52_0_32;

    /// @custom:legacy
    /// @custom:spacer paused
    /// @notice Spacer for backwards compatibility.
    bool private spacer_53_0_1;

    /// @custom:legacy
    /// @custom:spacer superchainConfig
    /// @notice Spacer for backwards compatibility.
    address private spacer_53_1_20;

    /// @custom:legacy
    /// @custom:spacer l2Oracle
    /// @notice Spacer taking up the legacy `l2Oracle` address slot.
    address private spacer_54_0_20;

    /// @notice Address of the SystemConfig contract.
    /// @custom:network-specific
    ISystemConfig public systemConfig;

    /// @custom:network-specific
    /// @custom:legacy
    /// @custom:spacer disputeGameFactory
    /// @notice Spacer taking up the legacy `disputeGameFactory` address slot.
    address private spacer_56_0_20;

    /// @notice A mapping of withdrawal hashes to proof submitters to ProvenWithdrawal data.
    mapping(bytes32 => mapping(address => ProvenWithdrawal)) public provenWithdrawals;

    /// @custom:legacy
    /// @custom:spacer disputeGameBlacklist
    bytes32 private spacer_58_0_32;

    /// @custom:legacy
    /// @custom:spacer respectedGameType
    GameType private spacer_59_0_4;

    /// @custom:legacy
    /// @custom:spacer respectedGameTypeUpdatedAt
    uint64 private spacer_59_4_8;

    /// @notice Mapping of withdrawal hashes to addresses that have submitted a proof for the
    ///         withdrawal. Original OptimismPortal contract only allowed one proof to be submitted
    ///         for any given withdrawal hash. Fault Proofs version of this contract must allow
    ///         multiple proofs for the same withdrawal hash to prevent a malicious user from
    ///         blocking other withdrawals by proving them against invalid proposals. Submitters
    ///         are tracked in an array to simplify the off-chain process of determining which
    ///         proof submission should be used when finalizing a withdrawal.
    mapping(bytes32 => address[]) public proofSubmitters;

    /// @custom:legacy
    /// @custom:spacer _balance
    uint256 private spacer_61_0_32;

    /// @notice Address of the AnchorStateRegistry contract.
    IAnchorStateRegistry public anchorStateRegistry;

    /// @notice Address of the ETHLockbox contract.
    IETHLockbox public ethLockbox;

    /// @notice Whether the OptimismPortal is using Super Roots or Output Roots.
    bool public superRootsActive;

    /// @notice Emitted when a transaction is deposited from L1 to L2. The parameters of this event
    ///         are read by the rollup node and used to derive deposit transactions on L2.
    /// @param from       Address that triggered the deposit transaction.
    /// @param to         Address that the deposit transaction is directed to.
    /// @param version    Version of this deposit transaction event.
    /// @param opaqueData ABI encoded deposit data to be parsed off-chain.
    event TransactionDeposited(address indexed from, address indexed to, uint256 indexed version, bytes opaqueData);

    /// @notice Emitted when a withdrawal transaction is proven.
    /// @param withdrawalHash Hash of the withdrawal transaction.
    /// @param from           Address that triggered the withdrawal transaction.
    /// @param to             Address that the withdrawal transaction is directed to.
    event WithdrawalProven(bytes32 indexed withdrawalHash, address indexed from, address indexed to);

    /// @notice Emitted when a withdrawal transaction is proven. Exists as a separate event to
    ///         allow for backwards compatibility for tooling that observes the WithdrawalProven
    ///         event.
    /// @param withdrawalHash Hash of the withdrawal transaction.
    /// @param proofSubmitter Address of the proof submitter.
    event WithdrawalProvenExtension1(bytes32 indexed withdrawalHash, address indexed proofSubmitter);

    /// @notice Emitted when a withdrawal transaction is finalized.
    /// @param withdrawalHash Hash of the withdrawal transaction.
    /// @param success        Whether the withdrawal transaction was successful.
    event WithdrawalFinalized(bytes32 indexed withdrawalHash, bool success);

    /// @notice Emitted when the total ETH balance is migrated to the ETHLockbox.
    /// @param lockbox The address of the ETHLockbox contract.
    /// @param ethBalance Amount of ETH migrated.
    event ETHMigrated(address indexed lockbox, uint256 ethBalance);

    /// @notice Emitted when the ETHLockbox contract is updated.
    /// @param oldLockbox The address of the old ETHLockbox contract.
    /// @param newLockbox The address of the new ETHLockbox contract.
    /// @param oldAnchorStateRegistry The address of the old AnchorStateRegistry contract.
    /// @param newAnchorStateRegistry The address of the new AnchorStateRegistry contract.
    event PortalMigrated(
        IETHLockbox oldLockbox,
        IETHLockbox newLockbox,
        IAnchorStateRegistry oldAnchorStateRegistry,
        IAnchorStateRegistry newAnchorStateRegistry
    );

    /// @notice Thrown when a withdrawal has already been finalized.
    error OptimismPortal_AlreadyFinalized();

    /// @notice Thrown when the target of a withdrawal is unsafe.
    error OptimismPortal_BadTarget();

    /// @notice Thrown when the calldata for a deposit is too large.
    error OptimismPortal_CalldataTooLarge();

    /// @notice Thrown when the portal is paused.
    error OptimismPortal_CallPaused();

    /// @notice Thrown when a gas estimation transaction is being executed.
    error OptimismPortal_GasEstimation();

    /// @notice Thrown when the gas limit for a deposit is too low.
    error OptimismPortal_GasLimitTooLow();

    /// @notice Thrown when the target of a withdrawal is not a proper dispute game.
    error OptimismPortal_ImproperDisputeGame();

    /// @notice Thrown when a withdrawal has not been proven against a valid dispute game.
    error OptimismPortal_InvalidDisputeGame();

    /// @notice Thrown when a withdrawal has not been proven against a valid merkle proof.
    error OptimismPortal_InvalidMerkleProof();

    /// @notice Thrown when a withdrawal has not been proven against a valid output root proof.
    error OptimismPortal_InvalidOutputRootProof();

    /// @notice Thrown when a withdrawal's timestamp is not greater than the dispute game's creation timestamp.
    error OptimismPortal_InvalidProofTimestamp();

    /// @notice Thrown when the root claim of a dispute game is invalid.
    error OptimismPortal_InvalidRootClaim();

    /// @notice Thrown when a withdrawal is being finalized by a reentrant call.
    error OptimismPortal_NoReentrancy();

    /// @notice Thrown when a withdrawal has not been proven for long enough.
    error OptimismPortal_ProofNotOldEnough();

    /// @notice Thrown when a withdrawal has not been proven.
    error OptimismPortal_Unproven();

    /// @notice Thrown when the caller is not authorized to call the function.
    error OptimismPortal_Unauthorized();

    /// @notice Thrown when the wrong proof method is used.
    error OptimismPortal_WrongProofMethod();

    /// @notice Thrown when a super root proof is invalid.
    error OptimismPortal_InvalidSuperRootProof();

    /// @notice Thrown when an output root index is invalid.
    error OptimismPortal_InvalidOutputRootIndex();

    /// @notice Thrown when an output root chain id is invalid.
    error OptimismPortal_InvalidOutputRootChainId();

    /// @notice Thrown when trying to migrate to the same AnchorStateRegistry.
    error OptimismPortal_MigratingToSameRegistry();

    /// @notice Semantic version.
    /// @custom:semver 4.6.0
    function version() public pure virtual returns (string memory) {
        return "4.6.0";
    }

    /// @param _proofMaturityDelaySeconds The proof maturity delay in seconds.
    constructor(uint256 _proofMaturityDelaySeconds) ReinitializableBase(2) {
        PROOF_MATURITY_DELAY_SECONDS = _proofMaturityDelaySeconds;
        _disableInitializers();
    }

    /// @notice Initializer.
    /// @param _systemConfig Address of the SystemConfig.
    /// @param _anchorStateRegistry Address of the AnchorStateRegistry.
    /// @param _ethLockbox Contract of the ETHLockbox.
    function initialize(
        ISystemConfig _systemConfig,
        IAnchorStateRegistry _anchorStateRegistry,
        IETHLockbox _ethLockbox
    )
        external
        reinitializer(initVersion())
    {
        // Initialization transactions must come from the ProxyAdmin or its owner.
        _assertOnlyProxyAdminOrProxyAdminOwner();

        // Now perform initialization logic.
        systemConfig = _systemConfig;
        anchorStateRegistry = _anchorStateRegistry;
        ethLockbox = _ethLockbox;

        // Set the l2Sender slot, only if it is currently empty. This signals the first
        // initialization of the contract.
        if (l2Sender == address(0)) {
            l2Sender = Constants.DEFAULT_L2_SENDER;
        }

        __ResourceMetering_init();
    }

    /// @notice Upgrades the OptimismPortal contract to have a reference to the AnchorStateRegistry and SystemConfig
    /// @param _anchorStateRegistry AnchorStateRegistry contract.
    /// @param _ethLockbox ETHLockbox contract.
    function upgrade(
        IAnchorStateRegistry _anchorStateRegistry,
        IETHLockbox _ethLockbox
    )
        external
        reinitializer(initVersion())
    {
        // Upgrade transactions must come from the ProxyAdmin or its owner.
        _assertOnlyProxyAdminOrProxyAdminOwner();

        // Now perform upgrade logic.
        anchorStateRegistry = _anchorStateRegistry;
        ethLockbox = _ethLockbox;
    }

    /// @notice Getter for the current paused status.
    function paused() public view returns (bool) {
        return systemConfig.paused();
    }

    /// @notice Getter for the proof maturity delay.
    function proofMaturityDelaySeconds() public view returns (uint256) {
        return PROOF_MATURITY_DELAY_SECONDS;
    }

    /// @notice Getter for the address of the DisputeGameFactory contract.
    function disputeGameFactory() public view returns (IDisputeGameFactory) {
        return anchorStateRegistry.disputeGameFactory();
    }

    /// @notice Returns the SuperchainConfig contract.
    /// @return ISuperchainConfig The SuperchainConfig contract.
    function superchainConfig() external view returns (ISuperchainConfig) {
        return systemConfig.superchainConfig();
    }

    /// @custom:legacy
    /// @notice Getter function for the address of the guardian.
    function guardian() external view returns (address) {
        return systemConfig.guardian();
    }

    /// @custom:legacy
    /// @notice Getter for the dispute game finality delay.
    function disputeGameFinalityDelaySeconds() external view returns (uint256) {
        return anchorStateRegistry.disputeGameFinalityDelaySeconds();
    }

    /// @custom:legacy
    /// @notice Getter for the respected game type.
    function respectedGameType() external view returns (GameType) {
        return anchorStateRegistry.respectedGameType();
    }

    /// @custom:legacy
    /// @notice Getter for the retirement timestamp. Note that this value NO LONGER reflects the
    ///         timestamp at which the respected game type was updated. Game retirement and
    ///         respected game type value have been decoupled, this function now only returns the
    ///         retirement timestamp.
    function respectedGameTypeUpdatedAt() external view returns (uint64) {
        return anchorStateRegistry.retirementTimestamp();
    }

    /// @custom:legacy
    /// @notice Getter for the dispute game blacklist.
    /// @param _disputeGame The dispute game to check.
    /// @return Whether the dispute game is blacklisted.
    function disputeGameBlacklist(IDisputeGame _disputeGame) public view returns (bool) {
        return anchorStateRegistry.disputeGameBlacklist(_disputeGame);
    }

    /// @notice Computes the minimum gas limit for a deposit.
    ///         The minimum gas limit linearly increases based on the size of the calldata.
    ///         This is to prevent users from creating L2 resource usage without paying for it.
    ///         This function can be used when interacting with the portal to ensure forwards
    ///         compatibility.
    /// @param _byteCount Number of bytes in the calldata.
    /// @return The minimum gas limit for a deposit.
    function minimumGasLimit(uint64 _byteCount) public pure returns (uint64) {
        return _byteCount * 40 + 21000;
    }

    /// @notice Accepts value so that users can send ETH directly to this contract and have the
    ///         funds be deposited to their address on L2. This is intended as a convenience
    ///         function for EOAs. Contracts should call the depositTransaction() function directly
    ///         otherwise any deposited funds will be lost due to address aliasing.
    receive() external payable {
        depositTransaction(msg.sender, msg.value, RECEIVE_DEFAULT_GAS_LIMIT, false, bytes(""));
    }

    /// @notice Accepts ETH value without triggering a deposit to L2.
    function donateETH() external payable {
        // Intentionally empty.
    }

    /// @notice Migrates the total ETH balance to the ETHLockbox.
    function migrateLiquidity() public {
        // Liquidity migration can only be triggered by the ProxyAdmin owner.
        _assertOnlyProxyAdminOwner();

        // Migrate the liquidity.
        uint256 ethBalance = address(this).balance;
        ethLockbox.lockETH{ value: ethBalance }();
        emit ETHMigrated(address(ethLockbox), ethBalance);
    }

    /// @notice Allows the owner of the ProxyAdmin to migrate the OptimismPortal to use a new
    ///         lockbox, point at a new AnchorStateRegistry, and start to use the Super Roots proof
    ///         method. Primarily used for OptimismPortal instances to join the interop set, but
    ///         can also be used to swap the proof method from Output Roots to Super Roots if the
    ///         provided lockbox is the same as the current one.
    /// @dev    It is possible to change lockboxes without migrating liquidity. This can cause one
    ///         of the OptimismPortal instances connected to the new lockbox to not be able to
    ///         unlock sufficient ETH to finalize withdrawals which would trigger reverts. To avoid
    ///         this issue, guarantee that this function is called atomically alongside the
    ///         ETHLockbox.migrateLiquidity() function within the same transaction.
    /// @param _newLockbox The address of the new ETHLockbox contract.
    /// @param _newAnchorStateRegistry The address of the new AnchorStateRegistry contract.
    function migrateToSuperRoots(IETHLockbox _newLockbox, IAnchorStateRegistry _newAnchorStateRegistry) external {
        // Migration can only be triggered when the system is not paused because the migration can
        // potentially unpause the system as a result of the modified ETHLockbox address.
        _assertNotPaused();

        // Migration can only be triggered by the ProxyAdmin owner.
        _assertOnlyProxyAdminOwner();

        // Chains can use this method to swap the proof method from Output Roots to Super Roots
        // without joining the interop set. In this case, the old and new lockboxes will be the
        // same. However, whether or not a chain is joining the interop set, all chains will need a
        // new AnchorStateRegistry when migrating to Super Roots. We therefore check that the new
        // AnchorStateRegistry is different than the old one to prevent this function from being
        // accidentally misused.
        if (anchorStateRegistry == _newAnchorStateRegistry) {
            revert OptimismPortal_MigratingToSameRegistry();
        }

        // Update the ETHLockbox.
        IETHLockbox oldLockbox = ethLockbox;
        ethLockbox = _newLockbox;

        // Update the AnchorStateRegistry.
        IAnchorStateRegistry oldAnchorStateRegistry = anchorStateRegistry;
        anchorStateRegistry = _newAnchorStateRegistry;

        // Set the proof method to Super Roots. We expect that migration will happen more than once
        // for some chains (switching to single-chain Super Roots and then later joining the
        // interop set) so we don't need to check that this is false.
        superRootsActive = true;

        // Emit a PortalMigrated event.
        emit PortalMigrated(oldLockbox, _newLockbox, oldAnchorStateRegistry, _newAnchorStateRegistry);
    }

    /// @notice Proves a withdrawal transaction using a Super Root proof. Only callable when the
    ///         OptimismPortal is using Super Roots (superRootsActive flag is true).
    /// @param _tx               Withdrawal transaction to finalize.
    /// @param _disputeGameProxy Address of the dispute game to prove the withdrawal against.
    /// @param _outputRootIndex  Index of the target Output Root within the Super Root.
    /// @param _superRootProof   Inclusion proof of the Output Root within the Super Root.
    /// @param _outputRootProof  Inclusion proof of the L2ToL1MessagePasser storage root.
    /// @param _withdrawalProof  Inclusion proof of the withdrawal within the L2ToL1MessagePasser.
    function proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        IDisputeGame _disputeGameProxy,
        uint256 _outputRootIndex,
        Types.SuperRootProof calldata _superRootProof,
        Types.OutputRootProof calldata _outputRootProof,
        bytes[] calldata _withdrawalProof
    )
        external
    {
        // Cannot prove withdrawal transactions while the system is paused.
        _assertNotPaused();

        // Make sure that the OptimismPortal is using Super Roots.
        if (!superRootsActive) {
            revert OptimismPortal_WrongProofMethod();
        }

        // Prove the transaction.
        _proveWithdrawalTransaction(
            _tx, _disputeGameProxy, _outputRootIndex, _superRootProof, _outputRootProof, _withdrawalProof
        );
    }

    /// @notice Proves a withdrawal transaction using an Output Root proof. Only callable when the
    ///         OptimismPortal is using Output Roots (superRootsActive flag is false).
    /// @param _tx               Withdrawal transaction to finalize.
    /// @param _disputeGameIndex Index of the dispute game to prove the withdrawal against.
    /// @param _outputRootProof  Inclusion proof of the L2ToL1MessagePasser storage root.
    /// @param _withdrawalProof  Inclusion proof of the withdrawal within the L2ToL1MessagePasser.
    function proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        uint256 _disputeGameIndex,
        Types.OutputRootProof calldata _outputRootProof,
        bytes[] calldata _withdrawalProof
    )
        external
    {
        // Cannot prove withdrawal transactions while the system is paused.
        _assertNotPaused();

        // Make sure that the OptimismPortal is using Output Roots.
        if (superRootsActive) {
            revert OptimismPortal_WrongProofMethod();
        }

        // Fetch the dispute game proxy from the `DisputeGameFactory` contract.
        (,, IDisputeGame disputeGameProxy) = disputeGameFactory().gameAtIndex(_disputeGameIndex);

        // Create a dummy super root proof to pass into the internal function. Note that this is
        // not a valid Super Root proof but it isn't used anywhere in the internal function when
        // using Output Roots.
        Types.SuperRootProof memory superRootProof;

        // Prove the transaction.
        _proveWithdrawalTransaction(_tx, disputeGameProxy, 0, superRootProof, _outputRootProof, _withdrawalProof);
    }

    /// @notice Internal function for proving a withdrawal transaction, used by both the Super Root
    ///         and Output Root proof functions. Will eventually be replaced with a single function
    ///         when the Output Root proof method is deprecated.
    /// @param _tx               Withdrawal transaction to prove.
    /// @param _disputeGameProxy Address of the dispute game to prove the withdrawal against.
    /// @param _outputRootIndex  Index of the target Output Root within the Super Root.
    /// @param _superRootProof   Inclusion proof of the Output Root within the Super Root.
    /// @param _outputRootProof  Inclusion proof of the L2ToL1MessagePasser storage root.
    /// @param _withdrawalProof  Inclusion proof of the withdrawal within the L2ToL1MessagePasser.
    function _proveWithdrawalTransaction(
        Types.WithdrawalTransaction memory _tx,
        IDisputeGame _disputeGameProxy,
        uint256 _outputRootIndex,
        Types.SuperRootProof memory _superRootProof,
        Types.OutputRootProof memory _outputRootProof,
        bytes[] memory _withdrawalProof
    )
        internal
    {
        // Make sure that the target address is safe.
        if (_isUnsafeTarget(_tx.target)) {
            revert OptimismPortal_BadTarget();
        }

        // Game must be a Proper Game.
        if (!anchorStateRegistry.isGameProper(_disputeGameProxy)) {
            revert OptimismPortal_ImproperDisputeGame();
        }

        // Game must have been respected game type when created.
        if (!anchorStateRegistry.isGameRespected(_disputeGameProxy)) {
            revert OptimismPortal_InvalidDisputeGame();
        }

        // Game must not have resolved in favor of the Challenger (invalid root claim).
        if (_disputeGameProxy.status() == GameStatus.CHALLENGER_WINS) {
            revert OptimismPortal_InvalidDisputeGame();
        }

        // As a sanity check, we make sure that the current timestamp is not less than or equal to
        // the dispute game's creation timestamp. Not strictly necessary but extra layer of
        // safety against weird bugs. Note that this blocks withdrawals from being proven in the
        // same block that a dispute game is created.
        if (block.timestamp <= _disputeGameProxy.createdAt().raw()) {
            revert OptimismPortal_InvalidProofTimestamp();
        }

        // Validate the provided Output Root and/or Super Root proof depending on proof method.
        if (superRootsActive) {
            // Verify that the super root can be generated with the elements in the proof.
            if (_disputeGameProxy.rootClaim().raw() != Hashing.hashSuperRootProof(_superRootProof)) {
                revert OptimismPortal_InvalidSuperRootProof();
            }

            // Check that the index exists in the super root proof.
            if (_outputRootIndex >= _superRootProof.outputRoots.length) {
                revert OptimismPortal_InvalidOutputRootIndex();
            }

            // Check that the output root has the correct chain id.
            Types.OutputRootWithChainId memory outputRoot = _superRootProof.outputRoots[_outputRootIndex];
            if (outputRoot.chainId != systemConfig.l2ChainId()) {
                revert OptimismPortal_InvalidOutputRootChainId();
            }

            // Verify that the output root can be generated with the elements in the proof.
            if (outputRoot.root != Hashing.hashOutputRootProof(_outputRootProof)) {
                revert OptimismPortal_InvalidOutputRootProof();
            }
        } else {
            // Verify that the output root can be generated with the elements in the proof.
            if (_disputeGameProxy.rootClaim().raw() != Hashing.hashOutputRootProof(_outputRootProof)) {
                revert OptimismPortal_InvalidOutputRootProof();
            }
        }

        // Load the ProvenWithdrawal into memory, using the withdrawal hash as a unique identifier.
        bytes32 withdrawalHash = Hashing.hashWithdrawal(_tx);

        // Compute the storage slot of the withdrawal hash in the L2ToL1MessagePasser contract.
        // Refer to the Solidity documentation for more information on how storage layouts are
        // computed for mappings.
        bytes32 storageKey = keccak256(
            abi.encode(
                withdrawalHash,
                uint256(0) // The withdrawals mapping is at the first slot in the layout.
            )
        );

        // Verify that the hash of this withdrawal was stored in the L2toL1MessagePasser contract
        // on L2. If this is true, under the assumption that the SecureMerkleTrie does not have
        // bugs, then we know that this withdrawal was actually triggered on L2 and can therefore
        // be relayed on L1.
        if (
            SecureMerkleTrie.verifyInclusionProof({
                _key: abi.encode(storageKey),
                _value: hex"01",
                _proof: _withdrawalProof,
                _root: _outputRootProof.messagePasserStorageRoot
            }) == false
        ) {
            revert OptimismPortal_InvalidMerkleProof();
        }

        // Designate the withdrawalHash as proven by storing the disputeGameProxy and timestamp in
        // the provenWithdrawals mapping. A given user may re-prove a withdrawalHash multiple
        // times, but each proof will reset the proof timer.
        provenWithdrawals[withdrawalHash][msg.sender] =
            ProvenWithdrawal({ disputeGameProxy: _disputeGameProxy, timestamp: uint64(block.timestamp) });

        // Add the proof submitter to the list of proof submitters for this withdrawal hash.
        proofSubmitters[withdrawalHash].push(msg.sender);

        // Emit a WithdrawalProven events.
        emit WithdrawalProven(withdrawalHash, _tx.sender, _tx.target);
        emit WithdrawalProvenExtension1(withdrawalHash, msg.sender);
    }

    /// @notice Finalizes a withdrawal transaction.
    /// @param _tx Withdrawal transaction to finalize.
    function finalizeWithdrawalTransaction(Types.WithdrawalTransaction memory _tx) external {
        finalizeWithdrawalTransactionExternalProof(_tx, msg.sender);
    }

    /// @notice Finalizes a withdrawal transaction, using an external proof submitter.
    /// @param _tx Withdrawal transaction to finalize.
    /// @param _proofSubmitter Address of the proof submitter.
    function finalizeWithdrawalTransactionExternalProof(
        Types.WithdrawalTransaction memory _tx,
        address _proofSubmitter
    )
        public
    {
        // Cannot finalize withdrawal transactions while the system is paused.
        _assertNotPaused();

        // Make sure that the l2Sender has not yet been set. The l2Sender is set to a value other
        // than the default value when a withdrawal transaction is being finalized. This check is
        // a defacto reentrancy guard.
        if (l2Sender != Constants.DEFAULT_L2_SENDER) {
            revert OptimismPortal_NoReentrancy();
        }

        // Make sure that the target address is safe.
        if (_isUnsafeTarget(_tx.target)) {
            revert OptimismPortal_BadTarget();
        }

        // Grab the withdrawal.
        bytes32 withdrawalHash = Hashing.hashWithdrawal(_tx);

        // Check that the withdrawal can be finalized.
        checkWithdrawal(withdrawalHash, _proofSubmitter);

        // Mark the withdrawal as finalized so it can't be replayed.
        finalizedWithdrawals[withdrawalHash] = true;

        // Unlock the ETH from the ETHLockbox.
        if (_tx.value > 0) ethLockbox.unlockETH(_tx.value);

        // Set the l2Sender so contracts know who triggered this withdrawal on L2.
        l2Sender = _tx.sender;

        // Trigger the call to the target contract. We use a custom low level method
        // SafeCall.callWithMinGas to ensure two key properties
        //   1. Target contracts cannot force this call to run out of gas by returning a very large
        //      amount of data (and this is OK because we don't care about the returndata here).
        //   2. The amount of gas provided to the execution context of the target is at least the
        //      gas limit specified by the user. If there is not enough gas in the current context
        //      to accomplish this, `callWithMinGas` will revert.
        bool success = SafeCall.callWithMinGas(_tx.target, _tx.gasLimit, _tx.value, _tx.data);

        // Reset the l2Sender back to the default value.
        l2Sender = Constants.DEFAULT_L2_SENDER;

        // All withdrawals are immediately finalized. Replayability can
        // be achieved through contracts built on top of this contract
        emit WithdrawalFinalized(withdrawalHash, success);

        // Send ETH back to the Lockbox in the case of a failed transaction or it'll get stuck here
        // and would need to be moved back via the migrateLiquidity function.
        if (!success && _tx.value > 0) {
            ethLockbox.lockETH{ value: _tx.value }();
        }

        // Reverting here is useful for determining the exact gas cost to successfully execute the
        // sub call to the target contract if the minimum gas limit specified by the user would not
        // be sufficient to execute the sub call.
        if (!success && tx.origin == Constants.ESTIMATION_ADDRESS) {
            revert OptimismPortal_GasEstimation();
        }
    }

    /// @notice Checks that a withdrawal has been proven and is ready to be finalized.
    /// @param _withdrawalHash Hash of the withdrawal.
    /// @param _proofSubmitter Address of the proof submitter.
    function checkWithdrawal(bytes32 _withdrawalHash, address _proofSubmitter) public view {
        // Grab the withdrawal and dispute game proxy.
        ProvenWithdrawal memory provenWithdrawal = provenWithdrawals[_withdrawalHash][_proofSubmitter];
        IDisputeGame disputeGameProxy = provenWithdrawal.disputeGameProxy;

        // Check that this withdrawal has not already been finalized, this is replay protection.
        if (finalizedWithdrawals[_withdrawalHash]) {
            revert OptimismPortal_AlreadyFinalized();
        }

        // A withdrawal can only be finalized if it has been proven. We know that a withdrawal has
        // been proven at least once when its timestamp is non-zero. Unproven withdrawals will have
        // a timestamp of zero.
        if (provenWithdrawal.timestamp == 0) {
            revert OptimismPortal_Unproven();
        }

        // As a sanity check, we make sure that the proven withdrawal's timestamp is greater than
        // starting timestamp inside the Dispute Game. Not strictly necessary but extra layer of
        // safety against weird bugs in the proving step. Note that this blocks withdrawals that
        // are proven in the same block that a dispute game is created.
        if (provenWithdrawal.timestamp <= disputeGameProxy.createdAt().raw()) {
            revert OptimismPortal_InvalidProofTimestamp();
        }

        // A proven withdrawal must wait at least `PROOF_MATURITY_DELAY_SECONDS` before finalizing.
        if (block.timestamp - provenWithdrawal.timestamp <= PROOF_MATURITY_DELAY_SECONDS) {
            revert OptimismPortal_ProofNotOldEnough();
        }

        // Check that the root claim is valid.
        if (!anchorStateRegistry.isGameClaimValid(disputeGameProxy)) {
            revert OptimismPortal_InvalidRootClaim();
        }
    }

    /// @notice Accepts deposits of ETH and data, and emits a TransactionDeposited event for use in
    ///         deriving deposit transactions. Note that if a deposit is made by a contract, its
    ///         address will be aliased when retrieved using `tx.origin` or `msg.sender`. Consider
    ///         using the CrossDomainMessenger contracts for a simpler developer experience.
    /// @dev    The `msg.value` is locked on the ETHLockbox and minted as ETH when the deposit
    ///         arrives on L2, while `_value` specifies how much ETH to send to the target.
    /// @param _to         Target address on L2.
    /// @param _value      ETH value to send to the recipient.
    /// @param _gasLimit   Amount of L2 gas to purchase by burning gas on L1.
    /// @param _isCreation Whether or not the transaction is a contract creation.
    /// @param _data       Data to trigger the recipient with.
    function depositTransaction(
        address _to,
        uint256 _value,
        uint64 _gasLimit,
        bool _isCreation,
        bytes memory _data
    )
        public
        payable
        metered(_gasLimit)
    {
        // Lock the ETH in the ETHLockbox.
        if (msg.value > 0) ethLockbox.lockETH{ value: msg.value }();

        // Just to be safe, make sure that people specify address(0) as the target when doing
        // contract creations.
        if (_isCreation && _to != address(0)) {
            revert OptimismPortal_BadTarget();
        }

        // Prevent depositing transactions that have too small of a gas limit. Users should pay
        // more for more resource usage.
        if (_gasLimit < minimumGasLimit(uint64(_data.length))) {
            revert OptimismPortal_GasLimitTooLow();
        }

        // Prevent the creation of deposit transactions that have too much calldata. This gives an
        // upper limit on the size of unsafe blocks over the p2p network. 120kb is chosen to ensure
        // that the transaction can fit into the p2p network policy of 128kb even though deposit
        // transactions are not gossipped over the p2p network.
        if (_data.length > 120_000) {
            revert OptimismPortal_CalldataTooLarge();
        }

        // Transform the from-address to its alias if the caller is a contract.
        address from = msg.sender;
        if (!EOA.isSenderEOA()) {
            from = AddressAliasHelper.applyL1ToL2Alias(msg.sender);
        }

        // Compute the opaque data that will be emitted as part of the TransactionDeposited event.
        // We use opaque data so that we can update the TransactionDeposited event in the future
        // without breaking the current interface.
        bytes memory opaqueData = abi.encodePacked(msg.value, _value, _gasLimit, _isCreation, _data);

        // Emit a TransactionDeposited event so that the rollup node can derive a deposit
        // transaction for this deposit.
        emit TransactionDeposited(from, _to, DEPOSIT_VERSION, opaqueData);
    }

    /// @notice External getter for the number of proof submitters for a withdrawal hash.
    /// @param _withdrawalHash Hash of the withdrawal.
    /// @return The number of proof submitters for the withdrawal hash.
    function numProofSubmitters(bytes32 _withdrawalHash) external view returns (uint256) {
        return proofSubmitters[_withdrawalHash].length;
    }

    /// @notice Asserts that the contract is not paused.
    function _assertNotPaused() internal view {
        if (paused()) {
            revert OptimismPortal_CallPaused();
        }
    }

    /// @notice Checks if a target address is unsafe.
    function _isUnsafeTarget(address _target) internal view virtual returns (bool) {
        // Prevent users from targeting an unsafe target address on a withdrawal transaction.
        return _target == address(this) || _target == address(ethLockbox);
    }

    /// @notice Getter for the resource config. Used internally by the ResourceMetering contract.
    ///         The SystemConfig is the source of truth for the resource config.
    /// @return config_ ResourceMetering ResourceConfig
    function _resourceConfig() internal view override returns (ResourceMetering.ResourceConfig memory config_) {
        IResourceMetering.ResourceConfig memory config = systemConfig.resourceConfig();
        assembly ("memory-safe") {
            config_ := config
        }
    }
}
