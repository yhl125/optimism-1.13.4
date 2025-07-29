// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { CommonTest } from "test/setup/CommonTest.sol";

/// @title ExtendedPause_Test
/// @notice These tests are somewhat redundant with tests in the SuperchainConfig and other
///         pausable contracts, however it is worthwhile to pull them into one location to ensure
///         that the behavior is consistent.
contract ExtendedPause_Test is CommonTest {
    /// @notice Tests that other contracts are paused when the superchain config is paused
    function test_pause_fullSystem_succeeds() public {
        assertFalse(superchainConfig.paused(address(0)));

        vm.prank(superchainConfig.guardian());
        superchainConfig.pause(address(0));

        // validate the paused state
        assertTrue(superchainConfig.paused(address(0)));
        assertTrue(optimismPortal2.paused());
        assertTrue(l1CrossDomainMessenger.paused());
        assertTrue(l1StandardBridge.paused());
        assertTrue(l1ERC721Bridge.paused());
    }

    /// @notice Tests that other contracts are unpaused when the superchain config is paused and
    ///         then unpaused.
    function test_unpause_fullSystem_succeeds() external {
        // first use the test above to pause the system
        test_pause_fullSystem_succeeds();

        vm.prank(superchainConfig.guardian());
        superchainConfig.unpause(address(0));

        // validate the unpaused state
        assertFalse(superchainConfig.paused(address(0)));
        assertFalse(optimismPortal2.paused());
        assertFalse(l1CrossDomainMessenger.paused());
        assertFalse(l1StandardBridge.paused());
        assertFalse(l1ERC721Bridge.paused());
    }
}
