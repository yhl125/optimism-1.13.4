// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Testing
import { stdStorage, StdStorage } from "forge-std/Test.sol";
import { CommonTest } from "test/setup/CommonTest.sol";
import { ForgeArtifacts, StorageSlot } from "scripts/libraries/ForgeArtifacts.sol";

// Contracts
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { StandardBridge } from "src/universal/StandardBridge.sol";

// Libraries
import { Predeploys } from "src/libraries/Predeploys.sol";
import { AddressAliasHelper } from "src/vendor/AddressAliasHelper.sol";
import { EIP1967Helper } from "test/mocks/EIP1967Helper.sol";

// Interfaces
import { ICrossDomainMessenger } from "interfaces/universal/ICrossDomainMessenger.sol";
import { IOptimismPortal2 } from "interfaces/L1/IOptimismPortal2.sol";
import { IL1StandardBridge } from "interfaces/L1/IL1StandardBridge.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { IProxyAdminOwnedBase } from "interfaces/L1/IProxyAdminOwnedBase.sol";

/// @title L1StandardBridge_TestInit
/// @notice Reusable test initialization for `L1StandardBridge` tests.
contract L1StandardBridge_TestInit is CommonTest {
    /// @notice Asserts the expected calls and events for bridging ETH depending on whether the
    ///         bridge call is legacy or not.
    function _preBridgeETH(bool isLegacy, uint256 value) internal {
        if (!isForkTest()) {
            assertEq(address(optimismPortal2).balance, 0, "OptimismPortal2 balance should be 0");
        }
        uint256 nonce = l1CrossDomainMessenger.messageNonce();
        uint256 version = 0; // Internal constant in the OptimismPortal: DEPOSIT_VERSION
        address l1MessengerAliased = AddressAliasHelper.applyL1ToL2Alias(address(l1CrossDomainMessenger));

        bytes memory message = abi.encodeCall(StandardBridge.finalizeBridgeETH, (alice, alice, value, hex"dead"));

        if (isLegacy) {
            vm.expectCall(
                address(l1StandardBridge), value, abi.encodeCall(l1StandardBridge.depositETH, (50000, hex"dead"))
            );
        } else {
            vm.expectCall(
                address(l1StandardBridge), value, abi.encodeCall(l1StandardBridge.bridgeETH, (50000, hex"dead"))
            );
        }
        vm.expectCall(
            address(l1CrossDomainMessenger),
            value,
            abi.encodeCall(ICrossDomainMessenger.sendMessage, (address(l2StandardBridge), message, 50000))
        );

        bytes memory innerMessage = abi.encodeCall(
            ICrossDomainMessenger.relayMessage,
            (nonce, address(l1StandardBridge), address(l2StandardBridge), value, 50000, message)
        );

        uint64 baseGas = l1CrossDomainMessenger.baseGas(message, 50000);
        vm.expectCall(
            address(optimismPortal2),
            value,
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (address(l2CrossDomainMessenger), value, baseGas, false, innerMessage)
            )
        );

        bytes memory opaqueData = abi.encodePacked(uint256(value), uint256(value), baseGas, false, innerMessage);

        vm.expectEmit(address(l1StandardBridge));
        emit ETHDepositInitiated(alice, alice, value, hex"dead");

        vm.expectEmit(address(l1StandardBridge));
        emit ETHBridgeInitiated(alice, alice, value, hex"dead");

        // OptimismPortal emits a TransactionDeposited event on `depositTransaction` call
        vm.expectEmit(address(optimismPortal2));
        emit TransactionDeposited(l1MessengerAliased, address(l2CrossDomainMessenger), version, opaqueData);

        // SentMessage event emitted by the CrossDomainMessenger
        vm.expectEmit(address(l1CrossDomainMessenger));
        emit SentMessage(address(l2StandardBridge), address(l1StandardBridge), message, nonce, 50000);

        // SentMessageExtension1 event emitted by the CrossDomainMessenger
        vm.expectEmit(address(l1CrossDomainMessenger));
        emit SentMessageExtension1(address(l1StandardBridge), value);

        vm.prank(alice, alice);
    }

    /// @notice Asserts the expected calls and events for bridging ETH to a different address
    ///         depending on whether the bridge call is legacy or not.
    function _preBridgeETHTo(bool isLegacy, uint256 value) internal {
        uint256 nonce = l1CrossDomainMessenger.messageNonce();
        uint256 version = 0; // Internal constant in the OptimismPortal: DEPOSIT_VERSION
        address l1MessengerAliased = AddressAliasHelper.applyL1ToL2Alias(address(l1CrossDomainMessenger));

        if (isLegacy) {
            vm.expectCall(
                address(l1StandardBridge), value, abi.encodeCall(l1StandardBridge.depositETHTo, (bob, 60000, hex"dead"))
            );
        } else {
            vm.expectCall(
                address(l1StandardBridge), value, abi.encodeCall(l1StandardBridge.bridgeETHTo, (bob, 60000, hex"dead"))
            );
        }

        bytes memory message = abi.encodeCall(StandardBridge.finalizeBridgeETH, (alice, bob, value, hex"dead"));

        // the L1 bridge should call
        // L1CrossDomainMessenger.sendMessage
        vm.expectCall(
            address(l1CrossDomainMessenger),
            abi.encodeCall(ICrossDomainMessenger.sendMessage, (address(l2StandardBridge), message, 60000))
        );

        bytes memory innerMessage = abi.encodeCall(
            ICrossDomainMessenger.relayMessage,
            (nonce, address(l1StandardBridge), address(l2StandardBridge), value, 60000, message)
        );

        uint64 baseGas = l1CrossDomainMessenger.baseGas(message, 60000);
        vm.expectCall(
            address(optimismPortal2),
            abi.encodeCall(
                IOptimismPortal2.depositTransaction,
                (address(l2CrossDomainMessenger), value, baseGas, false, innerMessage)
            )
        );

        bytes memory opaqueData = abi.encodePacked(uint256(value), uint256(value), baseGas, false, innerMessage);

        vm.expectEmit(address(l1StandardBridge));
        emit ETHDepositInitiated(alice, bob, value, hex"dead");

        vm.expectEmit(address(l1StandardBridge));
        emit ETHBridgeInitiated(alice, bob, value, hex"dead");

        // OptimismPortal emits a TransactionDeposited event on `depositTransaction` call
        vm.expectEmit(address(optimismPortal2));
        emit TransactionDeposited(l1MessengerAliased, address(l2CrossDomainMessenger), version, opaqueData);

        // SentMessage event emitted by the CrossDomainMessenger
        vm.expectEmit(address(l1CrossDomainMessenger));
        emit SentMessage(address(l2StandardBridge), address(l1StandardBridge), message, nonce, 60000);

        // SentMessageExtension1 event emitted by the CrossDomainMessenger
        vm.expectEmit(address(l1CrossDomainMessenger));
        emit SentMessageExtension1(address(l1StandardBridge), value);

        // deposit eth to bob
        vm.prank(alice, alice);
    }
}

/// @title L1StandardBridge_Constructor_Test
/// @notice Tests the `constructor` function of the `L1StandardBridge` contract.
contract L1StandardBridge_Constructor_Test is CommonTest {
    /// @notice Test that the constructor sets the correct values.
    /// @dev Marked virtual to be overridden in test/kontrol/deployment/DeploymentSummary.t.sol
    function test_constructor_succeeds() external virtual {
        IL1StandardBridge impl = IL1StandardBridge(payable(EIP1967Helper.getImplementation(address(l1StandardBridge))));
        assertEq(address(impl.systemConfig()), address(0));

        // The constructor now uses _disableInitializers, whereas OP Mainnet has these values in
        // storage.
        returnIfForkTest("L1StandardBridge_Initialize_Test: impl storage differs on forked network");
        assertEq(address(impl.MESSENGER()), address(0));
        assertEq(address(impl.messenger()), address(0));
        assertEq(address(impl.OTHER_BRIDGE()), address(0));
        assertEq(address(impl.otherBridge()), address(0));
        assertEq(address(l2StandardBridge), Predeploys.L2_STANDARD_BRIDGE);
    }
}

/// @title L1StandardBridge_Initialize_Test
/// @notice Tests the `initialize` function of the `L1StandardBridge` contract.
contract L1StandardBridge_Initialize_Test is CommonTest {
    /// @notice Test that the initialize function sets the correct values.
    function test_initialize_succeeds() external view {
        assertEq(address(l1StandardBridge.systemConfig()), address(systemConfig));
        assertEq(address(l1StandardBridge.MESSENGER()), address(l1CrossDomainMessenger));
        assertEq(address(l1StandardBridge.messenger()), address(l1CrossDomainMessenger));
        assertEq(address(l1StandardBridge.OTHER_BRIDGE()), Predeploys.L2_STANDARD_BRIDGE);
        assertEq(address(l1StandardBridge.otherBridge()), Predeploys.L2_STANDARD_BRIDGE);
        assertEq(address(l2StandardBridge), Predeploys.L2_STANDARD_BRIDGE);
    }

    /// @notice Tests that the initialize function reverts if called by a non-proxy admin or owner.
    /// @param _sender The address of the sender to test.
    function testFuzz_initialize_notProxyAdminOrProxyAdminOwner_reverts(address _sender) public {
        // Prank as the not ProxyAdmin or ProxyAdmin owner.
        vm.assume(_sender != address(proxyAdmin) && _sender != proxyAdminOwner);

        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("L1StandardBridge", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(l1StandardBridge), bytes32(slot.slot), bytes32(0));

        // Expect the revert with `ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner` selector.
        vm.expectRevert(IProxyAdminOwnedBase.ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner.selector);

        // Call the `initialize` function with the sender
        vm.prank(_sender);
        l1StandardBridge.initialize(l1CrossDomainMessenger, systemConfig);
    }

    /// @notice Tests that the initializer value is correct. Trivial test for normal initialization
    ///         but confirms that the initValue is not incremented incorrectly if an upgrade
    ///         function is not present.
    function test_initialize_correctInitializerValue_succeeds() public {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("L1StandardBridge", "_initialized");

        // Get the initializer value.
        bytes32 slotVal = vm.load(address(l1StandardBridge), bytes32(slot.slot));
        uint8 val = uint8(uint256(slotVal) & 0xFF);

        // Assert that the initializer value matches the expected value.
        assertEq(val, l1StandardBridge.initVersion());
    }
}

/// @title L1StandardBridge_Upgrade_Test
/// @notice Reusable test for the current upgrade() function in the L1StandardBridge contract. If
///         the upgrade() function is changed, tests inside of this contract should be updated to
///         reflect the new function. If the upgrade() function is removed, remove the
///         corresponding tests but leave this contract in place so it's easy to add tests back
///         in the future.
contract L1StandardBridge_Upgrade_Test is CommonTest {
    /// @notice Tests that the upgrade() function succeeds.
    function test_upgrade_succeeds() external {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("L1StandardBridge", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(l1StandardBridge), bytes32(slot.slot), bytes32(0));

        // Verify the initial systemConfig slot is non-zero.
        StorageSlot memory systemConfigSlot = ForgeArtifacts.getSlot("L1StandardBridge", "systemConfig");
        vm.store(address(l1StandardBridge), bytes32(systemConfigSlot.slot), bytes32(uint256(1)));
        assertNotEq(address(l1StandardBridge.systemConfig()), address(0));
        assertNotEq(vm.load(address(l1StandardBridge), bytes32(systemConfigSlot.slot)), bytes32(0));

        ISystemConfig newSystemConfig = ISystemConfig(address(0xdeadbeef));

        // Trigger upgrade().
        vm.prank(address(l1StandardBridge.proxyAdmin()));
        l1StandardBridge.upgrade(newSystemConfig);

        // Verify that the systemConfig was updated.
        assertEq(address(l1StandardBridge.systemConfig()), address(newSystemConfig));
    }

    /// @notice Tests that the upgrade() function reverts if called a second time.
    function test_upgrade_upgradeTwice_reverts() external {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("L1StandardBridge", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(l1StandardBridge), bytes32(slot.slot), bytes32(0));

        ISystemConfig newSystemConfig = ISystemConfig(address(0xdeadbeef));

        // Trigger first upgrade.
        vm.prank(address(l1StandardBridge.proxyAdmin()));
        l1StandardBridge.upgrade(newSystemConfig);

        // Try to trigger second upgrade.
        vm.prank(address(l1StandardBridge.proxyAdmin()));
        vm.expectRevert("Initializable: contract is already initialized");
        l1StandardBridge.upgrade(newSystemConfig);
    }

    /// @notice Tests that the upgrade() function reverts if called by a non-proxy admin or owner.
    /// @param _sender The address of the sender to test.
    function testFuzz_upgrade_notProxyAdminOrProxyAdminOwner_reverts(address _sender) public {
        // Prank as the not ProxyAdmin or ProxyAdmin owner.
        vm.assume(_sender != address(proxyAdmin) && _sender != proxyAdminOwner);

        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("L1StandardBridge", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(l1StandardBridge), bytes32(slot.slot), bytes32(0));

        // Expect the revert with `ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner` selector.
        vm.expectRevert(IProxyAdminOwnedBase.ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner.selector);

        // Call the `upgrade` function with the sender
        vm.prank(_sender);
        l1StandardBridge.upgrade(ISystemConfig(address(0xdeadbeef)));
    }
}

/// @title L1StandardBridge_Paused_Test
/// @notice Tests the `paused` function of the `L1StandardBridge` contract.
contract L1StandardBridge_Paused_Test is CommonTest {
    /// @notice Sets up the test by pausing the bridge, giving ether to the bridge and mocking the
    ///         calls to the xDomainMessageSender so that it returns the correct value.
    function _setupPausedBridge() internal {
        vm.startPrank(systemConfig.guardian());
        systemConfig.superchainConfig().pause(address(0));
        vm.stopPrank();
        assertTrue(l1StandardBridge.paused());

        vm.deal(address(l1StandardBridge.messenger()), 1 ether);

        vm.mockCall(
            address(l1StandardBridge.messenger()),
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(address(l1StandardBridge.otherBridge()))
        );
    }

    /// @notice Verifies that the `paused` accessor returns the same value as the `paused` function
    ///         of the `superchainConfig`.
    function test_paused_succeeds() external view {
        assertEq(l1StandardBridge.paused(), systemConfig.paused());
    }

    /// @notice Ensures that the `paused` function of the bridge contract actually calls the
    ///         `paused` function of the `superchainConfig`.
    function test_paused_callsSuperchainConfig_succeeds() external {
        vm.expectCall(address(systemConfig), abi.encodeCall(ISystemConfig.paused, ()));
        l1StandardBridge.paused();
    }

    /// @notice Checks that the `paused` state of the bridge matches the `paused` state of the
    ///         `superchainConfig` after it's been changed.
    function test_paused_matchesSuperchainConfig_succeeds() external {
        assertFalse(l1StandardBridge.paused());
        assertEq(l1StandardBridge.paused(), systemConfig.paused());

        vm.prank(superchainConfig.guardian());
        superchainConfig.pause(address(0));

        assertTrue(l1StandardBridge.paused());
        assertEq(l1StandardBridge.paused(), systemConfig.paused());
    }

    /// @notice Confirms that the `finalizeBridgeETH` function reverts when the bridge is paused.
    function test_paused_finalizeBridgeETH_reverts() external {
        _setupPausedBridge();

        vm.prank(address(l1StandardBridge.messenger()));
        vm.expectRevert("StandardBridge: paused");
        l1StandardBridge.finalizeBridgeETH{ value: 100 }({
            _from: address(2),
            _to: address(3),
            _amount: 100,
            _extraData: hex""
        });
    }

    /// @notice Confirms that the `finalizeETHWithdrawal` function reverts when the bridge is
    ///         paused.
    function test_paused_finalizeETHWithdrawal_reverts() external {
        _setupPausedBridge();

        vm.prank(address(l1StandardBridge.messenger()));
        vm.expectRevert("StandardBridge: paused");
        l1StandardBridge.finalizeETHWithdrawal{ value: 100 }({
            _from: address(2),
            _to: address(3),
            _amount: 100,
            _extraData: hex""
        });
    }

    /// @notice Confirms that the `finalizeERC20Withdrawal` function reverts when the bridge is
    ///         paused.
    function test_paused_finalizeERC20Withdrawal_reverts() external {
        _setupPausedBridge();

        vm.prank(address(l1StandardBridge.messenger()));
        vm.expectRevert("StandardBridge: paused");
        l1StandardBridge.finalizeERC20Withdrawal({
            _l1Token: address(0),
            _l2Token: address(0),
            _from: address(0),
            _to: address(0),
            _amount: 0,
            _extraData: hex""
        });
    }

    /// @notice Confirms that the `finalizeBridgeERC20` function reverts when the bridge is paused.
    function test_paused_finalizeBridgeERC20_reverts() external {
        _setupPausedBridge();

        vm.prank(address(l1StandardBridge.messenger()));
        vm.expectRevert("StandardBridge: paused");
        l1StandardBridge.finalizeBridgeERC20({
            _localToken: address(0),
            _remoteToken: address(0),
            _from: address(0),
            _to: address(0),
            _amount: 0,
            _extraData: hex""
        });
    }
}

/// @title L1StandardBridge_Receive_Test
/// @notice Tests the `receive` function of the `L1StandardBridge` contract.
contract L1StandardBridge_Receive_Test is CommonTest {
    /// @notice Tests receive bridges ETH successfully.
    function test_receive_succeeds() external {
        uint256 portalBalanceBefore = address(optimismPortal2).balance;
        uint256 ethLockboxBalanceBefore = address(ethLockbox).balance;

        // The legacy event must be emitted for backwards compatibility
        vm.expectEmit(address(l1StandardBridge));
        emit ETHDepositInitiated(alice, alice, 100, hex"");

        vm.expectEmit(address(l1StandardBridge));
        emit ETHBridgeInitiated(alice, alice, 100, hex"");

        vm.expectCall(
            address(l1CrossDomainMessenger),
            abi.encodeCall(
                ICrossDomainMessenger.sendMessage,
                (
                    address(l2StandardBridge),
                    abi.encodeCall(StandardBridge.finalizeBridgeETH, (alice, alice, 100, hex"")),
                    200_000
                )
            )
        );

        vm.prank(alice, alice);
        (bool success,) = address(l1StandardBridge).call{ value: 100 }(hex"");
        assertEq(success, true);
        assertEq(address(optimismPortal2).balance, portalBalanceBefore);
        assertEq(address(ethLockbox).balance, ethLockboxBalanceBefore + 100);
    }
}

/// @title L1StandardBridge_DepositETH_Test
/// @notice Tests the `depositETH` function of the `L1StandardBridge` contract.
contract L1StandardBridge_DepositETH_Test is L1StandardBridge_TestInit {
    /// @notice Tests that depositing ETH succeeds.
    ///         Emits ETHDepositInitiated and ETHBridgeInitiated events.
    ///         Calls depositTransaction on the OptimismPortal.
    ///         Only EOA can call depositETH.
    ///         ETH ends up in the optimismPortal.
    function test_depositETH_fromEOA_succeeds() external {
        _preBridgeETH({ isLegacy: true, value: 500 });
        uint256 portalBalanceBefore = address(optimismPortal2).balance;
        uint256 ethLockboxBalanceBefore = address(ethLockbox).balance;
        l1StandardBridge.depositETH{ value: 500 }(50000, hex"dead");
        assertEq(address(optimismPortal2).balance, portalBalanceBefore);
        assertEq(address(ethLockbox).balance, ethLockboxBalanceBefore + 500);
    }

    /// @notice Tests that depositing ETH succeeds for an EOA using 7702 delegation.
    function test_depositETH_fromEOA7702_succeeds() external {
        // Set alice to have 7702 code.
        vm.etch(alice, abi.encodePacked(hex"EF0100", address(0)));

        _preBridgeETH({ isLegacy: true, value: 500 });
        uint256 portalBalanceBefore = address(optimismPortal2).balance;
        uint256 ethLockboxBalanceBefore = address(ethLockbox).balance;
        l1StandardBridge.depositETH{ value: 500 }(50000, hex"dead");
        assertEq(address(optimismPortal2).balance, portalBalanceBefore);
        assertEq(address(ethLockbox).balance, ethLockboxBalanceBefore + 500);
    }

    /// @notice Tests that depositing ETH reverts if the call is not from an EOA.
    function test_depositETH_notEoa_reverts() external {
        vm.etch(alice, address(L1Token).code);
        vm.expectRevert("StandardBridge: function can only be called from an EOA");
        vm.prank(alice);
        l1StandardBridge.depositETH{ value: 1 }(300, hex"");
    }
}

/// @title L1StandardBridge_DepositETHTo_Test
/// @notice Tests the `depositETHTo` function of the `L1StandardBridge` contract.
contract L1StandardBridge_DepositETHTo_Test is L1StandardBridge_TestInit {
    /// @notice Tests that depositing ETH to a different address succeeds.
    ///         Emits ETHDepositInitiated event.
    ///         Calls depositTransaction on the OptimismPortal.
    ///         EOA or contract can call depositETHTo.
    ///         ETH ends up in the optimismPortal.
    function test_depositETHTo_succeeds() external {
        _preBridgeETHTo({ isLegacy: true, value: 600 });
        uint256 portalBalanceBefore = address(optimismPortal2).balance;
        uint256 ethLockboxBalanceBefore = address(ethLockbox).balance;
        l1StandardBridge.depositETHTo{ value: 600 }(bob, 60000, hex"dead");
        assertEq(address(optimismPortal2).balance, portalBalanceBefore);
        assertEq(address(ethLockbox).balance, ethLockboxBalanceBefore + 600);
    }
}

/// @title L1StandardBridge_DepositERC20_Test
/// @notice Tests the `depositERC20` function of the `L1StandardBridge` contract.
contract L1StandardBridge_DepositERC20_Test is CommonTest {
    using stdStorage for StdStorage;

    // depositERC20
    // - updates bridge.deposits
    // - emits ERC20DepositInitiated
    // - calls optimismPortal.depositTransaction
    // - only callable by EOA

    /// @notice Tests that depositing ERC20 to the bridge succeeds.
    ///         Bridge deposits are updated.
    ///         Emits ERC20DepositInitiated event.
    ///         Calls depositTransaction on the OptimismPortal.
    ///         Only EOA can call depositERC20.
    function test_depositERC20_succeeds() external {
        uint256 nonce = l1CrossDomainMessenger.messageNonce();
        uint256 version = 0; // Internal constant in the OptimismPortal: DEPOSIT_VERSION
        address l1MessengerAliased = AddressAliasHelper.applyL1ToL2Alias(address(l1CrossDomainMessenger));

        // Deal Alice's ERC20 State
        deal(address(L1Token), alice, 100000, true);
        vm.prank(alice);
        L1Token.approve(address(l1StandardBridge), type(uint256).max);

        // The l1StandardBridge should transfer alice's tokens to itself
        vm.expectCall(address(L1Token), abi.encodeCall(ERC20.transferFrom, (alice, address(l1StandardBridge), 100)));

        bytes memory message = abi.encodeCall(
            StandardBridge.finalizeBridgeERC20, (address(L2Token), address(L1Token), alice, alice, 100, hex"")
        );

        // the L1 bridge should call L1CrossDomainMessenger.sendMessage
        vm.expectCall(
            address(l1CrossDomainMessenger),
            abi.encodeCall(ICrossDomainMessenger.sendMessage, (address(l2StandardBridge), message, 10000))
        );

        bytes memory innerMessage = abi.encodeCall(
            ICrossDomainMessenger.relayMessage,
            (nonce, address(l1StandardBridge), address(l2StandardBridge), 0, 10000, message)
        );

        uint64 baseGas = l1CrossDomainMessenger.baseGas(message, 10000);
        vm.expectCall(
            address(optimismPortal2),
            abi.encodeCall(
                IOptimismPortal2.depositTransaction, (address(l2CrossDomainMessenger), 0, baseGas, false, innerMessage)
            )
        );

        bytes memory opaqueData = abi.encodePacked(uint256(0), uint256(0), baseGas, false, innerMessage);

        // Should emit both the bedrock and legacy events
        vm.expectEmit(address(l1StandardBridge));
        emit ERC20DepositInitiated(address(L1Token), address(L2Token), alice, alice, 100, hex"");

        vm.expectEmit(address(l1StandardBridge));
        emit ERC20BridgeInitiated(address(L1Token), address(L2Token), alice, alice, 100, hex"");

        // OptimismPortal emits a TransactionDeposited event on `depositTransaction` call
        vm.expectEmit(address(optimismPortal2));
        emit TransactionDeposited(l1MessengerAliased, address(l2CrossDomainMessenger), version, opaqueData);

        // SentMessage event emitted by the CrossDomainMessenger
        vm.expectEmit(address(l1CrossDomainMessenger));
        emit SentMessage(address(l2StandardBridge), address(l1StandardBridge), message, nonce, 10000);

        // SentMessageExtension1 event emitted by the CrossDomainMessenger
        vm.expectEmit(address(l1CrossDomainMessenger));
        emit SentMessageExtension1(address(l1StandardBridge), 0);

        vm.prank(alice, alice);
        l1StandardBridge.depositERC20(address(L1Token), address(L2Token), 100, 10000, hex"");
        assertEq(l1StandardBridge.deposits(address(L1Token), address(L2Token)), 100);
    }

    /// @notice Tests that depositing an ERC20 to the bridge reverts if the caller is not an EOA.
    function test_depositERC20_notEoa_reverts() external {
        // Turn alice into a contract
        vm.etch(alice, hex"ffff");

        vm.expectRevert("StandardBridge: function can only be called from an EOA");
        vm.prank(alice);
        l1StandardBridge.depositERC20(address(0), address(0), 100, 100, hex"");
    }
}

/// @title L1StandardBridge_DepositERC20To_Test
/// @notice Tests the `depositERC20To` function of the `L1StandardBridge` contract.
contract L1StandardBridge_DepositERC20To_Test is CommonTest {
    /// @notice Tests that depositing ERC20 to the bridge succeeds when sent to a different address.
    ///         Bridge deposits are updated.
    ///         Emits ERC20DepositInitiated event.
    ///         Calls depositTransaction on the OptimismPortal.
    ///         Contracts can call depositERC20.
    function test_depositERC20To_succeeds() external {
        uint256 nonce = l1CrossDomainMessenger.messageNonce();
        uint256 version = 0; // Internal constant in the OptimismPortal: DEPOSIT_VERSION
        address l1MessengerAliased = AddressAliasHelper.applyL1ToL2Alias(address(l1CrossDomainMessenger));

        bytes memory message = abi.encodeCall(
            StandardBridge.finalizeBridgeERC20, (address(L2Token), address(L1Token), alice, bob, 1000, hex"")
        );

        bytes memory innerMessage = abi.encodeCall(
            ICrossDomainMessenger.relayMessage,
            (nonce, address(l1StandardBridge), address(l2StandardBridge), 0, 10000, message)
        );

        uint64 baseGas = l1CrossDomainMessenger.baseGas(message, 10000);
        bytes memory opaqueData = abi.encodePacked(uint256(0), uint256(0), baseGas, false, innerMessage);

        deal(address(L1Token), alice, 100000, true);

        vm.prank(alice);
        L1Token.approve(address(l1StandardBridge), type(uint256).max);

        // Should emit both the bedrock and legacy events
        vm.expectEmit(address(l1StandardBridge));
        emit ERC20DepositInitiated(address(L1Token), address(L2Token), alice, bob, 1000, hex"");

        vm.expectEmit(address(l1StandardBridge));
        emit ERC20BridgeInitiated(address(L1Token), address(L2Token), alice, bob, 1000, hex"");

        // OptimismPortal emits a TransactionDeposited event on `depositTransaction` call
        vm.expectEmit(address(optimismPortal2));
        emit TransactionDeposited(l1MessengerAliased, address(l2CrossDomainMessenger), version, opaqueData);

        // SentMessage event emitted by the CrossDomainMessenger
        vm.expectEmit(address(l1CrossDomainMessenger));
        emit SentMessage(address(l2StandardBridge), address(l1StandardBridge), message, nonce, 10000);

        // SentMessageExtension1 event emitted by the CrossDomainMessenger
        vm.expectEmit(address(l1CrossDomainMessenger));
        emit SentMessageExtension1(address(l1StandardBridge), 0);

        // the L1 bridge should call L1CrossDomainMessenger.sendMessage
        vm.expectCall(
            address(l1CrossDomainMessenger),
            abi.encodeCall(ICrossDomainMessenger.sendMessage, (address(l2StandardBridge), message, 10000))
        );
        // The L1 XDM should call OptimismPortal.depositTransaction
        vm.expectCall(
            address(optimismPortal2),
            abi.encodeCall(
                IOptimismPortal2.depositTransaction, (address(l2CrossDomainMessenger), 0, baseGas, false, innerMessage)
            )
        );
        vm.expectCall(address(L1Token), abi.encodeCall(ERC20.transferFrom, (alice, address(l1StandardBridge), 1000)));

        vm.prank(alice);
        l1StandardBridge.depositERC20To(address(L1Token), address(L2Token), bob, 1000, 10000, hex"");

        assertEq(l1StandardBridge.deposits(address(L1Token), address(L2Token)), 1000);
    }
}

/// @title L1StandardBridge_FinalizeETHWithdrawal_Test
/// @notice Tests the `finalizeETHWithdrawal` function of the `L1StandardBridge` contract.
contract L1StandardBridge_FinalizeETHWithdrawal_Test is CommonTest {
    using stdStorage for StdStorage;

    /// @notice Tests that finalizing an ETH withdrawal succeeds.
    ///         Emits ETHWithdrawalFinalized event.
    ///         Only callable by the L2 bridge.
    function test_finalizeETHWithdrawal_succeeds() external {
        uint256 aliceBalance = alice.balance;

        vm.expectEmit(address(l1StandardBridge));
        emit ETHWithdrawalFinalized(alice, alice, 100, hex"");

        vm.expectEmit(address(l1StandardBridge));
        emit ETHBridgeFinalized(alice, alice, 100, hex"");

        vm.expectCall(alice, hex"");

        vm.mockCall(
            address(l1StandardBridge.messenger()),
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(address(l1StandardBridge.OTHER_BRIDGE()))
        );
        // ensure that the messenger has ETH to call with
        vm.deal(address(l1StandardBridge.messenger()), 100);
        vm.prank(address(l1StandardBridge.messenger()));
        l1StandardBridge.finalizeETHWithdrawal{ value: 100 }(alice, alice, 100, hex"");

        assertEq(address(l1StandardBridge.messenger()).balance, 0);
        assertEq(aliceBalance + 100, alice.balance);
    }
}

/// @title L1StandardBridge_FinalizeERC20Withdrawal_Test
/// @notice Tests the `finalizeERC20Withdrawal` function of the `L1StandardBridge` contract.
contract L1StandardBridge_FinalizeERC20Withdrawal_Test is CommonTest {
    using stdStorage for StdStorage;

    /// @notice Tests that finalizing an ERC20 withdrawal succeeds.
    ///         Bridge deposits are updated.
    ///         Emits ERC20WithdrawalFinalized event.
    ///         Only callable by the L2 bridge.
    function test_finalizeERC20Withdrawal_succeeds() external {
        deal(address(L1Token), address(l1StandardBridge), 100, true);

        uint256 slot = stdstore.target(address(l1StandardBridge)).sig("deposits(address,address)").with_key(
            address(L1Token)
        ).with_key(address(L2Token)).find();

        // Give the L1 bridge some ERC20 tokens
        vm.store(address(l1StandardBridge), bytes32(slot), bytes32(uint256(100)));
        assertEq(l1StandardBridge.deposits(address(L1Token), address(L2Token)), 100);

        vm.expectEmit(address(l1StandardBridge));
        emit ERC20WithdrawalFinalized(address(L1Token), address(L2Token), alice, alice, 100, hex"");

        vm.expectEmit(address(l1StandardBridge));
        emit ERC20BridgeFinalized(address(L1Token), address(L2Token), alice, alice, 100, hex"");

        vm.expectCall(address(L1Token), abi.encodeCall(ERC20.transfer, (alice, 100)));

        vm.mockCall(
            address(l1StandardBridge.messenger()),
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(address(l1StandardBridge.OTHER_BRIDGE()))
        );
        vm.prank(address(l1StandardBridge.messenger()));
        l1StandardBridge.finalizeERC20Withdrawal(address(L1Token), address(L2Token), alice, alice, 100, hex"");

        assertEq(L1Token.balanceOf(address(l1StandardBridge)), 0);
        assertEq(L1Token.balanceOf(address(alice)), 100);
    }

    /// @notice Tests that finalizing an ERC20 withdrawal reverts if the caller is not the L2
    ///         bridge.
    function test_finalizeERC20Withdrawal_notMessenger_reverts() external {
        vm.mockCall(
            address(l1StandardBridge.messenger()),
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(address(l1StandardBridge.OTHER_BRIDGE()))
        );
        vm.prank(address(28));
        vm.expectRevert("StandardBridge: function can only be called from the other bridge");
        l1StandardBridge.finalizeERC20Withdrawal(address(L1Token), address(L2Token), alice, alice, 100, hex"");
    }

    /// @notice Tests that finalizing an ERC20 withdrawal reverts if the caller is not the L2
    ///         bridge.
    function test_finalizeERC20Withdrawal_notOtherBridge_reverts() external {
        vm.mockCall(
            address(l1StandardBridge.messenger()),
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(address(address(0)))
        );
        vm.prank(address(l1StandardBridge.messenger()));
        vm.expectRevert("StandardBridge: function can only be called from the other bridge");
        l1StandardBridge.finalizeERC20Withdrawal(address(L1Token), address(L2Token), alice, alice, 100, hex"");
    }
}

/// @title L1StandardBridge_Unclassified_Test
/// @notice General tests that are not testing any function directly of the `L1StandardBridge`
///         contract or are testing multiple functions.
contract L1StandardBridge_Unclassified_Test is L1StandardBridge_TestInit {
    /// @notice Test that the accessors return the correct initialized values.
    function test_getters_succeeds() external view {
        assert(l1StandardBridge.l2TokenBridge() == address(l2StandardBridge));
        assert(address(l1StandardBridge.OTHER_BRIDGE()) == address(l2StandardBridge));
        assert(address(l1StandardBridge.messenger()) == address(l1CrossDomainMessenger));
        assert(address(l1StandardBridge.MESSENGER()) == address(l1CrossDomainMessenger));
        assert(l1StandardBridge.systemConfig() == systemConfig);
        assert(l1StandardBridge.superchainConfig() == systemConfig.superchainConfig());
    }

    /// @notice Tests that bridging ETH succeeds.
    ///         Emits ETHDepositInitiated and ETHBridgeInitiated events.
    ///         Calls depositTransaction on the OptimismPortal.
    ///         Only EOA can call bridgeETH.
    ///         ETH ends up in the optimismPortal.
    function test_bridgeETH_succeeds() external {
        _preBridgeETH({ isLegacy: false, value: 500 });
        uint256 portalBalanceBefore = address(optimismPortal2).balance;
        uint256 ethLockboxBalanceBefore = address(ethLockbox).balance;
        l1StandardBridge.bridgeETH{ value: 500 }(50000, hex"dead");
        assertEq(address(optimismPortal2).balance, portalBalanceBefore);
        assertEq(address(ethLockbox).balance, ethLockboxBalanceBefore + 500);
    }

    /// @notice Tests that bridging ETH to a different address succeeds.
    ///         Emits ETHDepositInitiated and ETHBridgeInitiated events.
    ///         Calls depositTransaction on the OptimismPortal.
    ///         Only EOA can call bridgeETHTo.
    ///         ETH ends up in the optimismPortal.
    function test_bridgeETHTo_succeeds() external {
        _preBridgeETHTo({ isLegacy: false, value: 600 });
        uint256 portalBalanceBefore = address(optimismPortal2).balance;
        uint256 ethLockboxBalanceBefore = address(ethLockbox).balance;
        l1StandardBridge.bridgeETHTo{ value: 600 }(bob, 60000, hex"dead");
        assertEq(address(optimismPortal2).balance, portalBalanceBefore);
        assertEq(address(ethLockbox).balance, ethLockboxBalanceBefore + 600);
    }

    /// @notice Tests that finalizing bridged ETH succeeds.
    function test_finalizeBridgeETH_succeeds() external {
        address messenger = address(l1StandardBridge.messenger());
        vm.mockCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(address(l1StandardBridge.OTHER_BRIDGE()))
        );
        vm.deal(messenger, 100);
        vm.prank(messenger);

        vm.expectEmit(address(l1StandardBridge));
        emit ETHBridgeFinalized(alice, alice, 100, hex"");

        l1StandardBridge.finalizeBridgeETH{ value: 100 }(alice, alice, 100, hex"");
    }

    /// @notice Tests that finalizing bridged ETH reverts if the amount is incorrect.
    function test_finalizeBridgeETH_incorrectValue_reverts() external {
        address messenger = address(l1StandardBridge.messenger());
        vm.mockCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(address(l1StandardBridge.OTHER_BRIDGE()))
        );
        vm.deal(messenger, 100);
        vm.prank(messenger);
        vm.expectRevert("StandardBridge: amount sent does not match amount required");
        l1StandardBridge.finalizeBridgeETH{ value: 50 }(alice, alice, 100, hex"");
    }

    /// @notice Tests that finalizing bridged ETH reverts if the destination is the L1 bridge.
    function test_finalizeBridgeETH_sendToSelf_reverts() external {
        address messenger = address(l1StandardBridge.messenger());
        vm.mockCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(address(l1StandardBridge.OTHER_BRIDGE()))
        );
        vm.deal(messenger, 100);
        vm.prank(messenger);
        vm.expectRevert("StandardBridge: cannot send to self");
        l1StandardBridge.finalizeBridgeETH{ value: 100 }(alice, address(l1StandardBridge), 100, hex"");
    }

    /// @notice Tests that finalizing bridged ETH reverts if the destination is the messenger.
    function test_finalizeBridgeETH_sendToMessenger_reverts() external {
        address messenger = address(l1StandardBridge.messenger());
        vm.mockCall(
            messenger,
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(address(l1StandardBridge.OTHER_BRIDGE()))
        );
        vm.deal(messenger, 100);
        vm.prank(messenger);
        vm.expectRevert("StandardBridge: cannot send to messenger");
        l1StandardBridge.finalizeBridgeETH{ value: 100 }(alice, messenger, 100, hex"");
    }
}
