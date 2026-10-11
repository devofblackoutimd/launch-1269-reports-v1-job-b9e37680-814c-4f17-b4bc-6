// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {FarmItems} from "../src/FarmItems.sol";
import {ItemMath} from "../src/lib/ItemMath.sol";
import "../src/lib/Errors.sol";

contract DrawHarness {
    function draw(bytes32 s, bool m, bool starter) external pure returns (uint8, uint8) {
        return ItemMath.draw(s, m, starter);
    }
}

contract PacksTest is BaseTest {
    function testVrgdaInitialStepDecayFloorCeilingAndBulkPricing() public {
        assertEq(d.packs.price(), 0.01 ether);
        uint256 q = d.packs.quote(2);
        assertApproxEqAbs(q, 0.0201 ether, 10);
        vm.prank(alice);
        d.packs.openPack{value: q}(2);
        assertApproxEqAbs(d.packs.price(), 0.010201 ether, 10);
        vm.warp(launch + 1 hours);
        assertLt(d.packs.price(), 0.01 ether);
        vm.warp(launch + 30 days);
        assertEq(d.packs.price(), 0.006 ether);
        assertEq(d.packs.priceAt(1_000_000), 0.03 ether);
    }

    function testFuzzVrgdaAlwaysBounded(uint32 sold, uint32 elapsed) public {
        vm.warp(launch + bound(elapsed, 0, 3650 days));
        uint256 p = d.packs.priceAt(sold);
        assertGe(p, 0.006 ether);
        assertLe(p, 0.03 ether);
    }

    function testNoWalletGlobalOrTokenPackDailyLimit() public {
        uint256 quote = d.packs.quote(200);
        vm.prank(alice);
        uint256 id = d.packs.openPack{value: quote}(200);
        assertEq(d.packs.sold(), 200);
        (,, uint256 n,,,,,,) = d.packs.commits(id);
        assertEq(n, 200);
        vm.prank(alice);
        d.farm.buyTokenPack(true);
        vm.prank(alice);
        d.farm.buyTokenPack(true);
        assertEq(d.packs.sold(), 202);
    }

    function testExactPaymentAndFutureBlockRequired() public {
        vm.expectRevert(InvalidValue.selector);
        vm.prank(alice);
        d.packs.openPack{value: 1}(1);
        uint256 id = payPack(alice);
        vm.expectRevert(TooEarly.selector);
        d.packs.resolve(id, 1);
        resolvePack(id);
        assertEq(d.items.inventory(alice), 3);
        vm.expectRevert(InvalidValue.selector);
        d.packs.resolve(id, 1);
    }

    function testExpiryThreeCommonGpusAndInventoryOpeningLimit() public {
        uint256 q = d.packs.quote(6);
        vm.prank(alice);
        uint256 id = d.packs.openPack{value: q}(6);
        vm.roll(vm.getBlockNumber() + 300);
        d.packs.resolve(id, 5);
        assertEq(d.items.inventory(alice), 15);
        for (uint256 i = 1; i <= 15; ++i) {
            FarmItems.Item memory x = d.items.data(i);
            assertEq(x.kind, 0);
            assertEq(x.rarity, 0);
        }
        vm.expectRevert(InsufficientBalance.selector);
        d.packs.resolve(id, 1);
        vm.prank(alice);
        d.farm.expand(true);
        d.packs.resolve(id, 1);
        assertEq(d.items.inventory(alice), 18);
        assertEq(d.items.capacity(alice), 20);
    }

    function testTokenPackDiscountAllToPoolAndBonusWhenInternal() public {
        uint256 price = d.packs.price();
        uint256 expected = market.quote(price) * 9 / 10;
        uint256 before_ = token.balanceOf(address(d.pool));
        vm.prank(alice);
        d.farm.buyTokenPack(true);
        assertEq(token.balanceOf(address(d.pool)) - before_, expected);
        fund(100_000_000 ether);
        place(alice, 0, 0, 0);
        calmNext();
        step();
        calmNext();
        step();
        uint256 nominal = market.quote(d.packs.price()) * 9 / 10;
        uint256 pending = d.rewards.pending(alice);
        before_ = d.pool.available();
        vm.prank(alice);
        d.farm.buyTokenPack(false);
        uint256 spent = (nominal * 10000 + 10499) / 10500;
        assertEq(pending - d.rewards.pending(alice), spent);
        assertEq(d.pool.available() - before_, spent);
        assertEq(d.rewards.queuedTax(), 0);
    }

    function testExactRarityThresholdsAndMythicGate() public {
        DrawHarness h = new DrawHarness();
        uint256[8] memory points = [uint256(0), 6999, 7000, 9199, 9200, 9869, 9870, 9970];
        uint256[8] memory expected = [uint256(0), 0, 1, 1, 2, 2, 3, 4];
        for (uint256 i; i < 8; ++i) {
            (, uint8 r) = h.draw(bytes32(points[i] << 64), true, false);
            assertEq(r, expected[i]);
        }
        (, uint8 low) = h.draw(bytes32(uint256(9970) << 64), false, false);
        assertEq(low, 0);
        (, uint8 rare) = h.draw(bytes32(uint256(9199) << 64), false, true);
        assertEq(rare, 1);
        (, uint8 epic) = h.draw(bytes32(uint256(9200) << 64), false, true);
        assertEq(epic, 2);
    }

    function testItemTypeDistributionExact() public {
        DrawHarness h = new DrawHarness();
        uint256[12] memory counts;
        for (uint256 i; i < 100; ++i) {
            (uint8 k,) = h.draw(bytes32(i), false, false);
            counts[k]++;
        }
        uint256[12] memory expected = [uint256(16), 15, 12, 9, 7, 7, 9, 6, 6, 5, 4, 4];
        for (uint256 i; i < 12; ++i) {
            assertEq(counts[i], expected[i]);
        }
    }

    function testStarterWindowProofTokenIdOnceAndInventoryFailureRetry() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(TooEarly.selector);
        vm.prank(alice);
        d.starter.claim(17, proof);
        vm.warp(launch + 48 hours);
        vm.expectRevert(InvalidProof.selector);
        vm.prank(bob);
        d.starter.claim(17, proof);
        vm.prank(alice);
        d.starter.claim(17, proof);
        vm.expectRevert(AlreadyDone.selector);
        vm.prank(alice);
        d.starter.claim(17, proof);
        vm.roll(vm.getBlockNumber() + 300);
        d.starter.resolve(17);
        assertEq(d.items.inventory(alice), 3);
        assertEq(d.items.data(1).rarity, 1);
        vm.warp(launch + 16 days);
        vm.expectRevert(TooEarly.selector);
        vm.prank(alice);
        d.starter.claim(18, proof);
    }
}
