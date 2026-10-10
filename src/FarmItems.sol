// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ItemMath} from "./lib/ItemMath.sol";
import "./lib/Errors.sol";

contract FarmItems is ERC1155 {
    address public immutable packSale;
    address public immutable starterClaim;
    address public immutable farmCore;

    constructor(address packs, address starter, address core) ERC1155("") {
        if (packs == address(0) || starter == address(0) || core == address(0)) revert InvalidAddress();
        packSale = packs;
        starterClaim = starter;
        farmCore = core;
    }

    function mint(address to, uint256 id) external {
        (,,, bool starter) = ItemMath.decode(id);
        if (starter ? msg.sender != starterClaim : msg.sender != packSale) revert Unauthorized();
        _mint(to, id, 1, "");
    }

    function burnForMerge(address from, uint256 id) external {
        if (msg.sender != packSale) revert Unauthorized();
        _burn(from, id, 3);
    }

    function uri(uint256 id) public pure override returns (string memory) {
        (uint256 kind, uint256 rarity, uint256 epoch, bool starter) = ItemMath.decode(id);
        string[7] memory kinds = ["GPU", "ASIC", "Power Supply", "Cooling", "Motherboard", "Router", "Room Key"];
        string[4] memory rarities = ["Common", "Rare", "Epic", "Legendary"];
        bytes memory json = abi.encodePacked(
            '{"name":"BLACKOUT ',
            rarities[rarity],
            " ",
            kinds[kind],
            '","description":"BLACKOUT farm equipment. Room keys unlock one of three additional six-slot rooms.","attributes":[',
            '{"trait_type":"Type","value":"',
            kinds[kind],
            '"},{"trait_type":"Rarity","value":"',
            rarities[rarity],
            '"},{"trait_type":"Mint epoch","value":',
            Strings.toString(epoch + 1),
            '},{"trait_type":"Mint hash bonus bps","value":',
            Strings.toString(ItemMath.epochBonus(id)),
            '},{"trait_type":"Edition","value":"',
            starter ? "Starter" : "Paid",
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory amounts) internal override {
        if (from != address(0) && to != address(0)) {
            for (uint256 i; i < ids.length; ++i) {
                (,,, bool starter) = ItemMath.decode(ids[i]);
                if (starter && from != farmCore && to != farmCore) revert Unauthorized();
            }
        }
        super._update(from, to, ids, amounts);
    }
}
