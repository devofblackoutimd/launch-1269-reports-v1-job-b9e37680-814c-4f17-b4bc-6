// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GameModule} from "./lib/GameModule.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Params} from "./Params.sol";
import {RewardPool} from "./RewardPool.sol";
import {FeeRouter} from "./FeeRouter.sol";
import {GridOperator} from "./GridOperator.sol";
import {ICore, ISeason} from "./interfaces/IGame.sol";
import "./lib/Errors.sol";

/// @notice Global epochs never visit farms. Anyone may settle one farm in bounded, unpaid batches.
contract FarmRewards is GameModule, ReentrancyGuard {
    uint256 public constant EPOCH = 6 hours;
    uint256 public constant MAX_SETTLE = 8;
    uint256 public constant PRECISION = 1e27;
    /// @notice A commitment stays in the global denominator for this many epochs after the last owner action.
    uint256 public constant IDLE_EPOCHS = 12;

    struct Epoch {
        uint64 start;
        uint64 end;
        uint256 raw; // Committed full-health allocation hash, fixed at epoch start.
        uint256 budget;
        uint256 mining;
        uint256 redis;
        uint256 spent;
        uint256 sales;
        uint256 target;
        uint256 tariff;
        uint256 emission;
        uint256 auditThreshold;
        uint256 rewardPerHash;
        uint256 accRewardPerHash;
        uint256 settledHash;
        uint256 allocated;
        uint256 scrap;
        GridOperator.Kind kind;
        uint16 severity;
        uint8 district;
        bytes32 seed;
    }

    struct Share {
        uint256 raw;
        uint256 productive;
        uint256 power;
        bool audit;
    }

    struct Vintage {
        uint64 epoch;
        uint64 at;
        uint256 amount;
    }

    struct Account {
        uint256 lastSettled;
        uint256 weight;
        uint256 nextWeight;
        uint256 weightEpoch;
        uint256 weightExpiry; // First epoch in which `weight` no longer counts.
        uint256 nextExpiry; // First epoch in which `nextWeight` no longer counts.
        bool initialized;
        uint256 pending;
        uint256 matured;
        address referrer;
        bool referralClosed;
        Vintage[32] vintages;
    }

    uint256 public epoch;
    uint256 public settledEpoch;
    uint256 public queuedTax;
    uint256 public currentRedis;
    uint256 public lastYieldPerHash;
    uint256 public scrapAllowance;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(uint256 => uint256)) public epochParam;
    mapping(uint256 => mapping(address => Share)) public shares;
    uint256 public nextTotalHash;
    uint256 public accRewardPerHash;
    mapping(uint256 => uint256) public lastEpochInWeek;
    mapping(address => Account) private accounts;
    /// @notice Committed hash that leaves the denominator when epoch `id` starts.
    mapping(uint256 => uint256) public expiring;
    event Committed(address indexed player, uint256 weight, uint256 fromEpoch, uint256 expiresAt);
    event Expired(uint256 indexed epoch, uint256 hash);
    event EpochStarted(uint256 indexed epoch, uint256 start, uint256 end, address caller);
    event EpochClosed(uint256 indexed epoch, uint256 budget, uint256 roster);
    event EpochSettled(uint256 indexed epoch, uint256 mining, uint256 recycled);
    event Credited(address indexed player, uint256 indexed epoch, uint256 amount);
    event Claimed(address indexed player, uint256 amount, uint256 tax);
    event Spent(address indexed player, uint256 consumed);
    event ReferrerSet(address indexed player, address indexed referrer);

    constructor(address registry_) GameModule(registry_) {}

    function params() public view returns (Params) {
        return Params(registry.params());
    }

    function pool() public view returns (RewardPool) {
        return RewardPool(registry.module(0));
    }

    function core() public view returns (ICore) {
        return ICore(registry.module(2));
    }

    function grid() public view returns (GridOperator) {
        return GridOperator(registry.module(7));
    }

    function fees() public view returns (FeeRouter) {
        return FeeRouter(payable(registry.module(6)));
    }

    function season() public view returns (ISeason) {
        return ISeason(registry.module(8));
    }

    function launchTime() public view returns (uint256) {
        return registry.launchTime();
    }
    modifier onlyCore() {
        if (msg.sender != address(core())) revert Unauthorized();
        _;
    }

    function ready() public view returns (bool) {
        return true;
    }

    function live() public view returns (bool) {
        return epoch != 0 && block.timestamp < epochs[epoch].end;
    }

    function epochStart() external view returns (uint256) {
        return epochs[epoch].start;
    }

    function epochEnd() external view returns (uint256) {
        return epochs[epoch].end;
    }

    function advanceEpoch() external nonReentrant {
        if (block.timestamp < launchTime() || (epoch != 0 && block.timestamp < epochs[epoch].end)) revert TooEarly();
        if (scrapAllowance != 0) {
            pool().recycle(scrapAllowance);
            scrapAllowance = 0;
        }
        if (epoch != 0) {
            grid().resolveFor(epoch, msg.sender);
            Epoch storage old = epochs[epoch];
            (old.kind, old.severity, old.district, old.seed,) = grid().eventAt(epoch);
            old.redis = currentRedis;
            uint256 week = (old.start - launchTime()) / 7 days;
            lastEpochInWeek[week] = epoch;
            if (old.raw != 0) {
                old.mining = pool().available() * old.emission / 40000;
                // 110% Green gross + 5% referral + 1% season = 116.5% maximum, before tariff.
                old.budget = old.mining * 117 / 100;
                pool().reserve(old.budget);
                old.rewardPerHash = Math.mulDiv(old.mining, PRECISION, old.raw);
                accRewardPerHash += old.rewardPerHash;
                old.accRewardPerHash = accRewardPerHash;
                uint256 prize = old.mining / 100;
                old.spent = prize;
                old.allocated = prize;
                if (prize != 0) season().addPrize(week, prize);
                lastYieldPerHash = Math.mulDiv(old.mining, 1 ether, old.raw);
            } else {
                queuedTax += old.redis;
                old.redis = 0;
                old.accRewardPerHash = accRewardPerHash;
                lastYieldPerHash = 0;
            }
            settledEpoch = epoch; // Globally closed; individual farm cursors are independent.
            emit EpochClosed(epoch, old.budget, old.raw);
        }
        epoch++;
        Epoch storage e = epochs[epoch];
        e.start = uint64(block.timestamp);
        e.end = uint64(block.timestamp + EPOCH);
        uint256 gone = expiring[epoch];
        if (gone != 0) {
            // O(1): one bucket per epoch, filled by owner actions, never a farm loop.
            nextTotalHash -= gone;
            delete expiring[epoch];
            emit Expired(epoch, gone);
        }
        e.raw = nextTotalHash;
        e.target = params().get(Params.Key.DemandTarget) * 6;
        e.tariff = params().get(Params.Key.TariffBps);
        e.emission = params().get(Params.Key.EmissionBps);
        e.auditThreshold = params().get(Params.Key.AuditHashThreshold);
        for (uint256 k = uint256(Params.Key.FullSetBps); k <= uint256(Params.Key.SetCapBps); ++k) {
            epochParam[epoch][k] = params().get(Params.Key(k));
        }
        currentRedis = queuedTax;
        queuedTax = 0;
        grid().shift(epoch);
        fees().payBounty(msg.sender);
        emit EpochStarted(epoch, e.start, e.end, msg.sender);
    }

    function epochData(uint256 id) external view returns (Epoch memory) {
        return epochs[id];
    }

    function eventAt(uint256 id) external view returns (GridOperator.Kind, uint16, uint8, bytes32, bool) {
        Epoch storage e = epochs[id];
        return (e.kind, e.severity, e.district, e.seed, id != 0 && id <= settledEpoch);
    }

    function recordSales(uint256 n) external onlyCore {
        if (!live()) revert TooEarly();
        epochs[epoch].sales += n;
    }

    function initialize(address p) external onlyCore {
        Account storage a = accounts[p];
        if (a.initialized) revert AlreadyDone();
        a.initialized = true;
        a.lastSettled = epoch == 0 ? 0 : epoch - 1;
    }

    /// @dev Owner configuration changes take effect next epoch. Settlement alone never changes weights.
    /// @dev Every owner action re-commits the farm for IDLE_EPOCHS epochs starting next epoch.
    function setWeight(address p, uint256 weight) external onlyCore {
        Account storage a = accounts[p];
        if (!a.initialized || a.lastSettled < settledEpoch) revert CatchUpRequired();
        _commit(a, p, weight);
    }

    function _commit(Account storage a, address p, uint256 weight) private {
        if (a.weightEpoch <= epoch) {
            a.weight = a.nextWeight;
            a.weightExpiry = a.nextExpiry;
        }
        // Buckets for epochs <= current have already been applied; later buckets still hold this commitment.
        if (a.nextExpiry > epoch) {
            nextTotalHash -= a.nextWeight;
            expiring[a.nextExpiry] -= a.nextWeight;
        }
        uint256 expiry = epoch + 1 + IDLE_EPOCHS;
        nextTotalHash += weight;
        expiring[expiry] += weight;
        a.nextWeight = weight;
        a.nextExpiry = expiry;
        a.weightEpoch = epoch + 1;
        emit Committed(p, weight, epoch + 1, expiry);
    }

    /// @notice Weight counted in epoch `e`'s denominator; zero once the farm has been idle for IDLE_EPOCHS.
    function farmWeight(address p, uint256 e) public view returns (uint256) {
        Account storage a = accounts[p];
        if (e >= a.weightEpoch) return e < a.nextExpiry ? a.nextWeight : 0;
        return e < a.weightExpiry ? a.weight : 0;
    }

    /// @notice Configured allocation hash, whether or not it is currently committed.
    function configuredWeight(address p) external view returns (uint256) {
        return accounts[p].nextWeight;
    }

    /// @notice First epoch in which the farm's latest commitment no longer counts.
    function expiresAt(address p) external view returns (uint256) {
        return accounts[p].nextExpiry;
    }

    function committed(address p) external view returns (bool) {
        Account storage a = accounts[p];
        return a.nextWeight != 0 && a.nextExpiry > epoch + 1;
    }

    function lastSettled(address p) external view returns (uint256) {
        return accounts[p].lastSettled;
    }

    /// @notice No bounty; catch-up is paid by the player or a voluntary sponsor. Mining never expires.
    function settle(address p, uint256 limit) external nonReentrant returns (uint256 cursor) {
        return _settle(p, limit);
    }

    function _settle(address p, uint256 limit) private returns (uint256 cursor) {
        if (limit == 0 || limit > MAX_SETTLE) revert InvalidValue();
        Account storage a = accounts[p];
        if (!a.initialized) return settledEpoch;
        cursor = a.lastSettled;
        for (uint256 n; n < limit && cursor < settledEpoch; ++n) {
            ++cursor;
            a.lastSettled = cursor; // CEI and monotonically increasing, including zero-yield epochs.
            _settleOne(p, cursor);
        }
    }

    function _settleOne(address p, uint256 id) private {
        Epoch storage e = epochs[id];
        (uint256 raw, uint256 productive, uint256 power) = core().process(p, id);
        uint256 weight = farmWeight(p, id);
        bool audit = e.kind == GridOperator.Kind.Audit && raw > e.auditThreshold;
        shares[id][p] = Share(raw, productive, power, audit);
        uint256 week = (e.start - launchTime()) / 7 days;
        if (weight != 0) {
            uint256 gross = Math.mulDiv(e.rewardPerHash, productive, PRECISION);
            uint256 electricity = Math.mulDiv(e.rewardPerHash, power, PRECISION) * e.tariff / 10000;
            if (e.kind == GridOperator.Kind.Cheap) electricity /= 2;
            uint256 tax = audit ? gross / 10 : 0;
            uint256 net = gross - tax - Math.min(electricity, gross - tax);
            uint256 redisAllocation = Math.mulDiv(e.redis, weight, e.raw);
            uint256 redis = Math.mulDiv(e.redis, Math.min(raw, weight), e.raw);
            Account storage a = accounts[p];
            a.referralClosed = true;
            uint256 referral;
            if (a.referrer != address(0)) {
                referral = gross * 500 / 10000;
                _credit(a.referrer, referral, id, e.end);
            }
            // Use the same rounding as actual gross. Flooring a global envelope before
            // apportionment can otherwise underfund a farm by one wei and lock its cursor.
            uint256 maxGross = Math.mulDiv(e.rewardPerHash, weight * 11000 / 10000, PRECISION);
            uint256 allocation = maxGross + maxGross * 500 / 10000 + redisAllocation;
            uint256 spent = net + redis + referral;
            // Protocol maximum combos bound productive hash by 110% of committed allocation hash.
            if (spent > allocation) revert InvalidValue();
            _credit(p, net + redis, id, e.end);
            e.spent += spent;
            e.allocated += allocation;
            e.settledHash += weight;
            uint256 unused = allocation - spent;
            if (id == settledEpoch) {
                uint256 allowance = Math.min(unused, e.mining / 6 - e.scrap);
                e.scrap += allowance;
                scrapAllowance += allowance;
                unused -= allowance;
            }
            if (unused != 0) pool().recycle(unused);
            if (e.settledHash == e.raw) {
                uint256 dust = e.budget + e.redis - e.allocated;
                if (dust != 0) pool().recycle(dust);
                emit EpochSettled(id, e.spent, dust);
            }
            if (raw != 0) {
                core().activity(p, id, gross, net);
                if (e.sales >= 2 * e.target && uint256(keccak256(abi.encode(e.seed, p, "supply"))) % 10000 < 500) {
                    core().grantDrop(p, keccak256(abi.encode(e.seed, p, "item")));
                }
                season().recordActivity(p, week, gross);
            }
        }
        // Only a complete week's yield may compete for spend/yield prizes; partial settlement cannot win.
        if (id == lastEpochInWeek[week] && epochs[epoch].start >= launchTime() + (week + 1) * 7 days) {
            season().complete(p, week);
        }
    }

    function pending(address p) external view returns (uint256) {
        return accounts[p].pending;
    }

    function referrer(address p) external view returns (address) {
        return accounts[p].referrer;
    }

    function setReferrer(address p, address ref) external onlyCore {
        Account storage a = accounts[p];
        if (a.referrer != address(0) || a.referralClosed) revert AlreadyDone();
        if (p == ref || !core().hasFarm(ref)) revert InvalidValue();
        a.referrer = ref;
        emit ReferrerSet(p, ref);
    }

    function _credit(address p, uint256 amount, uint256 e, uint256 at) private {
        if (amount == 0) return;
        Account storage a = accounts[p];
        a.pending += amount;
        // Referrals can arrive out of epoch order. Never evict a younger, still-taxable vintage.
        if (block.timestamp >= at + 7 days) {
            a.matured += amount;
            emit Credited(p, e, amount);
            return;
        }
        Vintage storage v = a.vintages[e % 32];
        if (v.amount != 0 && v.epoch != e) {
            a.matured += v.amount;
            v.amount = 0;
        }
        v.epoch = uint64(e);
        if (at > v.at || v.amount == 0) v.at = uint64(at);
        v.amount += amount;
        emit Credited(p, e, amount);
    }

    function taxBps(uint256 age) public pure returns (uint256) {
        return age >= 7 days ? 500 : 2000 - 1500 * age / 7 days;
    }

    function _consume(address p, uint256 amount, bool taxed) private returns (uint256 tax) {
        Account storage a = accounts[p];
        if (amount == 0 || amount > a.pending) revert InsufficientBalance();
        a.pending -= amount;
        // Sparse credits can leave an old slot behind the current ring head.
        // Sweep by actual age before consuming any higher-tax vintage.
        for (uint256 n; n < 32; ++n) {
            Vintage storage old = a.vintages[n];
            if (old.amount != 0 && block.timestamp >= uint256(old.at) + 7 days) {
                a.matured += old.amount;
                old.amount = 0;
            }
        }
        uint256 used = Math.min(amount, a.matured);
        a.matured -= used;
        amount -= used;
        if (taxed) tax = used * 500 / 10000;
        uint256 first = epoch > 31 ? epoch - 31 : 0;
        // Old slots are consumed before newer slots; all skipped generations have matured.
        for (uint256 n; n < 32 && amount != 0; ++n) {
            Vintage storage v = a.vintages[(first + n) % 32];
            if (v.amount == 0) continue;
            used = Math.min(amount, v.amount);
            v.amount -= used;
            amount -= used;
            if (taxed) tax += used * taxBps(block.timestamp > v.at ? block.timestamp - v.at : 0) / 10000;
        }
        assert(amount == 0);
    }

    function claim(uint256 amount) external nonReentrant returns (uint256 net) {
        _settle(msg.sender, MAX_SETTLE);
        Account storage a = accounts[msg.sender];
        // Claim is an owner action: re-commit when fully caught up. Never blocks the withdrawal.
        if (a.initialized && a.lastSettled >= settledEpoch && a.nextWeight != 0) _commit(a, msg.sender, a.nextWeight);
        uint256 tax = _consume(msg.sender, amount, true);
        queuedTax += tax;
        net = amount - tax;
        pool().pay(msg.sender, net);
        emit Claimed(msg.sender, amount, tax);
    }

    function spend(address p, uint256 nominal) external onlyCore nonReentrant returns (uint256 consumed) {
        consumed = Math.mulDiv(nominal, 10000, 10500, Math.Rounding.Ceil);
        _consume(p, consumed, false);
        pool().recycle(consumed);
        emit Spent(p, consumed);
    }

    function scrap(address p, uint256 hash, uint256 minimum) external onlyCore nonReentrant returns (uint256 amount) {
        amount = Math.mulDiv(hash, lastYieldPerHash, 6 ether);
        amount = Math.min(amount, scrapAllowance);
        if (amount < minimum) revert InsufficientBalance();
        scrapAllowance -= amount;
        if (amount != 0) _credit(p, amount, epoch, block.timestamp);
    }

    function seasonReady(uint256 week) external view returns (bool) {
        return epoch != 0 && epochs[epoch].start >= launchTime() + (week + 1) * 7 days;
    }

    function releasePrize(uint256 amount) external nonReentrant {
        if (msg.sender != address(season())) revert Unauthorized();
        pool().recycle(amount);
    }

    function award(address p, uint256 amount) external nonReentrant {
        if (msg.sender != address(season())) revert Unauthorized();
        _credit(p, amount, epoch, block.timestamp);
    }
}
