// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script} from "forge-std/Script.sol";
import {Params} from "../src/Params.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {RewardPool} from "../src/RewardPool.sol";
import {FarmRewards} from "../src/FarmRewards.sol";
import {FarmEngine} from "../src/FarmEngine.sol";
import {FarmCore} from "../src/FarmCore.sol";
import {FarmItems} from "../src/FarmItems.sol";
import {PackSale} from "../src/PackSale.sol";
import {StarterClaim} from "../src/StarterClaim.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {GridOperator} from "../src/GridOperator.sol";
import {Season} from "../src/Season.sol";
import "../src/lib/Errors.sol";

/// @dev Local fixture for the platform's predictContract/CREATE2 behavior, never a launch target.
contract LocalApplicationFactory {
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata initCode)
        external
        view
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), keccak256(abi.encode(launchNumber, index)), keccak256(initCode)
                        )
                    )
                )
            )
        );
    }

    function deploy(uint64 launchNumber, uint256 index, bytes memory initCode) external returns (address result) {
        if (index >= 8 || launchNumber == 0) revert InvalidValue();
        bytes32 salt = keccak256(abi.encode(launchNumber, index));
        assembly ("memory-safe") { result := create2(0, add(initCode, 32), mload(initCode), salt) }
        if (result == address(0)) revert InvalidValue();
    }
}

/// @notice Offline rehearsal of two application launches. Explicit values only; no broadcasts or environment reads.
contract Deploy is Script {
    struct Config {
        address token;
        address swarmWallet;
        address market;
        uint256 launchTime;
        bytes32 starterRoot;
        uint256 snapshotBlock;
        uint256 endowmentBps;
        uint256 heartbeatBps;
        uint256 heartbeatCap;
    }

    struct Deployment {
        Params params;
        RewardPool pool;
        FarmRewards rewards;
        FarmCore farm;
        FarmItems items;
        PackSale packs;
        StarterClaim starter;
        FeeRouter fees;
        GridOperator grid;
        Season season;
        FarmEngine engine;
        GameRegistry registry;
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        if (
            c.token == address(0) || c.swarmWallet == address(0) || c.market == address(0) || c.launchTime == 0
                || c.starterRoot == bytes32(0) || c.snapshotBlock == 0
        ) revert InvalidValue();
        if (
            c.endowmentBps != 0 && c.endowmentBps != 1000 && c.endowmentBps != 1500 && c.endowmentBps != 2000
                && c.endowmentBps != 2500
        ) revert InvalidValue();
        LocalApplicationFactory factory = new LocalApplicationFactory();
        d.params = Params(
            factory.deploy(
                1,
                0,
                abi.encodePacked(type(Params).creationCode, abi.encode(c.swarmWallet, c.heartbeatBps, c.heartbeatCap))
            )
        );
        d.registry = GameRegistry(
            factory.deploy(
                1,
                1,
                abi.encodePacked(
                    type(GameRegistry).creationCode,
                    abi.encode(
                        c.token,
                        address(d.params),
                        c.market,
                        c.starterRoot,
                        c.snapshotBlock,
                        1_000_000_000 ether * c.endowmentBps / 10000,
                        address(factory)
                    )
                )
            )
        );
        string[10] memory names = [
            "RewardPool",
            "FarmRewards",
            "FarmCore",
            "FarmItems",
            "PackSale",
            "StarterClaim",
            "FeeRouter",
            "GridOperator",
            "Season",
            "FarmEngine"
        ];
        address[10] memory modules;
        for (uint256 i; i < 10; ++i) {
            bytes memory code = vm.getCode(string.concat(names[i], ".sol:", names[i]));
            uint64 launchNumber = i < 6 ? 1 : 2;
            uint256 index = i < 6 ? i + 2 : i - 6;
            modules[i] = factory.deploy(launchNumber, index, abi.encodePacked(code, abi.encode(address(d.registry))));
            assert(d.registry.register(i, launchNumber, index, code) == modules[i]);
        }
        d.pool = RewardPool(modules[0]);
        d.rewards = FarmRewards(modules[1]);
        d.farm = FarmCore(modules[2]);
        d.items = FarmItems(modules[3]);
        d.packs = PackSale(modules[4]);
        d.starter = StarterClaim(modules[5]);
        d.fees = FeeRouter(payable(modules[6]));
        d.grid = GridOperator(modules[7]);
        d.season = Season(modules[8]);
        d.engine = FarmEngine(modules[9]);
    }
}
