// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

// Testing
import { CommonTest } from "test/setup/CommonTest.sol";

// Libraries
import { ForgeArtifacts, StorageSlot } from "scripts/libraries/ForgeArtifacts.sol";
import { Burn } from "src/libraries/Burn.sol";
import "src/dispute/lib/Types.sol";
import "src/dispute/lib/Errors.sol";

// Interfaces
import { IProxyAdmin } from "interfaces/universal/IProxyAdmin.sol";
import { IProxyAdminOwnedBase } from "interfaces/L1/IProxyAdminOwnedBase.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";

/// @title FallbackGasUser
/// @notice Contract that burns gas in the fallback function.
contract FallbackGasUser {
    /// @notice Amount of gas to use in the fallback function.
    uint256 public gas;

    /// @param _gas Amount of gas to use in the fallback function.
    constructor(uint256 _gas) {
        gas = _gas;
    }

    /// @notice Burn gas on fallback;
    fallback() external payable {
        Burn.gas(gas);
    }

    /// @notice Burn gas on receive.
    receive() external payable {
        Burn.gas(gas);
    }
}

/// @title FallbackReverter
/// @notice Contract that reverts in the fallback function.
contract FallbackReverter {
    /// @notice Revert on fallback.
    fallback() external payable {
        revert("FallbackReverter: revert");
    }

    /// @notice Revert on receive.
    receive() external payable {
        revert("FallbackReverter: revert");
    }
}

/// @title DelayedWETH_TestInit
/// @notice Reusable test initialization for `DelayedWETH` tests.
contract DelayedWETH_TestInit is CommonTest {
    event Approval(address indexed src, address indexed guy, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);
    event Unwrap(address indexed src, uint256 wad);

    function setUp() public virtual override {
        super.setUp();
    }
}

/// @title DelayedWETH_Initialize_Test
/// @notice Tests the `initialize` function of the `DelayedWETH` contract.
contract DelayedWETH_Initialize_Test is DelayedWETH_TestInit {
    /// @notice Tests that initialization is successful.
    function test_initialize_succeeds() public view {
        assertEq(delayedWeth.proxyAdminOwner(), proxyAdminOwner);
        assertEq(address(delayedWeth.systemConfig()), address(systemConfig));
        assertEq(address(delayedWeth.config()), address(systemConfig.superchainConfig()));
    }

    /// @notice Tests that the initializer value is correct. Trivial test for normal initialization
    ///         but confirms that the initValue is not incremented incorrectly if an upgrade
    ///         function is not present.
    function test_initialize_correctInitializerValue_succeeds() public {
        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("DelayedWETH", "_initialized");

        // Get the initializer value.
        bytes32 slotVal = vm.load(address(delayedWeth), bytes32(slot.slot));
        uint8 val = uint8(uint256(slotVal) & 0xFF);

        // Assert that the initializer value matches the expected value.
        assertEq(val, delayedWeth.initVersion());
    }

    /// @notice Tests that initialization reverts if called by a non-proxy admin or proxy admin
    ///         owner.
    /// @param _sender The address of the sender to test.
    function testFuzz_initialize_notProxyAdminOrProxyAdminOwner_reverts(address _sender) public {
        // Prank as the not ProxyAdmin or ProxyAdmin owner.
        vm.assume(_sender != address(delayedWeth.proxyAdmin()) && _sender != delayedWeth.proxyAdminOwner());

        // Get the slot for _initialized.
        StorageSlot memory slot = ForgeArtifacts.getSlot("DelayedWETH", "_initialized");

        // Set the initialized slot to 0.
        vm.store(address(delayedWeth), bytes32(slot.slot), bytes32(0));

        // Expect the revert with `ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner` selector.
        vm.expectRevert(IProxyAdminOwnedBase.ProxyAdminOwnedBase_NotProxyAdminOrProxyAdminOwner.selector);

        // Call the `initialize` function with the sender.
        vm.prank(_sender);
        delayedWeth.initialize(ISystemConfig(address(1234)));
    }
}

/// @title DelayedWETH_Unlock_Test
/// @notice Tests the `unlock` function of the `DelayedWETH` contract.
contract DelayedWETH_Unlock_Test is DelayedWETH_TestInit {
    /// @notice Tests that unlocking once is successful.
    function test_unlock_once_succeeds() public {
        delayedWeth.unlock(alice, 1 ether);
        (uint256 amount, uint256 timestamp) = delayedWeth.withdrawals(address(this), alice);
        assertEq(amount, 1 ether);
        assertEq(timestamp, block.timestamp);
    }

    /// @notice Tests that unlocking twice is successful and timestamp/amount is updated.
    function test_unlock_twice_succeeds() public {
        // Unlock once.
        uint256 ts = block.timestamp;
        delayedWeth.unlock(alice, 1 ether);
        (uint256 amount1, uint256 timestamp1) = delayedWeth.withdrawals(address(this), alice);
        assertEq(amount1, 1 ether);
        assertEq(timestamp1, ts);

        // Go forward in time.
        vm.warp(ts + 1);

        // Unlock again works.
        delayedWeth.unlock(alice, 1 ether);
        (uint256 amount2, uint256 timestamp2) = delayedWeth.withdrawals(address(this), alice);
        assertEq(amount2, 2 ether);
        assertEq(timestamp2, ts + 1);
    }
}

/// @title DelayedWETH_Withdraw_Test
/// @notice Tests the `withdraw` function of the `DelayedWETH` contract.
contract DelayedWETH_Withdraw_Test is DelayedWETH_TestInit {
    /// @notice Tests that withdrawing while unlocked and delay has passed is successful.
    function test_withdraw_whileUnlocked_succeeds() public {
        // Deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: 1 ether }();
        uint256 balance = address(alice).balance;

        // Unlock the withdrawal.
        vm.prank(alice);
        delayedWeth.unlock(alice, 1 ether);

        // Wait for the delay.
        vm.warp(block.timestamp + delayedWeth.delay() + 1);

        // Withdraw the WETH.
        vm.expectEmit(true, true, false, false);
        emit Withdrawal(address(alice), 1 ether);
        vm.prank(alice);
        delayedWeth.withdraw(1 ether);
        assertEq(address(alice).balance, balance + 1 ether);
    }

    /// @notice Tests that withdrawing when unlock was not called fails.
    function test_withdraw_whileLocked_fails() public {
        // Deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: 1 ether }();
        uint256 balance = address(alice).balance;

        // Withdraw fails when unlock not called.
        vm.expectRevert("DelayedWETH: withdrawal not unlocked");
        vm.prank(alice);
        delayedWeth.withdraw(0 ether);
        assertEq(address(alice).balance, balance);
    }

    /// @notice Tests that withdrawing while locked and delay has not passed fails.
    function test_withdraw_whileLockedNotLongEnough_fails() public {
        // Deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: 1 ether }();
        uint256 balance = address(alice).balance;

        // Call unlock.
        vm.prank(alice);
        delayedWeth.unlock(alice, 1 ether);

        // Wait for the delay, but not long enough.
        vm.warp(block.timestamp + delayedWeth.delay() - 1);

        // Withdraw fails when delay not met.
        vm.expectRevert("DelayedWETH: withdrawal delay not met");
        vm.prank(alice);
        delayedWeth.withdraw(1 ether);
        assertEq(address(alice).balance, balance);
    }

    /// @notice Tests that withdrawing more than unlocked amount fails.
    function test_withdraw_tooMuch_fails() public {
        // Deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: 1 ether }();
        uint256 balance = address(alice).balance;

        // Unlock the withdrawal.
        vm.prank(alice);
        delayedWeth.unlock(alice, 1 ether);

        // Wait for the delay.
        vm.warp(block.timestamp + delayedWeth.delay() + 1);

        // Withdraw too much fails.
        vm.expectRevert("DelayedWETH: insufficient unlocked withdrawal");
        vm.prank(alice);
        delayedWeth.withdraw(2 ether);
        assertEq(address(alice).balance, balance);
    }

    /// @notice Tests that withdrawing while paused fails.
    function test_withdraw_whenPaused_fails() public {
        // Deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: 1 ether }();

        // Unlock the withdrawal.
        vm.prank(alice);
        delayedWeth.unlock(alice, 1 ether);

        // Wait for the delay.
        vm.warp(block.timestamp + delayedWeth.delay() + 1);

        // Pause the contract.
        address guardian = optimismPortal2.guardian();
        vm.prank(guardian);
        superchainConfig.pause(address(0));

        // Withdraw fails.
        vm.expectRevert("DelayedWETH: contract is paused");
        vm.prank(alice);
        delayedWeth.withdraw(1 ether);
    }
}

/// @title DelayedWETH_WithdrawFrom_Test
/// @notice Tests the `withdraw(address, uint256)` function of the `DelayedWETH` contract.
contract DelayedWETH_WithdrawFrom_Test is DelayedWETH_TestInit {
    /// @notice Tests that withdrawing while unlocked and delay has passed is successful.
    function test_withdraw_whileUnlocked_succeeds() public {
        // Deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: 1 ether }();
        uint256 balance = address(alice).balance;

        // Unlock the withdrawal.
        vm.prank(alice);
        delayedWeth.unlock(alice, 1 ether);

        // Wait for the delay.
        vm.warp(block.timestamp + delayedWeth.delay() + 1);

        // Withdraw the WETH.
        vm.expectEmit(true, true, false, false);
        emit Withdrawal(address(alice), 1 ether);
        vm.prank(alice);
        delayedWeth.withdraw(alice, 1 ether);
        assertEq(address(alice).balance, balance + 1 ether);
    }

    /// @notice Tests that withdrawing when unlock was not called fails.
    function test_withdraw_whileLocked_fails() public {
        // Deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: 1 ether }();
        uint256 balance = address(alice).balance;

        // Withdraw fails when unlock not called.
        vm.expectRevert("DelayedWETH: withdrawal not unlocked");
        vm.prank(alice);
        delayedWeth.withdraw(alice, 0 ether);
        assertEq(address(alice).balance, balance);
    }

    /// @notice Tests that withdrawing while locked and delay has not passed fails.
    function test_withdraw_whileLockedNotLongEnough_fails() public {
        // Deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: 1 ether }();
        uint256 balance = address(alice).balance;

        // Call unlock.
        vm.prank(alice);
        delayedWeth.unlock(alice, 1 ether);

        // Wait for the delay, but not long enough.
        vm.warp(block.timestamp + delayedWeth.delay() - 1);

        // Withdraw fails when delay not met.
        vm.expectRevert("DelayedWETH: withdrawal delay not met");
        vm.prank(alice);
        delayedWeth.withdraw(alice, 1 ether);
        assertEq(address(alice).balance, balance);
    }

    /// @notice Tests that withdrawing more than unlocked amount fails.
    function test_withdraw_tooMuch_fails() public {
        // Deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: 1 ether }();
        uint256 balance = address(alice).balance;

        // Unlock the withdrawal.
        vm.prank(alice);
        delayedWeth.unlock(alice, 1 ether);

        // Wait for the delay.
        vm.warp(block.timestamp + delayedWeth.delay() + 1);

        // Withdraw too much fails.
        vm.expectRevert("DelayedWETH: insufficient unlocked withdrawal");
        vm.prank(alice);
        delayedWeth.withdraw(alice, 2 ether);
        assertEq(address(alice).balance, balance);
    }

    /// @notice Tests that withdrawing while paused fails.
    function test_withdraw_whenPaused_fails() public {
        // Deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: 1 ether }();

        // Unlock the withdrawal.
        vm.prank(alice);
        delayedWeth.unlock(alice, 1 ether);

        // Wait for the delay.
        vm.warp(block.timestamp + delayedWeth.delay() + 1);

        // Pause the contract.
        address guardian = optimismPortal2.guardian();
        vm.prank(guardian);
        superchainConfig.pause(address(0));

        // Withdraw fails.
        vm.expectRevert("DelayedWETH: contract is paused");
        vm.prank(alice);
        delayedWeth.withdraw(alice, 1 ether);
    }
}

/// @title DelayedWETH_Recover_Test
/// @notice Tests the `recover` function of the `DelayedWETH` contract.
contract DelayedWETH_Recover_Test is DelayedWETH_TestInit {
    /// @notice Tests that recovering WETH succeeds. Makes sure that doing so succeeds with any
    ///         amount of ETH in the contract and any amount of gas used in the fallback function
    ///         up to a maximum of 20,000,000 gas. Owner contract should never be using that much
    ///         gas but we might as well set a very large upper bound for ourselves.
    /// @param _amount Amount of WETH to recover.
    /// @param _fallbackGasUsage Amount of gas to use in the fallback function.
    function testFuzz_recover_succeeds(uint256 _amount, uint256 _fallbackGasUsage) public {
        // Assume
        _fallbackGasUsage = bound(_fallbackGasUsage, 0, 20000000);

        // Set up the gas burner.
        FallbackGasUser gasUser = new FallbackGasUser(_fallbackGasUsage);

        // Mock owner to return the gas user.
        vm.mockCall(address(proxyAdmin), abi.encodeCall(IProxyAdmin.owner, ()), abi.encode(address(gasUser)));

        // Give the contract some WETH to recover.
        vm.deal(address(delayedWeth), _amount);

        // Record the initial balance.
        uint256 initialBalance = address(gasUser).balance;

        // Recover the WETH.
        vm.prank(address(gasUser));
        delayedWeth.recover(_amount);

        // Verify the WETH was recovered.
        assertEq(address(delayedWeth).balance, 0);
        assertEq(address(gasUser).balance, initialBalance + _amount);
    }

    /// @notice Tests that recovering WETH by non-owner fails.
    function test_recover_byNonOwner_fails() public {
        // Pretend to be a non-owner.
        vm.prank(alice);

        // Recover fails.
        vm.expectRevert("DelayedWETH: not owner");
        delayedWeth.recover(1 ether);
    }

    /// @notice Tests that recovering more than the balance recovers what it can.
    function test_recover_moreThanBalance_succeeds() public {
        // Mock owner to return alice.
        vm.mockCall(address(proxyAdmin), abi.encodeCall(IProxyAdmin.owner, ()), abi.encode(alice));

        // Give the contract some WETH to recover.
        vm.deal(address(delayedWeth), 0.5 ether);

        // Record the initial balance.
        uint256 initialBalance = address(alice).balance;

        // Recover the WETH.
        vm.prank(alice);
        delayedWeth.recover(1 ether);

        // Verify the WETH was recovered.
        assertEq(address(delayedWeth).balance, 0);
        assertEq(address(alice).balance, initialBalance + 0.5 ether);
    }

    /// @notice Tests that recover reverts when recipient reverts.
    function test_recover_whenRecipientReverts_fails() public {
        // Set up the reverter.
        FallbackReverter reverter = new FallbackReverter();

        // Mock owner to return the reverter.
        vm.mockCall(address(proxyAdmin), abi.encodeCall(IProxyAdmin.owner, ()), abi.encode(address(reverter)));

        // Give the contract some WETH to recover.
        vm.deal(address(delayedWeth), 1 ether);

        // Recover fails.
        vm.expectRevert("DelayedWETH: recover failed");
        vm.prank(address(reverter));
        delayedWeth.recover(1 ether);
    }
}

/// @title DelayedWETH_Hold_Test
/// @notice Tests the `hold` function of the `DelayedWETH` contract.
contract DelayedWETH_Hold_Test is DelayedWETH_TestInit {
    /// @notice Tests that holding WETH succeeds.
    function test_hold_byOwner_succeeds() public {
        uint256 amount = 1 ether;

        // Pretend to be alice and deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: amount }();

        // Get our balance before.
        uint256 initialBalance = delayedWeth.balanceOf(address(proxyAdminOwner));

        // Hold some WETH.
        vm.expectEmit(true, true, true, false);
        emit Approval(alice, address(proxyAdminOwner), amount);
        vm.prank(proxyAdminOwner);
        delayedWeth.hold(alice, amount);

        // Get our balance after.
        uint256 finalBalance = delayedWeth.balanceOf(address(proxyAdminOwner));

        // Verify the transfer.
        assertEq(finalBalance, initialBalance + amount);
    }

    function test_hold_withoutAmount_succeeds() public {
        uint256 amount = 1 ether;

        // Pretend to be alice and deposit some WETH.
        vm.prank(alice);
        delayedWeth.deposit{ value: amount }();

        // Get our balance before.
        uint256 initialBalance = delayedWeth.balanceOf(address(proxyAdminOwner));

        // Hold some WETH.
        vm.expectEmit(true, true, true, false);
        emit Approval(alice, address(proxyAdminOwner), amount);
        vm.prank(proxyAdminOwner);
        delayedWeth.hold(alice); // without amount parameter

        // Get our balance after.
        uint256 finalBalance = delayedWeth.balanceOf(address(proxyAdminOwner));

        // Verify the transfer.
        assertEq(finalBalance, initialBalance + amount);
    }

    /// @notice Tests that holding WETH by non-owner fails.
    function test_hold_byNonOwner_fails() public {
        // Pretend to be a non-owner.
        vm.prank(alice);

        // Hold fails.
        vm.expectRevert("DelayedWETH: not owner");
        delayedWeth.hold(bob, 1 ether);
    }
}
