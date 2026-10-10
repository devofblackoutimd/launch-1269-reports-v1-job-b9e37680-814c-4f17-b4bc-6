// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Params} from "./Params.sol";
import {FeeRouter} from "./FeeRouter.sol";
import {IV4PoolManager, PoolKey, SwapParams} from "./interfaces/IV4.sol";
import "./lib/Errors.sol";

/// @notice Optional, immutable ETH/token v4 hook + buy adapter. Must be selected as the launch pool's hook.
/// @dev Implements the TOTAL IMD-style fee (not an add-on to a second 1.25% fee hook).
contract V4Market is ReentrancyGuard {
    uint256 public constant TOTAL_CAP_BPS = 1500;
    uint256 public constant NETWORK_BPS = 25;
    uint160 public constant HOOK_FLAGS = 0x10cc; // afterInitialize, before/afterSwap and both swap deltas
    IV4PoolManager public immutable manager;
    address public immutable token;
    Params public immutable params;
    FeeRouter public immutable fees;
    address public immutable networkRecipient;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    bytes32 public immutable poolId;
    uint256 public networkCredit;

    struct Volume {
        uint64 period;
        uint192 sells;
        uint192 buys;
    }
    Volume[12] private shortVolumes;
    Volume[24] private longVolumes;

    struct Observation {
        uint64 minute;
        uint256 cumulative;
    }
    Observation[32] private observations;
    uint256 public initializedAt;
    uint256 public updatedAt;
    uint256 public cumulative;
    uint256 public lastPrice;
    uint256 public storedFeeWad = 100 ether;
    uint256 public feeTimestamp;
    bool private buying;
    event PriceObserved(uint256 timestamp, uint256 tokensPerETH);
    event SellFee(
        address indexed sender,
        uint256 ethOutput,
        uint256 feeBps,
        uint256 hourImbalance,
        uint256 dayImbalance,
        uint256 deviation
    );
    event NetworkPaid(uint256 amount);

    constructor(
        address manager_,
        address token_,
        address params_,
        address fees_,
        address network_,
        uint24 fee_,
        int24 spacing_
    ) {
        if (
            manager_ == address(0) || token_ == address(0) || params_ == address(0) || fees_ == address(0)
                || network_ == address(0) || spacing_ <= 0 || spacing_ > 32767 || fee_ != 0
        ) revert InvalidValue();
        manager = IV4PoolManager(manager_);
        token = token_;
        params = Params(params_);
        fees = FeeRouter(payable(fees_));
        networkRecipient = network_;
        poolFee = fee_;
        tickSpacing = spacing_;
        poolId = keccak256(abi.encode(PoolKey(address(0), token_, fee_, spacing_, address(this))));
        _validateHookAddress();
    }

    function _validateHookAddress() internal view virtual {
        if (uint160(address(this)) & 0x3fff != HOOK_FLAGS) revert InvalidAddress();
    }

    receive() external payable {
        if (msg.sender != address(manager)) revert Unauthorized();
    }

    function key() public view returns (PoolKey memory) {
        return PoolKey(address(0), token, poolFee, tickSpacing, address(this));
    }

    function _check(PoolKey calldata k) private view {
        if (msg.sender != address(manager) || keccak256(abi.encode(k)) != poolId) revert Unauthorized();
    }

    function spot() public view returns (uint256) {
        uint256 sqrt = uint160(uint256(manager.extsload(keccak256(abi.encode(poolId, uint256(6))))));
        if (sqrt == 0) revert NotConfigured();
        uint256 price = Math.mulDiv(Math.mulDiv(sqrt, sqrt, 1 << 96), 1 ether, 1 << 96);
        if (price == 0 || price > 1e40) revert InvalidValue();
        return price;
    }

    function afterInitialize(address, PoolKey calldata k, uint160, int24) external returns (bytes4) {
        _check(k);
        if (initializedAt != 0) revert AlreadyDone();
        _observe(spot());
        return this.afterInitialize.selector;
    }

    function _observe(uint256 price) private {
        uint256 now_ = block.timestamp;
        if (initializedAt == 0) {
            initializedAt = now_;
            updatedAt = now_;
            lastPrice = price;
            emit PriceObserved(now_, price);
            return;
        }
        uint256 first = updatedAt / 60 + 1;
        uint256 last = now_ / 60;
        if (last >= 32 && first < last - 31) first = last - 31;
        for (uint256 minute = first; minute <= last; ++minute) {
            uint256 c = cumulative + (1e60 / lastPrice) * (minute * 60 - updatedAt);
            observations[minute % 32] = Observation(uint64(minute), c);
        }
        cumulative += (1e60 / lastPrice) * (now_ - updatedAt);
        updatedAt = now_;
        lastPrice = price;
        emit PriceObserved(now_, price);
    }

    function _cumulativeAt(uint256 minute) private view returns (uint256) {
        uint256 ts = minute * 60;
        if (ts < initializedAt) revert NotConfigured();
        if (ts >= updatedAt) return cumulative + (1e60 / lastPrice) * (ts - updatedAt);
        Observation memory o = observations[minute % 32];
        if (o.minute != minute) revert NotConfigured();
        return o.cumulative;
    }

    function twap() public view returns (uint256) {
        if (initializedAt == 0 || block.timestamp < initializedAt + 31 minutes) revert NotConfigured();
        uint256 minute = block.timestamp / 60;
        uint256 averageETH = (_cumulativeAt(minute) - _cumulativeAt(minute - 30)) / 30 minutes;
        return 1e60 / averageETH;
    }

    function quote(uint256 ethAmount) external view returns (uint256) {
        return Math.mulDiv(ethAmount, twap(), 1 ether);
    }

    function _record(bool sell, uint256 amount) private {
        if (amount > type(uint192).max) revert InvalidValue();
        uint256 p = block.timestamp / 5 minutes;
        Volume storage a = shortVolumes[p % 12];
        if (a.period != p) {
            delete shortVolumes[p % 12];
            a.period = uint64(p);
        }
        p = block.timestamp / 1 hours;
        Volume storage b = longVolumes[p % 24];
        if (b.period != p) {
            delete longVolumes[p % 24];
            b.period = uint64(p);
        }
        if (sell) {
            a.sells += uint192(amount);
            b.sells += uint192(amount);
        } else {
            a.buys += uint192(amount);
            b.buys += uint192(amount);
        }
    }

    function imbalances() public view returns (uint256 hour, uint256 day) {
        uint256 s;
        uint256 b;
        uint256 current = block.timestamp / 5 minutes;
        for (uint256 i; i < 12; ++i) {
            if (uint256(shortVolumes[i].period) + 12 > current) {
                s += shortVolumes[i].sells;
                b += shortVolumes[i].buys;
            }
        }
        if (s > b) hour = Math.mulDiv(s - b, 10000, s + b + 0.5 ether);
        s = 0;
        b = 0;
        current = block.timestamp / 1 hours;
        for (uint256 i; i < 24; ++i) {
            if (uint256(longVolumes[i].period) + 24 > current) {
                s += longVolumes[i].sells;
                b += longVolumes[i].buys;
            }
        }
        if (s > b) day = Math.mulDiv(s - b, 10000, s + b + 2 ether);
    }

    function _sellFee(uint256 price) private returns (uint256 fee, uint256 hour, uint256 day, uint256 dev) {
        (hour, day) = imbalances();
        uint256 average;
        // Trading is possible during warmup; the deviation component starts only when TWAP is ready.
        if (block.timestamp >= initializedAt + 31 minutes) average = twap();
        if (average != 0 && price > average) dev = Math.min(1000, 10000 - Math.mulDiv(average, 10000, price));
        uint256 target = 100 + params.get(Params.Key.SellHourBps) * hour / 10000 + params.get(Params.Key.SellDayBps)
            * day / 10000 + params.get(Params.Key.SellDeviationBps) * dev / 10000;
        target = Math.min(TOTAL_CAP_BPS - NETWORK_BPS, target) * 1 ether;
        uint256 fall = feeTimestamp == 0 ? 0 : (block.timestamp - feeTimestamp) * 100 ether / 10 minutes;
        uint256 decayed = storedFeeWad > fall ? storedFeeWad - fall : 100 ether;
        storedFeeWad = Math.max(target, decayed);
        feeTimestamp = block.timestamp;
        fee = Math.min(TOTAL_CAP_BPS - NETWORK_BPS, (storedFeeWad + 1 ether - 1) / 1 ether);
    }

    function beforeSwap(address, PoolKey calldata k, SwapParams calldata p, bytes calldata)
        external
        returns (bytes4, int256, uint24)
    {
        _check(k);
        if (p.amountSpecified >= 0) revert InvalidValue();
        _observe(spot());
        if (!p.zeroForOne) return (this.beforeSwap.selector, 0, 0);
        uint256 ethIn = uint256(-p.amountSpecified);
        uint256 fee = ethIn * 125 / 10000;
        if (fee > uint256(uint128(type(int128).max))) revert InvalidValue();
        _take(ethIn * 100 / 10000, 0, fee - ethIn * 100 / 10000);
        return (this.beforeSwap.selector, int256(fee << 128), 0);
    }

    function afterSwap(address sender, PoolKey calldata k, SwapParams calldata p, int256 delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        _check(k);
        if (p.amountSpecified >= 0) revert InvalidValue();
        uint256 price = spot();
        _observe(price);
        int128 ethDelta = int128(delta >> 128);
        if (p.zeroForOne) {
            if (ethDelta >= 0) revert InvalidValue();
            _record(false, uint256(-int256(ethDelta)));
            return (this.afterSwap.selector, 0);
        }
        if (ethDelta <= 0) revert InvalidValue();
        uint256 output = uint256(uint128(ethDelta));
        _record(true, output);
        (uint256 bps, uint256 hour, uint256 day, uint256 dev) = _sellFee(price);
        uint256 base = output * 100 / 10000;
        uint256 excess = output * (bps - 100) / 10000;
        uint256 network = output * NETWORK_BPS / 10000;
        _take(base, excess, network);
        emit SellFee(sender, output, bps, hour, day, dev);
        return (this.afterSwap.selector, int128(int256(base + excess + network)));
    }

    function _take(uint256 base, uint256 excess, uint256 network) private {
        if (base != 0) manager.take(address(0), address(fees), base);
        if (excess + network != 0) manager.take(address(0), address(this), excess + network);
        networkCredit += network;
        if (excess != 0) fees.depositSellTax{value: excess}();
    }

    function buy(uint256 minOut, address recipient) external payable nonReentrant returns (uint256 received) {
        if (msg.sender != address(fees) || recipient == address(0) || msg.value == 0 || minOut == 0) {
            revert Unauthorized();
        }
        twap();
        buying = true;
        received = abi.decode(manager.unlock(abi.encode(msg.value, minOut, recipient)), (uint256));
        buying = false;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || !buying) revert Unauthorized();
        (uint256 ethIn, uint256 minOut, address recipient) = abi.decode(data, (uint256, uint256, address));
        uint256 base = ethIn * 100 / 10000;
        uint256 network = ethIn * 25 / 10000;
        uint256 input = ethIn - base - network;
        _observe(spot());
        // v4 suppresses a hook's callbacks on its own swaps. Account for this system buy explicitly.
        int256 delta = manager.swap(key(), SwapParams(true, -int256(input), 4295128740), "");
        _observe(spot());
        int128 ethDelta = int128(delta >> 128);
        int128 tokenDelta = int128(delta);
        if (
            ethDelta >= 0 || uint256(-int256(ethDelta)) != input || tokenDelta <= 0
                || uint256(uint128(tokenDelta)) < minOut
        ) {
            revert InsufficientBalance();
        }
        manager.settle{value: input}();
        manager.take(token, recipient, uint256(uint128(tokenDelta)));
        networkCredit += network;
        if (base != 0) fees.depositBaseFee{value: base}();
        return abi.encode(uint256(uint128(tokenDelta)));
    }

    function withdrawNetwork() external nonReentrant {
        uint256 amount = networkCredit;
        if (amount == 0) revert InsufficientBalance();
        networkCredit = 0;
        (bool ok,) = networkRecipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit NetworkPaid(amount);
    }
}
