// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import "./Errors.sol";

library ItemMath {
    uint256 internal constant STARTER = 1 << 16;
    uint256 internal constant BONUS_SHIFT = 24;

    // IDs 1..140; 7 kinds, 4 rarities, 5 mint epochs. Zero means an empty slot.
    function encode(uint256 kind, uint256 rarity, uint256 epoch, bool starter) internal pure returns (uint256) {
        if (kind > 6 || rarity > 3 || epoch > 4) revert InvalidValue();
        return 1 + kind * 4 + rarity + 28 * epoch + (starter ? STARTER : 0) + ((epoch * 1000) << BONUS_SHIFT);
    }

    function decode(uint256 id) internal pure returns (uint256 kind, uint256 rarity, uint256 epoch, bool starter) {
        starter = id & STARTER != 0;
        uint256 plain = id & (STARTER - 1);
        if (id >> BONUS_SHIFT > 4000 || id & (uint256(127) << 17) != 0) revert InvalidValue();
        if (plain == 0 || plain > 140) revert InvalidValue();
        --plain;
        kind = (plain % 28) / 4;
        rarity = plain % 4;
        epoch = plain / 28;
    }

    function withBonus(uint256 id, uint256 bonus) internal pure returns (uint256) {
        if (bonus > 4000) revert InvalidValue();
        return (id & ((1 << BONUS_SHIFT) - 1)) | (bonus << BONUS_SHIFT);
    }

    function epochBonus(uint256 id) internal pure returns (uint256) {
        return id >> BONUS_SHIFT;
    }

    function baseHash(uint256 rarity) internal pure returns (uint256) {
        return uint256(rarity == 0 ? 10 : rarity == 1 ? 28 : rarity == 2 ? 80 : 250) * 1e18;
    }

    function draw(bytes32 seed, uint256 epoch, bool starter, bool expired) internal pure returns (uint256) {
        // GPU30 ASIC30 PSU12 Cooling12 Motherboard4 Router4 Room8. See design decisions.
        uint256 x = uint256(seed) % 100;
        uint256 kind = x < 30 ? 0 : x < 60 ? 1 : x < 72 ? 2 : x < 84 ? 3 : x < 88 ? 4 : x < 92 ? 5 : 6;
        uint256 r = (uint256(seed) >> 64) % 100;
        uint256 rarity = r < 70 ? 0 : r < 92 ? 1 : r < 99 ? 2 : 3;
        if (starter) rarity = expired ? 1 : (r < 92 ? 1 : 2);
        else if (expired) rarity = 0;
        return encode(kind, rarity, epoch, starter);
    }
}
