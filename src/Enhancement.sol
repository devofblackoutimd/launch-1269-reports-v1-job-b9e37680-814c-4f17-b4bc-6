// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GameModule} from "./lib/GameModule.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FarmItems} from "./FarmItems.sol";
import {Economy} from "./Economy.sol";
import {Params} from "./Params.sol";
import {EconomyMath} from "./lib/EconomyMath.sol";
import {ChainClock} from "./lib/ChainClock.sol";
import "./lib/Errors.sol";

interface IEnhanceCore {
    function level(address) external view returns (uint256);
    function prepareEnhancement(address, uint256, uint256, bool) external;
}

contract Enhancement is GameModule, ReentrancyGuard {
    struct Attempt {
        address player;
        uint256 item;
        uint64 target;
        uint8 level;
        bytes32 seed;
        bool captured;
        bool resolved;
    }
    uint8 public cap = 8;
    uint8 public announcedCap;
    uint256 public activationAt;
    uint256 public lastRaised;
    uint256 public nextId = 1;
    mapping(uint256 => Attempt) public attempts;
    mapping(uint256 => uint256) public pending;
    event EnhancementCommitted(
        uint256 indexed id, address indexed player, uint256 indexed item, uint256 level, uint256 target, uint256 cost
    );
    event EnhancementCaptured(uint256 indexed id, bytes32 seed);
    event EnhancementRearmed(uint256 indexed id, uint256 target);
    event EnhancementResolved(uint256 indexed id, bool success, bool burned, uint256 level);
    event CapAnnounced(uint256 cap, uint256 at, string letter);
    event CapRaised(uint256 cap);
    constructor(address r) GameModule(r) {}

    function table(uint256 level) external pure returns (uint256, uint256, uint256, uint256) {
        return EconomyMath.enhancement(level);
    }

    function announceCap(uint8 next, string calldata letter) external {
        if (msg.sender != Params(registry.params()).swarmWallet()) revert Unauthorized();
        if (
            (cap == 8 ? next != 12 : cap == 12 ? next != 16 : true) || announcedCap != 0 || bytes(letter).length == 0
                || bytes(letter).length > 1024
        ) revert InvalidValue();
        uint256 earliest = (lastRaised == 0 ? registry.launchTime() : lastRaised) + 30 days;
        activationAt = block.timestamp + 48 hours;
        if (activationAt < earliest) activationAt = earliest;
        announcedCap = next;
        emit CapAnnounced(next, activationAt, letter);
    }

    function activateCap() external {
        if (announcedCap == 0 || block.timestamp < activationAt) revert TooEarly();
        cap = announcedCap;
        announcedCap = 0;
        lastRaised = block.timestamp;
        emit CapRaised(cap);
    }

    function commit(uint256 item, uint256 maxCost, bool wallet) external nonReentrant returns (uint256 id) {
        FarmItems.Item memory x = FarmItems(registry.module(3)).data(item);
        IEnhanceCore core = IEnhanceCore(registry.module(2));
        uint8 target = x.overclock + 1;
        if (x.holder != msg.sender || pending[item] != 0 || target > cap) revert InvalidValue();
        if ((target >= 6 && core.level(msg.sender) < 7) || (target >= 9 && core.level(msg.sender) < 10)) {
            revert InvalidValue();
        }
        uint256 cost = Economy(registry.module(10)).enhanceQuote(item);
        if (cost > maxCost) revert InvalidValue();
        core.prepareEnhancement(msg.sender, item, cost, wallet);
        id = nextId++;
        pending[item] = id;
        attempts[id] = Attempt(msg.sender, item, uint64(ChainClock.number() + 2), target, bytes32(0), false, false);
        emit EnhancementCommitted(id, msg.sender, item, target, ChainClock.number() + 2, cost);
    }

    function capture(uint256 id) public {
        Attempt storage a = attempts[id];
        if (a.player == address(0) || a.resolved) revert InvalidValue();
        if (a.captured) return;
        if (ChainClock.number() <= a.target) revert TooEarly();
        bytes32 h = ChainClock.hash(a.target);
        if (h == bytes32(0)) {
            if (ChainClock.number() <= uint256(a.target) + 256) revert NotConfigured();
            a.target = uint64(ChainClock.number() + 2);
            emit EnhancementRearmed(id, a.target);
            return;
        }
        a.seed = keccak256(abi.encode(h, address(this), id));
        a.captured = true;
        emit EnhancementCaptured(id, a.seed);
    }

    function resolve(uint256 id) external nonReentrant {
        capture(id);
        Attempt storage a = attempts[id];
        if (!a.captured) return;
        a.resolved = true;
        delete pending[a.item];
        (uint256 chance, uint256 burn,,) = EconomyMath.enhancement(a.level);
        bool success = uint256(a.seed) % 100 < chance;
        bool burned = !success && uint256(keccak256(abi.encode(a.seed, "burn"))) % 100 < burn;
        uint8 level = success ? a.level : a.level >= 4 ? a.level - 2 : a.level - 1;
        FarmItems inventory = FarmItems(registry.module(3));
        FarmItems.Item memory x = inventory.data(a.item);
        if (x.holder != a.player || x.equipped) revert InvalidValue();
        if (burned) inventory.destroy(a.item);
        else inventory.maintain(a.item, x.durability, level);
        emit EnhancementResolved(id, success, burned, level);
    }
}
