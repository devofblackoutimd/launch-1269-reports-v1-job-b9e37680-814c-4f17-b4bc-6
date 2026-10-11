// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {V4Market} from "../src/V4Market.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {IV4PoolManager, PoolKey, SwapParams} from "../src/interfaces/IV4.sol";

struct LiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface RealManager is IV4PoolManager {
    function initialize(PoolKey memory, uint160) external returns (int24);
    function modifyLiquidity(PoolKey memory, LiquidityParams memory, bytes calldata) external returns (int256, int256);
    function sync(address) external;
}

contract V4IntegrationTest is BaseTest {
    RealManager internal manager;
    V4Market internal hook;
    FeeRouter internal router;
    address internal network;

    function setUp() public override {
        super.setUp();
        vm.deal(address(this), 10000 ether);
        network = makeAddr("integration network");
        manager = RealManager(address(new PoolManager(address(this))));
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        bytes memory code = abi.encodePacked(
            type(V4Market).creationCode,
            abi.encode(
                address(manager), address(token), address(d.params), predictedRouter, network, uint24(0), int24(60)
            )
        );
        bytes32 hash = keccak256(code);
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            address target = vm.computeCreate2Address(salt, hash, address(this));
            if (uint160(target) & 0x3fff == 0x10cc) break;
        }
        hook = new V4Market{salt: salt}(
            address(manager), address(token), address(d.params), predictedRouter, network, 0, 60
        );
        router = new FeeRouter(
            address(token),
            address(d.params),
            address(hook),
            address(d.pool),
            address(d.packs),
            address(d.grid),
            address(d.rewards)
        );
        assertEq(address(router), predictedRouter);
        manager.initialize(hook.key(), uint160(1 << 96));
        manager.unlock(abi.encode(uint8(0), uint256(1000 ether)));
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
    }
    receive() external payable {}

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 action, uint256 amount) = abi.decode(data, (uint8, uint256));
        int256 delta;
        if (action == 0) {
            (delta,) =
                manager.modifyLiquidity(hook.key(), LiquidityParams(-887220, 887220, int256(amount), bytes32(0)), "");
        } else {
            delta = manager.swap(
                hook.key(),
                SwapParams(
                    action == 1,
                    -int256(amount),
                    action == 1 ? 4295128740 : 1461446703485210103287273052203988822378723970341
                ),
                ""
            );
        }
        int128 a = int128(delta >> 128);
        int128 b = int128(delta);
        if (a < 0) manager.settle{value: uint256(-int256(a))}();
        else if (a > 0) manager.take(address(0), address(this), uint256(uint128(a)));
        if (b < 0) {
            manager.sync(address(token));
            token.transfer(address(manager), uint256(-int256(b)));
            manager.settle();
        } else if (b > 0) {
            manager.take(address(token), address(this), uint256(uint128(b)));
        }
        return abi.encode(delta);
    }

    function testRealV4BuyAndSingleSwapSellTaxConserveSettlement() public {
        uint256 before = address(this).balance;
        manager.unlock(abi.encode(uint8(1), uint256(1 ether)));
        assertEq(before - address(this).balance, 1 ether);
        assertEq(hook.networkCredit(), 0.0025 ether);
        assertEq(router.credit(team), 0.01 ether);
        uint256 oldCredit = hook.networkCredit();
        uint256 oldPrice = hook.lastPrice();
        manager.unlock(abi.encode(uint8(2), uint256(100 ether)));
        assertGt(hook.networkCredit(), oldCredit);
        assertGt(hook.lastPrice(), oldPrice);
        assertGt(hook.storedFeeWad(), 1000 ether);
        assertLe(hook.storedFeeWad(), 1475 ether);
        hook.withdrawNetwork();
        assertGt(network.balance, 0);
    }

    function testRealV4SystemBuyUsesTwapAndOnlySystemFunds() public {
        router.depositBaseFee{value: 1 ether}();
        uint256 beforePool = token.balanceOf(address(d.pool));
        uint256 quoted = hook.quote(0.5 ether);
        router.executeBuys(0.5 ether, quoted * 97 / 100);
        assertGe(token.balanceOf(address(d.pool)) - beforePool, quoted * 97 / 100);
        (uint256 hour, uint256 day) = hook.imbalances();
        assertEq(hour, 0);
        assertEq(day, 0);
    }

    function testRealV4ManipulatedSpotCannotInstantlySetBuybackQuote() public {
        uint256 quote = hook.quote(1 ether);
        manager.unlock(abi.encode(uint8(2), uint256(100 ether)));
        assertEq(hook.quote(1 ether), quote);
        assertGt(hook.lastPrice(), quote);
    }
}
