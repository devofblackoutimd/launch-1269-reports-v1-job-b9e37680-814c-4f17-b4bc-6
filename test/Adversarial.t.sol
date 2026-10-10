// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {PackSale} from "../src/PackSale.sol";
import {FarmItems} from "../src/FarmItems.sol";
import {FarmRewards} from "../src/FarmRewards.sol";
import {FarmCore} from "../src/FarmCore.sol";
import {Params} from "../src/Params.sol";
import {GridOperator} from "../src/GridOperator.sol";
import {ItemMath} from "../src/lib/ItemMath.sol";
import "../src/lib/Errors.sol";

contract HostilePayee {
    FeeRouter public router;
    bool public reentered;
    bool public reject;

    constructor(FeeRouter r) {
        router = r;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function withdraw() external {
        router.withdraw();
    }

    receive() external payable {
        require(!reject, "reject ETH");
        (reentered,) = address(router).call(abi.encodeCall(router.withdraw, ()));
    }
}

contract HostileMinter {
    PackSale public packs;
    uint256 public id;
    bool public reentered;

    constructor(PackSale p) {
        packs = p;
    }

    function buy() external payable {
        id = packs.openPack{value: msg.value}(1);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        (reentered,) = address(packs).call(abi.encodeCall(packs.resolve, (id)));
        return this.onERC1155Received.selector;
    }
}

contract AdversarialTest is BaseTest {
    function testERC1155ReceiverCannotReenterResolution() public {
        HostileMinter attacker = new HostileMinter(d.packs);
        attacker.buy{value: 0.01 ether}();
        resolvePack(attacker.id(), keccak256("adversarial reveal"));
        uint256 count;
        for (uint256 id = 1; id <= 28; ++id) {
            count += d.items.balanceOf(address(attacker), id);
        }
        assertEq(count, 3);
        assertFalse(attacker.reentered());
    }

    function testEthWithdrawalReentrancyAndRecipientFailureIsolation() public {
        HostilePayee attacker = new HostilePayee(d.fees);
        vm.prank(team);
        d.fees.changeTeam(address(attacker));
        d.fees.depositBaseFee{value: 1 ether}();
        attacker.withdraw();
        assertFalse(attacker.reentered());
        assertEq(address(attacker).balance, 0.2 ether);
        d.fees.depositBaseFee{value: 1 ether}();
        attacker.setReject(true);
        vm.expectRevert(TransferFailed.selector);
        attacker.withdraw();
        assertEq(d.fees.credit(address(attacker)), 0.2 ether);
        vm.prank(heartbeat);
        d.fees.withdraw();
        assertEq(heartbeat.balance, 0.2 ether);
    }

    function testERC20CallbackCannotReenterClaimAndFailureRollsBackLiabilities() public {
        fund(1_000_000 ether);
        placeSolo(alice, 0, 0, 0);
        mine(alice, 1 days);
        uint256 pending = d.rewards.pending(alice);
        uint256 reserved = d.pool.reserved();
        token.setFail(true);
        vm.prank(alice);
        vm.expectRevert();
        d.rewards.claim(pending);
        assertEq(d.rewards.pending(alice), pending);
        assertEq(d.pool.reserved(), reserved);
        token.setFail(false);
        token.setCallback(address(d.rewards), abi.encodeCall(d.rewards.claim, (uint256(1))));
        vm.prank(alice);
        d.rewards.claim(pending);
        assertFalse(token.callbackSucceeded());
        assertEq(d.rewards.pending(alice), 0);
    }

    function testLongInactiveFarmCanBeRemovedAndRepairedFromWallet() public {
        fund(1_000_000 ether);
        placeSolo(alice, 0, 0, 0);
        vm.warp(launch + 51 days);
        while (!d.rewards.checkpoint(64)) {}
        d.farm.refresh(alice);
        assertEq(d.rewards.accountHash(alice), 0);
        assertEq(d.rewards.durability(alice), 0);
        token.transfer(alice, 100_000 ether);
        vm.prank(alice);
        token.approve(address(d.farm), 100_000 ether);
        vm.prank(alice);
        d.farm.payMaintenance(true, 20);
        assertEq(d.rewards.durability(alice), 20 ether);
        assertGt(d.rewards.accountHash(alice), 0);
    }

    function testMintBonusIsFrozenAcrossParameterUpdatesAndDelayedResolve() public {
        vm.warp(launch + 7 days);
        uint256 price = d.packs.price();
        vm.prank(alice);
        uint256 commit = d.packs.openPack{value: price}(1);
        vm.prank(swarm);
        d.params.set(Params.Key.EpochHashBps, 900);
        vm.roll(vm.getBlockNumber() + 260);
        d.packs.resolve(commit);
        uint256 oldId = ItemMath.encode(0, 0, 1, false);
        assertEq(d.items.balanceOf(alice, oldId), 3);
        assertEq(d.farm.itemHash(alice, oldId, 0), 11 ether);
        vm.prank(alice);
        commit = d.packs.openPack{value: price}(1);
        vm.roll(vm.getBlockNumber() + 260);
        d.packs.resolve(commit);
        uint256 newId = ItemMath.withBonus(oldId, 900);
        assertEq(d.items.balanceOf(alice, newId), 3);
        assertEq(d.farm.itemHash(alice, newId, 0), 10.9 ether);
    }

    function testSwarmCanResumeEventsAfterLongOutage() public {
        vm.warp(launch + 20 days);
        vm.prank(swarm);
        d.grid.submitEvent(40, GridOperator.Kind.Surge);
        vm.warp(launch + 20 days + 12 hours);
        vm.prank(swarm);
        d.grid.submitEvent(41, GridOperator.Kind.Heatwave);
    }

    function testSupplyMetadataAndMintEditionRestrictions() public {
        string memory metadata = d.items.uri(ItemMath.encode(4, 3, 2, false));
        assertGt(bytes(metadata).length, 100);
        vm.prank(address(d.packs));
        vm.expectRevert(Unauthorized.selector);
        d.items.mint(alice, ItemMath.encode(0, 1, 0, true));
        vm.prank(address(d.starter));
        vm.expectRevert(Unauthorized.selector);
        d.items.mint(alice, 1);
    }
}
