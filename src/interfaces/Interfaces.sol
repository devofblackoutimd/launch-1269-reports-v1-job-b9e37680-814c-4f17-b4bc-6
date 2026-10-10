// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IEmission {
    function checkpoint(uint256 maxTicks) external returns (bool);
}

interface IFarm {
    function register(address player) external;
    function hasFarm(address player) external view returns (bool);
    function paidPackOpened(address player, uint256 count) external;
    function chargeMerge(address player, uint256 resultId) external;
    function refresh(address player) external;
}

/// @notice Quotes are raw token units per ETH. Implementations must enforce a 30 minute TWAP.
interface IMarket {
    function quote(uint256 ethAmount) external view returns (uint256 tokens);
    function buy(uint256 minOut, address recipient) external payable returns (uint256 tokens);
}

interface IGrid {
    function weight(uint256 bucket, uint256 timestamp) external view returns (uint256);
    function rewardBps(uint256 bucket, uint256 timestamp) external view returns (uint256);
    function emissionBps(uint256 timestamp) external view returns (uint256);
    function tokenLobby(address player, uint256 ethValue) external;
}

interface IPacks {
    function price() external view returns (uint256);
    function tokenPack(address player) external returns (uint256);
}

interface IGenerator {
    function locked(address player) external view returns (uint256);
}
