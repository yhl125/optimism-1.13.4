// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Testing
import { CommonTest } from "test/setup/CommonTest.sol";

// Scripts
import { ForgeArtifacts, StorageSlot } from "scripts/libraries/ForgeArtifacts.sol";

// Libraries
import { Constants } from "src/libraries/Constants.sol";
import { EIP1967Helper } from "test/mocks/EIP1967Helper.sol";

// Interfaces
import { IResourceMetering } from "interfaces/L1/IResourceMetering.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";
import { IProxyAdminOwnedBase } from "interfaces/L1/IProxyAdminOwnedBase.sol";

/// @title SystemConfig Test Init
/// @notice Reusable test initialization for SystemConfig tests.
contract SystemConfig_TestInit is CommonTest {
    event ConfigUpdate(uint256 indexed version, ISystemConfig.UpdateType indexed updateType, bytes data);

    address batchInbox;
    address owner;
    bytes32 batcherHash;
    uint64 gasLimit;
    address unsafeBlockSigner;
    address systemConfigImpl;
    address optimismMintableERC20Factory;
    uint32 basefeeScalar;
    uint32 blobbasefeeScalar;

    function setUp() public virtual override {
        super.setUp();
        skipIfForkTest("SystemConfig_Initialize_Test: cannot test initialization on forked network");
        batchInbox = deploy.cfg().batchInboxAddress();
        owner = deploy.cfg().finalSystemOwner();
        basefeeScalar = deploy.cfg().basefeeScalar();
        blobbasefeeScalar = deploy.cfg().blobbasefeeScalar();
        batcherHash = bytes32(uint256(uint160(deploy.cfg().batchSenderAddress())));
        gasLimit = uint64(deploy.cfg().l2GenesisBlockGasLimit());
        unsafeBlockSigner = deploy.cfg().p2pSequencerAddress();
        systemConfigImpl = EIP1967Helper.getImplementation(address(systemConfig));
        optimismMintableERC20Factory = artifacts.mustGetAddress("OptimismMintableERC20FactoryProxy");
    }
}

/// @title SystemConfig_Version_Test
/// @notice Test contract for SystemConfig `version` function.
contract SystemConfig_Version_Test is SystemConfig_TestInit {
    /// @notice Tests that the version function returns a valid string. We avoid testing the
    ///         specific value of the string as it changes frequently.
    function test_version_succeeds() external view {
        assert(bytes(systemConfig.version()).length > 0);
    }
}

/// @title SystemConfig_Constructor_Test
/// @notice Test contract for SystemConfig constructor.
contract SystemConfig_Constructor_Test is SystemConfig_TestInit {
    /// @notice Tests that constructor sets the correct values.
    function test_constructor_succeeds() external view {
        ISystemConfig impl = ISystemConfig(systemConfigImpl);
        assertEq(impl.owner(), address(0));
        assertEq(impl.overhead(), 0);
        assertEq(impl.scalar(), 0);
        assertEq(impl.batcherHash(), bytes32(0));
        assertEq(impl.gasLimit(), 0);
        assertEq(impl.unsafeBlockSigner(), address(0));
        assertEq(impl.basefeeScalar(), 0);
        assertEq(impl.blobbasefeeScalar(), 0);
        IResourceMetering.ResourceConfig memory actual = impl.resourceConfig();
        assertEq(actual.maxResourceLimit, 0);
        assertEq(actual.elasticityMultiplier, 0);
        assertEq(actual.baseFeeMaxChangeDenominator, 0);
        assertEq(actual.minimumBaseFee, 0);
        assertEq(actual.systemTxMaxGas, 0);
        assertEq(actual.maximumBaseFee, 0);
        assertEq(impl.startBlock(), type(uint256).max);
        assertEq(address(impl.batchInbox()), address(0));
        // Check addresses
        assertEq(address(impl.l1CrossDomainMessenger()), address(0));
        assertEq(address(impl.l1ERC721Bridge()), address(0));
        assertEq(address(impl.l1StandardBridge()), address(0));
        assertEq(address(impl.optimismPortal()), address(0));
        assertEq(address(impl.optimismMintableERC20Factory()), address(0));
    }
}

/// @title SystemConfig_Initialize_Test
/// @notice Test contract for SystemConfig `initialize` function.
contract SystemConfig_Initialize_Test is SystemConfig_TestInit {
    /// @notice Tests that initialization sets the correct values.
    function test_initialize_succeeds() external view {
        assertEq(systemConfig.owner(), owner);
        assertEq(systemConfig.overhead(), 0);
        assertEq(systemConfig.scalar() >> 248, 1);
        assertEq(systemConfig.batcherHash(), batcherHash);
        assertEq(systemConfig.gasLimit(), gasLimit);
        assertEq(systemConfig.unsafeBlockSigner(), unsafeBlockSigner);
        assertEq(systemConfig.basefeeScalar(), basefeeScalar);
        assertEq(systemConfig.blobbasefeeScalar(), blobbasefeeScalar);
        // Depends on `initialize` being called with defaults
        IResourceMetering.ResourceConfig memory rcfg = Constants.DEFAULT_RESOURCE_CONFIG();
        IResourceMetering.ResourceConfig memory actual = systemConfig.resourceConfig();
        assertEq(actual.maxResourceLimit, rcfg.maxResourceLimit);
        assertEq(actual.elasticityMultiplier, rcfg.elasticityMultiplier);
        assertEq(actual.baseFeeMaxChangeDenominator, rcfg.baseFeeMaxChangeDenominator);
        assertEq(actual.minimumBaseFee, rcfg.minimumBaseFee);
        assertEq(actual.systemTxMaxGas, rcfg.systemTxMaxGas);
        assertEq(actual.maximumBaseFee, rcfg.maximumBaseFee);
        // Depends on start block being set to 0 in `initialize`
        uint256 cfgStartBlock = deploy.cfg().systemConfigStartBlock();
        assertEq(systemConfig.startBlock(), (cfgStartBlock == 0 ? block.number : cfgStartBlock));
        assertEq(address(systemConfig.batchInbox()), address(batchInbox));

        // Check address getters both for the single contract getter and the struct getter
        ISystemConfig.Addresses memory addrs = systemConfig.getAddresses();
        assertEq(address(systemConfig.l1CrossDomainMessenger()), address(l1CrossDomainMessenger));
        assertEq(addrs.l1CrossDomainMessenger, address(l1CrossDomainMessenger));
        assertEq(address(systemConfig.l1ERC721Bridge()), address(l1ERC721Bridge));
        assertEq(addrs.l1ERC721Bridge, address(l1ERC721Bridge));
        assertEq(address(systemConfig.l1StandardBridge()), address(l1StandardBridge));
        assertEq(addrs.l1StandardBridge, address(l1StandardBridge));
        assertEq(address(systemConfig.optimismPortal()), address(optimismPortal2));
        assertEq(addrs.optimismPortal, address(optimismPortal2));
        assertEq(address(systemConfig.optimismMintableERC20Factory()), address(optimismMintableERC20Factory));
        assertEq(addrs.optimismMintableERC20Factory, address(optimismMintableERC20Factory));
        assertNotEq(systemConfig.l2ChainId(), 0);
    }

    /// @notice Tests that initialization reverts if the gas limit is too low.
    function test_initialize_lowGasLimit_reverts() external {
        uint64 minimumGasLimit = systemConfig.minimumGasLimit();

        // Wipe out the initialized slot so the proxy can be initialized again
        vm.store(address(systemConfig), bytes32(0), bytes32(0));

        address admin = address(uint160(uint256(vm.load(address(systemConfig), Constants.PROXY_OWNER_ADDRESS))));
        vm.prank(admin);

        vm.expectRevert("SystemConfig: gas limit too low");
        systemConfig.initialize({
            _owner: alice,
            _basefeeScalar: basefeeScalar,
            _blobbasefeeScalar: blobbasefeeScalar,
            _batcherHash: bytes32(hex"abcd"),
            _gasLimit: minimumGasLimit - 1,
            _unsafeBlockSigner: address(1),
            _config: Constants.DEFAULT_RESOURCE_CONFIG(),
            _batchInbox: address(0),
            _addresses: ISystemConfig.Addresses({
                l1CrossDomainMessenger: address(0),
                l1ERC721Bridge: address(0),
                l1StandardBridge: address(0),
                optimismPortal: address(0),
                optimismMintableERC20Factory: address(0)
            }),
            _l2ChainId: 1234,
            _superchainConfig: ISuperchainConfig(address(0))
        });
    }

    /// @notice Tests that the initializer value is correct. Trivial test for normal
    ///         initialization but confirms that the initValue is not incremented incorrectly if
    ///         an upgrade function is not present.
    function test_initialize_correctInitializerValue_succeeds() public {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("SystemConfig", "_initialized");

        // Get the initializer value.
        bytes32 slotVal = vm.load(address(systemConfig), bytes32(slot.slot));
        uint8 val = uint8(uint256(slotVal) & 0xFF);

        // Assert that the initializer value matches the expected value.
        assertEq(val, systemConfig.initVersion());
    }

    /// @notice Tests that `initialize` reverts if called by a non-proxy admin or owner.
    /// @param _sender The address of the sender to test.
    function testFuzz_initialize_notProxyAdminOrProxyAdminOwner_reverts(address _sender) public {
        // Prank as the not ProxyAdmin or ProxyAdmin owner.
        vm.assume(_sender != address(systemConfig.proxyAdmin()) && _sender != systemConfig.proxyAdminOwner());

        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("SystemConfig", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(systemConfig), bytes32(slot.slot), bytes32(0));

        // Get the minimum gas limit.
        uint64 minimumGasLimit = systemConfig.minimumGasLimit();

        // Expect the revert with `ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner` selector.
        vm.expectRevert(IProxyAdminOwnedBase.ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner.selector);

        // Call the `initialize` function with the sender
        vm.prank(_sender);
        systemConfig.initialize({
            _owner: alice,
            _basefeeScalar: basefeeScalar,
            _blobbasefeeScalar: blobbasefeeScalar,
            _batcherHash: bytes32(hex"abcd"),
            _gasLimit: minimumGasLimit - 1,
            _unsafeBlockSigner: address(1),
            _config: Constants.DEFAULT_RESOURCE_CONFIG(),
            _batchInbox: address(0),
            _addresses: ISystemConfig.Addresses({
                l1CrossDomainMessenger: address(0),
                l1ERC721Bridge: address(0),
                l1StandardBridge: address(0),
                optimismPortal: address(0),
                optimismMintableERC20Factory: address(0)
            }),
            _l2ChainId: 1234,
            _superchainConfig: ISuperchainConfig(address(0))
        });
    }
}

/// @title SystemConfig_upgrade_Test
/// @notice Reusable test for the current upgrade() function in the SystemConfig contract. If
///         the upgrade() function is changed, tests inside of this contract should be updated to
///         reflect the new function. If the upgrade() function is removed, remove the
///         corresponding tests but leave this contract in place so it's easy to add tests back
///         in the future.
contract SystemConfig_Upgrade_Test is SystemConfig_TestInit {
    /// @notice Tests that the upgrade() function succeeds.
    function test_upgrade_succeeds() external {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("SystemConfig", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(systemConfig), bytes32(slot.slot), bytes32(0));

        // Verify the initial dispute game factory slot is non-zero.
        // We set a value here since it seems this defaults to zero.
        bytes32 disputeGameFactorySlot = bytes32(uint256(keccak256("systemconfig.disputegamefactory")) - 1);
        vm.store(address(systemConfig), disputeGameFactorySlot, bytes32(uint256(1)));
        assertNotEq(systemConfig.disputeGameFactory(), address(0));
        assertNotEq(vm.load(address(systemConfig), disputeGameFactorySlot), bytes32(0));

        // Trigger upgrade().
        vm.prank(address(systemConfig.proxyAdmin()));
        systemConfig.upgrade(1234, ISuperchainConfig(address(0xdeadbeef)));

        // Verify that the initialized slot was updated.
        bytes32 initializedSlotAfter = vm.load(address(systemConfig), bytes32(slot.slot));
        assertEq(initializedSlotAfter, bytes32(uint256(2)));

        // Verify that the l2ChainId was updated.
        assertEq(systemConfig.l2ChainId(), 1234);

        // Verify that the dispute game factory address was cleared.
        assertEq(vm.load(address(systemConfig), disputeGameFactorySlot), bytes32(0));
    }

    /// @notice Tests that the upgrade() function reverts if called a second time.
    function test_upgrade_upgradeTwice_reverts() external {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("SystemConfig", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(systemConfig), bytes32(slot.slot), bytes32(0));

        // Trigger first upgrade.
        vm.prank(address(systemConfig.proxyAdmin()));
        systemConfig.upgrade(1234, ISuperchainConfig(address(0xdeadbeef)));

        // Try to trigger second upgrade.
        vm.prank(address(systemConfig.proxyAdmin()));
        vm.expectRevert("Initializable: contract is already initialized");
        systemConfig.upgrade(1234, ISuperchainConfig(address(0xdeadbeef)));
    }

    /// @notice Tests that the upgrade() function reverts if called after initialization.
    function test_upgrade_afterInitialization_reverts() external {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("SystemConfig", "_initialized");

        // Slot value should be set to 2 (already initialized).
        bytes32 initializedSlotBefore = vm.load(address(systemConfig), bytes32(slot.slot));
        assertEq(initializedSlotBefore, bytes32(uint256(2)));

        // l2ChainId should be non-zero.
        assertNotEq(systemConfig.l2ChainId(), 0);

        // Try to trigger upgrade().
        vm.expectRevert("Initializable: contract is already initialized");
        systemConfig.upgrade(1234, ISuperchainConfig(address(0xdeadbeef)));
    }

    /// @notice Tests that the upgrade() function reverts if called by a non-proxy admin or owner.
    /// @param _sender The address of the sender to test.
    function testFuzz_upgrade_notProxyAdminOrProxyAdminOwner_reverts(address _sender) public {
        // Prank as the not ProxyAdmin or ProxyAdmin owner.
        vm.assume(_sender != address(systemConfig.proxyAdmin()) && _sender != systemConfig.proxyAdminOwner());

        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("SystemConfig", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(systemConfig), bytes32(slot.slot), bytes32(0));

        // Expect the revert with `ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner` selector.
        vm.expectRevert(IProxyAdminOwnedBase.ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner.selector);

        // Call the `upgrade` function with the sender
        vm.prank(_sender);
        systemConfig.upgrade(1234, ISuperchainConfig(address(0xdeadbeef)));
    }
}

/// @title SystemConfig_StartBlock_TestFail
/// @notice Test contract for SystemConfig `startBlock` function.
contract SystemConfig_StartBlock_TestFail is SystemConfig_TestInit {
    /// @notice Tests that startBlock is updated correctly when it's zero.
    function test_startBlock_update_succeeds() external {
        // Wipe out the initialized slot so the proxy can be initialized again
        vm.store(address(systemConfig), bytes32(0), bytes32(0));
        // Set slot startBlock to zero
        vm.store(address(systemConfig), systemConfig.START_BLOCK_SLOT(), bytes32(uint256(0)));

        // Initialize and check that StartBlock updates to current block number
        vm.prank(address(systemConfig.proxyAdmin()));
        systemConfig.initialize({
            _owner: alice,
            _basefeeScalar: basefeeScalar,
            _blobbasefeeScalar: blobbasefeeScalar,
            _batcherHash: bytes32(hex"abcd"),
            _gasLimit: gasLimit,
            _unsafeBlockSigner: address(1),
            _config: Constants.DEFAULT_RESOURCE_CONFIG(),
            _batchInbox: address(0),
            _addresses: ISystemConfig.Addresses({
                l1CrossDomainMessenger: address(0),
                l1ERC721Bridge: address(0),
                l1StandardBridge: address(0),
                optimismPortal: address(0),
                optimismMintableERC20Factory: address(0)
            }),
            _l2ChainId: 1234,
            _superchainConfig: ISuperchainConfig(address(0))
        });
        assertEq(systemConfig.startBlock(), block.number);
    }

    /// @notice Tests that startBlock is not updated when it's not zero.
    function test_startBlock_update_fails() external {
        // Wipe out the initialized slot so the proxy can be initialized again
        vm.store(address(systemConfig), bytes32(0), bytes32(0));
        // Set slot startBlock to non-zero value 1
        vm.store(address(systemConfig), systemConfig.START_BLOCK_SLOT(), bytes32(uint256(1)));

        // Initialize and check that StartBlock doesn't update
        vm.prank(address(systemConfig.proxyAdmin()));
        systemConfig.initialize({
            _owner: alice,
            _basefeeScalar: basefeeScalar,
            _blobbasefeeScalar: blobbasefeeScalar,
            _batcherHash: bytes32(hex"abcd"),
            _gasLimit: gasLimit,
            _unsafeBlockSigner: address(1),
            _config: Constants.DEFAULT_RESOURCE_CONFIG(),
            _batchInbox: address(0),
            _addresses: ISystemConfig.Addresses({
                l1CrossDomainMessenger: address(0),
                l1ERC721Bridge: address(0),
                l1StandardBridge: address(0),
                optimismPortal: address(0),
                optimismMintableERC20Factory: address(0)
            }),
            _l2ChainId: 1234,
            _superchainConfig: ISuperchainConfig(address(0))
        });
        assertEq(systemConfig.startBlock(), 1);
    }
}

/// @title SystemConfig_SetUnsafeBlockSigner_Test
/// @notice Test contract for SystemConfig `setUnsafeBlockSigner` function.
contract SystemConfig_SetUnsafeBlockSigner_Test is SystemConfig_TestInit {
    /// @notice Tests that `setUnsafeBlockSigner` reverts if the caller is not the owner.
    function test_setUnsafeBlockSigner_notOwner_reverts() external {
        vm.expectRevert("Ownable: caller is not the owner");
        systemConfig.setUnsafeBlockSigner(address(0x20));
    }

    /// @notice Tests that `setUnsafeBlockSigner` updates the block signer successfully.
    function testFuzz_setUnsafeBlockSigner_succeeds(address newUnsafeSigner) external {
        vm.expectEmit(address(systemConfig));
        emit ConfigUpdate(0, ISystemConfig.UpdateType.UNSAFE_BLOCK_SIGNER, abi.encode(newUnsafeSigner));

        vm.prank(systemConfig.owner());
        systemConfig.setUnsafeBlockSigner(newUnsafeSigner);
        assertEq(systemConfig.unsafeBlockSigner(), newUnsafeSigner);
    }
}

/// @title SystemConfig_SetBatcherHash_Test
/// @notice Test contract for SystemConfig `setBatcherHash` function.
contract SystemConfig_SetBatcherHash_Test is SystemConfig_TestInit {
    /// @notice Tests that `setBatcherHash` reverts if the caller is not the owner.
    function test_setBatcherHash_notOwner_reverts() external {
        vm.expectRevert("Ownable: caller is not the owner");
        systemConfig.setBatcherHash(bytes32(hex""));
    }

    /// @notice Tests that `setBatcherHash` updates the batcher hash successfully.
    function testFuzz_setBatcherHash_succeeds(bytes32 newBatcherHash) external {
        vm.expectEmit(address(systemConfig));
        emit ConfigUpdate(0, ISystemConfig.UpdateType.BATCHER, abi.encode(newBatcherHash));

        vm.prank(systemConfig.owner());
        systemConfig.setBatcherHash(newBatcherHash);
        assertEq(systemConfig.batcherHash(), newBatcherHash);
    }
}

/// @title SystemConfig_SetGasConfig_Test
/// @notice Test contract for SystemConfig `setGasConfig` function.
contract SystemConfig_SetGasConfig_Test is SystemConfig_TestInit {
    /// @notice Tests that `setGasConfig` reverts if the caller is not the owner.
    function test_setGasConfig_notOwner_reverts() external {
        vm.expectRevert("Ownable: caller is not the owner");
        systemConfig.setGasConfig(0, 0);
    }

    /// @notice Ensures that `setGasConfig` reverts if version byte is set.
    function test_setGasConfig_badValues_reverts() external {
        vm.prank(systemConfig.owner());
        vm.expectRevert("SystemConfig: scalar exceeds max.");
        systemConfig.setGasConfig({ _overhead: 0, _scalar: type(uint256).max });
    }

    /// @notice Tests that `setGasConfig` updates the overhead and scalar successfully.
    function testFuzz_setGasConfig_succeeds(uint256 newOverhead, uint256 newScalar) external {
        // always zero out most significant byte
        newScalar = (newScalar << 16) >> 16;
        vm.expectEmit(address(systemConfig));
        emit ConfigUpdate(0, ISystemConfig.UpdateType.FEE_SCALARS, abi.encode(newOverhead, newScalar));

        vm.prank(systemConfig.owner());
        systemConfig.setGasConfig(newOverhead, newScalar);
        assertEq(systemConfig.overhead(), newOverhead);
        assertEq(systemConfig.scalar(), newScalar);
    }
}

/// @title SystemConfig_SetGasConfigEcotone_Test
/// @notice Test contract for SystemConfig `setGasConfigEcotone` function.
contract SystemConfig_SetGasConfigEcotone_Test is SystemConfig_TestInit {
    /// @notice Tests that `setGasConfigEcotone` reverts if the caller is not the owner.
    function test_setGasConfigEcotone_notOwner_reverts() external {
        vm.expectRevert("Ownable: caller is not the owner");
        systemConfig.setGasConfigEcotone({ _basefeeScalar: 0, _blobbasefeeScalar: 0 });
    }

    function testFuzz_setGasConfigEcotone_succeeds(uint32 _basefeeScalar, uint32 _blobbasefeeScalar) external {
        bytes32 encoded =
            ffi.encodeScalarEcotone({ _basefeeScalar: _basefeeScalar, _blobbasefeeScalar: _blobbasefeeScalar });

        vm.expectEmit(address(systemConfig));
        emit ConfigUpdate(0, ISystemConfig.UpdateType.FEE_SCALARS, abi.encode(systemConfig.overhead(), encoded));

        vm.prank(systemConfig.owner());
        systemConfig.setGasConfigEcotone({ _basefeeScalar: _basefeeScalar, _blobbasefeeScalar: _blobbasefeeScalar });
        assertEq(systemConfig.basefeeScalar(), _basefeeScalar);
        assertEq(systemConfig.blobbasefeeScalar(), _blobbasefeeScalar);
        assertEq(systemConfig.scalar(), uint256(encoded));

        (uint32 basefeeScalar, uint32 blobbbasefeeScalar) = ffi.decodeScalarEcotone(encoded);
        assertEq(uint256(basefeeScalar), uint256(_basefeeScalar));
        assertEq(uint256(blobbbasefeeScalar), uint256(_blobbasefeeScalar));
    }
}

/// @title SystemConfig_SetGasLimit_Test
/// @notice Test contract for SystemConfig `setGasLimit` function.
contract SystemConfig_SetGasLimit_Test is SystemConfig_TestInit {
    /// @notice Tests that `setGasLimit` reverts if the caller is not the owner.
    function test_setGasLimit_notOwner_reverts() external {
        vm.expectRevert("Ownable: caller is not the owner");
        systemConfig.setGasLimit(0);
    }

    /// @notice Tests that `setGasLimit` reverts if the gas limit is too low.
    function test_setGasLimit_lowGasLimit_reverts() external {
        uint64 minimumGasLimit = systemConfig.minimumGasLimit();
        vm.prank(systemConfig.owner());
        vm.expectRevert("SystemConfig: gas limit too low");
        systemConfig.setGasLimit(minimumGasLimit - 1);
    }

    /// @notice Tests that `setGasLimit` reverts if the gas limit is too high.
    function test_setGasLimit_highGasLimit_reverts() external {
        uint64 maximumGasLimit = systemConfig.maximumGasLimit();
        vm.prank(systemConfig.owner());
        vm.expectRevert("SystemConfig: gas limit too high");
        systemConfig.setGasLimit(maximumGasLimit + 1);
    }

    /// @notice Tests that `setGasLimit` updates the gas limit successfully.
    function testFuzz_setGasLimit_succeeds(uint64 newGasLimit) external {
        uint64 minimumGasLimit = systemConfig.minimumGasLimit();
        uint64 maximumGasLimit = systemConfig.maximumGasLimit();
        newGasLimit = uint64(bound(uint256(newGasLimit), uint256(minimumGasLimit), uint256(maximumGasLimit)));

        vm.expectEmit(address(systemConfig));
        emit ConfigUpdate(0, ISystemConfig.UpdateType.GAS_LIMIT, abi.encode(newGasLimit));

        vm.prank(systemConfig.owner());
        systemConfig.setGasLimit(newGasLimit);
        assertEq(systemConfig.gasLimit(), newGasLimit);
    }
}

/// @title SystemConfig_SetEIP1559Params_Test
/// @notice Test contract for SystemConfig `setEIP1559Params` function.
contract SystemConfig_SetEIP1559Params_Test is SystemConfig_TestInit {
    /// @notice Tests that `setEIP1559Params` reverts if the caller is not the owner.
    function test_setEIP1559Params_notOwner_reverts(uint32 _denominator, uint32 _elasticity) external {
        vm.expectRevert("Ownable: caller is not the owner");
        systemConfig.setEIP1559Params({ _denominator: _denominator, _elasticity: _elasticity });
    }

    /// @notice Tests that `setEIP1559Params` reverts if the denominator is zero.
    function test_setEIP1559Params_zeroDenominator_reverts(uint32 _elasticity) external {
        vm.prank(systemConfig.owner());
        vm.expectRevert("SystemConfig: denominator must be >= 1");
        systemConfig.setEIP1559Params({ _denominator: 0, _elasticity: _elasticity });
    }

    /// @notice Tests that `setEIP1559Params` reverts if the elasticity is zero.
    function test_setEIP1559Params_zeroElasticity_reverts(uint32 _denominator) external {
        _denominator = uint32(bound(_denominator, 1, type(uint32).max));
        vm.prank(systemConfig.owner());
        vm.expectRevert("SystemConfig: elasticity must be >= 1");
        systemConfig.setEIP1559Params({ _denominator: _denominator, _elasticity: 0 });
    }

    /// @notice Tests that `setEIP1559Params` updates the EIP1559 parameters successfully.
    function testFuzz_setEIP1559Params_succeeds(uint32 _denominator, uint32 _elasticity) external {
        _denominator = uint32(bound(_denominator, 2, type(uint32).max));
        _elasticity = uint32(bound(_elasticity, 2, type(uint32).max));

        vm.expectEmit(address(systemConfig));
        emit ConfigUpdate(
            0, ISystemConfig.UpdateType.EIP_1559_PARAMS, abi.encode(uint256(_denominator) << 32 | uint64(_elasticity))
        );

        vm.prank(systemConfig.owner());
        systemConfig.setEIP1559Params(_denominator, _elasticity);
        assertEq(systemConfig.eip1559Denominator(), _denominator);
        assertEq(systemConfig.eip1559Elasticity(), _elasticity);
    }
}

/// @title SystemConfig_SetResourceConfig_Test
/// @notice Test contract for SystemConfig `setResourceConfig` function.
contract SystemConfig_SetResourceConfig_Test is SystemConfig_TestInit {
    function setUp() public virtual override {
        super.setUp();
        skipIfOpsRepoTest(
            "SystemConfig_Init_ResourceConfig: cannot test initialization on superchain ops repo upgrade tests"
        );
    }

    /// @notice Tests that `setResourceConfig` reverts if the min base fee
    ///      is greater than the maximum allowed base fee.
    function test_setResourceConfig_badMinMax_reverts() external {
        IResourceMetering.ResourceConfig memory config = IResourceMetering.ResourceConfig({
            maxResourceLimit: 20_000_000,
            elasticityMultiplier: 10,
            baseFeeMaxChangeDenominator: 8,
            systemTxMaxGas: 1_000_000,
            minimumBaseFee: 2 gwei,
            maximumBaseFee: 1 gwei
        });
        _initializeWithResourceConfig(config, "SystemConfig: min base fee must be less than max base");
    }

    /// @notice Tests that `setResourceConfig` reverts if the baseFeeMaxChangeDenominator
    ///      is zero.
    function test_setResourceConfig_zeroDenominator_reverts() external {
        IResourceMetering.ResourceConfig memory config = IResourceMetering.ResourceConfig({
            maxResourceLimit: 20_000_000,
            elasticityMultiplier: 10,
            baseFeeMaxChangeDenominator: 0,
            systemTxMaxGas: 1_000_000,
            minimumBaseFee: 1 gwei,
            maximumBaseFee: 2 gwei
        });
        _initializeWithResourceConfig(config, "SystemConfig: denominator must be larger than 1");
    }

    /// @notice Tests that `setResourceConfig` reverts if the gas limit is too low.
    function test_setResourceConfig_lowGasLimit_reverts() external {
        uint64 gasLimit = systemConfig.gasLimit();

        IResourceMetering.ResourceConfig memory config = IResourceMetering.ResourceConfig({
            maxResourceLimit: uint32(gasLimit),
            elasticityMultiplier: 10,
            baseFeeMaxChangeDenominator: 8,
            systemTxMaxGas: uint32(gasLimit),
            minimumBaseFee: 1 gwei,
            maximumBaseFee: 2 gwei
        });
        _initializeWithResourceConfig(config, "SystemConfig: gas limit too low");
    }

    /// @notice Tests that `setResourceConfig` reverts if the gas limit is too low.
    function test_setResourceConfig_elasticityMultiplierIs0_reverts() external {
        IResourceMetering.ResourceConfig memory config = IResourceMetering.ResourceConfig({
            maxResourceLimit: 20_000_000,
            elasticityMultiplier: 0,
            baseFeeMaxChangeDenominator: 8,
            systemTxMaxGas: 1_000_000,
            minimumBaseFee: 1 gwei,
            maximumBaseFee: 2 gwei
        });
        _initializeWithResourceConfig(config, "SystemConfig: elasticity multiplier cannot be 0");
    }

    /// @notice Tests that `setResourceConfig` reverts if the elasticity multiplier
    ///      and max resource limit are configured such that there is a loss of precision.
    function test_setResourceConfig_badPrecision_reverts() external {
        IResourceMetering.ResourceConfig memory config = IResourceMetering.ResourceConfig({
            maxResourceLimit: 20_000_000,
            elasticityMultiplier: 11,
            baseFeeMaxChangeDenominator: 8,
            systemTxMaxGas: 1_000_000,
            minimumBaseFee: 1 gwei,
            maximumBaseFee: 2 gwei
        });
        _initializeWithResourceConfig(config, "SystemConfig: precision loss with target resource limit");
    }

    /// @notice Helper to initialize the system config with a resource config and default values,
    ///         and expect a revert with the given message.
    function _initializeWithResourceConfig(
        IResourceMetering.ResourceConfig memory config,
        string memory revertMessage
    )
        internal
    {
        // Wipe out the initialized slot so the proxy can be initialized again
        vm.store(address(systemConfig), bytes32(0), bytes32(0));
        // Fetch the current gas limit
        uint64 gasLimit = systemConfig.gasLimit();

        vm.prank(address(systemConfig.proxyAdmin()));
        vm.expectRevert(bytes(revertMessage));
        systemConfig.initialize({
            _owner: address(0xdEaD),
            _basefeeScalar: 0,
            _blobbasefeeScalar: 0,
            _batcherHash: bytes32(0),
            _gasLimit: gasLimit,
            _unsafeBlockSigner: address(0),
            _config: config,
            _batchInbox: address(0),
            _addresses: ISystemConfig.Addresses({
                l1CrossDomainMessenger: address(0),
                l1ERC721Bridge: address(0),
                l1StandardBridge: address(0),
                optimismPortal: address(0),
                optimismMintableERC20Factory: address(0)
            }),
            _l2ChainId: 1234,
            _superchainConfig: ISuperchainConfig(address(0))
        });
    }
}

/// @title SystemConfig_Paused_Test
/// @notice Test contract for SystemConfig `paused` function.
contract SystemConfig_Paused_Test is SystemConfig_TestInit {
    /// @notice Tests that `paused()` returns the correct value.
    function test_paused_succeeds() external view {
        assertEq(systemConfig.paused(), superchainConfig.paused(address(0)));
    }

    /// @notice Tests that `paused()` returns the correct value after pausing.
    function test_paused_afterPause_succeeds() external {
        // Initially not paused
        assertFalse(systemConfig.paused());
        assertEq(systemConfig.paused(), superchainConfig.paused(address(0)));

        // Pause the system
        vm.prank(superchainConfig.guardian());
        superchainConfig.pause(address(0));

        // Verify paused state
        assertTrue(systemConfig.paused());
        assertEq(systemConfig.paused(), superchainConfig.paused(address(0)));
    }

    /// @notice Tests that `paused()` returns true when the ETHLockbox identifier is set.
    function test_paused_ethLockboxIdentifier_succeeds() external {
        // Initially not paused
        assertFalse(systemConfig.paused());

        // Pause the system with ETHLockbox identifier
        vm.prank(superchainConfig.guardian());
        superchainConfig.pause(address(ethLockbox));

        // Verify paused state
        assertTrue(systemConfig.paused());
    }

    /// @notice Tests that `paused()` returns false when any other address is set.
    function test_paused_otherAddress_works() external {
        // Initially not paused
        assertFalse(systemConfig.paused());

        // Pause the system with a different address
        vm.prank(superchainConfig.guardian());
        superchainConfig.pause(address(0x1234));

        // Verify still not paused
        assertFalse(systemConfig.paused());
    }
}

/// @title SystemConfig_Guardian_Test
/// @notice Test contract for SystemConfig `guardian` function.
contract SystemConfig_Guardian_Test is SystemConfig_TestInit {
    /// @notice Tests that `guardian()` returns the correct address.
    function test_guardian_succeeds() external view {
        assertEq(systemConfig.guardian(), superchainConfig.guardian());
    }
}

/// @notice This test is not testing any function directly from SystemConfig, but is indirectly
///      testing the `SuperchainConfig` inherited contract.
contract SystemConfig_Test is SystemConfig_TestInit {
    /// @notice Tests that `superchainConfig()` returns the correct address.
    function test_superchainConfig_succeeds() external view {
        assertEq(address(systemConfig.superchainConfig()), address(superchainConfig));
    }
}
