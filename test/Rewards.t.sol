// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {FarmCore} from "../src/FarmCore.sol";
import {Params} from "../src/Params.sol";
import "../src/lib/Errors.sol";

contract RewardsTest is BaseTest {
    function start() internal {
        fund(10_000_000 ether);
        placeSolo(alice, 0, 1, 0);
    }

    function testMiningClaimTaxAndConservation() public {
        start();
        uint256 initial = token.balanceOf(address(d.pool));
        mine(alice, 1 days);
        uint256 pending = d.rewards.pending(alice);
        assertGt(pending, 0);
        assertGe(d.pool.reserved(), pending);
        uint256 tax = pending * d.rewards.taxBps(0) / 10000;
        vm.prank(alice);
        uint256 paid = d.rewards.claim(pending);
        assertEq(paid, pending - tax);
        assertEq(token.balanceOf(alice), paid);
        assertEq(d.rewards.redistribution(), tax);
        assertEq(token.balanceOf(address(d.pool)) + token.balanceOf(address(d.burn)) + paid, initial);
        assertGe(token.balanceOf(address(d.pool)), d.pool.reserved());
        vm.prank(alice);
        vm.expectRevert(InsufficientBalance.selector);
        d.rewards.claim(1);
    }

    function testReservedUnclaimedCannotBeEmittedAgain() public {
        start();
        mine(alice, 1 days);
        uint256 p = d.rewards.pending(alice);
        uint256 reserved = d.pool.reserved();
        assertGt(reserved, p);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        d.rewards.checkpoint(64);
        assertGt(d.pool.reserved(), reserved);
        assertLt(d.pool.available(), 10_000_000 ether - reserved);
        vm.prank(alice);
        d.rewards.claim(p);
        assertGe(token.balanceOf(address(d.pool)), d.pool.reserved());
    }

    function testOldRewardsKeepVintageWithoutDailyCalls() public {
        start();
        vm.warp(launch + 1 days);
        d.rewards.checkpoint(64);
        // Remove hash at day one, retaining its original day-zero vintage.
        vm.prank(alice);
        d.farm.unplace(4, 0);
        uint256 old = d.rewards.pending(alice);
        vm.warp(launch + 8 days);
        vm.prank(alice);
        uint256 net = d.rewards.claim(old);
        assertEq(net, old - old * 500 / 10000);
    }

    function testFIFOConsumesOldBeforeFresh() public {
        start();
        mine(alice, 1 days);
        uint256 old = d.rewards.pending(alice);
        vm.warp(launch + 8 days);
        d.rewards.settle(alice, 64);
        uint256 all = d.rewards.pending(alice);
        assertGt(all, old);
        vm.prank(alice);
        uint256 net = d.rewards.claim(old);
        assertEq(net, old - old * 500 / 10000);
    }

    function testReferralOnceNotSelfAndNoCyclesOrRetroactiveReferral() public {
        vm.prank(bob);
        d.farm.register(bob);
        vm.prank(alice);
        d.farm.setReferrer(bob);
        vm.prank(alice);
        vm.expectRevert(AlreadyDone.selector);
        d.farm.setReferrer(bob);
        vm.prank(bob);
        vm.expectRevert(InvalidValue.selector);
        d.farm.setReferrer(alice);
        fund(10_000_000 ether);
        placeSolo(alice, 0, 1, 0);
        mine(alice, 1 days);
        assertGt(d.rewards.pending(bob), 0);
        uint256 p = d.rewards.pending(bob);
        vm.prank(bob);
        d.rewards.claim(p);
        assertEq(token.balanceOf(bob), p - p / 5);
        address carol = makeAddr("carol");
        vm.prank(carol);
        vm.expectRevert(InvalidValue.selector);
        d.farm.setReferrer(carol);
        placeSolo(bob, 0, 0, 0);
        vm.prank(bob);
        vm.expectRevert(InvalidValue.selector);
        d.farm.setReferrer(alice);
    }

    function testSpendingBonusBurnAndNoWithdrawalTax() public {
        start();
        mine(alice, 2 days);
        uint256 beforePending = d.rewards.pending(alice);
        uint256 beforeBurn = token.balanceOf(address(d.burn));
        vm.prank(alice);
        d.farm.spend(FarmCore.SpendKind.Electricity, 0, 0, 105 ether);
        assertEq(beforePending - d.rewards.pending(alice), 100 ether);
        assertEq(token.balanceOf(address(d.burn)) - beforeBurn, 100 ether);
        assertEq(d.rewards.redistribution(), 0);
    }

    function testRepairUpgradeAndTokenPackSpend() public {
        start();
        mine(alice, 4 days);
        uint256 oldHash = d.rewards.accountHash(alice);
        uint256 oldDur = d.rewards.durability(alice);
        vm.prank(alice);
        d.farm.spend(FarmCore.SpendKind.Repair, 0, 0, 1);
        assertEq(d.rewards.durability(alice), oldDur + 1 ether);
        vm.prank(alice);
        d.farm.spend(FarmCore.SpendKind.Upgrade, 4, 0, 1);
        assertGt(d.rewards.accountHash(alice), oldHash);
        uint256 next = d.packs.nextId();
        uint256 teamCredit = d.fees.credit(team);
        vm.prank(alice);
        d.farm.spend(FarmCore.SpendKind.TokenPack, 0, 0, 1);
        assertEq(d.packs.nextId(), next + 1);
        assertEq(d.fees.credit(team), teamCredit);
        vm.prank(alice);
        vm.expectRevert(TooEarly.selector);
        d.farm.spend(FarmCore.SpendKind.TokenPack, 0, 0, 1);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.farm.spend(FarmCore.SpendKind.Repair, 0, 0, 100);
    }

    function testNoFreeUpgradeBeforeRewardsExist() public {
        placeSolo(alice, 0, 0, 0);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.farm.spend(FarmCore.SpendKind.Upgrade, 4, 0, 1);
    }

    function testClaimsWithdrawalsAndItemExitDuringPause() public {
        start();
        mine(alice, 1 days);
        uint256 pending = d.rewards.pending(alice);
        vm.prank(swarm);
        d.packs.pause(72 hours);
        vm.prank(alice);
        d.rewards.claim(pending);
        vm.prank(alice);
        d.farm.unplace(4, 0);
        assertEq(d.items.balanceOf(alice, 2), 1);
        assertGt(token.balanceOf(alice), 0);
    }

    function testZeroHashDoesNotEmitAndDonationIsPermissionless() public {
        fund(1000 ether);
        vm.warp(launch + 1 days);
        d.rewards.checkpoint(64);
        assertEq(d.pool.reserved(), 0);
        assertEq(d.pool.available(), 1000 ether);
        vm.expectRevert(InvalidValue.selector);
        d.pool.donate(0);
    }

    function testLongIdleCatchupIsPermissionlessAndBounded() public {
        start();
        vm.warp(launch + 100 days);
        assertFalse(d.rewards.checkpoint(1));
        while (!d.rewards.checkpoint(64)) {}
        assertFalse(d.rewards.settle(alice, 1));
        while (!d.rewards.settle(alice, 64)) {}
        uint256 pending = d.rewards.pending(alice);
        assertGt(pending, 0);
        assertGe(token.balanceOf(address(d.pool)), d.pool.reserved());
        vm.prank(alice);
        d.farm.unplace(4, 0);
        vm.prank(alice);
        d.rewards.claim(pending);
    }

    function testInspectionWindowWinnerPayoutAndNoDoublePay() public {
        fund(10_000_000 ether);
        for (uint256 i; i < 4; ++i) {
            placeSolo(alice, i, 2, i);
        }
        mine(alice, 6 days);
        vm.prank(alice);
        d.farm.spend(FarmCore.SpendKind.Electricity, 0, 0, 1000 ether);
        vm.expectRevert(TooEarly.selector);
        d.rewards.submitInspection(0, alice);
        vm.warp(launch + 7 days);
        d.rewards.submitInspection(0, alice);
        assertEq(d.rewards.inspectionWinner(0), alice);
        vm.expectRevert(TooEarly.selector);
        d.rewards.finalizeInspection(0);
        vm.warp(launch + 8 days);
        d.rewards.settle(alice, 64);
        uint256 pending = d.rewards.pending(alice);
        uint256 prize = d.rewards.weekPrize(0);
        d.rewards.finalizeInspection(0);
        assertEq(d.rewards.pending(alice), pending + prize);
        vm.expectRevert(AlreadyDone.selector);
        d.rewards.finalizeInspection(0);
    }

    function testFuzzConservation(uint96 donation, uint32 elapsed) public {
        uint256 amount = bound(donation, 1 ether, 100_000_000 ether);
        uint256 duration = bound(elapsed, 1 hours, 30 days);
        fund(amount);
        placeSolo(alice, 0, 0, 0);
        mine(alice, duration);
        uint256 pending = d.rewards.pending(alice);
        if (pending != 0) {
            vm.prank(alice);
            d.rewards.claim(pending);
        }
        assertEq(token.balanceOf(address(d.pool)) + token.balanceOf(address(d.burn)) + token.balanceOf(alice), amount);
        assertGe(token.balanceOf(address(d.pool)), d.pool.reserved());
    }
}
