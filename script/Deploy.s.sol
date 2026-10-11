// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script} from "forge-std/Script.sol";
import {Params} from "../src/Params.sol";
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

/// @notice Local construction helper only. No broadcast, environment reads, token deployment, or manifest.
contract Deploy is Script {
    struct Config {
        address token;
        address swarmWallet;
        address market;
        uint256 launchTime;
        bytes32 starterRoot;
        uint256 snapshotBlock;
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
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        if (
            c.token == address(0) || c.swarmWallet == address(0) || c.market == address(0) || c.launchTime == 0
                || c.starterRoot == bytes32(0) || c.snapshotBlock == 0
        ) revert InvalidValue();
        address[11] memory a;
        uint256 nonce = vm.getNonce(address(this));
        for (uint256 i; i < 11; ++i) {
            a[i] = vm.computeCreateAddress(address(this), nonce + i);
        }
        d.params = new Params(c.swarmWallet);
        d.pool = new RewardPool(c.token, a[2]);
        d.rewards = new FarmRewards(a[0], a[1], a[3], a[8], a[7], a[9], c.launchTime);
        d.farm = new FarmCore(a[4], a[2], a[0], a[5], a[6], c.market, a[8], a[9], c.token, a[1], a[10]);
        d.items = new FarmItems(a[5], a[6], a[3], a[9], a[10]);
        d.packs = new PackSale(a[4], a[0], a[7], a[3], a[9], c.launchTime);
        d.starter = new StarterClaim(c.starterRoot, c.snapshotBlock, c.launchTime, a[4], a[3]);
        d.fees = new FeeRouter(c.token, a[0], c.market, a[1], a[5], a[8], a[2]);
        d.grid = new GridOperator(c.swarmWallet, a[0], a[7], a[2], a[3], a[9]);
        d.season = new Season(a[2], a[3], a[4], a[5], a[8], c.launchTime);
        d.engine = new FarmEngine(a[4], a[0], a[2], a[8], a[3]);
        assert(address(d.engine) == a[10]);
    }
}
