// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

// Testing
import { BaseFaultDisputeGame_TestInit, _changeClaimStatus } from "test/dispute/FaultDisputeGame.t.sol";

// Libraries
import { GameType, GameStatus, Hash, Claim, VMStatuses, Proposal } from "src/dispute/lib/Types.sol";
import { ForgeArtifacts, StorageSlot } from "scripts/libraries/ForgeArtifacts.sol";

// Interfaces
import { IDisputeGame } from "interfaces/dispute/IDisputeGame.sol";
import { IFaultDisputeGame } from "interfaces/dispute/IFaultDisputeGame.sol";
import { IAnchorStateRegistry } from "interfaces/dispute/IAnchorStateRegistry.sol";
import { IProxyAdminOwnedBase } from "interfaces/L1/IProxyAdminOwnedBase.sol";

/// @title AnchorStateRegistry_TestInit
/// @notice Reusable test initialization for `AnchorStateRegistry` tests.
contract AnchorStateRegistry_TestInit is BaseFaultDisputeGame_TestInit {
    /// @dev A valid l2BlockNumber that comes after the current anchor root block.
    uint256 validL2BlockNumber;

    event AnchorUpdated(IFaultDisputeGame indexed game);
    event RespectedGameTypeSet(GameType gameType);
    event RetirementTimestampSet(uint256 timestamp);

    function setUp() public virtual override {
        // Duplicating the initialization/setup logic of FaultDisputeGame_Test.
        bytes memory absolutePrestateData = abi.encode(0);
        Claim absolutePrestate = _changeClaimStatus(Claim.wrap(keccak256(absolutePrestateData)), VMStatuses.UNFINISHED);

        super.setUp();

        // Get the actual anchor roots
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();
        validL2BlockNumber = l2BlockNumber + 1;
        Claim rootClaim = Claim.wrap(Hash.unwrap(root));
        super.init({ rootClaim: rootClaim, absolutePrestate: absolutePrestate, l2BlockNumber: validL2BlockNumber });
    }
}

/// @title AnchorStateRegistry_Version_Test
/// @notice Tests the `version` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_Version_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that the version function returns a string.
    function test_version_succeeds() public view {
        assert(bytes(anchorStateRegistry.version()).length > 0);
    }
}

/// @title AnchorStateRegistry_Initialize_Test
/// @notice Tests the `initialize` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_Initialize_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that initialization is successful.
    function test_initialize_succeeds() public {
        skipIfForkTest("State has changed since initialization on a forked network.");

        // Verify starting anchor root.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();
        assertEq(root.raw(), 0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF);
        assertEq(l2BlockNumber, 0);

        // Verify contract addresses.
        assert(anchorStateRegistry.systemConfig() == systemConfig);
        assert(anchorStateRegistry.disputeGameFactory() == disputeGameFactory);
        assert(anchorStateRegistry.superchainConfig() == superchainConfig);
    }

    /// @notice Tests that the initializer value is correct. Trivial test for normal
    ///         initialization but confirms that the initValue is not incremented incorrectly if
    ///         an upgrade function is not present.
    function test_initialize_correctInitializerValue_succeeds() public {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("AnchorStateRegistry", "_initialized");

        // Get the initializer value.
        bytes32 slotVal = vm.load(address(anchorStateRegistry), bytes32(slot.slot));
        uint8 val = uint8(uint256(slotVal) & 0xFF);

        // Assert that the initializer value matches the expected value.
        assertEq(val, anchorStateRegistry.initVersion());
    }

    /// @notice Tests that initialization cannot be done twice
    function test_initialize_twice_reverts() public {
        vm.expectRevert("Initializable: contract is already initialized");
        anchorStateRegistry.initialize(
            systemConfig,
            disputeGameFactory,
            Proposal({
                root: Hash.wrap(0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF),
                l2SequenceNumber: 0
            }),
            GameType.wrap(0)
        );
    }

    /// @notice Tests that initialization reverts if called by a non-proxy admin or owner.
    /// @param _sender The address of the sender to test.
    function testFuzz_initialize_notProxyAdminOrProxyAdminOwner_reverts(address _sender) public {
        // Prank as the not ProxyAdmin or ProxyAdmin owner.
        vm.assume(
            _sender != address(anchorStateRegistry.proxyAdmin()) && _sender != anchorStateRegistry.proxyAdminOwner()
        );

        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("AnchorStateRegistry", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(anchorStateRegistry), bytes32(slot.slot), bytes32(0));

        // Expect the revert with `ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner` selector.
        vm.expectRevert(IProxyAdminOwnedBase.ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner.selector);

        // Call the `initialize` function with the sender
        vm.prank(_sender);
        anchorStateRegistry.initialize(
            systemConfig,
            disputeGameFactory,
            Proposal({
                root: Hash.wrap(0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF),
                l2SequenceNumber: 0
            }),
            GameType.wrap(0)
        );
    }
}

/// @title AnchorStateRegistry_Paused_Test
/// @notice Tests the `paused` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_Paused_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that paused() will return the correct value.
    function test_paused_succeeds() public {
        // Pause the superchain.
        vm.prank(superchainConfig.guardian());
        superchainConfig.pause(address(0));

        // Paused should return true.
        assertTrue(anchorStateRegistry.paused());

        // Unpause the superchain.
        vm.prank(superchainConfig.guardian());
        superchainConfig.unpause(address(0));

        // Paused should return false.
        assertFalse(anchorStateRegistry.paused());
    }
}

/// @title AnchorStateRegistry_SetRespectedGameType_Test
/// @notice Tests the `setRespectedGameType` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_SetRespectedGameType_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that setRespectedGameType succeeds when called by the guardian
    /// @param _gameType The game type to set as respected
    function testFuzz_setRespectedGameType_succeeds(GameType _gameType) public {
        // Call as guardian
        vm.prank(superchainConfig.guardian());
        vm.expectEmit(address(anchorStateRegistry));
        emit RespectedGameTypeSet(_gameType);
        anchorStateRegistry.setRespectedGameType(_gameType);

        // Verify the game type was set
        assertEq(anchorStateRegistry.respectedGameType().raw(), _gameType.raw());
    }

    /// @notice Tests that setRespectedGameType reverts when not called by the guardian
    /// @param _gameType The game type to attempt to set
    /// @param _caller The address attempting to call the function
    function testFuzz_setRespectedGameType_notGuardian_reverts(GameType _gameType, address _caller) public {
        // Ensure caller is not the guardian
        vm.assume(_caller != superchainConfig.guardian());

        // Attempt to call as non-guardian
        vm.prank(_caller);
        vm.expectRevert(IAnchorStateRegistry.AnchorStateRegistry_Unauthorized.selector);
        anchorStateRegistry.setRespectedGameType(_gameType);
    }
}

/// @title AnchorStateRegistry_UpdateRetirementTimestamp_Test
/// @notice Tests the `updateRetirementTimestamp` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_UpdateRetirementTimestamp_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that updateRetirementTimestamp succeeds when called by the guardian
    function test_updateRetirementTimestamp_succeeds() public {
        // Call as guardian
        vm.prank(superchainConfig.guardian());
        vm.expectEmit(address(anchorStateRegistry));
        emit RetirementTimestampSet(block.timestamp);
        anchorStateRegistry.updateRetirementTimestamp();

        // Verify the timestamp was set
        assertEq(anchorStateRegistry.retirementTimestamp(), block.timestamp);
    }

    /// @notice Tests that updateRetirementTimestamp can be called multiple times by the guardian
    function test_updateRetirementTimestamp_multipleUpdates_succeeds() public {
        // First update
        vm.prank(superchainConfig.guardian());
        anchorStateRegistry.updateRetirementTimestamp();
        uint64 firstTimestamp = anchorStateRegistry.retirementTimestamp();

        // Warp forward and update again
        vm.warp(block.timestamp + 1000);
        vm.prank(superchainConfig.guardian());
        vm.expectEmit(address(anchorStateRegistry));
        emit RetirementTimestampSet(block.timestamp);
        anchorStateRegistry.updateRetirementTimestamp();

        // Verify the timestamp was updated
        assertEq(anchorStateRegistry.retirementTimestamp(), block.timestamp);
        assertGt(anchorStateRegistry.retirementTimestamp(), firstTimestamp);
    }

    /// @notice Tests that updateRetirementTimestamp reverts when not called by the guardian
    /// @param _caller The address attempting to call the function
    function testFuzz_updateRetirementTimestamp_notGuardian_reverts(address _caller) public {
        // Ensure caller is not the guardian
        vm.assume(_caller != superchainConfig.guardian());

        // Attempt to call as non-guardian
        vm.prank(_caller);
        vm.expectRevert(IAnchorStateRegistry.AnchorStateRegistry_Unauthorized.selector);
        anchorStateRegistry.updateRetirementTimestamp();
    }
}

/// @title AnchorStateRegistry_BlacklistDisputeGame_Test
/// @notice Tests the `blacklistDisputeGame` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_BlacklistDisputeGame_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that blacklistDisputeGame succeeds when called by the guardian
    function test_blacklistDisputeGame_succeeds() public {
        // Call as guardian
        vm.prank(superchainConfig.guardian());
        vm.expectEmit(address(anchorStateRegistry));
        emit DisputeGameBlacklisted(gameProxy);
        anchorStateRegistry.blacklistDisputeGame(gameProxy);

        // Verify the game was blacklisted
        assertTrue(anchorStateRegistry.disputeGameBlacklist(gameProxy));
    }

    /// @notice Tests that multiple games can be blacklisted
    function test_blacklistDisputeGame_multipleGames_succeeds() public {
        // Create a second game proxy
        IDisputeGame secondGame = IDisputeGame(address(0x123));

        // Blacklist both games
        vm.startPrank(superchainConfig.guardian());
        anchorStateRegistry.blacklistDisputeGame(gameProxy);
        anchorStateRegistry.blacklistDisputeGame(secondGame);
        vm.stopPrank();

        // Verify both games are blacklisted
        assertTrue(anchorStateRegistry.disputeGameBlacklist(gameProxy));
        assertTrue(anchorStateRegistry.disputeGameBlacklist(secondGame));
    }

    /// @notice Tests that blacklistDisputeGame reverts when not called by the guardian
    /// @param _caller The address attempting to call the function
    function testFuzz_blacklistDisputeGame_notGuardian_reverts(address _caller) public {
        // Ensure caller is not the guardian
        vm.assume(_caller != superchainConfig.guardian());

        // Attempt to call as non-guardian
        vm.prank(_caller);
        vm.expectRevert(IAnchorStateRegistry.AnchorStateRegistry_Unauthorized.selector);
        anchorStateRegistry.blacklistDisputeGame(gameProxy);
    }

    /// @notice Tests that blacklisting a game twice succeeds but doesn't change state
    function test_blacklistDisputeGame_twice_succeeds() public {
        // Blacklist the game
        vm.startPrank(superchainConfig.guardian());
        anchorStateRegistry.blacklistDisputeGame(gameProxy);

        // Blacklist again - should emit event but not change state
        vm.expectEmit(address(anchorStateRegistry));
        emit DisputeGameBlacklisted(gameProxy);
        anchorStateRegistry.blacklistDisputeGame(gameProxy);
        vm.stopPrank();

        // Verify the game is still blacklisted
        assertTrue(anchorStateRegistry.disputeGameBlacklist(gameProxy));
    }
}

/// @title AnchorStateRegistry_Anchors_Test
/// @notice Tests the `anchors` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_Anchors_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that the anchors() function always matches the result of the getAnchorRoot()
    ///         function regardless of the game type used.
    /// @param _gameType Game type to use as input to anchors().
    function testFuzz_anchors_matchesGetAnchorRoot_succeeds(GameType _gameType) public view {
        // Get the anchor root according to getAnchorRoot().
        (Hash root1, uint256 l2BlockNumber1) = anchorStateRegistry.getAnchorRoot();

        // Get the anchor root according to anchors().
        (Hash root2, uint256 l2BlockNumber2) = anchorStateRegistry.anchors(_gameType);

        // Assert that the two roots are the same.
        assertEq(root1.raw(), root2.raw());
        assertEq(l2BlockNumber1, l2BlockNumber2);
    }
}

/// @title AnchorStateRegistry_GetAnchorRoot_Test
/// @notice Tests the `getAnchorRoot` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_GetAnchorRoot_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that getAnchorRoot will return the value of the starting anchor root when no
    ///         anchor game exists yet.
    function test_getAnchorRoot_noAnchorGame_succeeds() public {
        skipIfForkTest("On a forked network, there would most likely be an anchor game already.");

        // Assert that we nave no anchor game yet.
        assert(address(anchorStateRegistry.anchorGame()) == address(0));

        // We should get the starting anchor root back.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();
        assertEq(root.raw(), 0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF);
        assertEq(l2BlockNumber, 0);
    }

    /// @notice Tests that getAnchorRoot will return the correct anchor root if an anchor game exists.
    function test_getAnchorRoot_anchorGameExists_succeeds() public {
        // Mock the game to be resolved.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(block.timestamp));
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds() + 1);

        // Mock the game to be the defender wins.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Set the anchor game to the game proxy.
        anchorStateRegistry.setAnchorState(gameProxy);

        // We should get the anchor root back.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();
        assertEq(root.raw(), gameProxy.rootClaim().raw());
        assertEq(l2BlockNumber, gameProxy.l2SequenceNumber());
    }

    /// @notice Tests that getAnchorRoot will return the latest anchor root even if the superchain
    ///         is paused.
    function test_getAnchorRoot_superchainPaused_succeeds() public {
        // Mock the game to be resolved.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(block.timestamp));
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds() + 1);

        // Mock the game to be the defender wins.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Set the anchor game to the game proxy.
        anchorStateRegistry.setAnchorState(gameProxy);

        // Pause the superchain.
        vm.prank(superchainConfig.guardian());
        superchainConfig.pause(address(0));

        // We should get the anchor root back.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();
        assertEq(root.raw(), gameProxy.rootClaim().raw());
        assertEq(l2BlockNumber, gameProxy.l2SequenceNumber());
    }

    /// @notice Tests that getAnchorRoot returns even if the anchor game is blacklisted.
    function test_getAnchorRoot_blacklistedGame_succeeds() public {
        // Mock the game to be resolved.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(block.timestamp));
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds() + 1);

        // Mock the game to be the defender wins.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Set the anchor game to the game proxy.
        anchorStateRegistry.setAnchorState(gameProxy);

        // Blacklist the game.
        vm.prank(superchainConfig.guardian());
        anchorStateRegistry.blacklistDisputeGame(gameProxy);

        // Get the anchor root.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();
        assertEq(root.raw(), gameProxy.rootClaim().raw());
        assertEq(l2BlockNumber, gameProxy.l2SequenceNumber());
    }
}

/// @title AnchorStateRegistry_IsGameRegistered_Test
/// @notice Tests the `isGameRegistered` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_IsGameRegistered_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that isGameRegistered will return true if the game is registered.
    function test_isGameRegistered_isActuallyFactoryRegistered_succeeds() public view {
        assertTrue(anchorStateRegistry.isGameRegistered(gameProxy));
    }

    /// @notice Tests that isGameRegistered will return false if the game is not registered.
    function test_isGameRegistered_isNotFactoryRegistered_succeeds() public {
        // Mock the DisputeGameFactory to make it seem that the game was not registered.
        vm.mockCall(
            address(disputeGameFactory),
            abi.encodeCall(
                disputeGameFactory.games, (gameProxy.gameType(), gameProxy.rootClaim(), gameProxy.extraData())
            ),
            abi.encode(address(0), 0)
        );

        // Game should not be registered.
        assertFalse(anchorStateRegistry.isGameRegistered(gameProxy));
    }

    /// @notice Tests that isGameRegistered will return false if the game is not using the same
    ///         AnchorStateRegistry as the one checking the registration.
    /// @param _anchorStateRegistry The AnchorStateRegistry to use for the test.
    function test_isGameRegistered_isNotSameAnchorStateRegistry_succeeds(address _anchorStateRegistry) public {
        // Make sure the AnchorStateRegistry is different.
        vm.assume(_anchorStateRegistry != address(anchorStateRegistry));

        // Mock the gameProxy's AnchorStateRegistry to be a different address.
        vm.mockCall(
            address(gameProxy), abi.encodeCall(gameProxy.anchorStateRegistry, ()), abi.encode(_anchorStateRegistry)
        );

        // Game should not be registered.
        assertFalse(anchorStateRegistry.isGameRegistered(gameProxy));
    }
}

/// @title AnchorStateRegistry_IsGameRespected_Test
/// @notice Tests the `isGameRespected` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_IsGameRespected_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that isGameRespected will return true if the game is of the respected game
    ///         type.
    function test_isGameRespected_isRespected_succeeds() public {
        // Mock that the game was respected.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(true));
        assertTrue(anchorStateRegistry.isGameRespected(gameProxy));
    }

    /// @notice Tests that isGameRespected will return false if the game is not of the respected
    ///         game type.
    function test_isGameRespected_isNotRespected_succeeds() public {
        // Mock that the game was not respected.
        vm.mockCall(
            address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(false)
        );
        assertFalse(anchorStateRegistry.isGameRespected(gameProxy));
    }
}

/// @title AnchorStateRegistry_IsGameBlacklisted_Test
/// @notice Tests the `isGameBlacklisted` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_IsGameBlacklisted_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that isGameBlacklisted will return true if the game is blacklisted.
    function test_isGameBlacklisted_isActuallyBlacklisted_succeeds() public {
        // Blacklist the game.
        vm.prank(superchainConfig.guardian());
        anchorStateRegistry.blacklistDisputeGame(gameProxy);

        // Should return true.
        assertTrue(anchorStateRegistry.isGameBlacklisted(gameProxy));
    }

    /// @notice Tests that isGameBlacklisted will return false if the game is not blacklisted.
    function test_isGameBlacklisted_isNotBlacklisted_succeeds() public {
        // Mock the disputeGameBlacklist call to return false.
        vm.mockCall(
            address(anchorStateRegistry),
            abi.encodeCall(anchorStateRegistry.disputeGameBlacklist, (gameProxy)),
            abi.encode(false)
        );
        assertFalse(anchorStateRegistry.isGameBlacklisted(gameProxy));
    }
}

/// @title AnchorStateRegistry_IsGameRetired_Test
/// @notice Tests the `isGameRetired` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_IsGameRetired_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that isGameRetired will return true if the game is retired.
    /// @param _createdAtTimestamp The createdAt timestamp to use for the test.
    function testFuzz_isGameRetired_isRetired_succeeds(uint64 _createdAtTimestamp) public {
        // Set the retirement timestamp to now.
        vm.prank(superchainConfig.guardian());
        anchorStateRegistry.updateRetirementTimestamp();

        // Make sure createdAt timestamp is less than or equal to the retirementTimestamp.
        _createdAtTimestamp = uint64(bound(_createdAtTimestamp, 0, anchorStateRegistry.retirementTimestamp()));

        // Mock the createdAt call.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.createdAt, ()), abi.encode(_createdAtTimestamp));

        // Game should be retired.
        assertTrue(anchorStateRegistry.isGameRetired(gameProxy));
    }

    /// @notice Tests that isGameRetired will return false if the game is not retired.
    /// @param _createdAtTimestamp The createdAt timestamp to use for the test.
    function testFuzz_isGameRetired_isNotRetired_succeeds(uint64 _createdAtTimestamp) public {
        // Set the retirement timestamp to now.
        vm.prank(superchainConfig.guardian());
        anchorStateRegistry.updateRetirementTimestamp();

        // Make sure createdAt timestamp is greater than the retirementTimestamp.
        _createdAtTimestamp =
            uint64(bound(_createdAtTimestamp, anchorStateRegistry.retirementTimestamp() + 1, type(uint64).max));

        // Mock the call to createdAt.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.createdAt, ()), abi.encode(_createdAtTimestamp));

        // Game should not be retired.
        assertFalse(anchorStateRegistry.isGameRetired(gameProxy));
    }
}

/// @title AnchorStateRegistry_IsGameResolved_Test
/// @notice Tests the `isGameResolved` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_IsGameResolved_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that isGameResolved will return true if the game is resolved.
    /// @param _resolvedAtTimestamp The resolvedAt timestamp to use for the test.
    function testFuzz_isGameResolved_challengerWins_succeeds(uint256 _resolvedAtTimestamp) public {
        // Bound resolvedAt to be less than or equal to current timestamp.
        _resolvedAtTimestamp = bound(_resolvedAtTimestamp, 1, block.timestamp);

        // Mock the resolvedAt timestamp.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(_resolvedAtTimestamp));

        // Mock the status to be CHALLENGER_WINS.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.CHALLENGER_WINS));

        // Game should be resolved.
        assertTrue(anchorStateRegistry.isGameResolved(gameProxy));
    }

    /// @notice Tests that isGameResolved will return true if the game is resolved.
    /// @param _resolvedAtTimestamp The resolvedAt timestamp to use for the test.
    function testFuzz_isGameResolved_defenderWins_succeeds(uint256 _resolvedAtTimestamp) public {
        // Bound resolvedAt to be less than or equal to current timestamp.
        _resolvedAtTimestamp = bound(_resolvedAtTimestamp, 1, block.timestamp);

        // Mock the resolvedAt timestamp.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(_resolvedAtTimestamp));

        // Mock the status to be DEFENDER_WINS.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Game should be resolved.
        assertTrue(anchorStateRegistry.isGameResolved(gameProxy));
    }

    /// @notice Tests that isGameResolved will return false if the game is in progress and not
    ///         resolved.
    /// @param _resolvedAtTimestamp The resolvedAt timestamp to use for the test.
    function testFuzz_isGameResolved_inProgressNotResolved_succeeds(uint256 _resolvedAtTimestamp) public {
        // Bound resolvedAt to be less than or equal to current timestamp.
        _resolvedAtTimestamp = bound(_resolvedAtTimestamp, 1, block.timestamp);

        // Mock the resolvedAt timestamp.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(_resolvedAtTimestamp));

        // Mock the status to be IN_PROGRESS.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.IN_PROGRESS));

        // Game should not be resolved.
        assertFalse(anchorStateRegistry.isGameResolved(gameProxy));
    }
}

/// @title AnchorStateRegistry_IsGameProper_Test
/// @notice Tests the `isGameProper` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_IsGameProper_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that isGameProper will return true if the game meets all conditions.
    function test_isGameProper_meetsAllConditions_succeeds() public view {
        // Game will meet all conditions by default.
        assertTrue(anchorStateRegistry.isGameProper(gameProxy));
    }

    /// @notice Tests that isGameProper will return false if the game is not registered.
    function test_isGameProper_isNotFactoryRegistered_succeeds() public {
        // Mock the DisputeGameFactory to make it seem that the game was not registered.
        vm.mockCall(
            address(disputeGameFactory),
            abi.encodeCall(
                disputeGameFactory.games, (gameProxy.gameType(), gameProxy.rootClaim(), gameProxy.extraData())
            ),
            abi.encode(address(0), 0)
        );

        assertFalse(anchorStateRegistry.isGameProper(gameProxy));
    }

    /// @notice Tests that isGameProper will return false if the game is not the respected game
    ///         type.
    /// @param _gameType The game type to use for the test.
    function testFuzz_isGameProper_anyGameType_succeeds(GameType _gameType) public {
        if (_gameType.raw() == gameProxy.gameType().raw()) {
            _gameType = GameType.wrap(_gameType.raw() + 1);
        }

        // Mock that the game was not respected.
        vm.mockCall(
            address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(false)
        );

        // Still a proper game.
        assertTrue(anchorStateRegistry.isGameProper(gameProxy));
    }

    /// @notice Tests that isGameProper will return false if the game is blacklisted.
    function test_isGameProper_isBlacklisted_succeeds() public {
        // Blacklist the game.
        vm.prank(superchainConfig.guardian());
        anchorStateRegistry.blacklistDisputeGame(gameProxy);

        // Should return false.
        assertFalse(anchorStateRegistry.isGameProper(gameProxy));
    }

    /// @notice Tests that isGameProper will return false if the superchain is paused.
    function test_isGameProper_superchainPaused_succeeds() public {
        // Pause the superchain.
        vm.prank(superchainConfig.guardian());
        superchainConfig.pause(address(0));

        // Game should not be proper.
        assertFalse(anchorStateRegistry.isGameProper(gameProxy));
    }

    /// @notice Tests that isGameProper will return false if the game is retired.
    /// @param _createdAtTimestamp The createdAt timestamp to use for the test.
    function testFuzz_isGameProper_isRetired_succeeds(uint64 _createdAtTimestamp) public {
        // Set the retirement timestamp to now.
        vm.prank(superchainConfig.guardian());
        anchorStateRegistry.updateRetirementTimestamp();

        // Make sure createdAt timestamp is less than or equal to the retirementTimestamp.
        _createdAtTimestamp = uint64(bound(_createdAtTimestamp, 0, anchorStateRegistry.retirementTimestamp()));

        // Mock the call to createdAt.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.createdAt, ()), abi.encode(_createdAtTimestamp));

        // Game should not be proper.
        assertFalse(anchorStateRegistry.isGameProper(gameProxy));
    }
}

/// @title AnchorStateRegistry_IsGameFinalized_Test
/// @notice Tests the `isGameFinalized` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_IsGameFinalized_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that isGameFinalized will return true if the game is finalized.
    /// @param _resolvedAtTimestamp The resolvedAt timestamp to use for the test.
    function testFuzz_isGameFinalized_isFinalized_succeeds(uint256 _resolvedAtTimestamp) public {
        // Warp forward by disputeGameFinalityDelaySeconds.
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds());

        // Bound resolvedAt to be at least disputeGameFinalityDelaySeconds in the past.
        // Must be greater than 0.
        _resolvedAtTimestamp =
            bound(_resolvedAtTimestamp, 1, block.timestamp - optimismPortal2.disputeGameFinalityDelaySeconds() - 1);

        // Mock the resolvedAt timestamp.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(_resolvedAtTimestamp));

        // Mock the status to be DEFENDER_WINS.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Game should be finalized.
        assertTrue(anchorStateRegistry.isGameFinalized(gameProxy));
    }

    /// @notice Tests that isGameFinalized will return false if the game is not finalized.
    /// @param _resolvedAtTimestamp The resolvedAt timestamp to use for the test.
    function testFuzz_isGameFinalized_isNotAirgapped_succeeds(uint256 _resolvedAtTimestamp) public {
        // Warp forward by disputeGameFinalityDelaySeconds.
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds());

        // Bound resolvedAt to be less than disputeGameFinalityDelaySeconds in the past.
        _resolvedAtTimestamp = bound(
            _resolvedAtTimestamp, block.timestamp - optimismPortal2.disputeGameFinalityDelaySeconds(), block.timestamp
        );

        // Mock the resolvedAt timestamp.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(_resolvedAtTimestamp));

        // Game should not be finalized.
        assertFalse(anchorStateRegistry.isGameFinalized(gameProxy));
    }

    /// @notice Tests that isGameFinalized will return false if the game is not resolved.
    function test_isGameFinalized_isNotResolved_succeeds() public {
        // Warp forward by disputeGameFinalityDelaySeconds.
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds());

        // Mock the status call to be IN_PROGRESS.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.IN_PROGRESS));

        // Game should not be finalized.
        assertFalse(anchorStateRegistry.isGameFinalized(gameProxy));
    }
}

/// @title AnchorStateRegistry_IsGameClaimValid_Test
/// @notice Tests the `isGameClaimValid` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_IsGameClaimValid_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that isGameClaimValid will return true if the game claim is valid.
    /// @param _resolvedAtTimestamp The resolvedAt timestamp to use for the test.
    function testFuzz_isGameClaimValid_claimIsValid_succeeds(uint256 _resolvedAtTimestamp) public {
        // Warp forward by disputeGameFinalityDelaySeconds.
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds());

        // Bound resolvedAt to be at least disputeGameFinalityDelaySeconds in the past.
        _resolvedAtTimestamp =
            bound(_resolvedAtTimestamp, 1, block.timestamp - optimismPortal2.disputeGameFinalityDelaySeconds() - 1);

        // Mock that the game was respected.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(true));

        // Mock the resolvedAt timestamp.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(_resolvedAtTimestamp));

        // Mock the status to be DEFENDER_WINS.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Claim should be valid.
        assertTrue(anchorStateRegistry.isGameClaimValid(gameProxy));
    }

    /// @notice Tests that isGameClaimValid will return false if the game is not registered.
    function testFuzz_isGameClaimValid_notRegistered_succeeds() public {
        // Mock the DisputeGameFactory to make it seem that the game was not registered.
        vm.mockCall(
            address(disputeGameFactory),
            abi.encodeCall(
                disputeGameFactory.games, (gameProxy.gameType(), gameProxy.rootClaim(), gameProxy.extraData())
            ),
            abi.encode(address(0), 0)
        );

        // Claim should not be valid.
        assertFalse(anchorStateRegistry.isGameClaimValid(gameProxy));
    }

    /// @notice Tests that isGameClaimValid will return false if the game is not respected.
    /// @param _gameType The game type to use for the test.
    function testFuzz_isGameClaimValid_isNotRespected_succeeds(GameType _gameType) public {
        if (_gameType.raw() == gameProxy.gameType().raw()) {
            _gameType = GameType.wrap(_gameType.raw() + 1);
        }

        // Mock that the game was not respected.
        vm.mockCall(
            address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(false)
        );

        // Claim should not be valid.
        assertFalse(anchorStateRegistry.isGameClaimValid(gameProxy));
    }

    /// @notice Tests that isGameClaimValid will return false if the game is blacklisted.
    function testFuzz_isGameClaimValid_isBlacklisted_succeeds() public {
        // Mock the disputeGameBlacklist call to return true.
        vm.mockCall(
            address(anchorStateRegistry),
            abi.encodeCall(anchorStateRegistry.disputeGameBlacklist, (gameProxy)),
            abi.encode(true)
        );

        // Claim should not be valid.
        assertFalse(anchorStateRegistry.isGameClaimValid(gameProxy));
    }

    /// @notice Tests that isGameClaimValid will return false if the game is retired.
    /// @param _createdAtTimestamp The createdAt timestamp to use for the test.
    function testFuzz_isGameClaimValid_isRetired_succeeds(uint256 _createdAtTimestamp) public {
        // Set the retirement timestamp to now.
        vm.prank(superchainConfig.guardian());
        anchorStateRegistry.updateRetirementTimestamp();

        // Make sure createdAt timestamp is less than or equal to the retirementTimestamp.
        _createdAtTimestamp = uint64(bound(_createdAtTimestamp, 0, anchorStateRegistry.retirementTimestamp()));

        // Mock the call to createdAt.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.createdAt, ()), abi.encode(_createdAtTimestamp));

        // Claim should not be valid.
        assertFalse(anchorStateRegistry.isGameClaimValid(gameProxy));
    }

    /// @notice Tests that isGameClaimValid will return false if the game is not resolved.
    function testFuzz_isGameClaimValid_notResolved_succeeds() public {
        // Mock the status to be IN_PROGRESS.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.IN_PROGRESS));

        // Claim should not be valid.
        assertFalse(anchorStateRegistry.isGameClaimValid(gameProxy));
    }

    /// @notice Tests that isGameClaimValid will return false if the game is not airgapped.
    /// @param _resolvedAtTimestamp The resolvedAt timestamp to use for the test.
    function testFuzz_isGameClaimValid_notAirgapped_succeeds(uint256 _resolvedAtTimestamp) public {
        // Warp forward by disputeGameFinalityDelaySeconds.
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds());

        // Bound resolvedAt to be less than disputeGameFinalityDelaySeconds in the past.
        _resolvedAtTimestamp = bound(
            _resolvedAtTimestamp, block.timestamp - optimismPortal2.disputeGameFinalityDelaySeconds(), block.timestamp
        );

        // Mock the resolvedAt timestamp.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(_resolvedAtTimestamp));

        // Claim should not be valid.
        assertFalse(anchorStateRegistry.isGameClaimValid(gameProxy));
    }

    /// @notice Tests that isGameClaimValid will return false if the superchain is paused.
    function test_isGameClaimValid_superchainPaused_succeeds() public {
        // Pause the superchain.
        vm.prank(superchainConfig.guardian());
        superchainConfig.pause(address(0));

        // Game should not be valid.
        assertFalse(anchorStateRegistry.isGameClaimValid(gameProxy));
    }
}

/// @title AnchorStateRegistry_SetAnchorState_Test
/// @notice Tests the `setAnchorState` function of the `AnchorStateRegistry` contract.
contract AnchorStateRegistry_SetAnchorState_Test is AnchorStateRegistry_TestInit {
    /// @notice Tests that setAnchorState will succeed if the game is valid, the game block number
    ///         is greater than the current anchor root block number, and the game is the currently
    ///         respected game type.
    /// @param _l2BlockNumber The L2 block number to use for the game.
    function testFuzz_setAnchorState_validNewerState_succeeds(uint256 _l2BlockNumber) public {
        // Grab block number of the existing anchor root.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();

        // Bound the new block number.
        _l2BlockNumber = bound(_l2BlockNumber, validL2BlockNumber, type(uint256).max);

        // Mock the l2BlockNumber call.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.l2SequenceNumber, ()), abi.encode(_l2BlockNumber));

        // Mock the DEFENDER_WINS state.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Mock that the game was respected.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(true));

        // Mock the resolvedAt timestamp and fast forward to beyond the delay.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(block.timestamp));
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds() + 1);

        // Update the anchor state.
        vm.prank(address(gameProxy));
        vm.expectEmit(address(anchorStateRegistry));
        emit AnchorUpdated(gameProxy);
        anchorStateRegistry.setAnchorState(gameProxy);

        // Confirm that the anchor state is now the same as the game state.
        (root, l2BlockNumber) = anchorStateRegistry.getAnchorRoot();
        assertEq(l2BlockNumber, gameProxy.l2SequenceNumber());
        assertEq(root.raw(), gameProxy.rootClaim().raw());

        // Confirm that the anchor game is now set.
        IFaultDisputeGame anchorGame = anchorStateRegistry.anchorGame();
        assertEq(address(anchorGame), address(gameProxy));
    }

    /// @notice Tests that setAnchorState will revert if the game is valid and the game block
    ///         number is less than or equal to the current anchor root block number.
    /// @param _l2BlockNumber The L2 block number to use for the game.
    function testFuzz_setAnchorState_olderValidGameClaim_fails(uint256 _l2BlockNumber) public {
        // Grab block number of the existing anchor root.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();

        // Bound the new block number.
        _l2BlockNumber = bound(_l2BlockNumber, 0, l2BlockNumber);

        // Mock the l2BlockNumber call.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.l2SequenceNumber, ()), abi.encode(_l2BlockNumber));

        // Mock the DEFENDER_WINS state.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Mock that the game was respected.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(true));

        // Mock the resolvedAt timestamp and fast forward to beyond the delay.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(block.timestamp));
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds() + 1);

        // Try to update the anchor state.
        vm.prank(address(gameProxy));
        vm.expectRevert(IAnchorStateRegistry.AnchorStateRegistry_InvalidAnchorGame.selector);
        anchorStateRegistry.setAnchorState(gameProxy);

        // Confirm that the anchor state has not updated.
        (Hash updatedRoot, uint256 updatedL2BlockNumber) = anchorStateRegistry.getAnchorRoot();
        assertEq(updatedL2BlockNumber, l2BlockNumber);
        assertEq(updatedRoot.raw(), root.raw());
    }

    /// @notice Tests that setAnchorState will revert if the game is not registered.
    /// @param _l2BlockNumber The L2 block number to use for the game.
    function testFuzz_setAnchorState_notFactoryRegisteredGame_fails(uint256 _l2BlockNumber) public {
        // Grab block number of the existing anchor root.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();

        // Bound the new block number.
        _l2BlockNumber = bound(_l2BlockNumber, l2BlockNumber, type(uint256).max);

        // Mock the l2BlockNumber call.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.l2SequenceNumber, ()), abi.encode(_l2BlockNumber));

        // Mock the DEFENDER_WINS state.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Mock that the game was respected.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(true));

        // Mock the DisputeGameFactory to make it seem that the game was not registered.
        vm.mockCall(
            address(disputeGameFactory),
            abi.encodeCall(
                disputeGameFactory.games, (gameProxy.gameType(), gameProxy.rootClaim(), gameProxy.extraData())
            ),
            abi.encode(address(0), 0)
        );

        // Try to update the anchor state.
        vm.prank(superchainConfig.guardian());
        vm.expectRevert(IAnchorStateRegistry.AnchorStateRegistry_InvalidAnchorGame.selector);
        anchorStateRegistry.setAnchorState(gameProxy);

        // Confirm that the anchor state has not updated.
        (Hash updatedRoot, uint256 updatedL2BlockNumber) = anchorStateRegistry.getAnchorRoot();
        assertEq(updatedL2BlockNumber, l2BlockNumber);
        assertEq(updatedRoot.raw(), root.raw());
    }

    /// @notice Tests that setAnchorState will revert if the game is valid and the game status is
    ///         CHALLENGER_WINS.
    /// @param _l2BlockNumber The L2 block number to use for the game.
    function testFuzz_setAnchorState_challengerWins_fails(uint256 _l2BlockNumber) public {
        // Grab block number of the existing anchor root.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();

        // Bound the new block number.
        _l2BlockNumber = bound(_l2BlockNumber, l2BlockNumber, type(uint256).max);

        // Mock the l2BlockNumber call.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.l2SequenceNumber, ()), abi.encode(_l2BlockNumber));

        // Mock the CHALLENGER_WINS state.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.CHALLENGER_WINS));

        // Mock that the game was respected.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(true));

        // Mock the resolvedAt timestamp and fast forward to beyond the delay.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(block.timestamp));
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds() + 1);

        // Try to update the anchor state.
        vm.prank(address(gameProxy));
        vm.expectRevert(IAnchorStateRegistry.AnchorStateRegistry_InvalidAnchorGame.selector);
        anchorStateRegistry.setAnchorState(gameProxy);

        // Confirm that the anchor state has not updated.
        (Hash updatedRoot, uint256 updatedL2BlockNumber) = anchorStateRegistry.getAnchorRoot();
        assertEq(updatedL2BlockNumber, l2BlockNumber);
        assertEq(updatedRoot.raw(), root.raw());
    }

    /// @notice Tests that setAnchorState will revert if the game is valid and the game status is
    ///         IN_PROGRESS.
    /// @param _l2BlockNumber The L2 block number to use for the game.
    function testFuzz_setAnchorState_inProgress_fails(uint256 _l2BlockNumber) public {
        // Grab block number of the existing anchor root.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();

        // Bound the new block number.
        _l2BlockNumber = bound(_l2BlockNumber, l2BlockNumber, type(uint256).max);

        // Mock the l2BlockNumber call.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.l2SequenceNumber, ()), abi.encode(_l2BlockNumber));

        // Mock the CHALLENGER_WINS state.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.IN_PROGRESS));

        // Mock that the game was respected.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(true));

        // Mock the resolvedAt timestamp and fast forward to beyond the delay.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(block.timestamp));
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds() + 1);

        // Try to update the anchor state.
        vm.prank(address(gameProxy));
        vm.expectRevert(IAnchorStateRegistry.AnchorStateRegistry_InvalidAnchorGame.selector);
        anchorStateRegistry.setAnchorState(gameProxy);

        // Confirm that the anchor state has not updated.
        (Hash updatedRoot, uint256 updatedL2BlockNumber) = anchorStateRegistry.getAnchorRoot();
        assertEq(updatedL2BlockNumber, l2BlockNumber);
        assertEq(updatedRoot.raw(), root.raw());
    }

    /// @notice Tests that setAnchorState will revert if the game is not respected.
    /// @param _l2BlockNumber The L2 block number to use for the game.
    function testFuzz_setAnchorState_isNotRespectedGame_fails(uint256 _l2BlockNumber) public {
        // Grab block number of the existing anchor root.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.anchors(gameProxy.gameType());

        // Bound the new block number.
        _l2BlockNumber = bound(_l2BlockNumber, l2BlockNumber, type(uint256).max);

        // Mock the l2BlockNumber call.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.l2SequenceNumber, ()), abi.encode(_l2BlockNumber));

        // Mock the DEFENDER_WINS state.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Mock the resolvedAt timestamp and fast forward to beyond the delay.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(block.timestamp));
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds() + 1);

        // Mock that the game was not respected when created.
        vm.mockCall(
            address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(false)
        );

        // Try to update the anchor state.
        vm.prank(address(gameProxy));
        vm.expectRevert(IAnchorStateRegistry.AnchorStateRegistry_InvalidAnchorGame.selector);
        anchorStateRegistry.setAnchorState(gameProxy);

        // Confirm that the anchor state has not updated.
        (Hash updatedRoot, uint256 updatedL2BlockNumber) = anchorStateRegistry.anchors(gameProxy.gameType());
        assertEq(updatedL2BlockNumber, l2BlockNumber);
        assertEq(updatedRoot.raw(), root.raw());
    }

    /// @notice Tests that setAnchorState will revert if the game is valid and the game is
    ///         blacklisted.
    /// @param _l2BlockNumber The L2 block number to use for the game.
    function testFuzz_setAnchorState_blacklistedGame_fails(uint256 _l2BlockNumber) public {
        // Grab block number of the existing anchor root.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();

        // Bound the new block number.
        _l2BlockNumber = bound(_l2BlockNumber, validL2BlockNumber, type(uint256).max);

        // Mock the DEFENDER_WINS state.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Mock that the game was respected.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(true));

        // Mock the resolvedAt timestamp and fast forward to beyond the delay.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.resolvedAt, ()), abi.encode(block.timestamp));
        vm.warp(block.timestamp + optimismPortal2.disputeGameFinalityDelaySeconds() + 1);

        // Blacklist the game.
        vm.prank(superchainConfig.guardian());
        anchorStateRegistry.blacklistDisputeGame(gameProxy);

        // Update the anchor state.
        vm.prank(address(gameProxy));
        vm.expectRevert(IAnchorStateRegistry.AnchorStateRegistry_InvalidAnchorGame.selector);
        anchorStateRegistry.setAnchorState(gameProxy);

        // Confirm that the anchor state has not updated.
        (Hash updatedRoot, uint256 updatedL2BlockNumber) = anchorStateRegistry.anchors(gameProxy.gameType());
        assertEq(updatedL2BlockNumber, l2BlockNumber);
        assertEq(updatedRoot.raw(), root.raw());
    }

    /// @notice Tests that setAnchorState will revert if the game is retired.
    /// @param _l2BlockNumber The L2 block number to use for the game.
    function testFuzz_setAnchorState_retiredGame_fails(uint256 _l2BlockNumber) public {
        // Grab block number of the existing anchor root.
        (Hash root, uint256 l2BlockNumber) = anchorStateRegistry.getAnchorRoot();

        // Bound the new block number.
        _l2BlockNumber = bound(_l2BlockNumber, validL2BlockNumber, type(uint256).max);

        // Mock the DEFENDER_WINS state.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.status, ()), abi.encode(GameStatus.DEFENDER_WINS));

        // Mock that the game was respected.
        vm.mockCall(address(gameProxy), abi.encodeCall(gameProxy.wasRespectedGameTypeWhenCreated, ()), abi.encode(true));

        // Set the retirement timestamp.
        vm.prank(superchainConfig.guardian());
        anchorStateRegistry.updateRetirementTimestamp();

        // Mock the call to createdAt.
        vm.mockCall(
            address(gameProxy),
            abi.encodeCall(gameProxy.createdAt, ()),
            abi.encode(anchorStateRegistry.retirementTimestamp() - 1)
        );

        // Update the anchor state.
        vm.prank(address(gameProxy));
        vm.expectRevert(IAnchorStateRegistry.AnchorStateRegistry_InvalidAnchorGame.selector);
        anchorStateRegistry.setAnchorState(gameProxy);

        // Confirm that the anchor state has not updated.
        (Hash updatedRoot, uint256 updatedL2BlockNumber) = anchorStateRegistry.anchors(gameProxy.gameType());
        assertEq(updatedL2BlockNumber, l2BlockNumber);
        assertEq(updatedRoot.raw(), root.raw());
    }

    /// @notice Tests that setAnchorState will revert if the superchain is paused.
    function test_setAnchorState_superchainPaused_fails() public {
        // Pause the superchain.
        vm.prank(superchainConfig.guardian());
        superchainConfig.pause(address(0));

        // Update the anchor state.
        vm.prank(address(gameProxy));
        vm.expectRevert(IAnchorStateRegistry.AnchorStateRegistry_InvalidAnchorGame.selector);
        anchorStateRegistry.setAnchorState(gameProxy);
    }
}
