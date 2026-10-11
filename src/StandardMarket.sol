// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {V4Market} from "./V4Market.sol";

/// @notice Executable standard-fee reference path: 1% project, .25% network, no surcharge.
/// The actual IMD standard hook must forward its project fee to FeeRouter; never stack this hook on it.
contract StandardMarket is V4Market {
    constructor(
        address manager_,
        address token_,
        address network_,
        uint24 fee_,
        int24 spacing_,
        address launcher_,
        address factory_,
        bytes32 gameConfigHash_
    ) V4Market(manager_, token_, network_, fee_, spacing_, launcher_, factory_, gameConfigHash_) {
        storedFeeWad = 100 ether;
    }

    function projectBps() public pure override returns (uint256) {
        return 100;
    }
}
