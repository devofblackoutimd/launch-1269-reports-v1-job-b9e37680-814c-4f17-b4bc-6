// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FarmItems} from "./FarmItems.sol";
import {Params} from "./Params.sol";
import {FeeRouter} from "./FeeRouter.sol";
import {IFarm} from "./interfaces/Interfaces.sol";
import {ChainClock} from "./lib/ChainClock.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import "./lib/Errors.sol";

contract PackSale is ReentrancyGuard {
    struct Commit {
        address player;
        uint64 target;
        uint8 count;
        uint8 epoch;
        uint16 bonusBps;
        bool resolved;
    }

    struct Hour {
        uint64 number;
        uint192 count;
    }
    FarmItems public immutable items;
    Params public immutable params;
    FeeRouter public immutable fees;
    IFarm public immutable farm;
    address public immutable swarmWallet;
    uint256 public immutable launchTime;
    uint256 public nextId = 1;
    uint256 public pausedUntil;
    uint256 public pauseAgainAfter;
    mapping(uint256 => Commit) public commits;
    mapping(address => uint64[20]) private boughtAt;
    mapping(address => uint256) private walletCursor;
    mapping(address => uint256) public tokenPackAt;
    Hour[25] private hourBuckets;
    event PackCommitted(uint256 indexed id, address indexed player, uint256 count, uint256 target, uint256 epoch);
    event PackResolved(uint256 indexed id, bool expired, uint256[] items);
    event Merged(address indexed player, uint256 sourceId, uint256 resultId);
    event PausedUntil(uint256 until);

    constructor(address items_, address params_, address fees_, address farm_, address swarm_, uint256 launch_) {
        if (
            items_ == address(0) || params_ == address(0) || fees_ == address(0) || farm_ == address(0)
                || swarm_ == address(0) || launch_ == 0
        ) revert InvalidValue();
        items = FarmItems(items_);
        params = Params(params_);
        fees = FeeRouter(payable(fees_));
        farm = IFarm(farm_);
        swarmWallet = swarm_;
        launchTime = launch_;
    }

    function paused() public view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    function pause(uint256 duration) external {
        if (msg.sender != swarmWallet) revert Unauthorized();
        if (duration == 0) {
            pausedUntil = 0;
            emit PausedUntil(0);
            return;
        }
        if (duration > 72 hours) revert InvalidValue();
        if (paused() || block.timestamp < pauseAgainAfter) revert TooEarly();
        pausedUntil = block.timestamp + duration;
        pauseAgainAfter = pausedUntil + 24 hours;
        emit PausedUntil(pausedUntil);
    }

    function walletCap() public view returns (uint256) {
        if (block.timestamp < launchTime) return 0;
        uint256 t = block.timestamp - launchTime;
        return t < 12 hours ? 3 : t < 24 hours ? 6 : t < 48 hours ? 10 : 20;
    }

    function globalCap() public view returns (uint256) {
        if (block.timestamp < launchTime) return 0;
        uint256 t = block.timestamp - launchTime;
        return t < 6 hours ? 75 : t < 24 hours ? 150 : t < 48 hours ? 300 : type(uint256).max;
    }

    function walletPacks24h(address player) public view returns (uint256 n) {
        for (uint256 i; i < 20; ++i) {
            if (boughtAt[player][i] != 0 && block.timestamp < uint256(boughtAt[player][i]) + 1 days) ++n;
        }
    }

    function packs24h() public view returns (uint256 n) {
        uint256 hour = block.timestamp / 1 hours;
        for (uint256 i; i < 25; ++i) {
            if (hourBuckets[i].number + 24 >= hour) n += hourBuckets[i].count;
        }
    }

    function epoch() public view returns (uint256 e) {
        if (block.timestamp < launchTime) return 0;
        e = (block.timestamp - launchTime) / 7 days;
        if (e > 4) e = 4;
    }

    function price() public view returns (uint256 p) {
        p = 0.01 ether;
        uint256 step = params.get(Params.Key.PriceStepBps);
        // Epoch price decline continues to the floor, with a bounded iteration count.
        uint256 e = block.timestamp < launchTime ? 0 : (block.timestamp - launchTime) / 7 days;
        if (e > 128) e = 128;
        for (uint256 i; i < e; ++i) {
            p = p * (10000 - step) / 10000;
        }
        uint256 floor = params.get(Params.Key.PriceFloor);
        if (p < floor) p = floor;
        uint256 count = packs24h();
        uint256 target = params.get(Params.Key.DemandTarget);
        if (count > target) {
            uint256 premium = (count - target) * 5000 / target;
            uint256 cap = params.get(Params.Key.PremiumBps);
            if (premium > cap) premium = cap;
            p = p * (10000 + premium) / 10000;
        }
    }

    function openPack(uint256 count) external payable nonReentrant returns (uint256 id) {
        if (msg.value != price() * count) revert InvalidValue();
        id = _commit(msg.sender, count);
        fees.depositPack{value: msg.value}();
    }

    function tokenPack(address player) external nonReentrant returns (uint256 id) {
        if (msg.sender != address(farm)) revert Unauthorized();
        if (tokenPackAt[player] != 0 && block.timestamp < tokenPackAt[player] + 1 days) revert TooEarly();
        tokenPackAt[player] = block.timestamp;
        id = _commit(player, 1);
    }

    function _commit(address player, uint256 count) private returns (uint256 id) {
        if (block.timestamp < launchTime || paused()) revert TooEarly();
        if (count == 0 || count > 20 || walletPacks24h(player) + count > walletCap()) revert InvalidValue();
        uint256 hour = block.timestamp / 1 hours;
        Hour storage h = hourBuckets[hour % 25];
        if (h.number != hour) {
            h.number = uint64(hour);
            h.count = 0;
        }
        if (uint256(h.count) + count > globalCap()) revert InvalidValue();
        h.count += uint192(count);
        for (uint256 i; i < count; ++i) {
            boughtAt[player][walletCursor[player]++ % 20] = uint64(block.timestamp);
        }
        farm.register(player);
        id = nextId++;
        uint256 target = ChainClock.number() + 2;
        commits[id] = Commit(
            player,
            uint64(target),
            uint8(count),
            uint8(epoch()),
            uint16(
                epoch() * params.get(Params.Key.EpochHashBps) > 4000
                    ? 4000
                    : epoch() * params.get(Params.Key.EpochHashBps)
            ),
            false
        );
        emit PackCommitted(id, player, count, target, epoch());
    }

    function merge(uint256 id) external nonReentrant returns (uint256 resultId) {
        (uint256 kind, uint256 rarity, uint256 mintEpoch, bool starter) = ItemMath.decode(id);
        if (kind == 6 || rarity == 3 || starter) revert InvalidValue();
        resultId = ItemMath.withBonus(ItemMath.encode(kind, rarity + 1, mintEpoch, false), ItemMath.epochBonus(id));
        farm.chargeMerge(msg.sender, resultId);
        items.burnForMerge(msg.sender, id);
        items.mint(msg.sender, resultId);
        emit Merged(msg.sender, id, resultId);
    }

    function resolve(uint256 id) external nonReentrant {
        Commit storage c = commits[id];
        if (c.player == address(0)) revert InvalidValue();
        if (c.resolved) revert AlreadyDone();
        if (ChainClock.number() <= c.target) revert TooEarly();
        bytes32 h = ChainClock.hash(c.target);
        bool expired = h == bytes32(0);
        c.resolved = true;
        uint256[] memory ids = new uint256[](uint256(c.count) * 3);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = expired
                ? ItemMath.encode(0, 0, c.epoch, false)
                : ItemMath.draw(keccak256(abi.encode(h, address(this), id, i)), c.epoch, false, false);
            ids[i] = ItemMath.withBonus(ids[i], c.bonusBps);
            items.mint(c.player, ids[i]);
        }
        farm.paidPackOpened(c.player, c.count);
        emit PackResolved(id, expired, ids);
    }
}
