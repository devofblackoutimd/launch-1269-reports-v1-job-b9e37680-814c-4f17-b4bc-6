// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {FarmCore} from "../src/FarmCore.sol";
import {ItemMath} from "../src/lib/ItemMath.sol";
import "../src/lib/Errors.sol";

contract RoomsTest is BaseTest {
    function fill(uint256 rarity) internal {
        for (uint256 i; i < 6; ++i) {
            uint256 id = mintItem(alice, i, rarity, 0, false);
            vm.prank(alice);
            d.farm.place(id, 0, i);
        }
    }

    function testAllSixMineAlone() public {
        for (uint256 kind; kind < 6; ++kind) {
            uint256 id = placeSolo(alice, kind, 0, kind);
            assertEq(d.farm.itemHash(alice, id, 0), 10 ether);
        }
        assertGt(d.rewards.accountHash(alice), 30 ether);
    }

    function testFullCommonSetAndPairs() public {
        fill(0);
        FarmCore.RoomStats memory s = d.farm.roomStats(alice, 0);
        assertEq(s.bonusBps, 3500);
        assertEq(s.hash, 81 ether);
        assertEq(s.powerHash, 68.85 ether);
        assertTrue(s.shield);
        assertFalse(s.heatProof);
    }

    function testRareEpicLegendarySetCap() public {
        fill(1);
        FarmCore.RoomStats memory s = d.farm.roomStats(alice, 0);
        assertEq(s.bonusBps, 4000);
        assertEq(s.hash, 235.2 ether);
        assertTrue(s.heatProof);
        for (uint256 i; i < 6; ++i) {
            vm.prank(alice);
            d.farm.unplace(0, i);
        }
        fill(3);
        s = d.farm.roomStats(alice, 0);
        assertEq(s.bonusBps, 4000);
        assertEq(s.hash, 2100 ether);
    }

    function testPartialRarityBonusesAndNoCrossRoomSet() public {
        for (uint256 i; i < 3; ++i) {
            uint256 id = mintItem(alice, i + 2, 2, 0, false);
            vm.prank(alice);
            d.farm.place(id, 0, i + 2);
        }
        FarmCore.RoomStats memory s = d.farm.roomStats(alice, 0);
        assertEq(s.bonusBps, 1000);
        assertEq(s.hash, 264 ether);
        uint256 key = mintItem(alice, 6, 0, 0, false);
        vm.prank(alice);
        d.farm.installRoom(1, key);
        uint256 gpu = mintItem(alice, 0, 0, 0, false);
        uint256 asic = mintItem(alice, 1, 0, 0, false);
        vm.prank(alice);
        d.farm.place(gpu, 0, 0);
        vm.prank(alice);
        d.farm.place(asic, 1, 1);
        assertEq(d.farm.roomStats(alice, 1).bonusBps, 0);
        assertEq(d.farm.roomStats(alice, 0).bonusBps, 1000);
    }

    function testRoomSlotTypeOwnershipAndNoDoublePlacement() public {
        uint256 id = mintItem(alice, 0, 0, 0, false);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.farm.place(id, 0, 1);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.farm.place(id, 1, 0);
        vm.prank(bob);
        vm.expectRevert();
        d.farm.place(id, 0, 0);
        vm.prank(alice);
        d.farm.place(id, 0, 0);
        vm.prank(alice);
        vm.expectRevert();
        d.farm.place(id, 4, 0);
        vm.prank(bob);
        vm.expectRevert(InvalidValue.selector);
        d.farm.unplace(0, 0);
        vm.prank(alice);
        d.farm.unplace(0, 0);
        assertEq(d.items.balanceOf(alice, id), 1);
        assertEq(d.rewards.accountHash(alice), 0);
    }

    function testRoomKeyCannotLeaveOccupiedRoomAndCanReturn() public {
        uint256 key = mintItem(alice, 6, 1, 0, false);
        vm.prank(alice);
        d.farm.installRoom(1, key);
        uint256 id = mintItem(alice, 1, 0, 0, false);
        vm.prank(alice);
        d.farm.place(id, 1, 1);
        vm.prank(alice);
        vm.expectRevert(InvalidValue.selector);
        d.farm.removeRoom(1);
        vm.prank(alice);
        d.farm.unplace(1, 1);
        vm.prank(alice);
        d.farm.removeRoom(1);
        assertEq(d.items.balanceOf(alice, key), 1);
    }

    function testDirectUntrackedDepositRejected() public {
        uint256 id = mintItem(alice, 0, 0, 0, false);
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        d.items.safeTransferFrom(alice, address(d.farm), id, 1, "");
    }

    function testFuzzSetCap(uint8 rarity) public {
        uint256 r = bound(rarity, 0, 3);
        fill(r);
        assertLe(d.farm.roomStats(alice, 0).bonusBps, 4000);
    }
}
