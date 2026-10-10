// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script} from "forge-std/Script.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {V4Market} from "../src/V4Market.sol";

contract DeployMarket is Script {
    function run() external returns (V4Market market) {
        MarketFactory factory = MarketFactory(vm.envAddress("MARKET_FACTORY"));
        uint256 spacing = vm.envUint("TICK_SPACING");
        require(spacing > 0 && spacing <= 32767, "invalid tick spacing");
        MarketFactory.Config memory c = MarketFactory.Config(
            vm.envAddress("POOL_MANAGER"),
            vm.envAddress("TOKEN"),
            vm.envAddress("PARAMS"),
            vm.envAddress("FEE_ROUTER"),
            vm.envAddress("NETWORK_RECIPIENT"),
            int24(uint24(spacing))
        );
        bytes32 salt = vm.envBytes32("MARKET_SALT");
        vm.startBroadcast(vm.envAddress("DEPLOYER"));
        market = factory.deploy(c, salt);
        vm.stopBroadcast();
    }
}
