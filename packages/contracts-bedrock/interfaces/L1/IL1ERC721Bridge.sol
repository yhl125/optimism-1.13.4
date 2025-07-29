// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC721Bridge } from "interfaces/universal/IERC721Bridge.sol";
import { ICrossDomainMessenger } from "interfaces/universal/ICrossDomainMessenger.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";
import { IProxyAdminOwnedBase } from "interfaces/L1/IProxyAdminOwnedBase.sol";

interface IL1ERC721Bridge is IERC721Bridge, IProxyAdminOwnedBase {
    error ReinitializableBase_ZeroInitVersion();

    function initVersion() external view returns (uint8);
    function upgrade(ISystemConfig _systemConfig) external;
    function bridgeERC721(
        address _localToken,
        address _remoteToken,
        uint256 _tokenId,
        uint32 _minGasLimit,
        bytes memory _extraData
    )
        external;
    function bridgeERC721To(
        address _localToken,
        address _remoteToken,
        address _to,
        uint256 _tokenId,
        uint32 _minGasLimit,
        bytes memory _extraData
    )
        external;
    function deposits(address, address, uint256) external view returns (bool);
    function finalizeBridgeERC721(
        address _localToken,
        address _remoteToken,
        address _from,
        address _to,
        uint256 _tokenId,
        bytes memory _extraData
    )
        external;
    function initialize(ICrossDomainMessenger _messenger, ISystemConfig _systemConfig) external;
    function paused() external view returns (bool);
    function systemConfig() external view returns (ISystemConfig);
    function version() external view returns (string memory);
    function superchainConfig() external view returns (ISuperchainConfig);

    function __constructor__() external;
}
