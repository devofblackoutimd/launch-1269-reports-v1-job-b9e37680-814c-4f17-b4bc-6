// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {ItemMath} from "../src/lib/ItemMath.sol";
import {Params} from "../src/Params.sol";
import {GridOperator} from "../src/GridOperator.sol";
import {Vm} from "forge-std/Vm.sol";
import "../src/lib/Errors.sol";

contract ExtraBehaviorTest is BaseTest {
    function testPackBuybackBootstrapsMiningWithoutAnInitialDonation() public {
        vm.warp(launch + 1 minutes);
        vm.prank(alice);
        uint256 commit = d.packs.openPack{value: 0.01 ether}(1);
        vm.roll(vm.getBlockNumber() + 260);
        d.packs.resolve(commit);
        vm.prank(alice);
        d.farm.place(1, 4, 0);
        vm.warp(launch + 2 minutes);
        d.fees.executeBuys(false, 0.0065 ether, market.quote(0.0065 ether) * 98 / 100);
        vm.warp(launch + 1 hours);
        d.rewards.settle(alice, 64);
        assertGt(d.rewards.pending(alice), 0);
    }

    function testMergeMintsOnlyThroughPackSaleAndConsumesThreeWithFee() public {
        fund(10_000_000 ether);
        placeSolo(alice, 0, 3, 0);
        mine(alice, 3 days);
        for (uint256 i; i < 3; ++i) {
            mintItem(alice, 1, 0, 0, false);
        }
        uint256 pending = d.rewards.pending(alice);
        vm.prank(alice);
        uint256 result = d.packs.merge(5);
        assertEq(result, 6);
        assertEq(d.items.balanceOf(alice, 5), 0);
        assertEq(d.items.balanceOf(alice, 6), 1);
        assertLt(d.rewards.pending(alice), pending);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.packs.merge(ItemMath.encode(0, 3, 0, false));
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.packs.merge(ItemMath.encode(0, 1, 0, true));
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        d.items.burnForMerge(alice, 6);
    }

    function testLongerTaxDecayCannotLoseAgedVintageOnRingRollover() public {
        fund(10_000_000 ether);
        placeSolo(alice, 0, 0, 0);
        mine(alice, 1 days);
        vm.prank(alice);
        d.farm.unplace(4, 0);
        uint256 old = d.rewards.pending(alice);
        for (uint256 day = 1; day <= 7; ++day) {
            vm.warp(launch + day * 1 days);
            uint256 duration = d.params.get(Params.Key.TaxDecaySeconds);
            vm.prank(swarm);
            d.params.set(Params.Key.TaxDecaySeconds, duration * 11 / 10);
        }
        vm.warp(launch + 9 days);
        uint256 bps = d.rewards.taxBps(8 days);
        assertGt(bps, 500);
        vm.prank(alice);
        uint256 net = d.rewards.claim(old);
        assertEq(net, old - old * bps / 10000);
    }

    function testRedistributionIsFullyAddedAndNotTaxedForReferralAgain() public {
        fund(10_000_000 ether);
        placeSolo(alice, 0, 0, 0);
        mine(alice, 12 hours);
        uint256 p = d.rewards.pending(alice);
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        vm.warp(launch + 1 days);
        d.rewards.checkpoint(64);
        uint256 baseline = grossFromLogs(vm.getRecordedLogs());
        assertTrue(vm.revertToState(snapshot));
        vm.prank(alice);
        d.rewards.claim(p);
        uint256 tax = d.rewards.redistribution();
        // Current time is exactly a tick boundary, so this claim enters that next tick.
        vm.recordLogs();
        vm.warp(launch + 1 days);
        d.rewards.checkpoint(64);
        uint256 withTax = grossFromLogs(vm.getRecordedLogs());
        // A second independent baseline uses the same half-day rate (fresh budget at 12h).
        assertApproxEqAbs(withTax - baseline, tax, 2);
        // Per-bucket mining index excludes every redistributed token.
        uint256 bucket = d.farm.district(alice) * 16;
        assertGt(d.rewards.acc(bucket), d.rewards.miningAcc(bucket));
    }

    function grossFromLogs(Vm.Log[] memory logs) internal pure returns (uint256 sum) {
        bytes32 signature = keccak256("Emission(uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == signature) {
                (uint256 gross,) = abi.decode(logs[i].data, (uint256, uint256));
                sum += gross;
            }
        }
    }

    function testAllPoolSpendingUnderAuditRemainsBacked() public {
        fund(10_000_000 ether);
        for (uint256 i; i < 20; ++i) {
            placeSolo(alice, i % 6, 3, i);
        }
        vm.prank(swarm);
        d.grid.submitEvent(0, GridOperator.Kind.Audit);
        (uint256 target,,,,,) = d.grid.eventInfo(0);
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("audit"));
        d.grid.resolveEvent(0);
        uint256 burn = token.balanceOf(address(d.burn));
        mine(alice, 12 hours);
        assertGt(token.balanceOf(address(d.burn)), burn);
        uint256 pending = d.rewards.pending(alice);
        vm.prank(alice);
        d.rewards.claim(pending);
        assertGe(token.balanceOf(address(d.pool)), d.pool.reserved());
    }
}
