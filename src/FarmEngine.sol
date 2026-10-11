// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FarmItems} from "./FarmItems.sol";
import {Params} from "./Params.sol";
import {GridOperator} from "./GridOperator.sol";
import {IRewards} from "./interfaces/IGame.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import "./lib/Errors.sol";

/// @notice Immutable room/event calculator. Only Core may apply damage; no delegatecall or upgrades.
contract FarmEngine {
    struct Snapshot {
        uint256[24] ids;
        uint8[24] clocks;
        uint16[24] health;
        bool paid;
        uint64 theftUntil;
        uint16 routerRepairBps;
    }

    struct RoomStats {
        uint256 raw;
        uint256 productive;
        uint256 power;
        uint256 bonus;
        bool cooling;
        bool cold;
        bool offgrid;
        bool clean;
        bool locked;
        bool airflow;
    }
    FarmItems public immutable items;
    Params public immutable params;
    IRewards public immutable rewards;
    GridOperator public immutable grid;
    address public immutable core;

    constructor(address items_, address params_, address rewards_, address grid_, address core_) {
        if (
            items_ == address(0) || params_ == address(0) || rewards_ == address(0) || grid_ == address(0)
                || core_ == address(0)
        ) {
            revert InvalidAddress();
        }
        items = FarmItems(items_);
        params = Params(params_);
        rewards = IRewards(rewards_);
        grid = GridOperator(grid_);
        core = core_;
    }

    function _param(Params.Key k, bool active, uint256 e) private view returns (uint256) {
        return active ? rewards.epochParam(e, uint256(k)) : params.get(k);
    }

    function stats(Snapshot memory f, uint256 room, bool active, uint256 e) public view returns (RoomStats memory s) {
        s = _stats(f, room, active, e);
        // Repair restores only the remaining fraction of this epoch, including Router combos.
        if (e < f.theftUntil && f.routerRepairBps != 0 && !s.locked) {
            uint64 saved = f.theftUntil;
            f.theftUntil = 0;
            RoomStats memory restored = _stats(f, room, active, e);
            f.theftUntil = saved;
            uint256 fraction = f.routerRepairBps;
            s.raw = (s.raw * (10000 - fraction) + restored.raw * fraction) / 10000;
            s.productive = (s.productive * (10000 - fraction) + restored.productive * fraction) / 10000;
            s.power = (s.power * (10000 - fraction) + restored.power * fraction) / 10000;
            s.bonus = (s.bonus * (10000 - fraction) + restored.bonus * fraction) / 10000;
        }
    }

    function _stats(Snapshot memory f, uint256 room, bool active, uint256 e) private view returns (RoomStats memory s) {
        if (room >= 4) revert InvalidValue();
        uint256 mask;
        uint256 tags;
        uint256[5] memory rarity;
        for (uint256 i; i < 6; ++i) {
            uint256 id = f.ids[room * 6 + i];
            if (id == 0) continue;
            FarmItems.Item memory x = items.data(id);
            if (x.holder != address(0)) mask |= 1 << x.kind;
        }
        s.cooling = mask & ((1 << 6) | (1 << 7)) != 0;
        s.airflow = mask & (1 << 6) != 0 && mask & (1 << 10) != 0;
        s.cold = mask & (1 << 3) != 0 && mask & (1 << 7) != 0;
        s.offgrid = mask & (1 << 4) != 0 && mask & (1 << 5) != 0;
        s.clean = mask & (1 << 11) != 0 && mask & (1 << 3) != 0;
        s.locked = mask & (1 << 8) != 0 && mask & (1 << 10) != 0;
        for (uint256 i; i < 6; ++i) {
            uint256 idx = room * 6 + i;
            uint256 id = f.ids[idx];
            if (id == 0) continue;
            FarmItems.Item memory x = items.data(id);
            if (x.holder == address(0)) continue;
            if (x.kind == 8 && e < f.theftUntil && !s.locked) continue;
            tags |= 1 << ItemMath.tag(x.kind);
            rarity[x.rarity]++;
            uint256 raw = ItemMath.baseHash(x.rarity) * (x.kind < 3 ? 10000 : 6000) / 10000;
            raw = raw * (10 + f.clocks[idx]) / 10;
            if (!f.paid) raw /= 2;
            if (f.health[idx] == 0) continue;
            s.raw += raw;
            s.productive += raw * f.health[idx] / 10000;
        }
        if (mask & 3 == 3) {
            s.bonus += _param(mask & 7 == 7 ? Params.Key.TripleCoreBps : Params.Key.ComputePairBps, active, e);
        }
        if (tags == 31) s.bonus += _param(Params.Key.FullSetBps, active, e);
        if (s.airflow) s.bonus += _param(Params.Key.AirflowBps, active, e);
        if (rarity[4] >= 3) s.bonus += _param(Params.Key.MythicSetBps, active, e);
        else if (rarity[3] >= 3) s.bonus += _param(Params.Key.LegendarySetBps, active, e);
        else if (rarity[2] >= 3) s.bonus += _param(Params.Key.EpicSetBps, active, e);
        else if (rarity[1] >= 3) s.bonus += _param(Params.Key.RareSetBps, active, e);
        s.bonus = Math.min(s.bonus, _param(Params.Key.SetCapBps, active, e));
        s.raw = s.raw * (10000 + s.bonus) / 10000;
        s.productive = s.productive * (10000 + s.bonus) / 10000;
        uint256 saving = (s.cold ? _param(Params.Key.ElectricityPairBps, active, e) : 0)
            + (s.offgrid ? _param(Params.Key.OffgridBps, active, e) : 0);
        s.power = s.productive * (10000 - saving) / 10000;
    }

    function process(address p, uint256 e, Snapshot memory f)
        external
        returns (uint256 raw, uint256 productive, uint256 power, uint64 theftUntil)
    {
        if (msg.sender != core) revert Unauthorized();
        (GridOperator.Kind kind, uint16 severity, uint8 d, bytes32 seed, bool resolved) = grid.eventAt(e);
        if (!resolved) revert TooEarly();
        uint256 random = uint256(keccak256(abi.encode(seed, p)));
        bool local = uint256(keccak256(abi.encodePacked(p))) % 8 == d;
        bool outage = local && kind == GridOperator.Kind.Outage && random % 10000 < 3000 * uint256(severity) / 10000;
        bool surge = local && kind == GridOperator.Kind.Surge && random % 10000 < 1000 * uint256(severity) / 10000;
        bool theft = local && kind == GridOperator.Kind.Theft && random % 10000 < 2000 * uint256(severity) / 10000;
        uint256 occupied;
        for (uint256 i; i < 24; ++i) {
            if (f.ids[i] != 0) occupied++;
        }
        uint256 target = occupied == 0 ? type(uint256).max : (random >> 64) % occupied;
        uint256 cursor;
        RoomStats[4] memory baseline;
        for (uint256 r; r < 4; ++r) {
            baseline[r] = stats(f, r, true, e);
        }
        for (uint256 r; r < 4; ++r) {
            RoomStats memory before_ = baseline[r];
            raw += before_.raw;
            if (theft && !before_.locked) {
                f.theftUntil = uint64(e + 2);
                f.routerRepairBps = 0;
            }
            for (uint256 i; i < 6; ++i) {
                uint256 idx = r * 6 + i;
                uint256 id = f.ids[idx];
                if (id == 0) continue;
                FarmItems.Item memory x = items.data(id);
                if (x.holder == address(0)) continue;
                uint256 damage;
                if (surge && cursor == target && !before_.clean) {
                    if ((random >> 128) % 100 < 2 && x.rarity < 3) {
                        items.destroy(id);
                        f.ids[idx] = 0;
                        cursor++;
                        continue;
                    }
                    damage = 5000;
                }
                if (local && kind == GridOperator.Kind.Fire && !before_.cold) {
                    damage += 3000 * uint256(severity) / 10000 / (before_.airflow ? 2 : 1);
                }
                f.health[idx] = uint16(f.health[idx] > damage ? f.health[idx] - damage : 0);
                items.maintain(id, uint16(x.durability > damage ? x.durability - damage : 0), x.overclock);
                cursor++;
            }
            RoomStats memory s = stats(f, r, true, e);
            if (outage) {
                s.productive = s.offgrid ? s.productive / 2 : 0;
                s.power = s.offgrid ? s.power / 2 : 0;
            }
            if (local && kind == GridOperator.Kind.Fire && !s.cooling) {
                s.productive = 0;
                s.power = 0;
            }
            if (local && kind == GridOperator.Kind.Green) {
                s.productive = s.productive * (10000 + uint256(severity) / 10) / 10000;
                s.power = s.power * (10000 + uint256(severity) / 10) / 10000;
            }
            productive += s.productive;
            power += s.power;
            for (uint256 i; i < 6; ++i) {
                uint256 id = f.ids[r * 6 + i];
                if (id == 0) continue;
                FarmItems.Item memory x = items.data(id);
                items.maintain(id, x.durability > 50 ? x.durability - 50 : 0, x.overclock);
            }
        }
        theftUntil = f.theftUntil;
    }
}
