// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {Params} from "../src/Params.sol";
import {GridOperator} from "../src/GridOperator.sol";
import "../src/lib/Errors.sol";

contract OperationsTest is BaseTest {
    function testParamsRoleStepBoundsAnd24Hours() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        d.params.set(Params.Key.TariffBps, 1350);
        vm.prank(swarm);
        vm.expectRevert(InvalidValue.selector);
        d.params.set(Params.Key.TariffBps, 1349);
        vm.prank(swarm);
        d.params.set(Params.Key.TariffBps, 1350);
        assertEq(d.params.get(Params.Key.TariffBps), 1350);
        vm.prank(swarm);
        vm.expectRevert(TooEarly.selector);
        d.params.set(Params.Key.TariffBps, 1400);
        vm.warp(launch + 1 days);
        vm.prank(swarm);
        d.params.set(Params.Key.TariffBps, 1400);
        vm.warp(launch + 2 days);
        vm.prank(swarm);
        vm.expectRevert(InvalidValue.selector);
        d.params.set(Params.Key.SetCapBps, 4100);
        vm.prank(swarm);
        vm.expectRevert(InvalidValue.selector);
        d.params.set(Params.Key.EmissionBps, 501);
    }

    function testFuzzParamCannotExceedTenPercent(uint16 delta) public {
        uint256 change = bound(delta, 151, 1500);
        vm.prank(swarm);
        vm.expectRevert(InvalidValue.selector);
        d.params.set(Params.Key.TariffBps, 1500 + change);
    }

    function testEveryParameterRejectsHardBoundAndExcessStep() public {
        for (uint256 i; i <= uint256(Params.Key.SellDeviationBps); ++i) {
            Params.Key key = Params.Key(i);
            (, uint256 high) = d.params.bounds(key);
            uint256 old = d.params.get(key);
            vm.prank(swarm);
            vm.expectRevert(InvalidValue.selector);
            d.params.set(key, high + 1);
            vm.prank(swarm);
            vm.expectRevert(InvalidValue.selector);
            d.params.set(key, old + old / 10 + 1);
            vm.prank(alice);
            vm.expectRevert(Unauthorized.selector);
            d.params.set(key, old);
        }
    }

    function testBlackoutRollingMaximumAndDistrictCooldown() public {
        bool[8] memory selected;
        for (uint256 tick; tick < 5; ++tick) {
            vm.warp(launch + tick * 12 hours);
            vm.prank(swarm);
            d.grid.submitEvent(tick, GridOperator.Kind.Blackout);
            (uint256 target,,,,,) = d.grid.eventInfo(tick);
            vm.roll(target + 1);
            vm.setBlockhash(target, keccak256(abi.encode("blackout quota", tick)));
            d.grid.resolveEvent(tick);
            (,,, uint256 district,,) = d.grid.eventInfo(tick);
            assertFalse(selected[district]);
            selected[district] = true;
        }
        vm.warp(launch + 5 * 12 hours);
        vm.prank(swarm);
        vm.expectRevert(InvalidValue.selector);
        d.grid.submitEvent(5, GridOperator.Kind.Blackout);
        vm.prank(swarm);
        d.grid.submitEvent(5, GridOperator.Kind.Surge);
    }

    function testFeeSplitsEveryStreamAndPullRecipientRotation() public {
        d.fees.depositBaseFee{value: 1 ether}();
        d.fees.depositSellTax{value: 1 ether}();
        vm.prank(alice);
        d.grid.lobby{value: 1 ether}();
        assertEq(d.fees.rewardETH(), 0.7 ether);
        assertEq(d.fees.burnETH(), 1.6 ether);
        assertEq(d.fees.credit(team), 0.45 ether);
        assertEq(d.fees.credit(heartbeat), 0.25 ether);
        vm.prank(team);
        d.fees.changeTeam(bob);
        d.fees.depositBaseFee{value: 1 ether}();
        assertEq(d.fees.credit(bob), 0.2 ether);
        vm.prank(team);
        d.fees.withdraw();
        assertEq(team.balance, 0.45 ether);
        vm.prank(team);
        vm.expectRevert(Unauthorized.selector);
        d.fees.changeTeam(alice);
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        d.fees.depositPack{value: 1}();
    }

    function testBuybackQuoteSlippageSpacingAndFailureAtomicity() public {
        d.fees.depositBaseFee{value: 2 ether}();
        uint256 q = market.quote(0.1 ether);
        vm.expectRevert(InvalidValue.selector);
        d.fees.executeBuys(false, 0.1 ether, q * 97 / 100);
        uint256 beforeQueue = d.fees.rewardETH();
        market.setFailure(true);
        vm.expectRevert();
        d.fees.executeBuys(false, 0.1 ether, q * 98 / 100);
        assertEq(d.fees.rewardETH(), beforeQueue);
        market.setFailure(false);
        market.setFill(9700);
        vm.expectRevert(InsufficientBalance.selector);
        d.fees.executeBuys(false, 0.1 ether, q * 98 / 100);
        assertEq(d.fees.rewardETH(), beforeQueue);
        market.setFill(10000);
        d.fees.executeBuys(false, 0.1 ether, q * 98 / 100);
        assertEq(token.balanceOf(address(d.pool)), q);
        vm.expectRevert(TooEarly.selector);
        d.fees.executeBuys(true, 0.1 ether, q * 98 / 100);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        d.fees.executeBuys(true, 0.1 ether, q * 98 / 100);
        assertEq(token.balanceOf(address(d.burn)), q);
    }

    function testGeneratorLockUnlockPrincipalAndPauseIsolation() public {
        fund(10_000_000 ether);
        placeSolo(alice, 0, 1, 0);
        mine(alice, 1 days);
        uint256 amount = d.farm.generatorRequirement(alice) * 2;
        token.transfer(alice, amount);
        vm.startPrank(alice);
        token.approve(address(d.generator), amount);
        d.generator.lock(amount);
        assertEq(d.generator.locked(alice), amount);
        vm.expectRevert(TooEarly.selector);
        d.generator.unlock();
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(swarm);
        d.packs.pause(72 hours);
        vm.prank(alice);
        d.generator.unlock();
        assertEq(token.balanceOf(alice), amount);
        assertEq(d.generator.locked(alice), 0);
        vm.prank(alice);
        vm.expectRevert(InsufficientBalance.selector);
        d.generator.unlock();
    }

    function testGridRoleFutureBlockExpiryAndHerald() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        d.grid.submitEvent(0, GridOperator.Kind.Blackout);
        vm.prank(swarm);
        d.grid.submitEvent(0, GridOperator.Kind.Blackout);
        vm.expectRevert(TooEarly.selector);
        d.grid.resolveEvent(0);
        (uint256 target,,,,,) = d.grid.eventInfo(0);
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("event"));
        d.grid.resolveEvent(0);
        (,, GridOperator.Kind kind, uint256 district,, bool resolved) = d.grid.eventInfo(0);
        assertTrue(resolved);
        assertEq(uint256(kind), 3);
        assertEq(d.grid.weight(district * 16, block.timestamp), 5000);
        assertEq(d.grid.weight(district * 16 + 2, block.timestamp), 6250);
        assertEq(d.grid.weight(district * 16 + 3, block.timestamp), 7188);
        vm.expectRevert(AlreadyDone.selector);
        d.grid.resolveEvent(0);
        vm.prank(swarm);
        d.grid.postHerald(keccak256("letter"), "ipfs://content");
        vm.warp(launch + 12 hours);
        vm.prank(swarm);
        d.grid.submitEvent(1, GridOperator.Kind.Surge);
        vm.roll(vm.getBlockNumber() + 260);
        d.grid.resolveEvent(1);
        (,, kind,,,) = d.grid.eventInfo(1);
        assertEq(uint256(kind), 0);
    }

    function testLobbyDecayFloorSnapshotAndCalmFallback() public {
        vm.prank(alice);
        d.grid.lobby{value: 10 ether}();
        uint256 district = d.grid.district(alice);
        assertGe(d.grid.lobbyWeight(district), 4000);
        uint256 value = d.grid.lobbyValue(district);
        vm.warp(launch + 3 days);
        assertApproxEqRel(d.grid.lobbyValue(district), value / 2, 1e12);
        vm.warp(launch + 3 days + 1 hours);
        d.grid.calmTick(6);
        assertEq(d.grid.weight(0, block.timestamp), 10000);
        vm.prank(swarm);
        vm.expectRevert(TooEarly.selector);
        d.grid.submitEvent(6, GridOperator.Kind.Surge);
    }
}
