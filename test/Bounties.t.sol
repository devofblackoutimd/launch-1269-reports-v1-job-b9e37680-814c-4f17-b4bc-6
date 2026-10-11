// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {Params} from "../src/Params.sol";
import {GridOperator} from "../src/GridOperator.sol";
import {ItemMath} from "../src/lib/ItemMath.sol";
import "../src/lib/Errors.sol";

contract BountiesTest is BaseTest {
    address private keeper;

    function setUp() public override {
        super.setUp();
        keeper = makeAddr("public keeper");
        vm.deal(address(d.packs), 100 ether);
        vm.prank(address(d.packs));
        d.fees.depositPack{value: 50 ether}();
    }

    function _close() private {
        entropy();
        vm.warp(d.rewards.epochEnd());
        d.rewards.advanceEpoch();
    }

    function testSettlementPaidPerUnitNotPerCallAndCannotReplay() public {
        payPack(alice);
        payPack(bob);
        place(alice, 0, 0, 0);
        place(bob, 0, 0, 0);
        _close();
        vm.prank(keeper);
        d.rewards.processEpoch(1);
        assertGt(d.fees.credit(keeper), 0);
        assertLe(d.fees.credit(keeper), d.params.get(Params.Key.MeasureBounty));
        uint256 paid = d.fees.credit(keeper);
        vm.prank(keeper);
        d.rewards.processEpoch(8);
        assertGt(d.fees.credit(keeper), paid);
        assertLe(d.fees.credit(keeper) - paid, d.params.get(Params.Key.MeasureBounty));
        assertLe(d.fees.credit(keeper), d.params.get(Params.Key.MeasureBounty) * 2);
        paid = d.fees.credit(keeper);
        vm.prank(keeper);
        d.rewards.processEpoch(8);
        assertGt(d.fees.credit(keeper), paid);
        assertLe(d.fees.credit(keeper) - paid, d.params.get(Params.Key.CreditBounty) * 2);
        assertLe(
            d.fees.credit(keeper), (d.params.get(Params.Key.MeasureBounty) + d.params.get(Params.Key.CreditBounty)) * 2
        );
        assertTrue(d.rewards.ready());
        paid = d.fees.credit(keeper);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(keeper);
        d.rewards.processEpoch(1);
        assertEq(d.fees.credit(keeper), paid);
    }

    function testEmptyRosterAndInvalidBatchReceiveNothing() public {
        _close();
        vm.expectRevert(InvalidValue.selector);
        vm.prank(keeper);
        d.rewards.processEpoch(0);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(keeper);
        d.rewards.processEpoch(9);
        vm.startPrank(keeper);
        while (!d.rewards.ready()) d.rewards.processEpoch(8);
        vm.stopPrank();
        assertEq(d.fees.credit(keeper), 0);
    }

    function testPlanResolutionPaidOnceIncludingAdvanceForwarding() public {
        vm.expectRevert(TooEarly.selector);
        vm.prank(keeper);
        d.grid.resolve(1);
        assertEq(d.fees.credit(keeper), 0);
        entropy();
        vm.prank(keeper);
        d.grid.resolve(1);
        assertGt(d.fees.credit(keeper), 0);
        assertLe(d.fees.credit(keeper), d.params.get(Params.Key.EntropyBounty));
        uint256 entropyPaid = d.fees.credit(keeper);
        vm.prank(keeper);
        d.grid.resolve(1);
        assertEq(d.fees.credit(keeper), entropyPaid);
        vm.expectRevert(Unauthorized.selector);
        d.grid.resolveFor(1, keeper);
        vm.warp(d.rewards.epochEnd());
        vm.prank(keeper);
        d.rewards.advanceEpoch();
        assertEq(d.fees.credit(keeper), entropyPaid + d.params.get(Params.Key.Bounty));
        finish();
        entropy();
        vm.warp(d.rewards.epochEnd());
        uint256 old = d.fees.credit(keeper);
        vm.prank(keeper);
        d.rewards.advanceEpoch();
        assertGt(d.fees.credit(keeper) - old, d.params.get(Params.Key.Bounty));
        assertLe(d.fees.credit(keeper) - old, d.params.get(Params.Key.EntropyBounty) + d.params.get(Params.Key.Bounty));
        assertEq(d.fees.credit(address(d.rewards)), 0);
    }

    function testPackEntropyCapturedOnceWithFullInventoryAndThroughPause() public {
        uint256 id = payPack(alice);
        for (uint256 i; i < 15; ++i) {
            mintItem(alice, uint8(i % 12), 0);
        }
        vm.prank(swarm);
        d.packs.pause(72 hours);
        entropy();
        vm.prank(keeper);
        d.packs.captureEntropy(id);
        assertGt(d.fees.credit(keeper), 0);
        assertLe(d.fees.credit(keeper), d.params.get(Params.Key.EntropyBounty));
        uint256 paid = d.fees.credit(keeper);
        vm.prank(keeper);
        d.packs.captureEntropy(id);
        assertEq(d.fees.credit(keeper), paid);
        vm.expectRevert(InsufficientBalance.selector);
        vm.prank(keeper);
        d.packs.resolve(id, 1);
        assertEq(d.fees.credit(keeper), paid);
        vm.expectRevert(InvalidValue.selector);
        d.packs.captureEntropy(10000);
    }

    function testBuyBountyProportionalCapNoDustCreditAndFailureRollback() public {
        uint256 q = market.quote(0.5 ether);
        market.setFailure(true);
        vm.expectRevert();
        vm.prank(keeper);
        d.fees.executeBuys(0.5 ether, q);
        assertEq(d.fees.credit(keeper), 0);
        market.setFailure(false);
        vm.prank(keeper);
        d.fees.executeBuys(0.25 ether, q / 2);
        uint256 first = d.fees.credit(keeper);
        assertGt(first, 0);
        assertLe(first, d.params.get(Params.Key.BuyBounty) / 2);
        vm.prank(keeper);
        d.fees.executeBuys(0.25 ether, q / 2);
        uint256 paid = d.fees.credit(keeper);
        assertGt(paid, first);
        assertLe(paid - first, d.params.get(Params.Key.BuyBounty) / 2);
        assertLe(paid, d.params.get(Params.Key.BuyBounty));
        vm.prank(keeper);
        d.fees.executeBuys(1, market.quote(1));
        assertEq(d.fees.credit(keeper), paid);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(keeper);
        d.fees.executeBuys(0, 1);
        assertEq(d.fees.credit(keeper), paid);
    }

    function testWeeklyScoringAndFinalizeEachPaidOnceAndEmptyWeekUnpaid() public {
        vm.mockCall(address(d.rewards), abi.encodeCall(d.rewards.seasonReady, (0)), abi.encode(true));
        vm.startPrank(address(d.rewards));
        d.season.recordActivity(alice, 0, 10 ether);
        d.season.recordActivity(bob, 0, 20 ether);
        vm.stopPrank();
        vm.prank(keeper);
        d.season.prepare(0, 1);
        uint256 first = d.fees.credit(keeper);
        assertGt(first, 0);
        assertLe(first, d.params.get(Params.Key.SeasonScoreBounty));
        vm.prank(keeper);
        d.season.prepare(0, 64);
        uint256 scored = d.fees.credit(keeper);
        assertGt(scored, first);
        assertLe(scored - first, d.params.get(Params.Key.SeasonScoreBounty));
        assertLe(d.fees.credit(keeper), d.params.get(Params.Key.SeasonScoreBounty) * 2);
        vm.expectRevert(AlreadyDone.selector);
        vm.prank(keeper);
        d.season.prepare(0, 64);
        assertEq(d.fees.credit(keeper), scored);
        vm.expectRevert(TooEarly.selector);
        vm.prank(keeper);
        d.season.finalize(0);
        assertEq(d.fees.credit(keeper), scored);
        entropy();
        vm.prank(keeper);
        d.season.finalize(0);
        uint256 paid = d.fees.credit(keeper);
        assertGt(paid, scored);
        assertLe(paid - scored, d.params.get(Params.Key.SeasonBounty));
        assertLe(paid, d.params.get(Params.Key.SeasonScoreBounty) * 2 + d.params.get(Params.Key.SeasonBounty));
        vm.expectRevert(AlreadyDone.selector);
        vm.prank(keeper);
        d.season.finalize(0);
        assertEq(d.fees.credit(keeper), paid);
        vm.mockCall(address(d.rewards), abi.encodeCall(d.rewards.seasonReady, (1)), abi.encode(true));
        vm.prank(keeper);
        d.season.prepare(1, 64);
        entropy();
        vm.prank(keeper);
        d.season.finalize(1);
        assertEq(d.fees.credit(keeper), paid);
    }

    function testEveryWorkKindBoundedByHeartbeatAndAuthorizedProducer() public {
        Params.Key[8] memory kinds = [
            Params.Key.MeasureBounty,
            Params.Key.CreditBounty,
            Params.Key.AuditBounty,
            Params.Key.EntropyBounty,
            Params.Key.SeasonScoreBounty,
            Params.Key.SeasonBounty,
            Params.Key.EntropyBounty,
            Params.Key.EntropyBounty
        ];
        address[8] memory senders = [
            address(d.rewards),
            address(d.rewards),
            address(d.rewards),
            address(d.grid),
            address(d.season),
            address(d.season),
            address(d.packs),
            address(d.starter)
        ];
        for (uint256 i; i < kinds.length; ++i) {
            vm.expectRevert(Unauthorized.selector);
            d.fees.payWork(keeper, kinds[i], 1, 100_000);
            vm.expectRevert(InvalidValue.selector);
            vm.prank(senders[i]);
            d.fees.payWork(keeper, kinds[i], 0, 100_000);
            vm.expectRevert(InvalidValue.selector);
            vm.prank(senders[i]);
            d.fees.payWork(keeper, kinds[i], 65, 100_000);
            // Exhaust heartbeat first, then give precisely one wei of budget via the routing split.
            while (d.fees.heartbeatBalance() != 0) {
                vm.prank(address(d.rewards));
                d.fees.payBounty(keeper);
            }
            vm.prank(address(d.packs));
            d.fees.depositPack{value: 50}();
            uint256 old = d.fees.credit(keeper);
            vm.prank(senders[i]);
            d.fees.payWork(keeper, kinds[i], 1, 100_000);
            assertEq(d.fees.credit(keeper) - old, 1);
            assertEq(d.fees.heartbeatBalance(), 0);
            vm.prank(senders[i]);
            d.fees.payWork(keeper, kinds[i], 1, 100_000);
            assertEq(d.fees.credit(keeper) - old, 1);
        }
    }

    function testAuditSelectionBountyOnlyForActuallySelectedFarms() public {
        fund(10_000_000 ether);
        payPack(alice);
        place(alice, 0, 0, 0);
        step();
        vm.mockCall(
            address(d.grid),
            abi.encodeCall(d.grid.eventAt, (2)),
            abi.encode(GridOperator.Kind.Audit, uint16(10000), uint8(0), keccak256("audit"), true)
        );
        _close();
        d.rewards.processEpoch(8);
        vm.prank(keeper);
        d.rewards.processEpoch(8);
        assertGt(d.fees.credit(keeper), 0);
        assertLe(d.fees.credit(keeper), d.params.get(Params.Key.AuditBounty));
        uint256 auditPaid = d.fees.credit(keeper);
        vm.prank(keeper);
        d.rewards.processEpoch(8);
        assertGt(d.fees.credit(keeper), auditPaid);
        assertLe(d.fees.credit(keeper) - auditPaid, d.params.get(Params.Key.CreditBounty));
        assertLe(d.fees.credit(keeper), d.params.get(Params.Key.AuditBounty) + d.params.get(Params.Key.CreditBounty));
    }

    function testStarterEntropySurvivesFullInventoryExpiryAndPauseWithoutReplayPayment() public {
        entropy();
        vm.warp(launch + 48 hours);
        d.rewards.advanceEpoch();
        finish();
        for (uint256 i; i < 15; ++i) {
            mintItem(alice, uint8(i % 12), 0);
        }
        vm.prank(swarm);
        d.packs.pause(72 hours);
        vm.prank(alice);
        d.starter.claim(17, new bytes32[](0));
        vm.expectRevert(TooEarly.selector);
        vm.prank(keeper);
        d.starter.captureEntropy(17);
        assertEq(d.fees.credit(keeper), 0);
        entropy();
        vm.prank(keeper);
        d.starter.captureEntropy(17);
        bytes32 captured = d.starter.entropyHash(17);
        assertTrue(d.starter.entropyCaptured(17));
        assertTrue(captured != bytes32(0));
        uint256 paid = d.fees.credit(keeper);
        assertGt(paid, 0);
        assertLe(paid, d.params.get(Params.Key.EntropyBounty));
        vm.prank(keeper);
        d.starter.captureEntropy(17);
        assertEq(d.fees.credit(keeper), paid);
        vm.expectRevert(InsufficientBalance.selector);
        d.starter.resolve(17);

        vm.roll(vm.getBlockNumber() + 300);
        assertEq(d.starter.entropyHash(17), captured);
        vm.prank(alice);
        d.farm.expand(true);
        vm.prank(keeper);
        d.starter.resolve(17);
        assertEq(d.items.inventory(alice), 18);
        for (uint256 i; i < 3; ++i) {
            (uint8 kind, uint8 rarity) =
                ItemMath.draw(keccak256(abi.encode(captured, address(d.starter), uint256(17), i)), false, true);
            assertEq(d.items.data(16 + i).kind, kind);
            assertEq(d.items.data(16 + i).rarity, rarity);
        }
        vm.prank(keeper);
        d.starter.captureEntropy(17);
        assertEq(d.fees.credit(keeper), paid);
        vm.expectRevert(AlreadyDone.selector);
        d.starter.resolve(17);
    }

    function testWorkCreditRespectsZeroGasPricePriceCeilingAndUnitCap() public {
        vm.txGasPrice(0);
        vm.prank(address(d.rewards));
        d.fees.payWork(keeper, Params.Key.MeasureBounty, 1, 100_000);
        assertEq(d.fees.credit(keeper), 0);

        uint256 ceiling = d.params.get(Params.Key.KeeperGasPrice);
        vm.txGasPrice(ceiling);
        vm.prank(address(d.rewards));
        d.fees.payWork(keeper, Params.Key.MeasureBounty, 1, 100_000);
        uint256 atCeiling = d.fees.credit(keeper);
        assertGt(atCeiling, 0);
        assertLt(atCeiling, d.params.get(Params.Key.MeasureBounty));
        vm.txGasPrice(ceiling * 100);
        vm.prank(address(d.rewards));
        d.fees.payWork(keeper, Params.Key.MeasureBounty, 1, 100_000);
        assertEq(d.fees.credit(keeper), atCeiling * 2);

        uint256 before_ = d.fees.credit(keeper);
        vm.prank(address(d.rewards));
        d.fees.payWork(keeper, Params.Key.MeasureBounty, 1, 100_000_000);
        assertEq(d.fees.credit(keeper) - before_, d.params.get(Params.Key.MeasureBounty));
    }
}
