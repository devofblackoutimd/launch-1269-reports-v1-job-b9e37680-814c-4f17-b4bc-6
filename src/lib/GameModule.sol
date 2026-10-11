// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IGameRegistry} from "../interfaces/IGameRegistry.sol";
import "./Errors.sol";

/// @notice Every module is permanently tied to one immutable, append-only deployment graph.
abstract contract GameModule {
    IGameRegistry public immutable registry;

    constructor(address registry_) {
        if (registry_ == address(0)) revert InvalidAddress();
        registry = IGameRegistry(registry_);
    }
}
