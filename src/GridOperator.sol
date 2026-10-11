// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Params} from "./Params.sol";
import {FeeRouter} from "./FeeRouter.sol";
import {ChainClock} from "./lib/ChainClock.sol";
import {IRewards, ICore, ISeason} from "./interfaces/IGame.sol";
import "./lib/Errors.sol";

contract GridOperator is ReentrancyGuard {
    enum Kind {
        Calm,
        Outage,
        Surge,
        Fire,
        Theft,
        Audit,
        Green,
        Cheap
    }

    struct Plan {
        Kind kind;
        uint16 severity;
        bytes32 number;
        string letter;
        bool submitted;
    }

    struct EventData {
        Kind kind;
        uint16 severity;
        uint8 district;
        uint64 target;
        uint64 started;
        bytes32 seed;
        bool resolved;
        uint256[8] weights;
    }

    struct Lobby {
        uint256 amount;
        uint64 at;
    }
    address public immutable swarmWallet;
    Params public immutable params;
    FeeRouter public immutable fees;
    IRewards public immutable rewards;
    ICore public immutable core;
    ISeason public immutable season;
    mapping(uint256 => Plan) private plans;
    mapping(uint256 => EventData) private events;
    mapping(uint256 => Lobby) public lobbies;
    mapping(uint256 => uint256) public lastOutage;
    event PlanSubmitted(uint256 indexed epoch, Kind kind, uint256 severity, bytes32 number, string letter);
    event Herald(uint256 indexed epoch, Kind kind, uint256 district, uint256 severity, bytes32 seed, string letter);
    event Lobbied(address indexed player, uint256 indexed district, uint256 ethValue);

    constructor(address swarm_, address params_, address fees_, address rewards_, address core_, address season_) {
        if (
            swarm_ == address(0) || params_ == address(0) || fees_ == address(0) || rewards_ == address(0)
                || core_ == address(0) || season_ == address(0)
        ) revert InvalidAddress();
        swarmWallet = swarm_;
        params = Params(params_);
        fees = FeeRouter(payable(fees_));
        rewards = IRewards(rewards_);
        core = ICore(core_);
        season = ISeason(season_);
    }

    function district(address p) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(p))) % 8;
    }

    function submitPlan(uint256 e, Kind kind, uint16 severity, bytes32 number, string calldata letter) external {
        if (msg.sender != swarmWallet) revert Unauthorized();
        uint256 current = rewards.epoch();
        if (
            e <= current || e > current + 2 || severity < 5000 || severity > 10000 || bytes(letter).length == 0
                || bytes(letter).length > 1024
        ) revert InvalidValue();
        if (plans[e].submitted) revert AlreadyDone();
        plans[e] = Plan(kind, severity, number, letter, true);
        emit PlanSubmitted(e, kind, severity, number, letter);
    }

    /// @dev Rational interpolation between exact three-day halvings, with bounded work.
    function lobbyAmount(uint256 d) public view returns (uint256) {
        Lobby memory l = lobbies[d];
        uint256 dt = block.timestamp - l.at;
        uint256 halves = dt / 3 days;
        if (halves >= 128) return 0;
        uint256 a = l.amount >> halves;
        return a * 3 days / (3 days + dt % 3 days);
    }

    function lobbyWeight(uint256 d) public view returns (uint256) {
        uint256 a = lobbyAmount(d);
        uint256 reduction = a * params.get(Params.Key.LobbyKBps) / (1 ether + a);
        uint256 w = 10000 - reduction;
        uint256 floor = params.get(Params.Key.LobbyMinWeight);
        return w < floor ? floor : w;
    }

    function lobbyETH() external payable nonReentrant {
        if (msg.value == 0 || !core.hasFarm(msg.sender) || !rewards.live() || !rewards.ready()) revert InvalidValue();
        _lobby(msg.sender, msg.value);
        season.recordSpend(msg.sender, msg.value, true);
        fees.depositLobby{value: msg.value}();
    }

    function tokenLobby(address p, uint256 value) external {
        if (msg.sender != address(core) || value == 0) revert Unauthorized();
        _lobby(p, value);
    }

    function _lobby(address p, uint256 value) private {
        uint256 d = district(p);
        lobbies[d] = Lobby(lobbyAmount(d) + value, uint64(block.timestamp));
        emit Lobbied(p, d, value);
    }

    function shift(uint256 e) external {
        if (msg.sender != address(rewards)) revert Unauthorized();
        EventData storage x = events[e];
        if (x.target != 0) revert AlreadyDone();
        x.target = uint64(ChainClock.number() + 1);
        x.started = uint64(block.timestamp);
        for (uint256 d; d < 8; ++d) {
            x.weights[d] = lobbyWeight(d);
        }
    }

    function fallbackKind(uint256 e) public pure returns (Kind) {
        uint8[20] memory table = [uint8(6), 7, 0, 1, 0, 6, 2, 0, 3, 0, 7, 4, 0, 5, 0, 6, 0, 1, 0, 7];
        return Kind(table[(e - 1) % 20]);
    }

    function resolve(uint256 e) public {
        EventData storage x = events[e];
        if (x.resolved) return;
        if (x.target == 0 || ChainClock.number() <= x.target) revert TooEarly();
        Plan storage p = plans[e];
        bytes32 h = ChainClock.hash(x.target);
        // Missing/expired entropy has an explicit fixed, non-rerollable fallback.
        x.seed = h == bytes32(0)
            ? keccak256(abi.encode(address(this), e, "fixed fallback"))
            : keccak256(abi.encode(p.number, h, address(this), e));
        Kind k = p.submitted && h != bytes32(0) ? p.kind : fallbackKind(e);
        x.severity = p.submitted && h != bytes32(0) ? p.severity : 10000;
        uint256 positives;
        uint256 repeated;
        uint256 first = e > 19 ? e - 19 : 1;
        for (uint256 j = first; j < e; ++j) {
            Kind old = events[j].kind;
            if (old == Kind.Green || old == Kind.Cheap) positives++;
            if (old == k) repeated++;
        }
        if ((e >= 20 && positives < 4) || (e < 20 && positives + 20 - e < 4)) {
            k = uint256(x.seed) % 2 == 0 ? Kind.Green : Kind.Cheap;
        }
        if (k >= Kind.Outage && k <= Kind.Audit && repeated >= 4) k = Kind.Calm;
        if (!p.submitted && h != bytes32(0) && uint256(x.seed) % 10000 < params.get(Params.Key.PositiveWeight)) {
            k = uint256(x.seed) >> 16 & 1 == 0 ? Kind.Green : Kind.Cheap;
        }
        uint256[8] memory weights;
        uint256 sum;
        for (uint256 d; d < 8; ++d) {
            uint256 w = k == Kind.Green ? 20000 - x.weights[d] : x.weights[d];
            if (k == Kind.Outage && lastOutage[d] != 0 && x.started < lastOutage[d] + 2 days) w = 0;
            weights[d] = w;
            sum += w;
        }
        if (sum == 0) {
            k = Kind.Calm;
        } else {
            uint256 point = uint256(keccak256(abi.encode(x.seed, "district"))) % sum;
            for (uint256 d; d < 8; ++d) {
                if (point < weights[d]) {
                    x.district = uint8(d);
                    break;
                }
                point -= weights[d];
            }
        }
        x.kind = k;
        x.resolved = true;
        if (k == Kind.Outage) lastOutage[x.district] = x.started;
        emit Herald(
            e, k, x.district, x.severity, x.seed, p.submitted ? p.letter : "Autonomous fallback: the grid continues."
        );
    }

    function eventAt(uint256 e)
        external
        view
        returns (Kind kind, uint16 severity, uint8 d, bytes32 seed, bool resolved)
    {
        EventData storage x = events[e];
        return (x.kind, x.severity, x.district, x.seed, x.resolved);
    }
}
