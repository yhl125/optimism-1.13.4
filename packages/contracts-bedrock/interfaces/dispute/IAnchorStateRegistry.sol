// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IDisputeGame } from "interfaces/dispute/IDisputeGame.sol";
import { IFaultDisputeGame } from "interfaces/dispute/IFaultDisputeGame.sol";
import { IDisputeGameFactory } from "interfaces/dispute/IDisputeGameFactory.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { GameType, Hash, Proposal } from "src/dispute/lib/Types.sol";
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";
import { IProxyAdminOwnedBase } from "interfaces/L1/IProxyAdminOwnedBase.sol";

interface IAnchorStateRegistry is IProxyAdminOwnedBase {
    error AnchorStateRegistry_InvalidAnchorGame();
    error AnchorStateRegistry_Unauthorized();
    error ReinitializableBase_ZeroInitVersion();

    event AnchorUpdated(IFaultDisputeGame indexed game);
    event DisputeGameBlacklisted(IDisputeGame indexed disputeGame);
    event Initialized(uint8 version);
    event RespectedGameTypeSet(GameType gameType);
    event RetirementTimestampSet(uint256 timestamp);

    function initVersion() external view returns (uint8);
    function anchorGame() external view returns (IFaultDisputeGame);
    function anchors(GameType) external view returns (Hash, uint256);
    function blacklistDisputeGame(IDisputeGame _disputeGame) external;
    function disputeGameBlacklist(IDisputeGame) external view returns (bool);
    function getAnchorRoot() external view returns (Hash, uint256);
    function disputeGameFinalityDelaySeconds() external view returns (uint256);
    function disputeGameFactory() external view returns (IDisputeGameFactory);
    function initialize(
        ISystemConfig _systemConfig,
        IDisputeGameFactory _disputeGameFactory,
        Proposal memory _startingAnchorRoot,
        GameType _startingRespectedGameType
    )
        external;
    function isGameBlacklisted(IDisputeGame _game) external view returns (bool);
    function isGameProper(IDisputeGame _game) external view returns (bool);
    function isGameRegistered(IDisputeGame _game) external view returns (bool);
    function isGameResolved(IDisputeGame _game) external view returns (bool);
    function isGameRespected(IDisputeGame _game) external view returns (bool);
    function isGameRetired(IDisputeGame _game) external view returns (bool);
    function isGameFinalized(IDisputeGame _game) external view returns (bool);
    function isGameClaimValid(IDisputeGame _game) external view returns (bool);
    function paused() external view returns (bool);
    function respectedGameType() external view returns (GameType);
    function retirementTimestamp() external view returns (uint64);
    function setAnchorState(IDisputeGame _game) external;
    function setRespectedGameType(GameType _gameType) external;
    function systemConfig() external view returns (ISystemConfig);
    function updateRetirementTimestamp() external;
    function version() external view returns (string memory);
    function superchainConfig() external view returns (ISuperchainConfig);

    function __constructor__(
        uint256 _disputeGameFinalityDelaySeconds
    ) external;
}
