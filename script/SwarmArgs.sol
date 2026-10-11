// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SwarmDesk} from "../src/SwarmDesk.sol";
import "../src/lib/Errors.sol";

/// @notice Offline constructor encoding: exactly fourteen static words, no tuple/dynamic arguments.
library SwarmArgs {
    function context(SwarmDesk.OracleConfig memory o) internal pure returns (uint256) {
        if (o.questionChain > type(uint64).max) revert InvalidValue();
        return o.questionChain | (uint256(o.fromBlock) << 64) | (uint256(o.toBlock) << 128);
    }

    function binding(SwarmDesk.BindingConfig memory b) internal pure returns (uint256) {
        if (b.heartbeatCap != 1 ether || b.heartbeatBps > type(uint16).max) revert InvalidValue();
        return uint256(b.registryLaunch) | (uint256(b.registryIndex) << 64) | (uint256(b.paramsLaunch) << 72)
            | (uint256(b.paramsIndex) << 136) | (b.heartbeatBps << 144);
    }

    function encode(SwarmDesk.OracleConfig memory o, SwarmDesk.BindingConfig memory b)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            abi.encode(o.intake, o.delivery, o.signer, o.asset, o.action, o.maxPrice, context(o)),
            abi.encode(
                o.questions[0], o.questions[1], o.bodies[0], o.bodies[1], b.factory, binding(b), b.gameConfigHash
            )
        );
    }
}
