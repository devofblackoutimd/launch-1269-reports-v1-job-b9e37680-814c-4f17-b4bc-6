// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Params} from "./Params.sol";
import {FarmItems} from "./FarmItems.sol";
import {IFarm} from "./interfaces/Interfaces.sol";
import {ChainClock} from "./lib/ChainClock.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import "./lib/Errors.sol";

contract StarterClaim is ReentrancyGuard {
    struct Claim {
        address player;
        uint64 target;
        uint8 epoch;
        uint16 bonusBps;
        bool resolved;
    }
    bytes32 public immutable root;
    uint256 public immutable snapshotBlock;
    uint256 public immutable launchTime;
    FarmItems public immutable items;
    Params public immutable params;
    IFarm public immutable farm;
    mapping(uint256 => Claim) public claims;
    event StarterCommitted(uint256 indexed tokenId, address indexed holder, uint256 target);
    event StarterResolved(uint256 indexed tokenId, bool expired, uint256[3] ids);

    constructor(bytes32 root_, uint256 snapshot_, uint256 launch_, address items_, address farm_, address params_) {
        if (
            root_ == bytes32(0) || snapshot_ == 0 || launch_ == 0 || items_ == address(0) || farm_ == address(0)
                || params_ == address(0)
        ) {
            revert InvalidValue();
        }
        root = root_;
        snapshotBlock = snapshot_;
        launchTime = launch_;
        items = FarmItems(items_);
        farm = IFarm(farm_);
        params = Params(params_);
    }

    function claim(uint256 tokenId, bytes32[] calldata proof) external nonReentrant {
        if (block.timestamp < launchTime + 48 hours || block.timestamp >= launchTime + 16 days) revert TooEarly();
        if (claims[tokenId].player != address(0)) revert AlreadyDone();
        if (!MerkleProof.verifyCalldata(proof, root, keccak256(abi.encode(tokenId, msg.sender)))) {
            revert InvalidProof();
        }
        uint256 target = ChainClock.number() + 2;
        uint256 e = (block.timestamp - launchTime) / 7 days;
        claims[tokenId] = Claim(
            msg.sender,
            uint64(target),
            uint8(e),
            uint16(e * params.get(Params.Key.EpochHashBps) > 4000 ? 4000 : e * params.get(Params.Key.EpochHashBps)),
            false
        );
        farm.register(msg.sender);
        emit StarterCommitted(tokenId, msg.sender, target);
    }

    function resolve(uint256 tokenId) external nonReentrant {
        Claim storage c = claims[tokenId];
        if (c.player == address(0)) revert InvalidValue();
        if (c.resolved) revert AlreadyDone();
        if (ChainClock.number() <= c.target) revert TooEarly();
        c.resolved = true;
        bytes32 h = ChainClock.hash(c.target);
        bool expired = h == bytes32(0);
        uint256[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            ids[i] = expired
                ? ItemMath.encode(0, 1, c.epoch, true)
                : ItemMath.draw(keccak256(abi.encode(h, address(this), tokenId, i)), c.epoch, true, false);
            ids[i] = ItemMath.withBonus(ids[i], c.bonusBps);
            items.mint(c.player, ids[i]);
        }
        emit StarterResolved(tokenId, expired, ids);
    }
}
