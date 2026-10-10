// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Params} from "../src/Params.sol";
import {BurnVault} from "../src/BurnVault.sol";
import {RewardPool} from "../src/RewardPool.sol";
import {FarmRewards} from "../src/FarmRewards.sol";
import {FarmCore} from "../src/FarmCore.sol";
import {FarmItems} from "../src/FarmItems.sol";
import {PackSale} from "../src/PackSale.sol";
import {StarterClaim} from "../src/StarterClaim.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {GridOperator} from "../src/GridOperator.sol";
import {Generator} from "../src/Generator.sol";
import "../src/lib/Errors.sol";

/// @notice Script only, never an on-chain factory. Every deployed contract fits EIP-170.
contract Deploy is Script {
    struct Config {
        address token;
        address swarmWallet;
        address heartbeatRecipient;
        address team;
        address market;
        uint256 launchTime;
        bytes32 starterRoot;
        uint256 snapshotBlock;
    }

    struct Deployment {
        Params params;
        BurnVault burn;
        RewardPool pool;
        FarmRewards rewards;
        FarmCore farm;
        FarmItems items;
        PackSale packs;
        StarterClaim starter;
        FeeRouter fees;
        GridOperator grid;
        Generator generator;
    }

    function run() external returns (Deployment memory d) {
        Config memory c = Config({
            token: vm.envAddress("TOKEN"),
            swarmWallet: vm.envAddress("SWARM_WALLET"),
            heartbeatRecipient: vm.envAddress("HEARTBEAT_RECIPIENT"),
            team: vm.envAddress("TEAM"),
            market: vm.envAddress("MARKET"),
            launchTime: vm.envUint("LAUNCH_TIME"),
            starterRoot: vm.envBytes32("STARTER_ROOT"),
            snapshotBlock: vm.envUint("SNAPSHOT_BLOCK")
        });
        if (c.launchTime <= block.timestamp) revert InvalidValue();
        // forge script is a simulation unless its operator explicitly supplies --broadcast.
        vm.startBroadcast(vm.envAddress("DEPLOYER"));
        d = deploy(c);
        vm.stopBroadcast();
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        if (
            c.token == address(0) || c.swarmWallet == address(0) || c.heartbeatRecipient == address(0)
                || c.team == address(0) || c.market == address(0) || c.starterRoot == bytes32(0) || c.snapshotBlock == 0
                || c.launchTime == 0
        ) revert InvalidValue();
        (VmSafe.CallerMode mode, address sender,) = vm.readCallers();
        address creator = (mode == VmSafe.CallerMode.Broadcast || mode == VmSafe.CallerMode.RecurrentBroadcast)
            ? sender
            : address(this);
        uint256 nonce = vm.getNonce(creator);
        address[11] memory a;
        for (uint256 i; i < 11; ++i) {
            a[i] = vm.computeCreateAddress(creator, nonce + i);
        }
        d.params = new Params(c.swarmWallet, a[3]);
        d.burn = new BurnVault();
        d.pool = new RewardPool(c.token, a[3]);
        d.rewards = new FarmRewards(a[0], a[2], a[4], a[1], a[9], c.launchTime);
        d.farm = new FarmCore(a[5], a[3], a[0], a[6], a[7], c.market, a[9], a[10]);
        d.items = new FarmItems(a[6], a[7], a[4]);
        d.packs = new PackSale(a[5], a[0], a[8], a[4], c.swarmWallet, c.launchTime);
        d.starter = new StarterClaim(c.starterRoot, c.snapshotBlock, c.launchTime, a[5], a[4], a[0]);
        d.fees = new FeeRouter(c.token, a[0], c.market, a[2], a[1], a[6], a[9], c.team, c.heartbeatRecipient);
        d.grid = new GridOperator(c.swarmWallet, a[4], c.launchTime, a[0], a[8], a[3]);
        d.generator = new Generator(c.token, a[4]);
        assert(address(d.generator) == a[10]);
    }
}
