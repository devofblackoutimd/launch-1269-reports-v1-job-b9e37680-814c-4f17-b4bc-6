// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FarmItems} from "./FarmItems.sol";
import {FarmRewards} from "./FarmRewards.sol";
import {Params} from "./Params.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import {IPacks, IMarket, IGrid, IGenerator} from "./interfaces/Interfaces.sol";
import "./lib/Errors.sol";

contract FarmCore is ReentrancyGuard, IERC1155Receiver {
    using SafeERC20 for IERC20;
    uint256 public constant SOLO = 4;
    enum SpendKind {
        Upgrade,
        Repair,
        Electricity,
        Lobby,
        TokenPack
    }

    struct Farm {
        uint256[6][4] rooms;
        uint256[40] solo;
        uint256[4] keys;
        uint8[6][4] levels;
        uint8[40] soloLevels;
        uint256 itemCount;
        uint256 paidPacks;
        uint256 serial;
    }

    struct RoomStats {
        uint256 hash;
        uint256 powerHash;
        bool heatProof;
        bool shield;
        uint256 bonusBps;
    }
    FarmItems public immutable items;
    FarmRewards public immutable rewards;
    Params public immutable params;
    IPacks public immutable packs;
    address public immutable starter;
    IMarket public immutable market;
    IGrid public immutable grid;
    IGenerator public immutable generator;
    mapping(address => Farm) private farms;
    uint256 private nextSerial = 1;
    address private receivingFrom;
    event Registered(address indexed player, uint256 district);
    event Placed(address indexed player, uint256 indexed id, uint256 room, uint256 slot);
    event Unplaced(address indexed player, uint256 indexed id, uint256 room, uint256 slot);
    event RoomKey(address indexed player, uint256 room, uint256 id, bool installed);
    event Refreshed(address indexed player, uint256 hash, uint256 powerHash);
    event Spent(address indexed player, SpendKind kind, uint256 nominal);

    constructor(
        address items_,
        address rewards_,
        address params_,
        address packs_,
        address starter_,
        address market_,
        address grid_,
        address generator_
    ) {
        if (
            items_ == address(0) || rewards_ == address(0) || params_ == address(0) || packs_ == address(0)
                || starter_ == address(0) || market_ == address(0) || grid_ == address(0) || generator_ == address(0)
        ) revert InvalidAddress();
        items = FarmItems(items_);
        rewards = FarmRewards(rewards_);
        params = Params(params_);
        packs = IPacks(packs_);
        starter = starter_;
        market = IMarket(market_);
        grid = IGrid(grid_);
        generator = IGenerator(generator_);
    }

    function district(address player) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(player))) % 8;
    }

    function hasFarm(address player) external view returns (bool) {
        return farms[player].serial != 0;
    }

    function paidPacks(address player) external view returns (uint256) {
        return farms[player].paidPacks;
    }

    function itemAt(address player, uint256 room, uint256 slot) external view returns (uint256) {
        _checkSlot(room, slot);
        return room == SOLO ? farms[player].solo[slot] : farms[player].rooms[room][slot];
    }

    function keyAt(address player, uint256 room) external view returns (uint256) {
        if (room >= 4) revert InvalidValue();
        return farms[player].keys[room];
    }

    function register(address player) external {
        if (msg.sender != address(packs) && msg.sender != starter && msg.sender != player) revert Unauthorized();
        _register(player);
    }

    function _register(address player) private {
        if (player == address(0)) revert InvalidAddress();
        if (farms[player].serial != 0) return;
        farms[player].serial = nextSerial++;
        emit Registered(player, district(player));
    }

    function setReferrer(address inviter) external {
        _register(msg.sender);
        if (farms[inviter].serial == 0 || farms[inviter].serial >= farms[msg.sender].serial) revert InvalidValue();
        rewards.setReferrer(msg.sender, inviter);
    }

    function paidPackOpened(address player, uint256 count) external nonReentrant {
        if (msg.sender != address(packs)) revert Unauthorized();
        farms[player].paidPacks += count;
        _refresh(player);
    }

    function _checkSlot(uint256 room, uint256 slot) private pure {
        if (room > SOLO || (room == SOLO ? slot >= 40 : slot >= 6)) revert InvalidValue();
    }

    function place(uint256 id, uint256 room, uint256 slot) external nonReentrant {
        _checkSlot(room, slot);
        _register(msg.sender);
        (uint256 kind,,,) = ItemMath.decode(id);
        if (kind == 6) revert InvalidValue();
        Farm storage f = farms[msg.sender];
        if (f.itemCount >= 40) revert InvalidValue();
        if (room == SOLO) {
            if (f.solo[slot] != 0) revert AlreadyDone();
            f.solo[slot] = id;
        } else {
            if (room != 0 && f.keys[room] == 0) revert InvalidValue();
            if (kind != slot || f.rooms[room][slot] != 0) revert InvalidValue();
            f.rooms[room][slot] = id;
        }
        ++f.itemCount;
        _refresh(msg.sender);
        receivingFrom = msg.sender;
        items.safeTransferFrom(msg.sender, address(this), id, 1, "");
        receivingFrom = address(0);
        emit Placed(msg.sender, id, room, slot);
    }

    function unplace(uint256 room, uint256 slot) external nonReentrant {
        _checkSlot(room, slot);
        Farm storage f = farms[msg.sender];
        uint256 id;
        if (room == SOLO) {
            id = f.solo[slot];
            delete f.solo[slot];
            delete f.soloLevels[slot];
        } else {
            id = f.rooms[room][slot];
            delete f.rooms[room][slot];
            delete f.levels[room][slot];
        }
        if (id == 0) revert InvalidValue();
        --f.itemCount;
        _refresh(msg.sender);
        items.safeTransferFrom(address(this), msg.sender, id, 1, "");
        emit Unplaced(msg.sender, id, room, slot);
    }

    function installRoom(uint256 room, uint256 id) external nonReentrant {
        if (room == 0 || room >= 4) revert InvalidValue();
        (uint256 kind,,,) = ItemMath.decode(id);
        if (kind != 6) revert InvalidValue();
        _register(msg.sender);
        Farm storage f = farms[msg.sender];
        if (f.keys[room] != 0) revert AlreadyDone();
        f.keys[room] = id;
        receivingFrom = msg.sender;
        items.safeTransferFrom(msg.sender, address(this), id, 1, "");
        receivingFrom = address(0);
        emit RoomKey(msg.sender, room, id, true);
    }

    function removeRoom(uint256 room) external nonReentrant {
        if (room == 0 || room >= 4) revert InvalidValue();
        Farm storage f = farms[msg.sender];
        uint256 id = f.keys[room];
        if (id == 0) revert InvalidValue();
        for (uint256 i; i < 6; ++i) {
            if (f.rooms[room][i] != 0) revert InvalidValue();
        }
        delete f.keys[room];
        items.safeTransferFrom(address(this), msg.sender, id, 1, "");
        emit RoomKey(msg.sender, room, id, false);
    }

    function itemHash(address player, uint256 id, uint256 level) public view returns (uint256 h) {
        (uint256 kind, uint256 rarity,, bool isStarter) = ItemMath.decode(id);
        if (kind == 6) return 0;
        uint256 epochBonus = ItemMath.epochBonus(id);
        h = ItemMath.baseHash(rarity) * (10000 + epochBonus) / 10000 * (10 + level) / 10;
        if (isStarter && farms[player].paidPacks == 0) h /= 2;
    }

    function roomStats(address player, uint256 room) public view returns (RoomStats memory s) {
        if (room >= 4) revert InvalidValue();
        Farm storage f = farms[player];
        uint256 count;
        uint256[4] memory rarities;
        for (uint256 i; i < 6; ++i) {
            uint256 id = f.rooms[room][i];
            if (id == 0) continue;
            ++count;
            (, uint256 r,,) = ItemMath.decode(id);
            ++rarities[r];
            s.hash += itemHash(player, id, f.levels[room][i]);
            if (i == 3 && r >= 1) s.heatProof = true;
        }
        if (count == 6) s.bonusBps = params.get(Params.Key.FullSetBps);
        if (f.rooms[room][0] != 0 && f.rooms[room][1] != 0) s.bonusBps += params.get(Params.Key.ComputePairBps);
        // At most one rarity bonus: use the highest qualifying rarity, never stack two triples.
        if (rarities[3] >= 3) s.bonusBps += params.get(Params.Key.LegendarySetBps);
        else if (rarities[2] >= 3) s.bonusBps += params.get(Params.Key.EpicSetBps);
        else if (rarities[1] >= 3) s.bonusBps += params.get(Params.Key.RareSetBps);
        s.bonusBps = Math.min(s.bonusBps, params.get(Params.Key.SetCapBps));
        s.hash = s.hash * (10000 + s.bonusBps) / 10000;
        uint256 saving = f.rooms[room][2] != 0 && f.rooms[room][3] != 0 ? params.get(Params.Key.ElectricityPairBps) : 0;
        s.powerHash = s.hash * (10000 - saving) / 10000;
        s.shield = f.rooms[room][4] != 0 && f.rooms[room][5] != 0;
    }

    function refresh(address player) external nonReentrant {
        _refresh(player);
    }

    function _refresh(address player) private {
        Farm storage f = farms[player];
        if (f.serial == 0) return;
        if (!rewards.checkpoint(64)) revert CatchUpRequired();
        uint8[5] memory buckets;
        uint256[5] memory hashes;
        uint256[5] memory powers;
        uint256 raw;
        uint256 power;
        for (uint256 room; room < 4; ++room) {
            RoomStats memory s = roomStats(player, room);
            hashes[room] = s.hash;
            powers[room] = s.powerHash;
            raw += s.hash;
            buckets[room] = uint8(district(player) * 16 + (s.heatProof ? 4 : 0) + (s.shield ? 2 : 0));
        }
        for (uint256 slot; slot < 40; ++slot) {
            if (f.solo[slot] != 0) hashes[4] += itemHash(player, f.solo[slot], f.soloLevels[slot]);
        }
        powers[4] = hashes[4];
        raw += hashes[4];
        buckets[4] = uint8(district(player) * 16);
        uint256 required = Math.mulDiv(raw, rewards.rpsEMA(), 1e18) * params.get(Params.Key.TariffBps) / 10000;
        bool protected = required != 0 && generator.locked(player) >= required;
        // A fixed point solves the self-inclusive soft cap against other farms at refresh time.
        uint256 others = rewards.totalHash() - rewards.accountHash(player);
        uint256 capBps = params.get(Params.Key.SoftCapBps);
        uint256 cap = Math.mulDiv(others, capBps, 10000 - capBps);
        uint256 effective = raw <= cap ? raw : (raw * 10000 + others * capBps) / (20000 - capBps);
        if (rewards.initialized(player) && rewards.durability(player) == 0) effective = 0;
        for (uint256 i; i < 5; ++i) {
            if (protected) buckets[i] += 1;
            if (effective >= 2000 ether) buckets[i] += 8;
            if (raw != 0) {
                hashes[i] = Math.mulDiv(hashes[i], effective, raw);
                power += Math.mulDiv(powers[i], effective, raw);
            }
        }
        rewards.update(player, buckets, hashes, power);
        emit Refreshed(player, effective, power);
    }

    function rawHash(address player) public view returns (uint256 raw) {
        for (uint256 room; room < 4; ++room) {
            raw += roomStats(player, room).hash;
        }
        Farm storage f = farms[player];
        for (uint256 slot; slot < 40; ++slot) {
            if (f.solo[slot] != 0) raw += itemHash(player, f.solo[slot], f.soloLevels[slot]);
        }
    }

    function generatorRequirement(address player) external view returns (uint256) {
        return Math.mulDiv(rawHash(player), rewards.rpsEMA(), 1e18) * params.get(Params.Key.TariffBps) / 10000;
    }

    function payMaintenance(bool repair_, uint256 units) external nonReentrant {
        if (!rewards.checkpoint(64) || !rewards.settle(msg.sender, 64)) revert CatchUpRequired();
        uint256 cost = units;
        if (repair_) {
            if (units == 0 || units > 100 || rewards.durability(msg.sender) + units * 1 ether > 100 ether) {
                revert InvalidValue();
            }
            cost = Math.mulDiv(rawHash(msg.sender), rewards.rpsEMA(), 1e18) * units * params.get(Params.Key.RepairBps)
                / 10000;
        }
        if (cost == 0) revert InvalidValue();
        IERC20 token = rewards.pool().token();
        address burn = rewards.burnVault();
        uint256 beforeBalance = token.balanceOf(burn);
        token.safeTransferFrom(msg.sender, burn, cost);
        if (token.balanceOf(burn) - beforeBalance != cost) revert InvalidValue();
        rewards.recordWalletSpend(msg.sender, cost);
        if (repair_) rewards.repair(msg.sender, units);
        else rewards.prepay(msg.sender, cost);
        _refresh(msg.sender);
    }

    function chargeMerge(address player, uint256 resultId) external nonReentrant {
        if (msg.sender != address(packs)) revert Unauthorized();
        if (!rewards.checkpoint(64) || !rewards.settle(player, 64)) revert CatchUpRequired();
        uint256 cost = Math.mulDiv(itemHash(player, resultId, 0), rewards.rpsEMA(), 1e18) * 2;
        if (cost == 0) revert InvalidValue();
        rewards.spend(player, cost, 0);
    }

    function spend(SpendKind kind, uint256 room, uint256 slot, uint256 units) external nonReentrant {
        if (!rewards.checkpoint(64) || !rewards.settle(msg.sender, 64)) revert CatchUpRequired();
        Farm storage f = farms[msg.sender];
        uint256 nominal;
        if (kind == SpendKind.Upgrade) {
            _checkSlot(room, slot);
            uint256 id = room == SOLO ? f.solo[slot] : f.rooms[room][slot];
            uint256 level = room == SOLO ? f.soloLevels[slot] : f.levels[room][slot];
            if (id == 0 || level >= 5 || units != 1) revert InvalidValue();
            nominal = Math.mulDiv(itemHash(msg.sender, id, 0), rewards.rpsEMA(), 1e18) * 15 / 10;
            for (uint256 i; i < level; ++i) {
                nominal = nominal * 14 / 10;
            }
            if (room == SOLO) ++f.soloLevels[slot];
            else ++f.levels[room][slot];
        } else if (kind == SpendKind.Repair) {
            if (units == 0 || units > 100 || rewards.durability(msg.sender) + units * 1 ether > 100 ether) {
                revert InvalidValue();
            }
            nominal = Math.mulDiv(rawHash(msg.sender), rewards.rpsEMA(), 1e18) * units
                * params.get(Params.Key.RepairBps) / 10000;
        } else if (kind == SpendKind.TokenPack) {
            if (units != 1) revert InvalidValue();
            nominal = market.quote(packs.price());
        } else {
            nominal = units;
        }
        if (nominal == 0) revert InvalidValue();
        rewards.spend(msg.sender, nominal, kind == SpendKind.TokenPack ? params.get(Params.Key.TokenRecycleBps) : 0);
        if (kind == SpendKind.Repair) rewards.repair(msg.sender, units);
        if (kind == SpendKind.Electricity) rewards.prepay(msg.sender, nominal);
        if (kind == SpendKind.Lobby) {
            uint256 tokensPerETH = market.quote(1 ether);
            if (tokensPerETH == 0) revert InvalidValue();
            grid.tokenLobby(msg.sender, Math.mulDiv(nominal, 1 ether, tokensPerETH));
        }
        if (kind == SpendKind.TokenPack) packs.tokenPack(msg.sender);
        _refresh(msg.sender);
        emit Spent(msg.sender, kind, nominal);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId || id == 0x01ffc9a7;
    }

    function onERC1155Received(address operator, address from, uint256, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(items) || operator != address(this) || from != receivingFrom || from == address(0)) {
            revert Unauthorized();
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert Unauthorized();
    }
}
