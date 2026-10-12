// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script} from "forge-std/Script.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {SwarmArgs} from "./SwarmArgs.sol";
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
import {Economy} from "../src/Economy.sol";
import {Enhancement} from "../src/Enhancement.sol";
import {Billboards} from "../src/Billboards.sol";
import {Civic} from "../src/Civic.sol";
import {Season} from "../src/Season.sol";
import "../src/lib/Errors.sol";

/// @dev Local fixture for the platform's predictContract/CREATE2 behavior, never a launch target.
contract LocalApplicationFactory {
    mapping(uint64 => mapping(uint256 => bool)) public used;
    mapping(uint64 => bool) public isRecorded;

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
        if (used[launchNumber][index]) revert AlreadyDone();
        used[launchNumber][index] = true;
        isRecorded[launchNumber] = true;
        bytes32 salt = keccak256(abi.encode(launchNumber, index));
        assembly ("memory-safe") { result := create2(0, add(initCode, 32), mload(initCode), salt) }
        if (result == address(0)) revert InvalidValue();
    }
}

/// @notice Offline rehearsal of a Desk bootstrap and two application launches. Explicit values only; no broadcasts or environment reads.
contract Deploy is Script {
    struct Config {
        address token;
        bytes oracle;
        address market;
        uint256 launchTime;
        bytes32 starterRoot;
        bytes32 freeRoot;
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
        Economy economy;
        Enhancement enhancement;
        Civic civic;
        Billboards billboards;
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        if (
            c.token == address(0) || c.oracle.length == 0 || c.market == address(0) || c.launchTime == 0
                || c.freeRoot == bytes32(0) || c.starterRoot == bytes32(0) || c.snapshotBlock == 0
        ) revert InvalidValue();
        if (
            c.endowmentBps != 0 && c.endowmentBps != 1000 && c.endowmentBps != 1500 && c.endowmentBps != 2000
                && c.endowmentBps != 2500
        ) revert InvalidValue();
        LocalApplicationFactory factory = new LocalApplicationFactory();
        // v3.8: no launch coordinates at construction; the token is excluded (Desk precedes the token launch).
        SwarmDesk.BindingConfig memory binding = SwarmDesk.BindingConfig(
            address(factory),
            0,
            0,
            0,
            0,
            keccak256(
                abi.encode(c.starterRoot, c.freeRoot, c.snapshotBlock, 1_000_000_000 ether * c.endowmentBps / 10000)
            ),
            c.heartbeatBps,
            c.heartbeatCap
        );
        SwarmDesk desk = SwarmDesk(
            factory.deploy(
                3,
                0,
                bytes.concat(
                    vm.getCode("SwarmDesk.sol:SwarmDesk"),
                    SwarmArgs.encode(abi.decode(c.oracle, (SwarmDesk.OracleConfig)), binding)
                )
            )
        );

        d.params = Params(
            factory.deploy(
                1,
                0,
                abi.encodePacked(type(Params).creationCode, abi.encode(address(desk), c.heartbeatBps, c.heartbeatCap))
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
                        c.freeRoot,
                        c.snapshotBlock,
                        1_000_000_000 ether * c.endowmentBps / 10000,
                        address(factory)
                    )
                )
            )
        );
        desk.bind(address(d.registry), type(GameRegistry).creationCode, type(Params).creationCode, 1, 1, 1, 0);
        string[14] memory names = [
            "RewardPool",
            "FarmRewards",
            "FarmCore",
            "FarmItems",
            "PackSale",
            "StarterClaim",
            "FeeRouter",
            "GridOperator",
            "Season",
            "FarmEngine",
            "Economy",
            "Enhancement",
            "Civic",
            "Billboards"
        ];
        address[14] memory modules;
        for (uint256 i; i < 14; ++i) {
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
        d.economy = Economy(modules[10]);
        d.enhancement = Enhancement(modules[11]);
        d.civic = Civic(modules[12]);
        d.billboards = Billboards(modules[13]);
    }
}
