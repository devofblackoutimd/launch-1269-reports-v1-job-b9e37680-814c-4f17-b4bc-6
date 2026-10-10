// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Deploy} from "../script/Deploy.s.sol";
import {BaseTest} from "./Base.t.sol";
import {FarmItems} from "../src/FarmItems.sol";
import {RewardPool} from "../src/RewardPool.sol";
import {Params} from "../src/Params.sol";
import "../src/lib/Errors.sol";

contract DeploymentTest is BaseTest {
    function testWiringAndRuntimeLimits() public view {
        assertEq(address(d.params.emission()), address(d.rewards));
        assertEq(d.items.packSale(), address(d.packs));
        assertEq(d.items.starterClaim(), address(d.starter));
        assertEq(d.items.farmCore(), address(d.farm));
        assertEq(d.pool.rewards(), address(d.rewards));
        assertEq(d.fees.team(), team);
        assertEq(d.fees.heartbeatRecipient(), heartbeat);
        assertEq(d.params.swarmWallet(), swarm);
        assertLe(address(d.farm).code.length, 24576);
        assertLe(address(d.rewards).code.length, 24576);
        assertLe(address(d.packs).code.length, 24576);
    }

    function testNoAdminMintOrPoolDrain() public {
        vm.startPrank(swarm);
        vm.expectRevert(Unauthorized.selector);
        d.items.mint(swarm, 1);
        vm.expectRevert(Unauthorized.selector);
        d.pool.reserve(1);
        vm.expectRevert(Unauthorized.selector);
        d.pool.pay(swarm, 1);
        vm.expectRevert(Unauthorized.selector);
        d.fees.changeTeam(swarm);
        vm.stopPrank();
        vm.prank(team);
        vm.expectRevert(Unauthorized.selector);
        d.items.mint(team, 1);
        (bool ok,) = address(d.pool).call(abi.encodeWithSignature("withdraw()"));
        assertFalse(ok);
    }

    function testEmptyChainConstructorsDoNotCallDependencies() public {
        address placeholder = makeAddr("not deployed");
        new Params(swarm, placeholder);
        new FarmItems(placeholder, alice, bob);
        new RewardPool(placeholder, alice);
    }

    function testRejectInvalidConfiguration() public {
        vm.expectRevert(InvalidValue.selector);
        deployment.deploy(
            Deploy.Config(address(0), swarm, heartbeat, team, address(market), launch, bytes32(uint256(1)), 1)
        );
    }
}
