// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./lib/Errors.sol";

/// @notice Each ERC1155 id is one soulbound item; durability and overclock survive custody changes.
contract FarmItems is ERC1155, ReentrancyGuard {
    struct Item {
        address holder;
        uint16 durability;
        uint8 kind;
        uint8 rarity;
        uint8 overclock;
        bool starter;
        bool equipped;
    }
    address public immutable engine;
    address public immutable packSale;
    address public immutable starterClaim;
    address public immutable farmCore;
    address public immutable season;
    uint256 public nextId = 1;
    mapping(uint256 => Item) public item;
    mapping(address => uint256) public inventory;
    mapping(address => uint256) public expansions;
    event ItemChanged(uint256 indexed id, uint256 durability, uint256 overclock);

    constructor(address packs, address starter, address core, address season_, address engine_)
        ERC1155("BLACKOUT-v3:soulbound")
    {
        if (
            packs == address(0) || starter == address(0) || core == address(0) || season_ == address(0)
                || engine_ == address(0)
        ) {
            revert InvalidAddress();
        }
        engine = engine_;
        packSale = packs;
        starterClaim = starter;
        farmCore = core;
        season = season_;
    }
    modifier onlyCore() {
        if (msg.sender != farmCore) revert Unauthorized();
        _;
    }

    function capacity(address p) public view returns (uint256) {
        return 15 + 5 * expansions[p];
    }

    function data(uint256 id) external view returns (Item memory) {
        return item[id];
    }

    function mint(address p, uint8 k, uint8 r, bool starter) external nonReentrant returns (uint256 id) {
        if (starter
                ? msg.sender != starterClaim
                : (msg.sender != packSale && msg.sender != farmCore && msg.sender != season)) {
            revert Unauthorized();
        }
        if (p == address(0) || k >= 12 || r >= 5 || inventory[p] >= capacity(p)) revert InvalidValue();
        id = nextId++;
        item[id] = Item(p, 10000, k, r, 0, starter, false);
        inventory[p]++;
        _mint(p, id, 1, "");
    }

    function equip(address p, uint256 id) external onlyCore {
        Item storage x = item[id];
        if (x.holder != p || x.equipped) revert Unauthorized();
        x.equipped = true;
        inventory[p]--;
        _safeTransferFrom(p, farmCore, id, 1, "");
    }

    function unequip(address p, uint256 id) external onlyCore {
        Item storage x = item[id];
        if (x.holder != p || !x.equipped || inventory[p] >= capacity(p)) revert InvalidValue();
        x.equipped = false;
        inventory[p]++;
        _safeTransferFrom(farmCore, p, id, 1, "");
    }

    function destroy(uint256 id) external {
        if (msg.sender != farmCore && msg.sender != engine) revert Unauthorized();
        Item memory x = item[id];
        if (x.holder == address(0)) revert InvalidValue();
        delete item[id];
        if (!x.equipped) inventory[x.holder]--;
        _burn(x.equipped ? farmCore : x.holder, id, 1);
    }

    function maintain(uint256 id, uint16 durability, uint8 overclock) external {
        if (msg.sender != farmCore && msg.sender != engine) revert Unauthorized();
        if (item[id].holder == address(0) || durability > 10000 || overclock > 5) revert InvalidValue();
        item[id].durability = durability;
        item[id].overclock = overclock;
        emit ItemChanged(id, durability, overclock);
    }

    function expand(address p) external onlyCore {
        expansions[p]++;
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Unauthorized();
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory amounts) internal override {
        if (from != address(0) && to != address(0) && msg.sender != farmCore) revert Unauthorized();
        super._update(from, to, ids, amounts);
    }
}
