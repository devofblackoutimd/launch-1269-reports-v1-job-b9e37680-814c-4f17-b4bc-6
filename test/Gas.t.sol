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

    function testGasTypicalFarmSettlementHasNoBounty() public {
        fund(100_000_000 ether);
        payPack(alice);
        place(alice, 0, 0, 0);
        place(alice, 1, 0, 1);
        place(alice, 2, 0, 2);
        calmNext();
        step();
        entropy();
        vm.warp(d.rewards.epochEnd());
        d.rewards.advanceEpoch();
        uint256 beforeCredit = d.fees.credit(address(this));
        uint256 start = gasleft();
        d.rewards.settle(alice, 8);
        emit log_named_uint("settle typical three-item farm one epoch", start - gasleft());
        assertEq(d.fees.credit(address(this)), beforeCredit);
    }

    function testGasFullFarmLongIdleBoundedChunks() public {
        fund(100_000_000 ether);
        uint256 q = d.packs.quote(112);
        vm.prank(alice);
        d.packs.openPack{value: q}(112);
        vm.warp(launch + 3 days);
        entropy();
        d.rewards.advanceEpoch();
        finish();
        for (uint256 room; room < 4; ++room) {
            for (uint256 slot; slot < 6; ++slot) {
                uint256 id = mintItem(alice, uint8(slot), 0);
                vm.prank(alice);
                d.farm.place(id, room, slot);
            }
        }
        for (uint256 i; i < 40; ++i) {
            calmNext();
            entropy();
            vm.warp(d.rewards.epochEnd());
            d.rewards.advanceEpoch();
        }
        uint256 cursor = d.rewards.lastSettled(alice);
        uint256 g = gasleft();
        d.rewards.settle(alice, 8);
        uint256 used = g - gasleft();
        emit log_named_uint("settle full 24-item farm eight epochs after 40 idle", used);
        assertLt(used, 25_000_000);
        assertEq(d.rewards.lastSettled(alice), cursor + 8);
        finish();
        assertEq(d.rewards.lastSettled(alice), d.rewards.settledEpoch());
    }
}
