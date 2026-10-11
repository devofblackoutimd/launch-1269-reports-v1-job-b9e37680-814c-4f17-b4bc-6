// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GameModule} from "./lib/GameModule.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FeeRouter} from "./FeeRouter.sol";
import {Params} from "./Params.sol";
import {FarmItems} from "./FarmItems.sol";
import {ICore} from "./interfaces/IGame.sol";
import {ChainClock} from "./lib/ChainClock.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import "./lib/Errors.sol";

contract StarterClaim is GameModule, ReentrancyGuard {
    struct Claim {
        address player;
        uint64 target;
        bool resolved;
    }

    mapping(uint256 => bool) public entropyCaptured;
    mapping(uint256 => bytes32) public entropyHash;
    mapping(uint256 => Claim) public claims;
    event StarterCommitted(uint256 indexed tokenId, address indexed holder, uint256 target);
    event StarterResolved(uint256 indexed tokenId, bool expired);

    constructor(address registry_) GameModule(registry_) {}

    function root() public view returns (bytes32) {
        return registry.starterRoot();
    }

    function snapshotBlock() public view returns (uint256) {
        return registry.snapshotBlock();
    }

    function launchTime() public view returns (uint256) {
        return registry.launchTime();
    }

    function items() public view returns (FarmItems) {
        return FarmItems(registry.module(3));
    }

    function farm() public view returns (ICore) {
        return ICore(registry.module(2));
    }

    function fees() public view returns (FeeRouter) {
        return FeeRouter(payable(registry.module(6)));
    }

    function claim(uint256 tokenId, bytes32[] calldata proof) external nonReentrant {
        if (block.timestamp < launchTime() + 48 hours || block.timestamp >= launchTime() + 16 days) revert TooEarly();
        if (claims[tokenId].player != address(0)) revert AlreadyDone();
        if (!MerkleProof.verifyCalldata(proof, root(), keccak256(abi.encode(tokenId, msg.sender)))) {
            revert InvalidProof();
        }
        uint64 target = uint64(ChainClock.number() + 2);
        claims[tokenId] = Claim(msg.sender, target, false);
        farm().register(msg.sender);
        emit StarterCommitted(tokenId, msg.sender, target);
    }

    function captureEntropy(uint256 tokenId) external nonReentrant {
        _capture(tokenId, msg.sender);
    }

    function _capture(uint256 tokenId, address keeper) private {
        uint256 startGas = gasleft();
        Claim storage c = claims[tokenId];
        if (c.player == address(0)) revert InvalidValue();
        if (entropyCaptured[tokenId]) return;
        if (ChainClock.number() <= c.target) revert TooEarly();
        entropyHash[tokenId] = ChainClock.hash(c.target);
        entropyCaptured[tokenId] = true;
        fees().payWork(keeper, Params.Key.EntropyBounty, 1, startGas - gasleft());
    }

    function resolve(uint256 tokenId) external nonReentrant {
        Claim storage c = claims[tokenId];
        if (c.player == address(0)) revert InvalidValue();
        if (c.resolved) revert AlreadyDone();
        if (ChainClock.number() <= c.target) revert TooEarly();
        if (items().inventory(c.player) + 3 > items().capacity(c.player)) revert InsufficientBalance();
        c.resolved = true;
        _capture(tokenId, msg.sender);
        bytes32 h = entropyHash[tokenId];
        for (uint256 i; i < 3; ++i) {
            (uint8 k, uint8 r) = ItemMath.draw(keccak256(abi.encode(h, address(this), tokenId, i)), false, true);
            items().mint(c.player, h == bytes32(0) ? 0 : k, h == bytes32(0) ? 1 : r, true);
        }
        emit StarterResolved(tokenId, h == bytes32(0));
    }
}
