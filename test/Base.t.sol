// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {ItemMath} from "../src/lib/ItemMath.sol";
import {FarmCore} from "../src/FarmCore.sol";
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
    address internal heartbeat;
    uint256 internal launch;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        launch = block.timestamp;
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        swarm = makeAddr("swarm");
        team = makeAddr("team");
        heartbeat = makeAddr("heartbeat");
        token = new MockToken();
        market = new MockMarket(address(token));
        token.transfer(address(market), 100_000_000 ether);
        Deploy.Config memory c = Deploy.Config(
            address(token),
            swarm,
            heartbeat,
            team,
            address(market),
            launch,
            keccak256(abi.encode(uint256(17), alice)),
            23_000_000
        );
        address fixture = makeAddr("deployment script fixture");
        vm.etch(fixture, vm.getDeployedCode("Deploy.s.sol:Deploy"));
        deployment = Deploy(fixture);
        d = deployment.deploy(c);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(address(this), 100 ether);
        vm.prank(alice);
        d.items.setApprovalForAll(address(d.farm), true);
        vm.prank(bob);
        d.items.setApprovalForAll(address(d.farm), true);
    }

    function fund(uint256 amount) internal {
        token.approve(address(d.pool), amount);
        d.pool.donate(amount);
    }

    // Test-only minter impersonation creates precise room fixtures; public mint authorization is tested separately.
    function mintItem(address player, uint256 kind, uint256 rarity, uint256 epoch, bool starter)
        internal
        returns (uint256 id)
    {
        id = ItemMath.encode(kind, rarity, epoch, starter);
        vm.prank(starter ? address(d.starter) : address(d.packs));
        d.items.mint(player, id);
    }

    function placeSolo(address player, uint256 kind, uint256 rarity, uint256 slot) internal returns (uint256 id) {
        id = mintItem(player, kind, rarity, 0, false);
        vm.prank(player);
        d.farm.place(id, 4, slot);
    }

    function mine(address player, uint256 duration) internal {
        vm.warp(vm.getBlockTimestamp() + duration);
        d.rewards.settle(player, 64);
    }

    function resolvePack(uint256 id, bytes32 hash) internal {
        (, uint64 target,,,,) = d.packs.commits(id);
        vm.roll(uint256(target) + 1);
        vm.setBlockhash(target, hash);
        d.packs.resolve(id);
    }
}
