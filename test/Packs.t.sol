// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {ItemMath} from "../src/lib/ItemMath.sol";
import "../src/lib/Errors.sol";

contract PacksTest is BaseTest {
    function testPaidPackRoutesFeesAndPermissionlessResolve() public {
        uint256 p = d.packs.price();
        vm.prank(alice);
        uint256 id = d.packs.openPack{value: p}(1);
        assertEq(d.fees.rewardETH(), p * 65 / 100);
        assertEq(d.fees.burnETH(), p / 10);
        assertEq(d.fees.credit(team), p * 15 / 100);
        assertEq(d.fees.credit(heartbeat), p / 10);
        vm.expectRevert(TooEarly.selector);
        d.packs.resolve(id);
        resolvePack(id, keccak256("future block"));
        uint256 count;
        for (uint256 i = 1; i <= 28; ++i) {
            count += d.items.balanceOf(alice, i);
        }
        assertEq(count, 3);
        assertEq(d.farm.paidPacks(alice), 1);
        vm.expectRevert(AlreadyDone.selector);
        d.packs.resolve(id);
    }

    function testExpiredPackCommonAndCommitEpochFixed() public {
        uint256 p = d.packs.price();
        vm.prank(alice);
        uint256 id = d.packs.openPack{value: p}(1);
        vm.roll(vm.getBlockNumber() + 260);
        vm.warp(launch + 28 days);
        d.packs.resolve(id);
        assertEq(d.items.balanceOf(alice, 1), 3);
        assertEq(d.items.balanceOf(alice, 113), 0);
    }

    function testBetaCapsAndExactRollingDay() public {
        vm.prank(alice);
        d.packs.openPack{value: 0.03 ether}(3);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.packs.openPack{value: 0.01 ether}(1);
        vm.warp(launch + 12 hours);
        assertEq(d.packs.walletCap(), 6);
        vm.prank(alice);
        d.packs.openPack{value: 0.03 ether}(3);
        vm.warp(launch + 1 days);
        assertEq(d.packs.walletPacks24h(alice), 3);
        assertEq(d.packs.walletCap(), 10);
        vm.warp(launch + 2 days);
        assertEq(d.packs.walletCap(), 20);
        assertEq(d.packs.walletPacks24h(alice), 0);
    }

    function testGlobalBetaCap() public {
        for (uint256 i; i < 25; ++i) {
            address player = address(uint160(0x10000 + i));
            vm.deal(player, 1 ether);
            vm.prank(player);
            d.packs.openPack{value: 0.03 ether}(3);
        }
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.packs.openPack{value: 0.01 ether}(1);
        vm.warp(launch + 1 hours);
        vm.prank(alice);
        d.packs.openPack{value: 0.01 ether}(1);
    }

    function testPackInvalidCountPaymentAndUnknownId() public {
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.packs.openPack{value: 1}(1);
        vm.expectRevert(InvalidValue.selector);
        d.packs.openPack(0);
        vm.expectRevert(InvalidValue.selector);
        d.packs.resolve(999);
    }

    function testPauseOnlySwarmBoundedAndCannotExtend() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        d.packs.pause(1 hours);
        vm.prank(swarm);
        vm.expectRevert(InvalidValue.selector);
        d.packs.pause(73 hours);
        vm.prank(alice);
        uint256 id = d.packs.openPack{value: 0.01 ether}(1);
        vm.prank(swarm);
        d.packs.pause(72 hours);
        vm.prank(alice);
        vm.expectRevert(TooEarly.selector);
        d.packs.openPack{value: 0.01 ether}(1);
        vm.prank(swarm);
        vm.expectRevert(TooEarly.selector);
        d.packs.pause(1 hours);
        resolvePack(id, keccak256("unpaused resolution"));
        vm.warp(launch + 72 hours);
        assertFalse(d.packs.paused());
        vm.prank(alice);
        d.packs.openPack{value: 0.01 ether}(1);
        vm.prank(swarm);
        vm.expectRevert(TooEarly.selector);
        d.packs.pause(1 hours);
    }

    function testStarterProofWindowExpiryAndSoulbound() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        vm.expectRevert(TooEarly.selector);
        d.starter.claim(17, proof);
        vm.warp(launch + 48 hours);
        vm.prank(bob);
        vm.expectRevert(InvalidProof.selector);
        d.starter.claim(17, proof);
        vm.prank(alice);
        d.starter.claim(17, proof);
        vm.prank(alice);
        vm.expectRevert(AlreadyDone.selector);
        d.starter.claim(17, proof);
        vm.expectRevert(TooEarly.selector);
        d.starter.resolve(17);
        vm.roll(vm.getBlockNumber() + 260);
        d.starter.resolve(17);
        uint256 id = ItemMath.encode(0, 1, 0, true);
        assertEq(d.items.balanceOf(alice, id), 3);
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        d.items.safeTransferFrom(alice, bob, id, 1, "");
        vm.prank(alice);
        d.farm.place(id, 4, 0);
        assertEq(d.farm.itemHash(alice, id, 0), 14 ether);
        vm.prank(alice);
        d.farm.unplace(4, 0);
        assertEq(d.items.balanceOf(alice, id), 3);
        vm.warp(launch + 16 days);
        vm.prank(alice);
        vm.expectRevert(TooEarly.selector);
        d.starter.claim(18, proof);
    }

    function testStarterBecomesFullHashOnlyAfterPaidReveal() public {
        uint256 id = mintItem(alice, 0, 1, 0, true);
        vm.prank(alice);
        d.farm.place(id, 4, 0);
        assertEq(d.farm.itemHash(alice, id, 0), 14 ether);
        vm.prank(alice);
        uint256 pack = d.packs.openPack{value: 0.01 ether}(1);
        assertEq(d.farm.itemHash(alice, id, 0), 14 ether);
        resolvePack(pack, keccak256("paid"));
        assertEq(d.farm.itemHash(alice, id, 0), 28 ether);
    }
}
