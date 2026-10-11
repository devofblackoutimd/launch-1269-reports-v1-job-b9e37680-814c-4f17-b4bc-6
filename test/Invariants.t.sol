// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Params} from "../src/Params.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract GameHandler is Test {
    Deploy.Deployment private d;
    address[2] public actors;

    constructor(Deploy.Deployment memory deployment, address a, address b) {
        d = deployment;
        actors = [a, b];
    }

    function buy(uint256 who) external {
        address p = actors[who % 2];
        uint256 price = d.packs.price();
        vm.prank(p);
        try d.packs.openPack{value: price}(1) {} catch {}
    }

    function resolve(uint256 id) external {
        uint256 n = d.packs.nextId();
        if (n <= 1) return;
        id = id % (n - 1) + 1;
        vm.roll(vm.getBlockNumber() + 3);
        try d.packs.resolve(id, 1) {} catch {}
    }

    function equip(uint256 who, uint256 id, uint256 slot) external {
        uint256 n = d.items.nextId();
        if (n <= 1) return;
        vm.prank(actors[who % 2]);
        try d.farm.place(id % (n - 1) + 1, 0, slot % 6) {} catch {}
    }

    function unplace(uint256 who, uint256 slot) external {
        vm.prank(actors[who % 2]);
        try d.farm.unplace(0, slot % 6) {} catch {}
    }

    function advance(uint256 gap) external {
        uint256 n = vm.getBlockNumber();
        vm.roll(n + 3);
        vm.setBlockhash(n + 1, keccak256(abi.encode(n)));
        vm.warp(d.rewards.epochEnd() + gap % 1 days);
        try d.rewards.advanceEpoch() {} catch {}
    }

    function settle(uint256 who, uint256 limit) external {
        try d.rewards.settle(actors[who % 2], limit % 8 + 1) {} catch {}
    }

    function claim(uint256 who, uint256 amount) external {
        address p = actors[who % 2];
        uint256 n = d.rewards.pending(p);
        if (n == 0) return;
        vm.prank(p);
        try d.rewards.claim(amount % n + 1) {} catch {}
    }

    function expand(uint256 who, bool wallet) external {
        vm.prank(actors[who % 2]);
        try d.farm.expand(wallet) {} catch {}
    }

    function tokenPack(uint256 who, bool wallet) external {
        vm.prank(actors[who % 2]);
        try d.farm.buyTokenPack(wallet) {} catch {}
    }
}

contract InvariantsTest is BaseTest {
    GameHandler private handler;

    function setUp() public override {
        super.setUp();
        fund(100_000_000 ether);
        payPack(alice);
        payPack(bob);
        place(alice, 0, 0, 0);
        place(bob, 0, 0, 0);
        handler = new GameHandler(d, alice, bob);
        targetContract(address(handler));
        // Only real player EOAs originate transactions. Fuzzing protocol addresses as
        // senders auto-funds those addresses and invalidates exact ETH conservation.
        targetSender(alice);
        targetSender(bob);
    }

    function invariantTokenConservationNoBurns() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(address(market))
            + token.balanceOf(address(d.pool)) + token.balanceOf(alice) + token.balanceOf(bob);
        assertEq(sum, token.totalSupply());
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariantReservesBackedAndPendingCovered() public view {
        assertLe(d.pool.reserved(), token.balanceOf(address(d.pool)));
        assertGe(
            d.pool.reserved(),
            d.rewards.pending(alice) + d.rewards.pending(bob) + d.rewards.queuedTax() + d.rewards.currentRedis()
        );
    }

    function invariantInventoryAndEthLiabilities() public view {
        assertLe(d.items.inventory(alice), d.items.capacity(alice));
        assertLe(d.items.inventory(bob), d.items.capacity(bob));
        uint256 due = d.fees.rewardETH() + d.fees.heartbeatBalance() + d.fees.credit(team)
            + d.fees.credit(address(handler)) + d.fees.credit(address(this));
        assertEq(address(d.fees).balance, due);
        assertLe(d.fees.heartbeatBalance(), 1 ether);
    }

    function invariantReceiptsNeverForfeitOrFixMissingEntropy() public view {
        for (uint256 id = 1; id < d.packs.nextId(); ++id) {
            (address p,, uint256 count, uint256 opened,,, bytes32 seed, bool fixedSeed, bool expired) =
                d.packs.commits(id);
            assertTrue(p != address(0));
            assertLe(opened, count);
            assertFalse(expired);
            if (opened != 0) assertTrue(fixedSeed);
            if (fixedSeed) assertTrue(seed != bytes32(0));
        }
    }

    function invariantPriceAndParamsBounds() public view {
        assertGe(d.packs.price(), d.params.get(Params.Key.PriceFloor));
        assertLe(d.packs.price(), d.params.get(Params.Key.PriceCeiling));
        for (uint256 i; i < 44; ++i) {
            Params.Key k = Params.Key(i);
            (uint256 low, uint256 high) = d.params.bounds(k);
            assertGe(d.params.get(k), low);
            assertLe(d.params.get(k), high);
        }
    }
}
