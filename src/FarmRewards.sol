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

/// @notice Epoch transitions do O(1) work. Anyone settles a closed roster in batches of at most eight.
contract FarmRewards is GameModule, ReentrancyGuard {
    uint256 public constant EPOCH = 6 hours;

    struct Epoch {
        uint64 start;
        uint64 end;
        uint64 roster;
        uint8 phase;
        uint256 cursor;
        uint256 raw;
        uint256 budget;
        uint256 mining;
        uint256 redis;
        uint256 spent;
        uint256 sales;
        uint256 target;
        uint256 tariff;
        uint256 emission;
        uint256 audited;
        uint256 lastActive;
        uint256 redisPaid;
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
    mapping(uint256 => uint256[]) private heaps;
    mapping(address => Account) private accounts;
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
        return epoch == 0 || settledEpoch + 1 == epoch;
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
        if (block.timestamp < launchTime() || !ready() || (epoch != 0 && block.timestamp < epochs[epoch].end)) {
            revert TooEarly();
        }
        if (epoch != 0) {
            grid().resolveFor(epoch, msg.sender);
            Epoch storage old = epochs[epoch];
            old.roster = uint64(core().count());
            old.phase = 1;
            old.mining = pool().available() * old.emission / 40000;
            old.budget = old.mining * 116 / 100;
            old.redis = currentRedis;
            pool().reserve(old.budget);
            emit EpochClosed(epoch, old.budget, old.roster);
        }
        epoch++;
        Epoch storage e = epochs[epoch];
        e.start = uint64(block.timestamp);
        e.end = uint64(block.timestamp + EPOCH);
        e.target = params().get(Params.Key.DemandTarget) * 6;
        e.tariff = params().get(Params.Key.TariffBps);
        e.emission = params().get(Params.Key.EmissionBps);
        for (uint256 k = uint256(Params.Key.FullSetBps); k <= uint256(Params.Key.SetCapBps); ++k) {
            epochParam[epoch][k] = params().get(Params.Key(k));
        }
        currentRedis = queuedTax;
        queuedTax = 0;
        grid().shift(epoch);
        fees().payBounty(msg.sender);
        emit EpochStarted(epoch, e.start, e.end, msg.sender);
    }

    function recordSales(uint256 n) external onlyCore {
        if (!live()) revert TooEarly();
        epochs[epoch].sales += n;
    }

    function _greater(uint256 e, uint256 a, uint256 b) private view returns (bool) {
        uint256 x = shares[e][core().playerAt(a)].raw;
        uint256 y = shares[e][core().playerAt(b)].raw;
        return x > y || (x == y && a < b);
    }

    function _push(uint256 e, uint256 id) private {
        uint256[] storage h = heaps[e];
        h.push(id);
        uint256 i = h.length - 1;
        while (i != 0) {
            uint256 p = (i - 1) / 2;
            if (!_greater(e, h[i], h[p])) break;
            (h[i], h[p]) = (h[p], h[i]);
            i = p;
        }
    }

    function _pop(uint256 e) private returns (uint256 id) {
        uint256[] storage h = heaps[e];
        id = h[0];
        h[0] = h[h.length - 1];
        h.pop();
        uint256 i;
        while (i * 2 + 1 < h.length) {
            uint256 j = i * 2 + 1;
            if (j + 1 < h.length && _greater(e, h[j + 1], h[j])) j++;
            if (!_greater(e, h[j], h[i])) break;
            (h[i], h[j]) = (h[j], h[i]);
            i = j;
        }
    }

    /// @dev Three phases: measure, select top decile (audit only), credit. No caller supplies allocation data.
    function processEpoch(uint256 limit) external nonReentrant {
        uint256 startGas = gasleft();
        if (limit == 0 || limit > 8 || epoch < 2 || ready()) revert InvalidValue();
        uint256 id = epoch - 1;
        Epoch storage e = epochs[id];
        (GridOperator.Kind kind, uint16 severity,, bytes32 seed,) = grid().eventAt(id);
        uint256 work;
        Params.Key bountyKind =
            e.phase == 1 ? Params.Key.MeasureBounty : e.phase == 2 ? Params.Key.AuditBounty : Params.Key.CreditBounty;
        if (e.phase == 1) {
            for (uint256 n; n < limit && e.cursor < e.roster; ++n) {
                address p = core().playerAt(e.cursor);
                (uint256 raw, uint256 productive, uint256 power) = core().process(p, id);
                shares[id][p] = Share(raw, productive, power, false);
                e.raw += raw;
                if (raw != 0) e.lastActive = e.cursor;
                if (raw != 0 && kind == GridOperator.Kind.Audit) _push(id, e.cursor);
                e.cursor++;
                work++;
            }
            if (e.cursor == e.roster) {
                e.cursor = 0;
                e.phase = kind == GridOperator.Kind.Audit ? 2 : 3;
                e.audited = (heaps[id].length + 9) / 10;
            }
        } else if (e.phase == 2) {
            for (uint256 n; n < limit && e.cursor < e.audited; ++n) {
                shares[id][core().playerAt(_pop(id))].audit = true;
                e.cursor++;
                work++;
            }
            if (e.cursor == e.audited) {
                e.cursor = 0;
                e.phase = 3;
            }
        } else {
            for (uint256 n; n < limit && e.cursor < e.roster; ++n) {
                address p = core().playerAt(e.cursor++);
                work++;
                Share storage s = shares[id][p];
                if (s.raw == 0) continue;
                uint256 gross = Math.mulDiv(e.mining, s.productive, e.raw);
                uint256 electricity = Math.mulDiv(e.mining, s.power, e.raw) * e.tariff / 10000;
                if (kind == GridOperator.Kind.Cheap) electricity /= 2;
                uint256 audit = s.audit ? gross * 1000 * severity / 100_000_000 : 0;
                uint256 net = gross - audit - Math.min(electricity, gross - audit);
                uint256 redis =
                    e.cursor - 1 == e.lastActive ? e.redis - e.redisPaid : Math.mulDiv(e.redis, s.raw, e.raw);
                e.redisPaid += redis;
                uint256 referral;
                Account storage a = accounts[p];
                a.referralClosed = true;
                if (a.referrer != address(0)) {
                    referral = gross * 500 / 10000;
                    _credit(a.referrer, referral, id, e.end);
                }
                _credit(p, net + redis, id, e.end);
                e.spent += net + redis + referral;
                core().activity(p, id, gross, net);
                if (e.sales >= 2 * e.target && uint256(keccak256(abi.encode(seed, p, "supply"))) % 10000 < 500) {
                    core().grantDrop(p, keccak256(abi.encode(seed, p, "item")));
                }
                season().recordActivity(p, (e.start - launchTime()) / 7 days, gross);
            }
            if (e.cursor == e.roster) {
                uint256 prize = e.raw == 0 ? 0 : e.mining / 100;
                e.spent += prize;
                if (prize != 0) season().addPrize((e.start - launchTime()) / 7 days, prize);
                uint256 recycle = e.budget + e.redis - e.spent;
                if (e.raw == 0) {
                    queuedTax += e.redis;
                    recycle -= e.redis;
                }
                uint256 freshUnused = e.budget > e.spent ? e.budget - e.spent : 0;
                uint256 allowance = e.raw == 0 ? 0 : Math.min(e.mining / 6, freshUnused);
                if (scrapAllowance != 0) pool().recycle(scrapAllowance);
                scrapAllowance = allowance;
                recycle -= allowance;
                if (recycle != 0) pool().recycle(recycle);
                lastYieldPerHash = e.raw == 0 ? 0 : Math.mulDiv(e.mining, 1 ether, e.raw);
                e.phase = 4;
                settledEpoch = id;
                emit EpochSettled(id, e.mining, recycle);
            }
        }
        if (work != 0) fees().payWork(msg.sender, bountyKind, work, startGas - gasleft());
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
        return ready() && epoch != 0 && epochs[epoch].start >= launchTime() + (week + 1) * 7 days;
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
