// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {FarmCore} from "../src/FarmCore.sol";
import {FarmItems} from "../src/FarmItems.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {MockGameRegistry} from "./mocks/MockGameRegistry.sol";
import {Params} from "../src/Params.sol";
import {GridOperator} from "../src/GridOperator.sol";
import "../src/lib/Errors.sol";

abstract contract BaseTest is Test {
    Deploy.Deployment internal d;
    Deploy internal deployment;
    MockToken internal token;
    MockMarket internal market;
    address internal alice;
    address internal bob;
    address internal swarm;
    address internal team;
    uint256 internal launch;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        vm.txGasPrice(20_000_000);
        launch = block.timestamp;
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        swarm = makeAddr("swarm");
        team = 0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007;
        token = new MockToken();
        market = new MockMarket(address(token));
        token.transfer(address(market), 100_000_000 ether);
        address fixture = makeAddr("deployment script fixture");
        vm.etch(fixture, vm.getDeployedCode("Deploy.s.sol:Deploy"));
        deployment = Deploy(fixture);
        d = deployment.deploy(
            Deploy.Config(
                address(token),
                swarm,
                address(market),
                launch,
                keccak256(abi.encode(uint256(17), alice)),
                23_000_000,
                0,
                200,
                1 ether
            )
        );
        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
        vm.deal(address(this), 10000 ether);
        token.transfer(alice, 10_000_000 ether);
        token.transfer(bob, 10_000_000 ether);
        vm.prank(alice);
        token.approve(address(d.farm), type(uint256).max);
        vm.prank(bob);
        token.approve(address(d.farm), type(uint256).max);
        d.rewards.advanceEpoch();
    }

    function mockRegistry(address market_, uint256 endowment_) internal returns (MockGameRegistry r) {
        r = new MockGameRegistry(
            address(token),
            address(d.params),
            market_,
            launch,
            keccak256(abi.encode(uint256(17), alice)),
            23_000_000,
            endowment_
        );
        address[10] memory a = [
            address(d.pool),
            address(d.rewards),
            address(d.farm),
            address(d.items),
            address(d.packs),
            address(d.starter),
            address(d.fees),
            address(d.grid),
            address(d.season),
            address(d.engine)
        ];
        for (uint256 i; i < 10; ++i) {
            r.setModule(i, a[i]);
        }
    }

    function newFees(address market_) internal returns (FeeRouter f) {
        MockGameRegistry r = mockRegistry(market_, 0);
        f = new FeeRouter(address(r));
        r.setModule(6, address(f));
    }

    function fund(uint256 amount) internal {
        token.approve(address(d.pool), amount);
        d.pool.donate(amount);
    }

    function mintItem(address p, uint8 k, uint8 r) internal returns (uint256 id) {
        vm.prank(address(d.packs));
        id = d.items.mint(p, k, r, false);
    }

    function place(address p, uint8 k, uint8 r, uint256 slot) internal returns (uint256 id) {
        id = mintItem(p, k, r);
        vm.prank(p);
        d.farm.place(id, 0, slot);
    }

    function payPack(address p) internal returns (uint256 id) {
        uint256 price = d.packs.price();
        vm.prank(p);
        id = d.packs.openPack{value: price}(1);
    }

    function entropy() internal {
        uint256 n = vm.getBlockNumber();
        vm.roll(n + 3);
        vm.setBlockhash(n + 1, keccak256(abi.encode(n, "shift")));
        vm.setBlockhash(n + 2, keccak256(abi.encode(n, "pack")));
    }

    function finish() internal {
        while (!d.rewards.ready()) d.rewards.processEpoch(8);
    }

    function step() internal {
        entropy();
        vm.warp(d.rewards.epochEnd());
        d.rewards.advanceEpoch();
        finish();
    }

    function calmNext() internal {
        uint256 e = d.rewards.epoch() + 1;
        vm.prank(swarm);
        d.grid.submitPlan(e, GridOperator.Kind.Calm, 10000, keccak256("test calm"), "Calm test epoch");
    }

    function resolvePack(uint256 id) internal {
        entropy();
        d.packs.resolve(id, 1);
    }
}
