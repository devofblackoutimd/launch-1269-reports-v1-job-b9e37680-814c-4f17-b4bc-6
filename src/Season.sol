// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GameModule} from "./lib/GameModule.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FeeRouter} from "./FeeRouter.sol";
import {Params} from "./Params.sol";
import {FarmItems} from "./FarmItems.sol";
import {IRewards, ICore} from "./interfaces/IGame.sol";
import {ChainClock} from "./lib/ChainClock.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import "./lib/Errors.sol";

interface IPrizePacks {
    function rewardPack(address p) external returns (uint256);
}

/// @notice Weekly tickets are active epochs, stored in a bounded 32-level sum tree.
contract Season is GameModule, ReentrancyGuard {
    struct Week {
        uint256[8] districtSpend;
        uint256 participants;
        uint256 totalTickets;
        uint256 prize;
        uint64 target;
        bool finalized;
        uint8 winnerDistrict;
        address best;
        uint256 bestScore;
        bytes32 seed;
    }

    mapping(uint256 => Week) private seasons;
    mapping(uint256 => mapping(address => uint256)) public spend;
    mapping(uint256 => mapping(address => uint256)) public yield;
    mapping(uint256 => mapping(address => uint256)) public index;
    mapping(uint256 => mapping(uint256 => address)) public participant;
    mapping(uint256 => mapping(uint256 => uint256)) private tree;
    mapping(uint256 => mapping(address => uint256)) public tickets;
    mapping(uint256 => mapping(address => bool)) public districtClaimed;
    mapping(uint256 => mapping(address => bool)) public lotteryWon;
    mapping(uint256 => mapping(address => bool)) public lotteryClaimed;
    event SeasonPrepared(uint256 indexed week, uint256 target);
    event SeasonFinalized(uint256 indexed week, uint256 district, address best, bytes32 seed);
    event LotteryWinner(uint256 indexed week, address indexed player);

    constructor(address registry_) GameModule(registry_) {}

    function rewards() public view returns (IRewards) {
        return IRewards(registry.module(1));
    }

    function core() public view returns (ICore) {
        return ICore(registry.module(2));
    }

    function items() public view returns (FarmItems) {
        return FarmItems(registry.module(3));
    }

    function packs() public view returns (IPrizePacks) {
        return IPrizePacks(registry.module(4));
    }

    function grid() public view returns (address) {
        return registry.module(7);
    }

    function fees() public view returns (FeeRouter) {
        return FeeRouter(payable(registry.module(6)));
    }

    function launchTime() public view returns (uint256) {
        return registry.launchTime();
    }

    function district(address p) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(p))) % 8;
    }

    function recordSpend(address p, uint256 value, bool districtSpend) external {
        if (msg.sender != address(core()) && msg.sender != grid()) revert Unauthorized();
        if (block.timestamp < launchTime()) revert TooEarly();
        uint256 w = (block.timestamp - launchTime()) / 7 days;
        spend[w][p] += value;
        if (districtSpend) seasons[w].districtSpend[district(p)] += value;
    }

    function _add(uint256 w, uint256 i, uint256 amount, bool subtract) private {
        uint256 node = (1 << 32) + i;
        for (uint256 n; n < 33; ++n) {
            if (subtract) tree[w][node] -= amount;
            else tree[w][node] += amount;
            node >>= 1;
        }
    }

    function recordActivity(address p, uint256 w, uint256 gross) external {
        if (msg.sender != address(rewards())) revert Unauthorized();
        Week storage s = seasons[w];
        uint256 i = index[w][p];
        if (i == 0) {
            i = ++s.participants;
            if (i >= 1 << 32) revert InvalidValue();
            index[w][p] = i;
            participant[w][i] = p;
        }
        tickets[w][p]++;
        s.totalTickets++;
        _add(w, i, 1, false);
        yield[w][p] += gross;
        // All spending and all epoch yields are finalized before prepare; selection is done there in bounded batches below.
    }

    function addPrize(uint256 w, uint256 amount) external {
        if (msg.sender != address(rewards())) revert Unauthorized();
        seasons[w].prize += amount;
    }
    mapping(uint256 => uint256) public scoreCursor;

    function prepare(uint256 w, uint256 limit) external nonReentrant {
        uint256 startGas = gasleft();
        if (!rewards().seasonReady(w) || limit == 0 || limit > 64) revert TooEarly();
        Week storage s = seasons[w];
        if (s.target != 0) revert AlreadyDone();
        uint256 cursor = scoreCursor[w];
        uint256 before_ = cursor;
        for (uint256 n; n < limit && cursor < s.participants; ++n) {
            address p = participant[w][++cursor];
            uint256 earned = yield[w][p];
            if (earned == 0) continue;
            uint256 score = Math.mulDiv(spend[w][p], 1 ether, earned);
            if (s.best == address(0) || score > s.bestScore || (score == s.bestScore && uint160(p) < uint160(s.best))) {
                s.best = p;
                s.bestScore = score;
            }
        }
        scoreCursor[w] = cursor;
        if (cursor > before_) {
            fees().payWork(msg.sender, Params.Key.SeasonScoreBounty, cursor - before_, startGas - gasleft());
        }
        if (cursor == s.participants) {
            s.target = uint64(ChainClock.number() + 2);
            emit SeasonPrepared(w, s.target);
        }
    }

    function _draw(uint256 w, uint256 point) private view returns (address) {
        uint256 node = 1;
        for (uint256 i; i < 32; ++i) {
            uint256 left = tree[w][node * 2];
            if (point < left) {
                node *= 2;
            } else {
                point -= left;
                node = node * 2 + 1;
            }
        }
        return participant[w][node - (1 << 32)];
    }

    function finalize(uint256 w) external nonReentrant {
        uint256 startGas = gasleft();
        Week storage s = seasons[w];
        if (s.finalized) revert AlreadyDone();
        if (s.target == 0 || ChainClock.number() <= s.target) revert TooEarly();
        bytes32 h = ChainClock.hash(s.target);
        if (h == bytes32(0)) revert NotConfigured();
        s.seed = keccak256(abi.encode(h, address(this), w, s.totalTickets));
        s.finalized = true;
        for (uint256 d = 1; d < 8; ++d) {
            if (s.districtSpend[d] > s.districtSpend[s.winnerDistrict]) s.winnerDistrict = uint8(d);
        }
        uint256 left = s.totalTickets;
        for (uint256 i; i < 3 && left != 0; ++i) {
            address winner = _draw(w, uint256(keccak256(abi.encode(s.seed, i))) % left);
            uint256 weight = tickets[w][winner];
            left -= weight;
            _add(w, index[w][winner], weight, true);
            lotteryWon[w][winner] = true;
            emit LotteryWinner(w, winner);
        }
        if (s.prize != 0) {
            if (s.best != address(0)) rewards().award(s.best, s.prize);
            else rewards().releasePrize(s.prize);
        }
        if (s.participants != 0) fees().payWork(msg.sender, Params.Key.SeasonBounty, 1, startGas - gasleft());
        emit SeasonFinalized(w, s.winnerDistrict, s.best, s.seed);
    }

    function rearm(uint256 w) external {
        Week storage s = seasons[w];
        if (s.finalized || s.target == 0 || ChainClock.number() <= uint256(s.target) + 256) revert TooEarly();
        s.target = uint64(ChainClock.number() + 2);
        emit SeasonPrepared(w, s.target);
    }

    function result(uint256 w)
        external
        view
        returns (bool finalized, uint8 d, address best, uint256 prize, bytes32 seed)
    {
        Week storage s = seasons[w];
        return (s.finalized, s.winnerDistrict, s.best, s.prize, s.seed);
    }

    function claimDistrict(uint256 w) external nonReentrant returns (uint256 id) {
        Week storage s = seasons[w];
        if (
            !s.finalized || tickets[w][msg.sender] == 0 || district(msg.sender) != s.winnerDistrict
                || districtClaimed[w][msg.sender]
        ) revert InvalidValue();
        districtClaimed[w][msg.sender] = true;
        id = packs().rewardPack(msg.sender);
    }

    function claimLottery(uint256 w) external nonReentrant returns (uint256 id) {
        if (!lotteryWon[w][msg.sender] || lotteryClaimed[w][msg.sender]) revert InvalidValue();
        lotteryClaimed[w][msg.sender] = true;
        bytes32 seed = keccak256(abi.encode(seasons[w].seed, msg.sender));
        (uint8 k,) = ItemMath.draw(seed, false, false);
        uint8 r = uint256(seed) % 100 < 90 ? 2 : 3;
        id = items().mint(msg.sender, k, r, false);
    }
}
