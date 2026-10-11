// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FarmEngine} from "./FarmEngine.sol";
import {FarmItems} from "./FarmItems.sol";
import {Params} from "./Params.sol";
import {GridOperator} from "./GridOperator.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import {IMarket} from "./interfaces/Interfaces.sol";
import {IRewards, ISeason} from "./interfaces/IGame.sol";
import "./lib/Errors.sol";

interface ITokenPacks {
    function tokenPack(address p) external returns (uint256);
    function price() external view returns (uint256);
}

contract FarmCore is ReentrancyGuard, IERC1155Receiver {
    using SafeERC20 for IERC20;

    struct Farm {
        uint64 born;
        uint64 serial;
        uint64 activeEpoch;
        uint64 theftUntil;
        uint64 activeTheftUntil;
        uint64 cableRepairedEpoch;
        uint16 routerRepairBps;
        uint256 xp;
        uint256 paid;
        uint256[24] loadout;
        uint256[24] active;
        uint8[24] clocks;
        uint16[24] health;
        bool activePaid;
        uint256 drops;
    }
    FarmEngine public immutable engine;
    FarmItems public immutable items;
    IRewards public immutable rewards;
    Params public immutable params;
    address public immutable packs;
    address public immutable starter;
    IMarket public immutable market;
    GridOperator public immutable grid;
    ISeason public immutable season;
    IERC20 public immutable token;
    address public immutable pool;
    mapping(address => mapping(uint256 => bytes32)) private dropSeeds;
    mapping(address => Farm) private farms;
    address[] private players;
    mapping(address => uint256) private minerIndex;
    uint64 private nextSerial = 1;
    event Retired(address indexed player);
    event Registered(address indexed player, uint256 district);
    event Placed(address indexed player, uint256 indexed id, uint256 room, uint256 slot);
    event Unplaced(address indexed player, uint256 indexed id, uint256 room, uint256 slot);
    event Spent(address indexed player, uint8 kind, uint256 paid, uint256 nominal);
    event Merged(address indexed player, uint256 indexed result);
    event Scrapped(address indexed player, uint256 indexed id, uint256 earned);
    event Active(address indexed player, uint256 indexed epoch, uint256 gross, uint256 net);

    constructor(
        address items_,
        address rewards_,
        address params_,
        address packs_,
        address starter_,
        address market_,
        address grid_,
        address season_,
        address token_,
        address pool_,
        address engine_
    ) {
        if (
            items_ == address(0) || rewards_ == address(0) || params_ == address(0) || packs_ == address(0)
                || starter_ == address(0) || market_ == address(0) || grid_ == address(0) || season_ == address(0)
                || token_ == address(0) || pool_ == address(0) || engine_ == address(0)
        ) revert InvalidAddress();
        engine = FarmEngine(engine_);
        items = FarmItems(items_);
        rewards = IRewards(rewards_);
        params = Params(params_);
        packs = packs_;
        starter = starter_;
        market = IMarket(market_);
        grid = GridOperator(grid_);
        season = ISeason(season_);
        token = IERC20(token_);
        pool = pool_;
    }

    function count() external view returns (uint256) {
        return players.length;
    }

    function playerAt(uint256 i) external view returns (address) {
        return players[i];
    }

    function hasFarm(address p) external view returns (bool) {
        return farms[p].serial != 0;
    }

    function district(address p) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(p))) % 8;
    }

    function xp(address p) external view returns (uint256) {
        return farms[p].xp;
    }

    function paidPacks(address p) external view returns (uint256) {
        return farms[p].paid;
    }

    function level(address p) public view returns (uint256) {
        uint256 x = farms[p].xp;
        if (x >= 2800) return 10;
        if (x >= 2400) return 9;
        if (x >= 2000) return 8;
        if (x >= 1600) return 7;
        if (x >= 1200) return 6;
        if (x >= 800) return 5;
        if (x >= 600) return 4;
        if (x >= 400) return 3;
        if (x >= 100) return 2;
        return 1;
    }

    function roomUnlocked(address p, uint256 room) public view returns (bool) {
        if (room == 0) return true;
        if (room == 1) return farms[p].born != 0 && block.timestamp >= farms[p].born + 3 days;
        if (room == 2) return level(p) >= 7;
        return room == 3 && level(p) >= 10;
    }

    function rooms(address p) public view returns (uint256 n) {
        n = 1;
        if (roomUnlocked(p, 1)) ++n;
        if (roomUnlocked(p, 2)) ++n;
        if (roomUnlocked(p, 3)) ++n;
    }

    function register(address p) external {
        if (msg.sender != p && msg.sender != packs && msg.sender != starter) revert Unauthorized();
        _register(p);
    }

    function _register(address p) private {
        if (p == address(0)) revert InvalidAddress();
        Farm storage f = farms[p];
        if (f.serial != 0) return;
        f.born = uint64(block.timestamp);
        f.serial = nextSerial++;
        emit Registered(p, district(p));
    }

    function _prepare(address p) private {
        if (!rewards.ready() || !rewards.live()) revert TooEarly();
        _register(p);
        _roll(p, rewards.epoch());
    }

    function _roll(address p, uint256 e) private {
        Farm storage f = farms[p];
        if (f.activeEpoch >= e) return;
        f.active = f.loadout;
        f.activeEpoch = uint64(e);
        f.activePaid = f.paid != 0;
        f.activeTheftUntil = f.theftUntil;
        f.routerRepairBps = 0;
        for (uint256 i; i < 24; ++i) {
            if (f.active[i] == 0) continue;
            FarmItems.Item memory x = items.data(f.active[i]);
            f.clocks[i] = x.overclock;
            f.health[i] = x.durability;
        }
    }

    function paidPackBought(address p, uint256 n, uint256 ethValue) external nonReentrant {
        if (msg.sender != packs) revert Unauthorized();
        _prepare(p);
        farms[p].paid += n;
        farms[p].xp += 25 * n;
        rewards.recordSales(n);
        season.recordSpend(p, ethValue, true);
    }

    function setReferrer(address inviter) external {
        _register(msg.sender);
        if (farms[inviter].serial == 0 || farms[inviter].serial >= farms[msg.sender].serial) revert InvalidValue();
        rewards.setReferrer(msg.sender, inviter);
    }

    function itemAt(address p, uint256 room, uint256 slot) external view returns (uint256) {
        if (room >= 4 || slot >= 6) revert InvalidValue();
        return farms[p].loadout[room * 6 + slot];
    }

    function place(uint256 id, uint256 room, uint256 slot) external nonReentrant {
        _prepare(msg.sender);
        if (!roomUnlocked(msg.sender, room) || slot >= 6) revert InvalidValue();
        Farm storage f = farms[msg.sender];
        FarmItems.Item memory x = items.data(id);
        if (x.holder != msg.sender || x.equipped || f.loadout[room * 6 + slot] != 0) revert InvalidValue();
        uint256 lev = level(msg.sender);
        if ((x.rarity == 2 && lev < 3) || (x.rarity == 3 && lev < 5) || (x.rarity == 4 && lev < 10)) {
            revert InvalidValue();
        }
        for (uint256 i; i < 6; ++i) {
            uint256 old = f.loadout[room * 6 + i];
            if (old != 0 && items.data(old).kind == x.kind) revert InvalidValue();
        }
        if (minerIndex[msg.sender] == 0) {
            players.push(msg.sender);
            minerIndex[msg.sender] = players.length;
        }
        f.loadout[room * 6 + slot] = id;
        items.equip(msg.sender, id);
        emit Placed(msg.sender, id, room, slot);
    }

    function unplace(uint256 room, uint256 slot) external nonReentrant {
        _prepare(msg.sender);
        if (room >= 4 || slot >= 6) revert InvalidValue();
        Farm storage f = farms[msg.sender];
        uint256 id = f.loadout[room * 6 + slot];
        if (id == 0) revert InvalidValue();
        delete f.loadout[room * 6 + slot];
        items.unequip(msg.sender, id);
        emit Unplaced(msg.sender, id, room, slot);
    }

    /// @notice Remove an empty farm from future settlement rosters; past season entitlements remain.
    function retire(address p) external nonReentrant {
        _prepare(p);
        Farm storage f = farms[p];
        for (uint256 i; i < 24; ++i) {
            if (f.loadout[i] != 0 || f.active[i] != 0) revert InvalidValue();
        }
        uint256 index = minerIndex[p];
        if (index == 0) revert InvalidValue();
        address last = players[players.length - 1];
        players[index - 1] = last;
        minerIndex[last] = index;
        players.pop();
        delete minerIndex[p];
        emit Retired(p);
    }

    function _locked(address p, uint256 id) private view returns (bool) {
        Farm storage f = farms[p];
        for (uint256 i; i < 24; ++i) {
            if (f.active[i] == id) return true;
        }
        return false;
    }

    function _charge(address p, uint256 nominal, bool wallet, uint8 kind) private returns (uint256 paid) {
        if (nominal == 0 || IERC20Metadata(address(token)).decimals() != 18) revert InvalidValue();
        if (wallet) {
            paid = nominal;
            uint256 before_ = token.balanceOf(pool);
            token.safeTransferFrom(p, pool, paid);
            if (token.balanceOf(pool) - before_ != paid) revert InvalidValue();
        } else {
            paid = rewards.spend(p, nominal);
        }
        uint256 rate = market.quote(1 ether);
        if (rate == 0) revert NotConfigured();
        uint256 value = Math.mulDiv(paid, 1 ether, rate);
        farms[p].xp += value * 2500 / 1 ether;
        season.recordSpend(p, value, kind == 0 || kind == 3 || kind == 4);
        emit Spent(p, kind, paid, nominal);
    }

    function repair(uint256 id, bool wallet) external nonReentrant {
        _prepare(msg.sender);
        FarmItems.Item memory x = items.data(id);
        if (x.holder != msg.sender || x.durability == 10000) revert InvalidValue();
        uint256 price = (10000 - x.durability) * ItemMath.baseHash(x.rarity) * params.get(Params.Key.RepairBps)
            * 1 ether / 10_000_000;
        _charge(msg.sender, price, wallet, 0);
        items.maintain(id, 10000, x.overclock);
    }

    function repairCable(bool wallet) external nonReentrant {
        _prepare(msg.sender);
        Farm storage f = farms[msg.sender];
        if (f.theftUntil <= rewards.epoch()) revert InvalidValue();
        _charge(msg.sender, params.get(Params.Key.MergePrice), wallet, 0);
        f.theftUntil = 0;
        f.cableRepairedEpoch = uint64(rewards.epoch());
        f.routerRepairBps = uint16((rewards.epochEnd() - block.timestamp) * 10000 / 6 hours);
    }

    function overclock(uint256 id, bool wallet) external nonReentrant {
        _prepare(msg.sender);
        FarmItems.Item memory x = items.data(id);
        if (x.holder != msg.sender || x.overclock >= 5) revert InvalidValue();
        uint256 price = params.get(Params.Key.OverclockPrice) * (uint256(x.overclock) + 1);
        _charge(msg.sender, price, wallet, 1);
        items.maintain(id, x.durability, x.overclock + 1);
    }

    function expand(bool wallet) external nonReentrant {
        _prepare(msg.sender);
        uint256 n = items.expansions(msg.sender);
        uint256 price = params.get(Params.Key.ExpansionPrice) * (n + 1) * (n + 1);
        _charge(msg.sender, price, wallet, 2);
        items.expand(msg.sender);
    }

    function buyTokenPack(bool wallet) external nonReentrant returns (uint256 id) {
        _prepare(msg.sender);
        uint256 price = market.quote(ITokenPacks(packs).price()) * 9000 / 10000;
        _charge(msg.sender, price, wallet, 3);
        farms[msg.sender].paid++;
        farms[msg.sender].xp += 25;
        rewards.recordSales(1);
        id = ITokenPacks(packs).tokenPack(msg.sender);
    }

    function lobby(uint256 amount, bool wallet) external nonReentrant {
        _prepare(msg.sender);
        uint256 paid = _charge(msg.sender, amount, wallet, 4);
        grid.tokenLobby(msg.sender, Math.mulDiv(paid, 1 ether, market.quote(1 ether)));
    }

    function merge(uint256[3] calldata ids, bool wallet) external nonReentrant returns (uint256 result) {
        _prepare(msg.sender);
        FarmItems.Item memory x = items.data(ids[0]);
        if (x.rarity >= 3) revert InvalidValue();
        for (uint256 i; i < 3; ++i) {
            FarmItems.Item memory y = items.data(ids[i]);
            if (
                y.holder != msg.sender || y.equipped || _locked(msg.sender, ids[i]) || y.kind != x.kind
                    || y.rarity != x.rarity || y.starter != x.starter
            ) revert InvalidValue();
            for (uint256 j; j < i; ++j) {
                if (ids[i] == ids[j]) revert InvalidValue();
            }
        }
        _charge(msg.sender, params.get(Params.Key.MergePrice) * (uint256(x.rarity) + 1), wallet, 5);
        for (uint256 i; i < 3; ++i) {
            items.destroy(ids[i]);
        }
        // Starter status follows a merge; its mining discount is account-wide below.
        result = items.mint(msg.sender, x.kind, x.rarity + 1, false);
        emit Merged(msg.sender, result);
    }

    function scrap(uint256 id, uint256 minimum) external nonReentrant {
        _prepare(msg.sender);
        FarmItems.Item memory x = items.data(id);
        if (x.holder != msg.sender || x.equipped || _locked(msg.sender, id)) revert InvalidValue();
        uint256 hash = ItemMath.baseHash(x.rarity) * (x.kind < 3 ? 10000 : 6000) / 10000 * x.durability / 10000;
        if (farms[msg.sender].paid == 0) hash /= 2;
        items.destroy(id);
        uint256 earned = rewards.scrap(msg.sender, hash, minimum);
        emit Scrapped(msg.sender, id, earned);
    }

    function roomStats(address p, uint256 room) external view returns (FarmEngine.RoomStats memory) {
        if (room >= 4) revert InvalidValue();
        Farm storage f = farms[p];
        FarmEngine.Snapshot memory snap;
        snap.ids = f.loadout;
        snap.paid = f.paid != 0;
        snap.theftUntil = f.theftUntil;
        for (uint256 i; i < 24; ++i) {
            if (snap.ids[i] == 0) continue;
            FarmItems.Item memory x = items.data(snap.ids[i]);
            snap.clocks[i] = x.overclock;
            snap.health[i] = x.durability;
        }
        return engine.stats(snap, room, false, rewards.epoch());
    }

    function process(address p, uint256 e)
        external
        nonReentrant
        returns (uint256 raw, uint256 productive, uint256 power)
    {
        if (msg.sender != address(rewards)) revert Unauthorized();
        _roll(p, e);
        Farm storage f = farms[p];
        bool occupied;
        for (uint256 i; i < 24; ++i) {
            if (f.active[i] != 0) {
                occupied = true;
                break;
            }
        }
        if (!occupied) return (0, 0, 0);
        FarmEngine.Snapshot memory snap =
            FarmEngine.Snapshot(f.active, f.clocks, f.health, f.activePaid, f.activeTheftUntil, f.routerRepairBps);
        uint64 theftUntil;
        (raw, productive, power, theftUntil) = engine.process(p, e, snap);
        f.theftUntil = f.cableRepairedEpoch == e && theftUntil == f.activeTheftUntil ? 0 : theftUntil;
        for (uint256 i; i < 24; ++i) {
            uint256 id = f.active[i];
            if (id != 0 && items.data(id).holder == address(0)) _remove(f, id);
        }
    }

    function _remove(Farm storage f, uint256 id) private {
        for (uint256 i; i < 24; ++i) {
            if (f.loadout[i] == id) delete f.loadout[i];
            if (f.active[i] == id) delete f.active[i];
        }
    }

    function activity(address p, uint256 e, uint256 gross, uint256 net) external {
        if (msg.sender != address(rewards)) revert Unauthorized();
        farms[p].xp += 100;
        emit Active(p, e, gross, net);
    }

    function grantDrop(address p, bytes32 seed) external {
        if (msg.sender != address(rewards)) revert Unauthorized();
        dropSeeds[p][farms[p].drops++] = seed;
    }

    function drops(address p) external view returns (uint256) {
        return farms[p].drops;
    }

    function claimDrop() external nonReentrant returns (uint256 id) {
        Farm storage f = farms[msg.sender];
        if (f.drops == 0) revert InsufficientBalance();
        f.drops--;
        bytes32 seed = dropSeeds[msg.sender][f.drops];
        delete dropSeeds[msg.sender][f.drops];
        (uint8 k, uint8 r) = ItemMath.draw(seed, false, false);
        id = items.mint(msg.sender, k, r == 0 ? 0 : 1, false);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(items)) revert Unauthorized();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert Unauthorized();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId || id == 0x01ffc9a7;
    }
}
