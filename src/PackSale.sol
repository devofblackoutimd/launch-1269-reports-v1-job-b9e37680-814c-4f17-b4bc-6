// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GameModule} from "./lib/GameModule.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {wadExp, wadLn} from "solmate/src/utils/SignedWadMath.sol";
import {RewardPool} from "./RewardPool.sol";
import {ILaunchHook} from "./interfaces/ILaunchHook.sol";
import {FarmItems} from "./FarmItems.sol";
import {Params} from "./Params.sol";
import {FeeRouter} from "./FeeRouter.sol";
import {ICore} from "./interfaces/IGame.sol";
import {ChainClock} from "./lib/ChainClock.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import "./lib/Errors.sol";

contract PackSale is GameModule, ReentrancyGuard {
    struct Commit {
        address player;
        uint64 target;
        uint256 count;
        uint256 opened;
        bool mythic;
        bool guaranteed;
        bytes32 seed;
        bool fixedSeed;
        bool expired;
    }

    uint256 public sold;
    /// @notice Sales open this long after the authenticated hook initialization timestamp.
    uint256 public constant OPEN_DELAY = 60 minutes;
    uint256 public pausedUntil;
    uint256 public nextPauseAt;
    event SalePaused(uint256 until);

    function paused() public view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    function pause(uint256 duration) external {
        if (msg.sender != params().swarmWallet()) revert Unauthorized();
        if (duration == 0 || duration > 72 hours) revert InvalidValue();
        if (block.timestamp < nextPauseAt) revert TooEarly();
        pausedUntil = block.timestamp + duration;
        nextPauseAt = pausedUntil + 72 hours; // No extension or chaining into an indefinite pause.
        emit SalePaused(pausedUntil);
    }

    function unpause() external {
        if (msg.sender != params().swarmWallet()) revert Unauthorized();
        pausedUntil = 0;
        emit SalePaused(0);
    }
    uint256 public nextId = 1;
    mapping(uint256 => Commit) public commits;
    event PackCommitted(uint256 indexed id, address indexed player, uint256 count, uint256 target, bool guaranteed);
    event PackOpened(uint256 indexed id, uint256 count, bool expired);

    constructor(address registry_) GameModule(registry_) {}

    function items() public view returns (FarmItems) {
        return FarmItems(registry.module(3));
    }

    function params() public view returns (Params) {
        return Params(registry.params());
    }

    function fees() public view returns (FeeRouter) {
        return FeeRouter(payable(registry.module(6)));
    }

    function farm() public view returns (ICore) {
        return ICore(registry.module(2));
    }

    function season() public view returns (address) {
        return registry.module(8);
    }

    function launchTime() public view returns (uint256) {
        return registry.launchTime();
    }

    function opensAt() public view returns (uint256) {
        return ILaunchHook(registry.market()).initializedAt() == 0
            ? type(uint256).max
            : ILaunchHook(registry.market()).initializedAt() + OPEN_DELAY;
    }

    function isOpen() public view returns (bool) {
        return block.timestamp >= opensAt() && !paused();
    }

    function price() public view returns (uint256) {
        return priceAt(sold);
    }

    function priceAt(uint256 sales) public view returns (uint256 p) {
        uint256 elapsed = block.timestamp > opensAt() ? block.timestamp - opensAt() : 0;
        uint256 target = params().get(Params.Key.DemandTarget);
        int256 ahead = int256(sales * 1 ether) - int256(elapsed * target * 1 ether / 1 hours);
        int256 exponent;
        if (ahead >= 0) {
            exponent = wadLn(int256(1 ether + params().get(Params.Key.PriceStepBps) * 1e14)) * ahead / 1 ether;
        } else {
            exponent = wadLn(int256(1 ether - params().get(Params.Key.PriceDecayBps) * 1e14)) * (-ahead)
                / int256(target) / 1 ether;
        }
        if (exponent > 10 ether) exponent = 10 ether;
        if (exponent < -10 ether) exponent = -10 ether;
        p = params().get(Params.Key.PriceStart) * uint256(wadExp(exponent)) / 1 ether;
        uint256 low = params().get(Params.Key.PriceFloor);
        uint256 high = params().get(Params.Key.PriceCeiling);
        if (p < low) p = low;
        if (p > high) p = high;
    }

    /// @notice Each pack pays its position on the curve. There is no wallet, daily, or global quantity cap.
    function quote(uint256 count_) public view returns (uint256 total) {
        if (count_ == 0) revert InvalidValue();
        uint256 ceiling = params().get(Params.Key.PriceCeiling);
        for (uint256 i; i < count_; ++i) {
            uint256 p = priceAt(sold + i);
            if (p == ceiling) return total + (count_ - i) * ceiling;
            total += p;
        }
    }

    function openPack(uint256 n) external payable nonReentrant returns (uint256 id) {
        if (block.timestamp < opensAt()) revert TooEarly();
        if (paused() || msg.value != quote(n)) revert InvalidValue();
        _requireReady();
        sold += n;
        farm().register(msg.sender);
        farm().paidPackBought(msg.sender, n, msg.value);
        id = _commit(msg.sender, n, false);
        fees().depositPack{value: msg.value}();
    }

    function tokenPack(address p) external nonReentrant returns (uint256 id) {
        if (msg.sender != address(farm())) revert Unauthorized();
        if (paused() || block.timestamp < opensAt()) revert TooEarly();
        _requireReady();
        sold++;
        id = _commit(p, 1, false);
    }

    function _requireReady() private view {
        if (!RewardPool(registry.module(0)).endowed() || ILaunchHook(registry.market()).fees() != address(fees())) {
            revert NotConfigured();
        }
    }

    function rewardPack(address p) external nonReentrant returns (uint256 id) {
        if (msg.sender != season()) revert Unauthorized();
        id = _commit(p, 1, true);
    }

    function _commit(address p, uint256 n, bool guaranteed) private returns (uint256 id) {
        id = nextId++;
        uint64 target = uint64(ChainClock.number() + 2);
        commits[id] = Commit(p, target, n, 0, false, guaranteed, bytes32(0), false, false);
        emit PackCommitted(id, p, n, target, guaranteed);
    }

    /// @notice Preserve entropy even when inventory is full. Exactly one credit per receipt.
    function captureEntropy(uint256 id) external nonReentrant {
        _capture(id, msg.sender);
    }

    function _capture(uint256 id, address keeper) private returns (bool) {
        uint256 startGas = gasleft();
        Commit storage c = commits[id];
        if (c.player == address(0)) revert InvalidValue();
        if (c.fixedSeed) return true;
        if (ChainClock.number() <= c.target) revert TooEarly();
        bytes32 h = ChainClock.hash(c.target);
        if (h == bytes32(0)) {
            if (ChainClock.number() <= uint256(c.target) + 256) revert NotConfigured();
            _rearm(id, c);
            return false;
        }
        c.seed = keccak256(abi.encode(h, address(this), id));
        c.fixedSeed = true;
        fees().payWork(keeper, Params.Key.EntropyBounty, 1, startGas - gasleft());
        return true;
    }

    event PackRearmed(uint256 indexed id, uint256 target);

    function rearm(uint256 id) external {
        Commit storage c = commits[id];
        if (c.player == address(0)) revert InvalidValue();
        if (c.fixedSeed || ChainClock.number() <= uint256(c.target) + 256) revert TooEarly();
        _rearm(id, c);
    }

    function _rearm(uint256 id, Commit storage c) private {
        c.target = uint64(ChainClock.number() + 2);
        emit PackRearmed(id, c.target);
    }

    /// @notice Opening is bounded; unopen packs stay claimable while the player makes inventory space.
    function resolve(uint256 id, uint256 n) external nonReentrant {
        Commit storage c = commits[id];
        if (c.player == address(0) || n == 0 || n > 8 || n > c.count - c.opened) revert InvalidValue();
        if (ChainClock.number() <= c.target) revert TooEarly();
        if (!_capture(id, msg.sender)) return;
        if (items().inventory(c.player) + n * 3 > items().capacity(c.player)) revert InsufficientBalance();
        c.mythic = farm().level(c.player) >= 10;
        uint256 first = c.opened * 3;
        c.opened += n;
        for (uint256 i; i < n * 3; ++i) {
            uint8 k;
            uint8 r;
            (k, r) = ItemMath.draw(keccak256(abi.encode(c.seed, first + i)), c.mythic, false);
            if (c.guaranteed && i % 3 == 0 && r < 1) r = 1;
            items().mint(c.player, k, r, false);
        }
        emit PackOpened(id, n, c.expired);
    }
}
