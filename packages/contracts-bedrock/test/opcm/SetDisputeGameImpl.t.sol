// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IDisputeGame } from "interfaces/dispute/IDisputeGame.sol";
import { IDisputeGameFactory } from "interfaces/dispute/IDisputeGameFactory.sol";
import { GameType, Proposal, Hash } from "src/dispute/lib/Types.sol";
import { SetDisputeGameImpl, SetDisputeGameImplInput } from "scripts/deploy/SetDisputeGameImpl.s.sol";
import { DisputeGameFactory } from "src/dispute/DisputeGameFactory.sol";
import { Proxy } from "src/universal/Proxy.sol";
import { SuperchainConfig } from "src/L1/SuperchainConfig.sol";
import { AnchorStateRegistry } from "src/dispute/AnchorStateRegistry.sol";
import { SystemConfig } from "src/L1/SystemConfig.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { IAnchorStateRegistry } from "interfaces/dispute/IAnchorStateRegistry.sol";
import { IResourceMetering } from "interfaces/L1/IResourceMetering.sol";
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";

contract SetDisputeGameImplInput_Test is Test {
    SetDisputeGameImplInput input;

    function setUp() public {
        input = new SetDisputeGameImplInput();
    }

    function test_getters_whenNotSet_reverts() public {
        vm.expectRevert("SetDisputeGameImplInput: not set");
        input.factory();

        vm.expectRevert("SetDisputeGameImplInput: not set");
        input.impl();

        // gameType doesn't revert when not set, returns 0
        assertEq(input.gameType(), 0);
    }

    function test_set_succeeds() public {
        address factory = makeAddr("factory");
        address impl = makeAddr("impl");
        uint32 gameType = 1;

        vm.etch(factory, hex"01");
        vm.etch(impl, hex"01");

        input.set(input.factory.selector, factory);
        input.set(input.impl.selector, impl);
        input.set(input.gameType.selector, gameType);

        assertEq(address(input.factory()), factory);
        assertEq(address(input.impl()), impl);
        assertEq(input.gameType(), gameType);
    }

    function test_set_withZeroAddress_reverts() public {
        vm.expectRevert("SetDisputeGameImplInput: cannot set zero address");
        input.set(input.factory.selector, address(0));

        vm.expectRevert("SetDisputeGameImplInput: cannot set zero address");
        input.set(input.impl.selector, address(0));
    }

    function test_set_withInvalidSelector_reverts() public {
        vm.expectRevert("SetDisputeGameImplInput: unknown selector");
        input.set(bytes4(0xdeadbeef), makeAddr("test"));

        vm.expectRevert("SetDisputeGameImplInput: unknown selector");
        input.set(bytes4(0xdeadbeef), uint32(1));
    }
}

contract SetDisputeGameImpl_Test is Test {
    SetDisputeGameImpl script;
    SetDisputeGameImplInput input;
    IDisputeGameFactory factory;
    IAnchorStateRegistry anchorStateRegistry;
    address mockImpl;
    uint32 gameType;

    function setUp() public {
        script = new SetDisputeGameImpl();
        input = new SetDisputeGameImplInput();
        DisputeGameFactory dgfImpl = new DisputeGameFactory();
        SuperchainConfig supConfigImpl = new SuperchainConfig();
        AnchorStateRegistry anchorStateRegistryImpl = new AnchorStateRegistry(0);
        SystemConfig systemConfigImpl = new SystemConfig();

        Proxy supConfigProxy = new Proxy(address(1));
        vm.prank(address(1));
        supConfigProxy.upgradeToAndCall(
            address(supConfigImpl), abi.encodeCall(supConfigImpl.initialize, (address(this)))
        );

        Proxy systemConfigProxy = new Proxy(address(1));
        vm.prank(address(1));
        {
            systemConfigProxy.upgradeToAndCall(
                address(systemConfigImpl), _encodeInitializeSystemConfig(supConfigProxy, systemConfigImpl)
            );
        }

        Proxy factoryProxy = new Proxy(address(1));
        vm.prank(address(1));
        factoryProxy.upgradeToAndCall(address(dgfImpl), abi.encodeCall(dgfImpl.initialize, (address(this))));
        factory = IDisputeGameFactory(address(factoryProxy));

        Proxy anchorStateRegistryProxy = new Proxy(address(1));
        vm.prank(address(1));
        anchorStateRegistryProxy.upgradeToAndCall(
            address(anchorStateRegistryImpl),
            abi.encodeCall(
                anchorStateRegistryImpl.initialize,
                (
                    ISystemConfig(address(systemConfigProxy)),
                    factory,
                    Proposal({ root: Hash.wrap(0), l2SequenceNumber: 0 }),
                    GameType.wrap(100)
                )
            )
        );
        anchorStateRegistry = IAnchorStateRegistry(address(anchorStateRegistryProxy));

        mockImpl = makeAddr("impl");
        gameType = 999;
    }

    function test_run_succeeds() public {
        input.set(input.factory.selector, address(factory));
        input.set(input.impl.selector, mockImpl);
        input.set(input.anchorStateRegistry.selector, address(anchorStateRegistry));
        input.set(input.gameType.selector, gameType);

        script.run(input);
    }

    function test_run_whenImplAlreadySet_reverts() public {
        input.set(input.factory.selector, address(factory));
        input.set(input.impl.selector, mockImpl);
        input.set(input.anchorStateRegistry.selector, address(anchorStateRegistry));
        input.set(input.gameType.selector, gameType);

        // First run should succeed
        script.run(input);

        // Subsequent runs should revert
        vm.expectRevert("SDGI-10");
        script.run(input);
    }

    function test_assertValid_whenNotValid_reverts() public {
        input.set(input.factory.selector, address(factory));
        input.set(input.impl.selector, mockImpl);
        input.set(input.gameType.selector, gameType);

        // First run should succeed
        script.run(input);

        vm.broadcast(address(this));
        factory.setImplementation(GameType.wrap(gameType), IDisputeGame(address(0)));

        vm.expectRevert("SDGI-30");
        script.assertValid(input);
    }

    function _encodeInitializeSystemConfig(
        Proxy supConfigProxy,
        SystemConfig systemConfigImpl
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            systemConfigImpl.initialize,
            (
                address(this),
                1000,
                1000,
                bytes32(0),
                30_000_000,
                address(1),
                IResourceMetering.ResourceConfig({
                    maxResourceLimit: 20_000_000,
                    elasticityMultiplier: 10,
                    baseFeeMaxChangeDenominator: 8,
                    minimumBaseFee: 100_000_000,
                    systemTxMaxGas: 1_000_000,
                    maximumBaseFee: type(uint128).max
                }),
                address(2),
                SystemConfig.Addresses({
                    l1CrossDomainMessenger: address(3),
                    l1ERC721Bridge: address(4),
                    l1StandardBridge: address(5),
                    optimismPortal: address(6),
                    optimismMintableERC20Factory: address(7)
                }),
                10,
                ISuperchainConfig(address(supConfigProxy))
            )
        );
    }
}
