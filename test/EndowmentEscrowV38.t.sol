// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {EndowmentEscrow} from "../src/EndowmentEscrow.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {RewardPool} from "../src/RewardPool.sol";
import {Params} from "../src/Params.sol";
import {LocalApplicationFactory} from "../script/Deploy.s.sol";
import "../src/lib/Errors.sol";

/// @dev v3.8: the token launch's remainderTo is an ownerless escrow deployed before the token; it forwards
/// its whole balance once to the RewardPool of the registry the Desk bound to, proven on chain.
contract EndowmentEscrowV38Test is BaseTest {
    EndowmentEscrow private escrow;
    bytes private registryCode;
    bytes private poolCode;

    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        vm.clearMockedCalls();
        LocalApplicationFactory f = LocalApplicationFactory(address(d.registry.factory()));
        escrow = new EndowmentEscrow(address(f), address(f), address(desk));
        registryCode = type(GameRegistry).creationCode;
        poolCode = vm.getCode("RewardPool.sol:RewardPool");
    }

    function testConstructorRejectsMissingInputs() public {
        vm.expectRevert(InvalidValue.selector);
        new EndowmentEscrow(address(0), address(this), address(desk));
        vm.expectRevert(InvalidValue.selector);
        new EndowmentEscrow(address(this), address(0), address(desk));
        vm.expectRevert(InvalidValue.selector);
        new EndowmentEscrow(address(this), address(this), address(0));
    }

    function testForwardSendsWholeBalanceOnceToAuthenticatedPoolAndFundsEndowment() public {
        uint256 amount = 200_000_000 ether;
        token.transfer(address(escrow), amount);
        assertEq(token.balanceOf(address(escrow)), amount);
        vm.expectRevert(AlreadyDone.selector);
        d.pool.fundEndowment(); // Fixture endowment is zero; a zero principal is never "funded".
        uint256 before_ = token.balanceOf(address(d.pool));
        vm.prank(bob);
        uint256 sent = escrow.forward(address(d.registry), 1, 1, registryCode, 1, 2, poolCode);
        assertEq(sent, amount);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(address(d.pool)), before_ + amount);
        assertTrue(escrow.forwarded());
        token.transfer(address(escrow), 1 ether);
        vm.expectRevert(AlreadyDone.selector);
        escrow.forward(address(d.registry), 1, 1, registryCode, 1, 2, poolCode);
    }

    function testForwardWithRealEndowmentActivatesDrip() public {
        // A registry with a 20% endowment, bound to a fresh Desk, at fresh coordinates of the fixture factory.
        LocalApplicationFactory f = LocalApplicationFactory(address(d.registry.factory()));
        bytes memory deskCode = vm.getCode("SwarmDesk.sol:SwarmDesk");
        uint256 endowment = 200_000_000 ether;
        bytes32 configHash = keccak256(
            abi.encode(d.registry.starterRoot(), d.registry.freeRoot(), d.registry.snapshotBlock(), endowment)
        );
        bytes memory words = _deskWords(address(f), configHash);
        address fresh = f.deploy(20, 0, bytes.concat(deskCode, words));
        Params p = Params(
            f.deploy(21, 0, bytes.concat(type(Params).creationCode, abi.encode(fresh, uint256(200), uint256(1 ether))))
        );
        GameRegistry r = GameRegistry(
            f.deploy(
                21,
                1,
                bytes.concat(
                    registryCode,
                    abi.encode(
                        address(token),
                        address(p),
                        address(market),
                        d.registry.starterRoot(),
                        d.registry.freeRoot(),
                        d.registry.snapshotBlock(),
                        endowment,
                        address(f)
                    )
                )
            )
        );
        RewardPool pool = RewardPool(f.deploy(22, 0, bytes.concat(poolCode, abi.encode(address(r)))));
        r.register(0, 22, 0, poolCode);
        (bool ok,) = fresh.call(
            abi.encodeWithSignature(
                "bind(address,bytes,bytes,uint64,uint8,uint64,uint8)",
                address(r),
                registryCode,
                type(Params).creationCode,
                uint64(21),
                uint8(1),
                uint64(21),
                uint8(0)
            )
        );
        assertTrue(ok, "bind");
        EndowmentEscrow e = new EndowmentEscrow(address(f), address(f), fresh);
        token.transfer(address(e), endowment);
        // The fixture registry is not the one this Desk bound to.
        vm.expectRevert(InvalidProof.selector);
        e.forward(address(d.registry), 1, 1, registryCode, 1, 2, poolCode);
        assertEq(pool.available(), 0);
        vm.expectRevert(InsufficientBalance.selector);
        pool.fundEndowment();
        e.forward(address(r), 21, 1, registryCode, 22, 0, poolCode);
        assertEq(token.balanceOf(address(pool)), endowment);
        pool.fundEndowment();
        assertTrue(pool.endowed());
        assertEq(pool.lockedEndowment(), endowment);
        vm.warp(block.timestamp + 21 days);
        assertEq(pool.lockedEndowment(), endowment / 2);
    }

    function testForwardRejectsBadProofs() public {
        token.transfer(address(escrow), 1 ether);
        vm.expectRevert(InvalidValue.selector);
        escrow.forward(address(d.registry), 0, 1, registryCode, 1, 2, poolCode);
        vm.expectRevert(InvalidValue.selector);
        escrow.forward(address(d.registry), 1, 8, registryCode, 1, 2, poolCode);
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(d.registry), 1, 1, hex"ff", 2, 0, poolCode);
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(d.registry), 1, 1, registryCode, 2, 0, hex"ff");
        // Wrong coordinates for a real registry/pool.
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(d.registry), 1, 0, registryCode, 1, 2, poolCode);
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(d.registry), 1, 1, registryCode, 1, 3, poolCode);
        // Unrecorded launch number.
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(d.registry), 77, 1, registryCode, 1, 2, poolCode);
        // A look-alike registry the Desk never bound to, even with the same configuration.
        GameRegistry spoof = new GameRegistry(
            address(token),
            address(d.params),
            address(market),
            d.registry.starterRoot(),
            d.registry.freeRoot(),
            d.registry.snapshotBlock(),
            d.registry.endowment(),
            address(d.registry.factory())
        );
        vm.expectRevert(InvalidProof.selector);
        escrow.forward(address(spoof), 1, 1, registryCode, 1, 2, poolCode);
        assertEq(token.balanceOf(address(escrow)), 1 ether);
        assertFalse(escrow.forwarded());
    }

    function testForwardRequiresBalance() public {
        vm.expectRevert(InsufficientBalance.selector);
        escrow.forward(address(d.registry), 1, 1, registryCode, 1, 2, poolCode);
    }

    function _deskWords(address factory, bytes32 configHash) private view returns (bytes memory) {
        (bool ok, bytes memory data) = address(desk).staticcall(abi.encodeWithSignature("oracleConfig()"));
        assertTrue(ok);
        // Re-encode from the fixture Desk's oracle configuration through the canonical flat encoder.
        return abi.encodePacked(_oracleWords(data), abi.encode(factory, uint256(200) << 144, configHash));
    }

    function _oracleWords(bytes memory raw) private pure returns (bytes memory) {
        (
            address intake,
            address delivery,
            address signer,
            address asset,
            bytes32 action,
            uint256 maxPrice,
            uint256 questionChain,
            uint64 fromBlock,
            uint64 toBlock,
            bytes32[2] memory questions,
            bytes32[2] memory bodies
        ) = abi.decode(
            raw, (address, address, address, address, bytes32, uint256, uint256, uint64, uint64, bytes32[2], bytes32[2])
        );
        uint256 context = questionChain | (uint256(fromBlock) << 64) | (uint256(toBlock) << 128);
        return abi.encode(
            intake, delivery, signer, asset, action, maxPrice, context, questions[0], questions[1], bodies[0], bodies[1]
        );
    }
}
