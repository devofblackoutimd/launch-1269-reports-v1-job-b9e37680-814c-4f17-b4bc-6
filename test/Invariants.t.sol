// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {FarmCore} from "../src/FarmCore.sol";

contract EconomyHandler is Test {
    Deploy.Deployment internal d;
    MockToken internal token;
    address[2] public actors;

    constructor(Deploy.Deployment memory deployment, MockToken token_, address a, address b) {
        d = deployment;
        token = token_;
        actors = [a, b];
    }

    function advance(uint32 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 2 days));
        d.rewards.checkpoint(64);
    }

    function placeOrWithdraw(uint8 who) external {
        address actor = actors[who % 2];
        if (d.farm.itemAt(actor, 4, 0) == 0) {
            vm.prank(actor);
            try d.farm.place(1, 4, 0) {} catch {}
        } else {
            vm.prank(actor);
            try d.farm.unplace(4, 0) {} catch {}
        }
    }

    function claim(uint8 who, uint16 fraction) external {
        address actor = actors[who % 2];
        d.rewards.settle(actor, 64);
        uint256 pending = d.rewards.pending(actor);
        if (pending == 0) return;
        uint256 amount = pending * bound(fraction, 1, 10000) / 10000;
        if (amount == 0) return;
        vm.prank(actor);
        d.rewards.claim(amount);
    }

    function prepay(uint8 who) external {
        address actor = actors[who % 2];
        d.rewards.settle(actor, 64);
        uint256 amount = d.rewards.pending(actor) / 20;
        if (amount == 0) return;
        vm.prank(actor);
        try d.farm.spend(FarmCore.SpendKind.Electricity, 0, 0, amount) {} catch {}
    }

    function donate(uint96 amount_) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(amount_, 1, balance);
        token.approve(address(d.pool), amount);
        d.pool.donate(amount);
    }
}

contract InvariantsTest is BaseTest {
    EconomyHandler internal handler;

    function setUp() public override {
        super.setUp();
        fund(10_000_000 ether);
        mintItem(alice, 0, 0, 0, false);
        mintItem(bob, 0, 0, 0, false);
        vm.prank(alice);
        d.farm.place(1, 4, 0);
        vm.prank(bob);
        d.farm.place(1, 4, 0);
        handler = new EconomyHandler(d, token, alice, bob);
        token.transfer(address(handler), 10_000_000 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.placeOrWithdraw.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.prepay.selector;
        selectors[4] = handler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantTokensConservedAndPendingFullyBacked() public view {
        assertEq(
            token.balanceOf(address(d.pool)) + token.balanceOf(address(d.burn)) + token.balanceOf(alice)
                + token.balanceOf(bob) + token.balanceOf(address(handler)),
            20_000_000 ether
        );
        assertGe(token.balanceOf(address(d.pool)), d.pool.reserved());
        assertGe(d.pool.reserved(), d.rewards.pending(alice) + d.rewards.pending(bob) + d.rewards.redistribution());
    }

    function invariantHashAndCustodyConserved() public view {
        uint256 total;
        for (uint256 i; i < 128; ++i) {
            total += d.rewards.bucketHash(i);
        }
        assertEq(total, d.rewards.totalHash());
        assertEq(total, d.rewards.accountHash(alice) + d.rewards.accountHash(bob));
        uint256 placed = (d.farm.itemAt(alice, 4, 0) == 1 ? 1 : 0) + (d.farm.itemAt(bob, 4, 0) == 1 ? 1 : 0);
        assertEq(d.items.balanceOf(address(d.farm), 1), placed);
        assertEq(d.items.balanceOf(alice, 1) + d.items.balanceOf(bob, 1) + placed, 2);
    }
}
