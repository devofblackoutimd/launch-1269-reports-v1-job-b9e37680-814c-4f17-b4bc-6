// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Params} from "./Params.sol";
import {RewardPool} from "./RewardPool.sol";
import {IGrid, IFarm} from "./interfaces/Interfaces.sol";
import "./lib/Errors.sol";

/// @notice Bounded checkpointing and daily reward vintages; pool liabilities are reserved before credit.
contract FarmRewards is ReentrancyGuard {
    using Math for uint256;
    uint256 public constant ACC = 1e27;
    uint256 public constant TICK = 12 hours;
    uint256 public immutable launchTime;
    Params public immutable params;
    RewardPool public immutable pool;
    address public immutable core;
    address public immutable burnVault;
    IGrid public immutable grid;
    uint256 public lastCheckpoint;
    uint256 public totalHash;
    uint256[128] public bucketHash;
    uint256[128] public acc;
    uint256[128] public miningAcc;
    uint256 public powerAcc;
    mapping(uint256 => mapping(uint256 => uint256)) public dayAcc;
    mapping(uint256 => mapping(uint256 => uint256)) public dayMiningAcc;
    mapping(uint256 => uint256) public dayPower;
    uint256 public rpsEMA;
    uint256 public dayEmission;
    uint256 private tickPoolBudget;
    uint256 private tickPoolCap;
    uint256 private tickPoolUsed;
    uint256 private tickRedisBudget;
    uint256 private tickRedisUsed;
    bool private tickReady;
    uint256 public redistribution;
    uint256 private tickInspectionBps;

    struct Allocation {
        uint256 dt;
        uint256 tick;
        uint256 week;
        uint256 weighted;
        uint256 fresh;
        uint256 reused;
        uint256 mining;
        uint256 gross;
        uint256 referral;
        uint256 prize;
        uint256 auditBurn;
        uint256 miningAuditBurn;
    }

    struct Vintage {
        uint64 day;
        uint192 amount;
    }

    struct Account {
        uint8[5] buckets;
        uint256[5] hashes;
        uint256[5] debts;
        uint256[5] miningDebts;
        uint256 powerHash;
        uint256 powerDebt;
        uint256 cursor;
        uint256 durability;
        uint256 maintainedAt;
        uint256 upkeepDebt;
        uint256 powerCredit;
        uint256 matured;
        uint256 pending;
        Vintage[16] vintages;
        address referrer;
        bool referralClosed;
    }
    mapping(address => Account) private accounts;
    mapping(uint256 => uint256) public weekEmission;
    mapping(uint256 => uint256) public inspectionMinHashInWeek;
    mapping(uint256 => uint256) public weekPrize;
    mapping(address => mapping(uint256 => uint256)) public grossInWeek;
    mapping(address => mapping(uint256 => uint256)) public burnInWeek;
    mapping(address => mapping(uint256 => bool)) public eligibleInWeek;
    mapping(uint256 => address) public inspectionWinner;
    mapping(uint256 => uint256) public inspectionScore;
    mapping(uint256 => bool) public inspectionPaid;
    event Emission(uint256 indexed tick, uint256 gross, uint256 reserve);
    event Settled(address indexed player, uint256 gross, uint256 burned, uint256 net, uint256 day);
    event Claimed(address indexed player, uint256 amount, uint256 tax);
    event Spent(address indexed player, uint256 consumed, uint256 burned);
    event ReferrerSet(address indexed player, address indexed referrer);
    event InspectionCandidate(uint256 indexed week, address indexed player, uint256 score);
    event InspectionPaid(uint256 indexed week, address indexed winner, uint256 amount);

    constructor(address params_, address pool_, address core_, address burn_, address grid_, uint256 launch_) {
        if (
            params_ == address(0) || pool_ == address(0) || core_ == address(0) || burn_ == address(0)
                || grid_ == address(0) || launch_ == 0
        ) revert InvalidValue();
        params = Params(params_);
        pool = RewardPool(pool_);
        core = core_;
        burnVault = burn_;
        grid = IGrid(grid_);
        launchTime = launch_;
        lastCheckpoint = launch_;
    }
    modifier onlyCore() {
        if (msg.sender != core) revert Unauthorized();
        _;
    }

    function checkpoint(uint256 maxTicks) external nonReentrant returns (bool) {
        return _checkpoint(maxTicks);
    }

    function _checkpoint(uint256 maxTicks) private returns (bool) {
        if (maxTicks == 0 || maxTicks > 64) revert InvalidValue();
        if (block.timestamp <= lastCheckpoint) return true;
        for (uint256 step; step < maxTicks && lastCheckpoint < block.timestamp; ++step) {
            uint256 tick = (lastCheckpoint - launchTime) / TICK;
            uint256 week = (lastCheckpoint - launchTime) / 7 days;
            if (inspectionMinHashInWeek[week] == 0) {
                inspectionMinHashInWeek[week] = params.get(Params.Key.InspectionMinHash);
            }
            uint256 end = launchTime + (tick + 1) * TICK;
            if (end > block.timestamp) end = block.timestamp;
            if (!tickReady) {
                uint256 available = pool.available();
                tickInspectionBps = params.get(Params.Key.InspectionBps);
                uint256 wanted =
                    available * params.get(Params.Key.EmissionBps) * (10500 + tickInspectionBps) / 200_000_000;
                tickPoolCap = available * 500 / 20000;
                tickPoolUsed = 0;
                tickPoolBudget = Math.min(wanted, tickPoolCap);
                tickRedisBudget = redistribution;
                redistribution = 0;
                tickRedisUsed = 0;
                // An empty launch pool must begin earning once its first buyback arrives.
                tickReady = tickPoolBudget != 0 || tickRedisBudget != 0;
            }
            uint256 dt = end - lastCheckpoint;
            uint256 weighted;
            for (uint256 b; b < 128; ++b) {
                if (bucketHash[b] != 0) weighted += bucketHash[b] * grid.weight(b, lastCheckpoint) / 10000;
            }
            if (weighted != 0) {
                Allocation memory a;
                a.dt = dt;
                a.tick = tick;
                a.week = week;
                a.weighted = weighted;
                _accrue(a);
            }
            lastCheckpoint = end;
            if (end == launchTime + (tick + 1) * TICK) {
                if (tickRedisBudget > tickRedisUsed) redistribution += tickRedisBudget - tickRedisUsed;
                tickReady = false;
                if ((tick + 1) % 2 == 0) {
                    uint256 day = tick / 2;
                    for (uint256 b; b < 128; ++b) {
                        dayAcc[day][b] = acc[b];
                        dayMiningAcc[day][b] = miningAcc[b];
                    }
                    dayPower[day] = powerAcc;
                    if (totalHash != 0) rpsEMA = rpsEMA * 7 / 10 + Math.mulDiv(dayEmission, 1e18, totalHash) * 3 / 10;
                    dayEmission = 0;
                }
            }
        }
        return lastCheckpoint >= block.timestamp;
    }

    function _accrue(Allocation memory a) private {
        a.fresh = Math.min(
            tickPoolCap - tickPoolUsed, tickPoolBudget * a.dt * grid.emissionBps(lastCheckpoint) / (TICK * 10000)
        );
        tickPoolUsed += a.fresh;
        a.reused = tickRedisBudget * a.dt / TICK;
        tickRedisUsed += a.reused;
        a.mining = a.fresh * 10000 / (10500 + tickInspectionBps);
        a.gross = a.mining + a.reused;
        a.referral = a.mining * 500 / 10000;
        a.prize = a.mining * tickInspectionBps / 10000;
        pool.reserve(a.fresh);
        if (a.fresh + a.reused > a.gross + a.referral + a.prize) {
            pool.recycle(a.fresh + a.reused - a.gross - a.referral - a.prize);
        }
        _distribute(a);
        if (rpsEMA == 0) rpsEMA = Math.mulDiv(a.gross, 1 days * 1e18, a.dt * totalHash);
        weekPrize[a.week] += a.prize;
        weekEmission[a.week] += a.mining;
        dayEmission += a.gross;
        powerAcc += Math.mulDiv(rpsEMA * 1e9, a.dt * params.get(Params.Key.TariffBps), 1 days * 10000);
        emit Emission(a.tick, a.gross, a.gross + a.referral + a.prize);
    }

    function _distribute(Allocation memory a) private {
        for (uint256 b; b < 128; ++b) {
            if (bucketHash[b] != 0) {
                uint256 weight_ = bucketHash[b] * grid.weight(b, lastCheckpoint);
                uint256 share = Math.mulDiv(a.gross, weight_, a.weighted * 10000);
                uint256 miningShare = Math.mulDiv(a.mining, weight_, a.weighted * 10000);
                uint256 penalty = 10000 - grid.rewardBps(b, lastCheckpoint);
                uint256 loss = share * penalty / 10000;
                uint256 miningLoss = miningShare * penalty / 10000;
                a.miningAuditBurn += miningLoss;
                a.auditBurn += loss;
                acc[b] += Math.mulDiv(share - loss, ACC, bucketHash[b]);
                miningAcc[b] += Math.mulDiv(miningShare - miningLoss, ACC, bucketHash[b]);
            }
        }
        if (a.auditBurn != 0) {
            pool.pay(burnVault, a.auditBurn);
            pool.recycle(a.miningAuditBurn * 500 / 10000);
        }
    }

    function settle(address player, uint256 maxDays) external nonReentrant returns (bool) {
        _checkpoint(64);
        return _settle(player, maxDays);
    }

    function _durability(Account storage a, uint256 at) private view returns (uint256) {
        if (at <= a.maintainedAt || a.hashes[0] + a.hashes[1] + a.hashes[2] + a.hashes[3] + a.hashes[4] == 0) {
            return a.durability;
        }
        uint256 loss = (at - a.maintainedAt) * 2 ether / 1 days;
        return loss >= a.durability ? 0 : a.durability - loss;
    }

    function initialized(address player) external view returns (bool) {
        return accounts[player].cursor != 0;
    }

    function durability(address player) external view returns (uint256) {
        return _durability(accounts[player], block.timestamp);
    }

    function pending(address player) external view returns (uint256) {
        return accounts[player].pending;
    }

    function upkeepDebt(address player) external view returns (uint256) {
        return accounts[player].upkeepDebt;
    }

    function referrer(address player) external view returns (address) {
        return accounts[player].referrer;
    }

    function accountHash(address player) public view returns (uint256 h) {
        for (uint256 i; i < 5; ++i) {
            h += accounts[player].hashes[i];
        }
    }

    function _settle(address player, uint256 maxDays) private returns (bool) {
        if (maxDays == 0 || maxDays > 64) revert InvalidValue();
        Account storage a = accounts[player];
        if (a.cursor == 0) return true;
        for (uint256 j; j < maxDays && a.cursor < lastCheckpoint; ++j) {
            uint256 day = (a.cursor - launchTime) / 1 days;
            uint256 dayEnd = launchTime + (day + 1) * 1 days;
            uint256 end = Math.min(dayEnd, lastCheckpoint);
            bool closed = end == dayEnd;
            uint256 gross;
            uint256 mining;
            for (uint256 i; i < 5; ++i) {
                uint256 index = closed ? dayAcc[day][a.buckets[i]] : acc[a.buckets[i]];
                gross += Math.mulDiv(a.hashes[i], index - a.debts[i], ACC);
                a.debts[i] = index;
                uint256 miningIndex = closed ? dayMiningAcc[day][a.buckets[i]] : miningAcc[a.buckets[i]];
                mining += Math.mulDiv(a.hashes[i], miningIndex - a.miningDebts[i], ACC);
                a.miningDebts[i] = miningIndex;
            }
            uint256 costIndex = closed ? dayPower[day] : powerAcc;
            uint256 power = Math.mulDiv(a.powerHash, costIndex - a.powerDebt, ACC);
            a.powerDebt = costIndex;
            uint256 prepaid = Math.min(power, a.powerCredit);
            a.powerCredit -= prepaid;
            power -= prepaid;
            uint256 average = (_durability(a, a.cursor) + _durability(a, end)) / 2;
            // The zero crossing uses exact area under linear durability, not endpoint averaging.
            uint256 startDur = _durability(a, a.cursor);
            if (startDur != 0 && _durability(a, end) == 0) {
                uint256 activeSeconds = startDur * 1 days / 2 ether;
                average = Math.mulDiv(startDur, activeSeconds, 2 * (end - a.cursor));
            }
            uint256 credited = Math.mulDiv(gross, average, 100 ether);
            uint256 burn = Math.min(credited, power + a.upkeepDebt);
            a.upkeepDebt = power + a.upkeepDebt - burn;
            uint256 net = credited - burn;
            uint256 referral = mining * 500 / 10000;
            uint256 earnedReferral = Math.mulDiv(mining, average, 100 ether) * 500 / 10000;
            if (a.referrer == address(0)) earnedReferral = 0;
            if (earnedReferral != 0) _credit(a.referrer, earnedReferral, day);
            uint256 recycle = gross - credited + referral - earnedReferral;
            if (recycle != 0) pool.recycle(recycle);
            if (burn != 0) pool.pay(burnVault, burn);
            if (net != 0) _credit(player, net, day);
            uint256 week = day / 7;
            grossInWeek[player][week] += credited;
            burnInWeek[player][week] += burn;
            if (accountHash(player) >= inspectionMinHashInWeek[week]) eligibleInWeek[player][week] = true;
            if (gross != 0) a.referralClosed = true;
            a.cursor = end;
            emit Settled(player, gross, burn, net, day);
        }
        return a.cursor >= lastCheckpoint;
    }

    function setReferrer(address player, address inviter) external onlyCore {
        Account storage a = accounts[player];
        if (a.referralClosed || a.referrer != address(0)) revert AlreadyDone();
        if (inviter == player || !IFarm(core).hasFarm(inviter)) revert InvalidValue();
        a.referrer = inviter;
        emit ReferrerSet(player, inviter);
    }

    function update(address player, uint8[5] calldata buckets, uint256[5] calldata hashes, uint256 powerHash)
        external
        onlyCore
        nonReentrant
    {
        if (!_checkpoint(64) || !_settle(player, 64)) revert CatchUpRequired();
        Account storage a = accounts[player];
        if (a.cursor == 0) {
            a.durability = 100 ether;
            a.maintainedAt = Math.max(block.timestamp, launchTime);
        } else {
            a.durability = _durability(a, block.timestamp);
            a.maintainedAt = block.timestamp;
        }
        for (uint256 i; i < 5; ++i) {
            bucketHash[a.buckets[i]] -= a.hashes[i];
            totalHash -= a.hashes[i];
            if (buckets[i] >= 128) revert InvalidValue();
            a.buckets[i] = buckets[i];
            a.hashes[i] = hashes[i];
            a.debts[i] = acc[buckets[i]];
            a.miningDebts[i] = miningAcc[buckets[i]];
            bucketHash[buckets[i]] += hashes[i];
            totalHash += hashes[i];
        }
        a.powerHash = powerHash;
        a.powerDebt = powerAcc;
        a.cursor = Math.max(block.timestamp, launchTime);
        if (hashes[0] + hashes[1] + hashes[2] + hashes[3] + hashes[4] != 0) a.referralClosed = true;
    }

    function _credit(address player, uint256 amount, uint256 day) private {
        if (amount > type(uint192).max) revert InvalidValue();
        Account storage a = accounts[player];
        a.pending += amount;
        uint256 current = block.timestamp < launchTime ? 0 : (block.timestamp - launchTime) / 1 days;
        if (day + 16 <= current) {
            a.matured += amount;
            return;
        }
        Vintage storage v = a.vintages[day % 16];
        if (v.amount != 0 && v.day != day) {
            a.matured += v.amount;
            v.amount = 0;
        }
        v.day = uint64(day);
        v.amount += uint192(amount);
    }

    function _consume(address player, uint256 amount, bool taxed) private returns (uint256 tax) {
        Account storage a = accounts[player];
        if (amount == 0 || amount > a.pending) revert InsufficientBalance();
        uint256 current = (block.timestamp - launchTime) / 1 days;
        for (uint256 i; i < 16; ++i) {
            Vintage storage v = a.vintages[i];
            if (uint256(v.day) + 16 <= current) {
                a.matured += v.amount;
                v.amount = 0;
            }
        }
        a.pending -= amount;
        uint256 used = Math.min(amount, a.matured);
        a.matured -= used;
        amount -= used;
        if (taxed) tax = used * params.get(Params.Key.TaxFloorBps) / 10000;
        uint256 first = current > 15 ? current - 15 : 0;
        for (uint256 day = first; day <= current && amount != 0; ++day) {
            Vintage storage v = a.vintages[day % 16];
            if (v.day != day) continue;
            used = Math.min(amount, v.amount);
            v.amount -= uint192(used);
            amount -= used;
            if (taxed) {
                uint256 vintageEnd = launchTime + (day + 1) * 1 days;
                uint256 age = block.timestamp > vintageEnd ? block.timestamp - vintageEnd : 0;
                tax += used * taxBps(age) / 10000;
            }
        }
        assert(amount == 0);
    }

    function taxBps(uint256 age) public view returns (uint256) {
        uint256 floor = params.get(Params.Key.TaxFloorBps);
        uint256 start = params.get(Params.Key.TaxDay0Bps);
        uint256 span = params.get(Params.Key.TaxDecaySeconds);
        if (age >= span) return floor;
        return start - (start - floor) * age / span;
    }

    function claim(uint256 amount) external nonReentrant returns (uint256 net) {
        _checkpoint(64);
        _settle(msg.sender, 64);
        uint256 tax = _consume(msg.sender, amount, true);
        redistribution += tax;
        net = amount - tax;
        pool.pay(msg.sender, net);
        emit Claimed(msg.sender, amount, tax);
    }

    function spend(address player, uint256 nominal, uint256 recycleBps)
        external
        onlyCore
        nonReentrant
        returns (uint256 consumed)
    {
        if (!_checkpoint(64) || !_settle(player, 64)) revert CatchUpRequired();
        if (recycleBps > 10000) revert InvalidValue();
        consumed = Math.mulDiv(nominal, 10000, 10000 + params.get(Params.Key.IngameBonusBps), Math.Rounding.Ceil);
        _consume(player, consumed, false);
        uint256 recycled = consumed * recycleBps / 10000;
        uint256 burned = consumed - recycled;
        if (recycled != 0) pool.recycle(recycled);
        if (burned != 0) pool.pay(burnVault, burned);
        burnInWeek[player][(block.timestamp - launchTime) / 7 days] += burned;
        emit Spent(player, consumed, burned);
    }

    function recordWalletSpend(address player, uint256 amount) external onlyCore {
        burnInWeek[player][(block.timestamp - launchTime) / 7 days] += amount;
        emit Spent(player, amount, amount);
    }

    function repair(address player, uint256 points) external onlyCore {
        Account storage a = accounts[player];
        uint256 d = _durability(a, block.timestamp);
        if (points == 0 || points > 100 || d + points * 1 ether > 100 ether) revert InvalidValue();
        a.durability = d + points * 1 ether;
        a.maintainedAt = block.timestamp;
    }

    function prepay(address player, uint256 amount) external onlyCore {
        Account storage a = accounts[player];
        uint256 debt = Math.min(a.upkeepDebt, amount);
        a.upkeepDebt -= debt;
        a.powerCredit += amount - debt;
    }

    function submitInspection(uint256 week, address player) external nonReentrant {
        uint256 end = launchTime + (week + 1) * 7 days;
        if (block.timestamp < end || block.timestamp >= end + 1 days) revert TooEarly();
        if (!_checkpoint(64) || !_settle(player, 64)) revert CatchUpRequired();
        uint256 gross = grossInWeek[player][week];
        if (gross == 0 || !eligibleInWeek[player][week]) revert InvalidValue();
        uint256 score = Math.mulDiv(burnInWeek[player][week], 1e18, gross);
        address winner = inspectionWinner[week];
        if (
            winner == address(0) || score > inspectionScore[week]
                || (score == inspectionScore[week] && uint160(player) < uint160(winner))
        ) {
            inspectionWinner[week] = player;
            inspectionScore[week] = score;
            emit InspectionCandidate(week, player, score);
        }
    }

    function finalizeInspection(uint256 week) external nonReentrant {
        if (block.timestamp < launchTime + (week + 1) * 7 days + 1 days) revert TooEarly();
        if (inspectionPaid[week]) revert AlreadyDone();
        if (!_checkpoint(64)) revert CatchUpRequired();
        inspectionPaid[week] = true;
        uint256 prize = weekPrize[week];
        address winner = inspectionWinner[week];
        if (winner == address(0)) {
            if (prize != 0) pool.recycle(prize);
        } else if (prize != 0) {
            _credit(winner, prize, (block.timestamp - launchTime) / 1 days);
        }
        emit InspectionPaid(week, winner, prize);
    }
}
