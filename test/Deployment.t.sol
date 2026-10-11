// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Params} from "../src/Params.sol";
import {FarmItems} from "../src/FarmItems.sol";
import "../src/lib/Errors.sol";

contract DeploymentTest is BaseTest {
    function testImmutableGraphAndEip170Sizes() public view {
        assertEq(d.items.farmCore(), address(d.farm));
        assertEq(d.items.engine(), address(d.engine));
        assertEq(d.pool.rewards(), address(d.rewards));
        assertEq(address(d.farm.engine()), address(d.engine));
        assertEq(d.engine.core(), address(d.farm));
        assertEq(d.fees.rewards(), address(d.rewards));
        assertEq(d.fees.team(), team);
        address[11] memory all = [
            address(d.params),
            address(d.pool),
            address(d.rewards),
            address(d.farm),
            address(d.items),
            address(d.packs),
            address(d.starter),
            address(d.fees),
            address(d.grid),
            address(d.season),
            address(d.engine)
        ];
        for (uint256 i; i < all.length; ++i) {
            assertGt(all[i].code.length, 0);
            assertLe(all[i].code.length, 24576);
        }
    }

    function testConstructorRejectsMissingInputsAndDoesNotCallExternalContracts() public {
        vm.expectRevert(InvalidAddress.selector);
        new Params(address(0));
        Params p = new Params(alice);
        assertEq(p.swarmWallet(), alice);
        FarmItems items =
            new FarmItems(alice, bob, makeAddr("empty core"), makeAddr("empty season"), makeAddr("empty engine"));
        assertEq(items.capacity(alice), 15);
        vm.expectRevert(InvalidValue.selector);
        deployment.deploy(Deploy.Config(address(0), swarm, address(market), launch, keccak256("root"), 123));
    }

    function testForeignCallerDoesNotGetAnyAuthority() public {
        vm.prank(bob);
        Deploy.Deployment memory fresh =
            deployment.deploy(Deploy.Config(address(token), swarm, address(market), launch, keccak256("root"), 123));
        assertEq(fresh.params.swarmWallet(), swarm);
        assertEq(fresh.fees.team(), team);
        assertEq(fresh.pool.rewards(), address(fresh.rewards));
    }
}
