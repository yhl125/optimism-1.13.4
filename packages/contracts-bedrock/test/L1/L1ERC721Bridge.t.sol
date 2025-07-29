// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Testing
import { CommonTest } from "test/setup/CommonTest.sol";
import { ForgeArtifacts, StorageSlot } from "scripts/libraries/ForgeArtifacts.sol";

// Contracts
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// Libraries
import { Predeploys } from "src/libraries/Predeploys.sol";
import { EIP1967Helper } from "test/mocks/EIP1967Helper.sol";

// Interfaces
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { ICrossDomainMessenger } from "interfaces/universal/ICrossDomainMessenger.sol";
import { IL1ERC721Bridge } from "interfaces/L1/IL1ERC721Bridge.sol";
import { IL2ERC721Bridge } from "interfaces/L2/IL2ERC721Bridge.sol";
import { IProxyAdminOwnedBase } from "interfaces/L1/IProxyAdminOwnedBase.sol";

/// @notice Test ERC721 contract.
contract TestERC721 is ERC721 {
    constructor() ERC721("Test", "TST") { }

    function mint(address to, uint256 tokenId) public {
        _mint(to, tokenId);
    }
}

/// @title L1ERC721Bridge_TestInit
/// @notice Test contract for L1ERC721Bridge initialization and setup.
contract L1ERC721Bridge_TestInit is CommonTest {
    TestERC721 internal localToken;
    TestERC721 internal remoteToken;
    uint256 internal constant tokenId = 1;

    event ERC721BridgeInitiated(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 tokenId,
        bytes extraData
    );

    event ERC721BridgeFinalized(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 tokenId,
        bytes extraData
    );

    /// @notice Sets up the testing environment.
    /// @dev Marked virtual to be overridden in
    ///         test/kontrol/deployment/DeploymentSummary.t.sol
    function setUp() public virtual override {
        super.setUp();

        localToken = new TestERC721();
        remoteToken = new TestERC721();

        // Mint alice a token.
        localToken.mint(alice, tokenId);

        // Approve the bridge to transfer the token.
        vm.prank(alice);
        localToken.approve(address(l1ERC721Bridge), tokenId);
    }
}

/// @title L1ERC721Bridge_Constructor_Test
/// @notice Test contract for L1ERC721Bridge `constructor` function.
contract L1ERC721Bridge_Constructor_Test is L1ERC721Bridge_TestInit {
    /// @notice Tests that the impl is created with the correct values.
    /// @dev Marked virtual to be overridden in
    ///      test/kontrol/deployment/DeploymentSummary.t.sol
    function test_constructor_succeeds() public virtual {
        IL1ERC721Bridge impl = IL1ERC721Bridge(EIP1967Helper.getImplementation(address(l1ERC721Bridge)));
        assertEq(address(impl.MESSENGER()), address(0));
        assertEq(address(impl.messenger()), address(0));
        assertEq(address(impl.systemConfig()), address(0));

        // The constructor now uses _disableInitializers, whereas OP Mainnet has the other bridge in storage
        returnIfForkTest("L1ERC721Bridge_Test: impl storage differs on forked network");
        assertEq(address(impl.OTHER_BRIDGE()), address(0));
        assertEq(address(impl.otherBridge()), address(0));
    }
}

/// @title L1ERC721Bridge_Initialize_Test
/// @notice Test contract for L1ERC721Bridge `initialize` function.
contract L1ERC721Bridge_Initialize_Test is L1ERC721Bridge_TestInit {
    /// @notice Tests that the proxy is initialized with the correct values.
    function test_initialize_succeeds() public view {
        assertEq(address(l1ERC721Bridge.MESSENGER()), address(l1CrossDomainMessenger));
        assertEq(address(l1ERC721Bridge.messenger()), address(l1CrossDomainMessenger));
        assertEq(address(l1ERC721Bridge.OTHER_BRIDGE()), Predeploys.L2_ERC721_BRIDGE);
        assertEq(address(l1ERC721Bridge.otherBridge()), Predeploys.L2_ERC721_BRIDGE);
        assertEq(address(l1ERC721Bridge.systemConfig()), address(systemConfig));
        assertEq(address(l1ERC721Bridge.superchainConfig()), address(systemConfig.superchainConfig()));
    }

    /// @notice Tests that the initializer value is correct. Trivial test for normal
    ///         initialization but confirms that the initValue is not incremented incorrectly if
    ///         an upgrade function is not present.
    function test_initialize_correctInitializerValue_succeeds() public {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("L1ERC721Bridge", "_initialized");

        // Get the initializer value.
        bytes32 slotVal = vm.load(address(l1ERC721Bridge), bytes32(slot.slot));
        uint8 val = uint8(uint256(slotVal) & 0xFF);

        // Assert that the initializer value matches the expected value.
        assertEq(val, l1ERC721Bridge.initVersion());
    }

    /// @notice Tests that the initialize function reverts if called by a non-proxy admin or owner.
    /// @param _sender The address of the sender to test.
    function testFuzz_initialize_notProxyAdminOrProxyAdminOwner_reverts(address _sender) public {
        // Prank as the not ProxyAdmin or ProxyAdmin owner.
        vm.assume(_sender != address(proxyAdmin) && _sender != proxyAdminOwner);

        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("L1ERC721Bridge", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(l1ERC721Bridge), bytes32(slot.slot), bytes32(0));

        // Expect the revert with `ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner` selector
        vm.expectRevert(IProxyAdminOwnedBase.ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner.selector);

        // Call the `initialize` function with the sender
        vm.prank(_sender);
        l1ERC721Bridge.initialize(l1CrossDomainMessenger, systemConfig);
    }
}

/// @title L1ERC721Bridge_Upgrade_Test
/// @notice Reusable test for the current upgrade() function in the L1ERC721Bridge contract. If
///         the upgrade() function is changed, tests inside of this contract should be updated to
///         reflect the new function. If the upgrade() function is removed, remove the
///         corresponding tests but leave this contract in place so it's easy to add tests back
///         in the future.
contract L1ERC721Bridge_Upgrade_Test is L1ERC721Bridge_TestInit {
    /// @notice Tests that the upgrade() function succeeds.
    function test_upgrade_succeeds() external {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("L1ERC721Bridge", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(l1ERC721Bridge), bytes32(slot.slot), bytes32(0));

        // Verify the initial systemConfig slot is non-zero.
        StorageSlot memory systemConfigSlot = ForgeArtifacts.getSlot("L1ERC721Bridge", "systemConfig");
        vm.store(address(l1ERC721Bridge), bytes32(systemConfigSlot.slot), bytes32(uint256(1)));
        assertNotEq(address(l1ERC721Bridge.systemConfig()), address(0));
        assertNotEq(vm.load(address(l1ERC721Bridge), bytes32(systemConfigSlot.slot)), bytes32(0));

        ISystemConfig newSystemConfig = ISystemConfig(address(0xdeadbeef));

        // Trigger upgrade().
        vm.prank(address(l1ERC721Bridge.proxyAdmin()));
        l1ERC721Bridge.upgrade(newSystemConfig);

        // Verify that the systemConfig was updated.
        assertEq(address(l1ERC721Bridge.systemConfig()), address(newSystemConfig));
    }

    /// @notice Tests that the upgrade() function reverts if called a second time.
    function test_upgrade_upgradeTwice_reverts() external {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("L1ERC721Bridge", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(l1ERC721Bridge), bytes32(slot.slot), bytes32(0));

        ISystemConfig newSystemConfig = ISystemConfig(address(0xdeadbeef));

        // Trigger first upgrade.
        vm.prank(address(l1ERC721Bridge.proxyAdmin()));
        l1ERC721Bridge.upgrade(newSystemConfig);

        // Try to trigger second upgrade.
        vm.prank(address(l1ERC721Bridge.proxyAdmin()));
        vm.expectRevert("Initializable: contract is already initialized");
        l1ERC721Bridge.upgrade(newSystemConfig);
    }

    /// @notice Tests that the upgrade() function reverts if called by a non-proxy admin or owner.
    /// @param _sender The address of the sender to test.
    function testFuzz_upgrade_notProxyAdminOrProxyAdminOwner_reverts(address _sender) public {
        // Prank as the not ProxyAdmin or ProxyAdmin owner.
        vm.assume(_sender != address(proxyAdmin) && _sender != proxyAdminOwner);

        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("L1ERC721Bridge", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(l1ERC721Bridge), bytes32(slot.slot), bytes32(0));

        // Expect the revert with `ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner` selector
        vm.expectRevert(IProxyAdminOwnedBase.ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner.selector);

        // Call the `upgrade` function with the sender
        vm.prank(_sender);
        l1ERC721Bridge.upgrade(ISystemConfig(address(0xdeadbeef)));
    }
}

/// @title L1ERC721Bridge_Pause_Test
/// @notice Test contract for L1ERC721Bridge `pause` functionality.
contract L1ERC721Bridge_Pause_Test is L1ERC721Bridge_TestInit {
    /// @dev Verifies that the `paused` accessor returns the same value as the `paused` function of
    ///      the `superchainConfig`.
    function test_paused_succeeds() external view {
        assertEq(l1ERC721Bridge.paused(), systemConfig.paused());
    }

    /// @dev Ensures that the `paused` function of the bridge contract actually calls the `paused`
    ///      function of the `superchainConfig`.
    function test_pause_callsSuperchainConfig_succeeds() external {
        vm.expectCall(address(systemConfig), abi.encodeCall(ISystemConfig.paused, ()));
        l1ERC721Bridge.paused();
    }

    /// @dev Checks that the `paused` state of the bridge matches the `paused` state of the
    ///      `superchainConfig` after it's been changed.
    function test_pause_matchesSuperchainConfig_succeeds() external {
        assertFalse(l1ERC721Bridge.paused());
        assertEq(l1ERC721Bridge.paused(), systemConfig.paused());

        vm.prank(superchainConfig.guardian());
        superchainConfig.pause(address(0));

        assertTrue(l1ERC721Bridge.paused());
        assertEq(l1ERC721Bridge.paused(), systemConfig.paused());
    }
}

/// @title L1ERC721Bridge_FinalizeBridgeERC721_Test
/// @notice Test contract for L1ERC721Bridge `finalizeBridgeERC721` function.
contract L1ERC721Bridge_FinalizeBridgeERC721_Test is L1ERC721Bridge_TestInit {
    /// @notice Tests that the ERC721 bridge successfully finalizes a withdrawal.
    function test_finalizeBridgeERC721_succeeds() external {
        // Bridge the token.
        vm.prank(alice, alice);
        l1ERC721Bridge.bridgeERC721(address(localToken), address(remoteToken), tokenId, 1234, hex"5678");

        // Expect an event to be emitted.
        vm.expectEmit(true, true, true, true);
        emit ERC721BridgeFinalized(address(localToken), address(remoteToken), alice, alice, tokenId, hex"5678");

        // Finalize a withdrawal.
        vm.mockCall(
            address(l1CrossDomainMessenger),
            abi.encodeCall(l1CrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(Predeploys.L2_ERC721_BRIDGE)
        );
        vm.prank(address(l1CrossDomainMessenger));
        l1ERC721Bridge.finalizeBridgeERC721(address(localToken), address(remoteToken), alice, alice, tokenId, hex"5678");

        // Token is not locked in the bridge.
        assertEq(l1ERC721Bridge.deposits(address(localToken), address(remoteToken), tokenId), false);
        assertEq(localToken.ownerOf(tokenId), alice);
    }

    /// @notice Tests that the ERC721 bridge finalize reverts when not called by the remote bridge.
    function test_finalizeBridgeERC721_notViaLocalMessenger_reverts() external {
        // Finalize a withdrawal.
        vm.prank(alice);
        vm.expectRevert("ERC721Bridge: function can only be called from the other bridge");
        l1ERC721Bridge.finalizeBridgeERC721(address(localToken), address(remoteToken), alice, alice, tokenId, hex"5678");
    }

    /// @notice Tests that the ERC721 bridge finalize reverts when not called from the remote
    ///         messenger.
    function test_finalizeBridgeERC721_notFromRemoteMessenger_reverts() external {
        // Finalize a withdrawal.
        vm.mockCall(
            address(l1CrossDomainMessenger),
            abi.encodeCall(l1CrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(alice)
        );
        vm.prank(address(l1CrossDomainMessenger));
        vm.expectRevert("ERC721Bridge: function can only be called from the other bridge");
        l1ERC721Bridge.finalizeBridgeERC721(address(localToken), address(remoteToken), alice, alice, tokenId, hex"5678");
    }

    /// @notice Tests that the ERC721 bridge finalize reverts when the local token is set as the
    ///         bridge itself.
    function test_finalizeBridgeERC721_selfToken_reverts() external {
        // Finalize a withdrawal.
        vm.mockCall(
            address(l1CrossDomainMessenger),
            abi.encodeCall(l1CrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(Predeploys.L2_ERC721_BRIDGE)
        );
        vm.prank(address(l1CrossDomainMessenger));
        vm.expectRevert("L1ERC721Bridge: local token cannot be self");
        l1ERC721Bridge.finalizeBridgeERC721(
            address(l1ERC721Bridge), address(remoteToken), alice, alice, tokenId, hex"5678"
        );
    }

    /// @notice Tests that the ERC721 bridge finalize reverts when the remote token is not escrowed
    ///         in the L1 bridge.
    function test_finalizeBridgeERC721_notEscrowed_reverts() external {
        // Finalize a withdrawal.
        vm.mockCall(
            address(l1CrossDomainMessenger),
            abi.encodeCall(l1CrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(Predeploys.L2_ERC721_BRIDGE)
        );
        vm.prank(address(l1CrossDomainMessenger));
        vm.expectRevert("L1ERC721Bridge: Token ID is not escrowed in the L1 Bridge");
        l1ERC721Bridge.finalizeBridgeERC721(address(localToken), address(remoteToken), alice, alice, tokenId, hex"5678");
    }

    /// @notice Ensures that the `bridgeERC721` function reverts when the bridge is paused.
    function test_finalizeBridgeERC721_paused_reverts() external {
        /// Sets up the test by pausing the bridge, giving ether to the bridge and mocking the
        /// calls to the xDomainMessageSender so that it returns the correct value.
        vm.startPrank(systemConfig.superchainConfig().guardian());
        systemConfig.superchainConfig().pause(address(0));
        vm.stopPrank();

        assertTrue(l1ERC721Bridge.paused());
        vm.mockCall(
            address(l1ERC721Bridge.messenger()),
            abi.encodeCall(ICrossDomainMessenger.xDomainMessageSender, ()),
            abi.encode(address(l1ERC721Bridge.otherBridge()))
        );

        vm.prank(address(l1ERC721Bridge.messenger()));
        vm.expectRevert("L1ERC721Bridge: paused");
        l1ERC721Bridge.finalizeBridgeERC721({
            _localToken: address(0),
            _remoteToken: address(0),
            _from: address(0),
            _to: address(0),
            _tokenId: 0,
            _extraData: hex""
        });
    }
}

/// @title L1ERC721Bridge_Test
/// @notice Test contract for L1ERC721Bridge functionality with test for functions that are
///         not specific to the L1ERC721Bridge.sol file
contract L1ERC721Bridge_Test is L1ERC721Bridge_TestInit {
    /// @notice Tests that the ERC721 can be bridged successfully.
    function test_bridgeERC721_fromEOA_succeeds() public {
        // Expect a call to the messenger.
        vm.expectCall(
            address(l1CrossDomainMessenger),
            abi.encodeCall(
                l1CrossDomainMessenger.sendMessage,
                (
                    address(l2ERC721Bridge),
                    abi.encodeCall(
                        IL2ERC721Bridge.finalizeBridgeERC721,
                        (address(remoteToken), address(localToken), alice, alice, tokenId, hex"5678")
                    ),
                    1234
                )
            )
        );

        // Expect an event to be emitted.
        vm.expectEmit(true, true, true, true);
        emit ERC721BridgeInitiated(address(localToken), address(remoteToken), alice, alice, tokenId, hex"5678");

        // Bridge the token.
        vm.prank(alice, alice);
        l1ERC721Bridge.bridgeERC721(address(localToken), address(remoteToken), tokenId, 1234, hex"5678");

        // Token is locked in the bridge.
        assertEq(l1ERC721Bridge.deposits(address(localToken), address(remoteToken), tokenId), true);
        assertEq(localToken.ownerOf(tokenId), address(l1ERC721Bridge));
    }

    /// @notice Tests that the ERC721 can be bridged successfully.
    function test_bridgeERC721_fromEOA7702_succeeds() public {
        // Expect a call to the messenger.
        vm.expectCall(
            address(l1CrossDomainMessenger),
            abi.encodeCall(
                l1CrossDomainMessenger.sendMessage,
                (
                    address(l2ERC721Bridge),
                    abi.encodeCall(
                        IL2ERC721Bridge.finalizeBridgeERC721,
                        (address(remoteToken), address(localToken), alice, alice, tokenId, hex"5678")
                    ),
                    1234
                )
            )
        );

        // Expect an event to be emitted.
        vm.expectEmit(true, true, true, true);
        emit ERC721BridgeInitiated(address(localToken), address(remoteToken), alice, alice, tokenId, hex"5678");

        // Set alice to have 7702 code.
        vm.etch(alice, abi.encodePacked(hex"EF0100", address(0)));

        // Bridge the token.
        vm.prank(alice);
        l1ERC721Bridge.bridgeERC721(address(localToken), address(remoteToken), tokenId, 1234, hex"5678");

        // Token is locked in the bridge.
        assertEq(l1ERC721Bridge.deposits(address(localToken), address(remoteToken), tokenId), true);
        assertEq(localToken.ownerOf(tokenId), address(l1ERC721Bridge));
    }

    /// @notice Tests that the ERC721 bridge reverts for non externally owned accounts.
    function test_bridgeERC721_fromContract_reverts() external {
        // Bridge the token.
        vm.etch(alice, hex"01");
        vm.prank(alice);
        vm.expectRevert("ERC721Bridge: account is not externally owned");
        l1ERC721Bridge.bridgeERC721(address(localToken), address(remoteToken), tokenId, 1234, hex"5678");

        // Token is not locked in the bridge.
        assertEq(l1ERC721Bridge.deposits(address(localToken), address(remoteToken), tokenId), false);
        assertEq(localToken.ownerOf(tokenId), alice);
    }

    /// @notice Tests that the ERC721 bridge reverts for a zero address local token.
    function test_bridgeERC721_localTokenZeroAddress_reverts() external {
        // Bridge the token.
        vm.prank(alice, alice);
        vm.expectRevert(bytes(""));
        l1ERC721Bridge.bridgeERC721(address(0), address(remoteToken), tokenId, 1234, hex"5678");

        // Token is not locked in the bridge.
        assertEq(l1ERC721Bridge.deposits(address(localToken), address(remoteToken), tokenId), false);
        assertEq(localToken.ownerOf(tokenId), alice);
    }

    /// @notice Tests that the ERC721 bridge reverts for a zero address remote token.
    function test_bridgeERC721_remoteTokenZeroAddress_reverts() external {
        // Bridge the token.
        vm.prank(alice, alice);
        vm.expectRevert("L1ERC721Bridge: remote token cannot be address(0)");
        l1ERC721Bridge.bridgeERC721(address(localToken), address(0), tokenId, 1234, hex"5678");

        // Token is not locked in the bridge.
        assertEq(l1ERC721Bridge.deposits(address(localToken), address(remoteToken), tokenId), false);
        assertEq(localToken.ownerOf(tokenId), alice);
    }

    /// @notice Tests that the ERC721 bridge reverts for an incorrect owner.
    function test_bridgeERC721_wrongOwner_reverts() external {
        // Bridge the token.
        vm.prank(bob, bob);
        vm.expectRevert("ERC721: transfer from incorrect owner");
        l1ERC721Bridge.bridgeERC721(address(localToken), address(remoteToken), tokenId, 1234, hex"5678");

        // Token is not locked in the bridge.
        assertEq(l1ERC721Bridge.deposits(address(localToken), address(remoteToken), tokenId), false);
        assertEq(localToken.ownerOf(tokenId), alice);
    }

    /// @notice Tests that the ERC721 bridge successfully sends a token to a different address than
    ///         the owner.
    function test_bridgeERC721To_succeeds() external {
        // Expect a call to the messenger.
        vm.expectCall(
            address(l1CrossDomainMessenger),
            abi.encodeCall(
                l1CrossDomainMessenger.sendMessage,
                (
                    address(Predeploys.L2_ERC721_BRIDGE),
                    abi.encodeCall(
                        IL2ERC721Bridge.finalizeBridgeERC721,
                        (address(remoteToken), address(localToken), alice, bob, tokenId, hex"5678")
                    ),
                    1234
                )
            )
        );

        // Expect an event to be emitted.
        vm.expectEmit(true, true, true, true);
        emit ERC721BridgeInitiated(address(localToken), address(remoteToken), alice, bob, tokenId, hex"5678");

        // Bridge the token.
        vm.prank(alice);
        l1ERC721Bridge.bridgeERC721To(address(localToken), address(remoteToken), bob, tokenId, 1234, hex"5678");

        // Token is locked in the bridge.
        assertEq(l1ERC721Bridge.deposits(address(localToken), address(remoteToken), tokenId), true);
        assertEq(localToken.ownerOf(tokenId), address(l1ERC721Bridge));
    }

    /// @notice Tests that the ERC721 bridge reverts for non externally owned accounts when sending
    ///         to a different address than the owner.
    function test_bridgeERC721To_localTokenZeroAddress_reverts() external {
        // Bridge the token.
        vm.prank(alice);
        vm.expectRevert(bytes(""));
        l1ERC721Bridge.bridgeERC721To(address(0), address(remoteToken), bob, tokenId, 1234, hex"5678");

        // Token is not locked in the bridge.
        assertEq(l1ERC721Bridge.deposits(address(localToken), address(remoteToken), tokenId), false);
        assertEq(localToken.ownerOf(tokenId), alice);
    }

    /// @notice Tests that the ERC721 bridge reverts for a zero address remote token when sending
    ///         to a different address than the owner.
    function test_bridgeERC721To_remoteTokenZeroAddress_reverts() external {
        // Bridge the token.
        vm.prank(alice);
        vm.expectRevert("L1ERC721Bridge: remote token cannot be address(0)");
        l1ERC721Bridge.bridgeERC721To(address(localToken), address(0), bob, tokenId, 1234, hex"5678");

        // Token is not locked in the bridge.
        assertEq(l1ERC721Bridge.deposits(address(localToken), address(remoteToken), tokenId), false);
        assertEq(localToken.ownerOf(tokenId), alice);
    }

    /// @notice Tests that the ERC721 bridge reverts for an incorrect owner when sending to a
    ///         different address than the owner.
    function test_bridgeERC721To_wrongOwner_reverts() external {
        // Bridge the token.
        vm.prank(bob);
        vm.expectRevert("ERC721: transfer from incorrect owner");
        l1ERC721Bridge.bridgeERC721To(address(localToken), address(remoteToken), bob, tokenId, 1234, hex"5678");

        // Token is not locked in the bridge.
        assertEq(l1ERC721Bridge.deposits(address(localToken), address(remoteToken), tokenId), false);
        assertEq(localToken.ownerOf(tokenId), alice);
    }

    /// @notice Tests that `bridgeERC721To` reverts if the to address is the zero address.
    function test_bridgeERC721To_toZeroAddress_reverts() external {
        // Bridge the token.
        vm.prank(bob);
        vm.expectRevert("ERC721Bridge: nft recipient cannot be address(0)");
        l1ERC721Bridge.bridgeERC721To(address(localToken), address(remoteToken), address(0), tokenId, 1234, hex"5678");
    }
}
