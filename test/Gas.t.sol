// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";

contract GasTest is BaseTest {
    function testGasCommonActions() public {
        fund(100_000_000 ether);
        uint256 price = d.packs.price();
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 pack = d.packs.openPack{value: price}(1);
        emit log_named_uint("buy ETH pack", g - gasleft());
        entropy();
        g = gasleft();
        d.packs.resolve(pack, 1);
        emit log_named_uint("open one pack", g - gasleft());
        uint256 id = mintItem(alice, 0, 0);
        vm.prank(alice);
        g = gasleft();
        d.farm.place(id, 0, 0);
        emit log_named_uint("equip", g - gasleft());
        calmNext();
        step();
        calmNext();
        step();
        vm.prank(alice);
        g = gasleft();
        d.farm.repair(id, true);
        emit log_named_uint("repair wallet", g - gasleft());
        vm.prank(alice);
        g = gasleft();
        d.farm.overclock(id, true);
        emit log_named_uint("overclock", g - gasleft());
        vm.prank(alice);
        g = gasleft();
        d.farm.expand(true);
        emit log_named_uint("expand", g - gasleft());
        vm.prank(alice);
        g = gasleft();
        d.farm.buyTokenPack(false);
        emit log_named_uint("token pack internal", g - gasleft());
        uint256 pending = d.rewards.pending(alice);
        vm.prank(alice);
        g = gasleft();
        d.rewards.claim(pending);
        emit log_named_uint("withdraw", g - gasleft());
        vm.prank(alice);
        g = gasleft();
        d.farm.unplace(0, 0);
        emit log_named_uint("unequip", g - gasleft());
    }

    function testGasEightFullFarmsSettlementStaysBounded() public {
        fund(100_000_000 ether);
        for (uint256 i; i < 8; ++i) {
            address p = address(uint160(0x50000 + i));
            vm.deal(p, 20 ether);
            uint256 q = d.packs.quote(112);
            vm.prank(p);
            d.packs.openPack{value: q}(112);
        }
        vm.warp(launch + 3 days);
        entropy();
        d.rewards.advanceEpoch();
        finish();
        for (uint256 i; i < 8; ++i) {
            address p = address(uint160(0x50000 + i));
            for (uint256 room; room < 4; ++room) {
                for (uint256 slot; slot < 6; ++slot) {
                    uint256 id = mintItem(p, uint8(slot), 0);
                    vm.prank(p);
                    d.farm.place(id, room, slot);
                }
            }
        }
        calmNext();
        step();
        entropy();
        vm.warp(d.rewards.epochEnd());
        d.rewards.advanceEpoch();
        uint256 g = gasleft();
        d.rewards.processEpoch(8);
        uint256 measured = g - gasleft();
        emit log_named_uint("measure eight full 24-item farms", measured);
        assertLt(measured, 15_000_000);
        g = gasleft();
        d.rewards.processEpoch(8);
        uint256 credit = g - gasleft();
        emit log_named_uint("credit eight full farms", credit);
        assertLt(credit, 8_000_000);
    }
}
