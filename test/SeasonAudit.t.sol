// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {GridOperator} from "../src/GridOperator.sol";
import {Params} from "../src/Params.sol";
import "../src/lib/Errors.sol";

contract SeasonAuditTest is BaseTest {
    function testAuditExactTopDecileNoWhaleSoftCap() public {
        fund(100_000_000 ether);
        for (uint256 i; i < 10; ++i) {
            address p = address(uint160(0x10000 + i));
            vm.deal(p, 1 ether);
            payPack(p);
            place(p, 0, 0, 0);
            if (i == 0) place(p, 1, 0, 1);
        }
        calmNext();
        step();
        vm.mockCall(
            address(d.grid),
            abi.encodeCall(d.grid.eventAt, (uint256(2))),
            abi.encode(GridOperator.Kind.Audit, uint16(10000), uint8(0), keccak256("audit"), true)
        );
        step();
        uint256 audited;
        for (uint256 i; i < 10; ++i) {
            (,,, bool a) = d.rewards.shares(2, address(uint160(0x10000 + i)));
            if (a) audited++;
            assertEq(a, i == 0);
        }
        assertEq(audited, 1);
    }

    function testParameterChangesCannotChangeClosedEpochBetweenBatches() public {
        fund(100_000_000 ether);
        payPack(alice);
        payPack(bob);
        place(alice, 0, 0, 0);
        place(alice, 1, 0, 1);
        place(bob, 0, 0, 0);
        place(bob, 1, 0, 1);
        calmNext();
        step();
        entropy();
        vm.warp(d.rewards.epochEnd());
        d.rewards.advanceEpoch();
        d.rewards.processEpoch(1);
        vm.warp(launch + 1 days);
        vm.prank(swarm);
        d.params.set(Params.Key.ComputePairBps, 900, "Future bonus reduction");
        finish();
        (uint256 a,,,) = d.rewards.shares(2, alice);
        (uint256 b,,,) = d.rewards.shares(2, bob);
        assertEq(a, b);
        assertEq(a, 22000);
    }

    function _week() internal {
        fund(100_000_000 ether);
        address carol = makeAddr("carol");
        vm.deal(carol, 10 ether);
        payPack(alice);
        payPack(bob);
        payPack(carol);
        place(alice, 0, 0, 0);
        place(bob, 0, 0, 0);
        place(carol, 0, 0, 0);
        vm.prank(alice);
        d.grid.lobbyETH{value: 1 ether}();
        for (uint256 i; i < 28; ++i) {
            calmNext();
            step();
        }
    }

    function testWeeklyThreeDistinctTicketWinnersRarePackAndBestPrize() public {
        _week();
        uint256 before_ = d.rewards.pending(alice);
        d.season.prepare(0, 64);
        entropy();
        d.season.finalize(0);
        (bool done, uint8 district, address best, uint256 prize,) = d.season.result(0);
        assertTrue(done);
        assertEq(best, alice);
        assertGt(prize, 0);
        assertEq(d.rewards.pending(alice), before_ + prize);
        assertEq(district, d.farm.district(alice));
        assertTrue(d.season.lotteryWon(0, alice));
        assertTrue(d.season.lotteryWon(0, bob));
        assertTrue(d.season.lotteryWon(0, makeAddr("carol")));
        assertEq(d.season.tickets(0, alice), 27);
        vm.prank(alice);
        uint256 item = d.season.claimLottery(0);
        assertGe(d.items.data(item).rarity, 2);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(alice);
        d.season.claimLottery(0);
        vm.prank(alice);
        uint256 pack = d.season.claimDistrict(0);
        uint256 next = d.items.nextId();
        resolvePack(pack);
        assertGe(d.items.data(next).rarity, 1);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(alice);
        d.season.claimDistrict(0);
        vm.expectRevert(AlreadyDone.selector);
        d.season.finalize(0);
    }

    function testSeasonCannotFinalizeEarlyAndExpiredLotteryMustRearm() public {
        vm.expectRevert(TooEarly.selector);
        d.season.prepare(0, 64);
        _week();
        d.season.prepare(0, 1);
        vm.expectRevert(TooEarly.selector);
        d.season.finalize(0);
        d.season.prepare(0, 64);
        vm.expectRevert(TooEarly.selector);
        d.season.rearm(0);
        vm.roll(vm.getBlockNumber() + 300);
        vm.expectRevert(NotConfigured.selector);
        d.season.finalize(0);
        d.season.rearm(0);
        entropy();
        d.season.finalize(0);
        (bool done,,,,) = d.season.result(0);
        assertTrue(done);
    }

    function testLotteryEntitlementSurvivesFullInventory() public {
        _week();
        d.season.prepare(0, 64);
        entropy();
        d.season.finalize(0);
        for (uint256 i; i < 15; ++i) {
            mintItem(alice, uint8(i % 12), 0);
        }
        vm.expectRevert(InvalidValue.selector);
        vm.prank(alice);
        d.season.claimLottery(0);
        assertFalse(d.season.lotteryClaimed(0, alice));
        vm.prank(alice);
        d.farm.expand(true);
        vm.prank(alice);
        d.season.claimLottery(0);
        assertTrue(d.season.lotteryClaimed(0, alice));
    }

    function testPackSupplyDropOnlyActiveFarmsAtDoublePace() public {
        fund(100_000_000 ether);
        payPack(alice);
        place(alice, 0, 0, 0);
        calmNext();
        step();
        uint256 q = d.packs.quote(240);
        vm.prank(alice);
        d.packs.openPack{value: q}(240);
        bytes32 seed;
        for (uint256 i;; ++i) {
            seed = bytes32(i);
            if (uint256(keccak256(abi.encode(seed, alice, "supply"))) % 10000 < 500) break;
        }
        vm.mockCall(
            address(d.grid),
            abi.encodeCall(d.grid.eventAt, (uint256(2))),
            abi.encode(GridOperator.Kind.Calm, uint16(10000), uint8(0), seed, true)
        );
        step();
        assertEq(d.farm.drops(alice), 1);
        vm.prank(alice);
        uint256 item = d.farm.claimDrop();
        assertLe(d.items.data(item).rarity, 1);
        assertEq(d.farm.drops(alice), 0);
    }
}
