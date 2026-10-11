// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRewards {
    function epoch() external view returns (uint256);
    function live() external view returns (bool);
    function ready() external view returns (bool);
    function epochParam(uint256 e, uint256 key) external view returns (uint256);
    function epochStart() external view returns (uint256);
    function epochEnd() external view returns (uint256);
    function settledEpoch() external view returns (uint256);
    function spend(address p, uint256 nominal) external returns (uint256);
    function scrap(address p, uint256 hash, uint256 minimum) external returns (uint256);
    function recordSales(uint256 count) external;
    function setReferrer(address p, address ref) external;
    function seasonReady(uint256 week) external view returns (bool);
    function award(address p, uint256 amount) external;
    function releasePrize(uint256 amount) external;
}

interface ICore {
    function hasFarm(address p) external view returns (bool);
    function count() external view returns (uint256);
    function playerAt(uint256 i) external view returns (address);
    function level(address p) external view returns (uint256);
    function register(address p) external;
    function paidPackBought(address p, uint256 n, uint256 ethValue) external;
    function process(address p, uint256 epoch) external returns (uint256 raw, uint256 productive, uint256 power);
    function grantDrop(address p, bytes32 seed) external;
    function activity(address p, uint256 e, uint256 gross, uint256 net) external;
}

interface ISeason {
    function recordSpend(address p, uint256 ethValue, bool districtSpend) external;
    function recordActivity(address p, uint256 week, uint256 gross) external;
    function addPrize(uint256 week, uint256 amount) external;
}
