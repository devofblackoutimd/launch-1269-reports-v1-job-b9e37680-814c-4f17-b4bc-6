// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FarmItems} from "./FarmItems.sol";
import {ICore} from "./interfaces/IGame.sol";
import {ChainClock} from "./lib/ChainClock.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import "./lib/Errors.sol";

contract StarterClaim is ReentrancyGuard {
    struct Claim {
        address player;
        uint64 target;
        bool resolved;
    }
    bytes32 public immutable root;
    uint256 public immutable snapshotBlock;
    uint256 public immutable launchTime;
    FarmItems public immutable items;
    ICore public immutable farm;
    mapping(uint256 => Claim) public claims;
    event StarterCommitted(uint256 indexed tokenId, address indexed holder, uint256 target);
    event StarterResolved(uint256 indexed tokenId, bool expired);

    constructor(bytes32 root_, uint256 snapshot_, uint256 launch_, address items_, address farm_) {
        if (root_ == bytes32(0) || snapshot_ == 0 || launch_ == 0 || items_ == address(0) || farm_ == address(0)) {
            revert InvalidValue();
        }
        root = root_;
        snapshotBlock = snapshot_;
        launchTime = launch_;
        items = FarmItems(items_);
        farm = ICore(farm_);
    }

    function claim(uint256 tokenId, bytes32[] calldata proof) external nonReentrant {
        if (block.timestamp < launchTime + 48 hours || block.timestamp >= launchTime + 16 days) revert TooEarly();
        if (claims[tokenId].player != address(0)) revert AlreadyDone();
        if (!MerkleProof.verifyCalldata(proof, root, keccak256(abi.encode(tokenId, msg.sender)))) {
            revert InvalidProof();
        }
        uint64 target = uint64(ChainClock.number() + 2);
        claims[tokenId] = Claim(msg.sender, target, false);
        farm.register(msg.sender);
        emit StarterCommitted(tokenId, msg.sender, target);
    }

    function resolve(uint256 tokenId) external nonReentrant {
        Claim storage c = claims[tokenId];
        if (c.player == address(0)) revert InvalidValue();
        if (c.resolved) revert AlreadyDone();
        if (ChainClock.number() <= c.target) revert TooEarly();
        if (items.inventory(c.player) + 3 > items.capacity(c.player)) revert InsufficientBalance();
        c.resolved = true;
        bytes32 h = ChainClock.hash(c.target);
        for (uint256 i; i < 3; ++i) {
            (uint8 k, uint8 r) = ItemMath.draw(keccak256(abi.encode(h, address(this), tokenId, i)), false, true);
            items.mint(c.player, h == bytes32(0) ? 0 : k, h == bytes32(0) ? 1 : r, true);
        }
        emit StarterResolved(tokenId, h == bytes32(0));
    }
}
