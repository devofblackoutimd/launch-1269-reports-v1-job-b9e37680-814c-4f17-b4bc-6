// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Params} from "./Params.sol";
import {FeeRouter} from "./FeeRouter.sol";
import {IEmission} from "./interfaces/Interfaces.sol";
import {ChainClock} from "./lib/ChainClock.sol";
import "./lib/Errors.sol";

contract GridOperator is ReentrancyGuard {
    enum Kind {
        Calm,
        Surge,
        Heatwave,
        Blackout,
        Audit
    }

    struct EventData {
        uint64 target;
        uint64 resolvedAt;
        Kind kind;
        uint8 first;
        uint8 second;
        bool submitted;
        bool resolved;
        uint256[8] weights;
    }

    struct Lobby {
        uint256 amount;
        uint256 updated;
    }
    address public immutable swarmWallet;
    address public immutable core;
    uint256 public immutable launchTime;
    Params public immutable params;
    FeeRouter public immutable fees;
    IEmission public immutable emission;
    mapping(uint256 => EventData) private events;
    mapping(uint256 => uint256) public lastBlackout;
    Lobby[8] public lobbies;
    event EventSubmitted(uint256 indexed tick, Kind kind, uint256 target);
    event EventResolved(uint256 indexed tick, Kind kind, uint256 first, uint256 second, bool expired);
    event Lobbied(address indexed player, uint256 indexed district, uint256 value, bool inTokens);
    event Herald(bytes32 indexed contentHash, string uri);

    constructor(address swarm_, address core_, uint256 launch_, address params_, address fees_, address emission_) {
        if (
            swarm_ == address(0) || core_ == address(0) || params_ == address(0) || fees_ == address(0)
                || emission_ == address(0) || launch_ == 0
        ) revert InvalidValue();
        swarmWallet = swarm_;
        core = core_;
        launchTime = launch_;
        params = Params(params_);
        fees = FeeRouter(payable(fees_));
        emission = IEmission(emission_);
    }

    function district(address player) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(player))) % 8;
    }

    function _decay(uint256 amount, uint256 elapsed) private pure returns (uint256) {
        uint256 base = 999997325824638267;
        uint256 factor = 1e18;
        // O(log seconds), with the three-day half-life accurate to fixed-point rounding.
        while (elapsed != 0) {
            if (elapsed & 1 != 0) factor = Math.mulDiv(factor, base, 1e18);
            base = Math.mulDiv(base, base, 1e18);
            elapsed >>= 1;
        }
        return Math.mulDiv(amount, factor, 1e18);
    }

    function lobbyValue(uint256 d) public view returns (uint256) {
        if (d >= 8) revert InvalidValue();
        Lobby memory l = lobbies[d];
        return _decay(l.amount, block.timestamp - l.updated);
    }

    function lobbyWeight(uint256 d) public view returns (uint256) {
        uint256 mean;
        for (uint256 i; i < 8; ++i) {
            mean += lobbyValue(i);
        }
        mean = Math.max(mean / 8, 0.05 ether);
        uint256 penalty = Math.mulDiv(params.get(Params.Key.LobbyKBps), lobbyValue(d), mean);
        return Math.max(params.get(Params.Key.LobbyMinWeight), 10000 * 10000 / (10000 + penalty));
    }

    function lobby() external payable nonReentrant {
        if (block.timestamp < launchTime || msg.value == 0) revert InvalidValue();
        _lobby(msg.sender, msg.value, false);
        fees.depositLobby{value: msg.value}();
    }

    function tokenLobby(address player, uint256 ethValue) external {
        if (msg.sender != core) revert Unauthorized();
        if (ethValue == 0) revert InvalidValue();
        _lobby(player, ethValue, true);
    }

    function _lobby(address player, uint256 value, bool inTokens) private {
        uint256 d = district(player);
        lobbies[d] = Lobby(lobbyValue(d) + value, block.timestamp);
        emit Lobbied(player, d, value, inTokens);
    }

    function postHerald(bytes32 contentHash, string calldata uri) external {
        if (msg.sender != swarmWallet) revert Unauthorized();
        if (contentHash == bytes32(0) || bytes(uri).length > 2048) revert InvalidValue();
        emit Herald(contentHash, uri);
    }

    function eventInfo(uint256 tick)
        external
        view
        returns (uint256 target, uint256 resolvedAt, Kind kind, uint256 first, uint256 second, bool resolved)
    {
        EventData storage e = events[tick];
        return (e.target, e.resolvedAt, e.kind, e.first, e.second, e.resolved);
    }

    function submitEvent(uint256 tick, Kind kind) external nonReentrant {
        if (msg.sender != swarmWallet) revert Unauthorized();
        if (
            block.timestamp < launchTime || tick != (block.timestamp - launchTime) / 12 hours
                || block.timestamp >= launchTime + tick * 12 hours + 1 hours
        ) revert TooEarly();
        EventData storage e = events[tick];
        if (e.submitted || e.resolved) revert AlreadyDone();
        uint256[5] memory counts;
        counts[uint256(kind)] = 1;
        uint256 first = tick > 19 ? tick - 19 : 0;
        for (uint256 t = first; t < tick; ++t) {
            ++counts[uint256(events[t].kind)];
        }
        if (counts[1] > 8 || counts[2] > 6 || counts[3] > 5 || counts[4] > 4) revert InvalidValue();
        // After an outage, permit positive events to rebuild the minimum quotas.
        if (tick >= 19 && (counts[1] < 4 || counts[2] < 2)) {
            bool recovering = (kind == Kind.Surge && counts[1] <= 4) || (kind == Kind.Heatwave && counts[2] <= 2);
            if (!recovering) revert InvalidValue();
        }
        e.submitted = true;
        e.kind = kind;
        e.target = uint64(ChainClock.number() + 2);
        // Lobby weights and eligible districts are committed before the future hash is known.
        for (uint256 d; d < 8; ++d) {
            bool eligible = lastBlackout[d] == 0
                || (tick + 1 - lastBlackout[d]) * 12 hours >= params.get(Params.Key.BlackoutCooldownSeconds);
            e.weights[d] = eligible ? lobbyWeight(d) : 0;
        }
        emit EventSubmitted(tick, kind, e.target);
    }

    function resolveEvent(uint256 tick) external nonReentrant {
        EventData storage e = events[tick];
        if (!e.submitted) revert InvalidValue();
        if (e.resolved) revert AlreadyDone();
        if (ChainClock.number() <= e.target) revert TooEarly();
        if (!emission.checkpoint(64)) revert CatchUpRequired();
        bytes32 h = ChainClock.hash(e.target);
        bool expired = h == bytes32(0) || block.timestamp >= launchTime + tick * 12 hours + 1 hours;
        if (expired) {
            e.kind = Kind.Calm;
        } else {
            uint256 seed = uint256(keccak256(abi.encode(h, address(this), tick)));
            if (e.kind == Kind.Blackout) {
                uint256 sum;
                for (uint256 d; d < 8; ++d) {
                    sum += e.weights[d];
                }
                if (sum == 0) {
                    e.kind = Kind.Calm;
                } else {
                    uint256 point = seed % sum;
                    for (uint256 d; d < 8; ++d) {
                        if (point < e.weights[d]) {
                            e.first = uint8(d);
                            lastBlackout[d] = tick + 1;
                            break;
                        }
                        point -= e.weights[d];
                    }
                }
            } else {
                e.first = uint8(seed % 8);
                e.second = uint8((uint256(e.first) + 1 + (seed / 8) % 7) % 8);
            }
        }
        e.resolved = true;
        e.resolvedAt = uint64(block.timestamp);
        emit EventResolved(tick, e.kind, e.first, e.second, expired);
    }

    function calmTick(uint256 tick) external nonReentrant {
        if (block.timestamp < launchTime + tick * 12 hours + 1 hours) revert TooEarly();
        EventData storage e = events[tick];
        if (e.resolved) revert AlreadyDone();
        if (!emission.checkpoint(64)) revert CatchUpRequired();
        e.resolved = true;
        e.resolvedAt = uint64(block.timestamp);
        e.kind = Kind.Calm;
        emit EventResolved(tick, Kind.Calm, 0, 0, true);
    }

    function weight(uint256 bucket, uint256 timestamp) external view returns (uint256 w) {
        w = 10000;
        if (timestamp < launchTime) return w;
        EventData storage e = events[(timestamp - launchTime) / 12 hours];
        if (!e.resolved || timestamp < e.resolvedAt) return w;
        uint256 d = bucket / 16;
        if (e.kind == Kind.Surge && d == e.first) return 15000;
        if (e.kind == Kind.Heatwave && (d == e.first || d == e.second) && bucket & 4 == 0) {
            return 10000 - params.get(Params.Key.HeatPenaltyBps);
        }
        if (e.kind == Kind.Blackout && d == e.first) {
            uint256 damage = 5000;
            if (bucket & 2 != 0) damage = damage * (10000 - params.get(Params.Key.ShieldPairBps)) / 10000;
            if (bucket & 1 != 0) damage = damage * 7500 / 10000;
            return 10000 - damage;
        }
        return w;
    }

    function rewardBps(uint256 bucket, uint256 timestamp) external view returns (uint256) {
        if (timestamp < launchTime) return 10000;
        EventData storage e = events[(timestamp - launchTime) / 12 hours];
        return e.resolved && timestamp >= e.resolvedAt && e.kind == Kind.Audit && bucket & 8 != 0 ? 9500 : 10000;
    }

    function emissionBps(uint256 timestamp) external view returns (uint256) {
        if (timestamp < launchTime) return 10000;
        EventData storage e = events[(timestamp - launchTime) / 12 hours];
        return e.resolved && timestamp >= e.resolvedAt && e.kind == Kind.Surge ? 10500 : 10000;
    }
}
