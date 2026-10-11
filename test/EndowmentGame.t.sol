// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract EndowmentGameTest is BaseTest {
    function testRealMiningCannotSpendFutureEndowment() public {
        d = deployment.deploy(
            Deploy.Config(
                address(token),
                swarm,
                address(market),
                launch,
                keccak256("endowed fixture root"),
                123,
                2500,
                200,
                1 ether
            )
        );
        uint256 principal = 250_000_000 ether;
        token.approve(address(d.pool), principal);
        d.pool.fundEndowment();
        assertEq(d.pool.available(), 0);
        d.rewards.advanceEpoch();
        payPack(alice);
        place(alice, 0, 0, 0);
        uint256 paid;
        for (uint256 i; i < 28; ++i) {
            calmNext();
            step();
            uint256 pending = d.rewards.pending(alice);
            if (pending > 0) {
                uint256 beforeBalance = token.balanceOf(alice);
                vm.prank(alice);
                d.rewards.claim(pending);
                paid += token.balanceOf(alice) - beforeBalance;
            }
            uint256 vested = principal - d.pool.lockedEndowment();
            assertLe(paid + d.pool.reserved(), vested);
            assertEq(token.balanceOf(address(d.pool)) + paid, principal);
            assertGe(token.balanceOf(address(d.pool)), d.pool.reserved() + d.pool.lockedEndowment());
        }
        assertGt(paid, 0);
        assertGt(d.pool.lockedEndowment(), 0);
    }
}
