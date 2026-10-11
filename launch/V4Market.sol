// SPDX-License-Identifier: MIT
pragma solidity =0.8.26 ^0.8.20;

// src/lib/Errors.sol

error Unauthorized();
error InvalidAddress();
error InvalidValue();
error TooEarly();
error AlreadyDone();
error NotConfigured();
error CatchUpRequired();
error InsufficientBalance();
error InvalidProof();
error TransferFailed();

// src/interfaces/IGameRegistry.sol

interface IGameRegistry {
    function module(uint256 role) external view returns (address);
    function token() external view returns (address);
    function params() external view returns (address);
    function market() external view returns (address);
    function launchTime() external view returns (uint256);
    function starterRoot() external view returns (bytes32);
    function snapshotBlock() external view returns (uint256);
    function endowment() external view returns (uint256);
}

// src/interfaces/ILaunchHook.sol

interface ILaunchHook {
    function initializedAt() external view returns (uint256);
    function fees() external view returns (address);
}

// src/interfaces/IV4.sol

// ABI subset of Uniswap v4-core at 46c6834698c48bc4a463a86d8420f4eb1d7f3b75.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IV4PoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);
    function take(address currency, address to, uint256 amount) external;
    function settle() external payable returns (uint256);
    function extsload(bytes32 slot) external view returns (bytes32);
}

// vendor/openzeppelin/contracts/utils/math/Math.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/math/Math.sol)

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Muldiv operation overflow.
     */
    error MathOverflowedMulDiv();

    enum Rounding {
        Floor, // Toward negative infinity
        Ceil, // Toward positive infinity
        Trunc, // Toward zero
        Expand // Away from zero
    }

    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with an overflow flag.
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
            // benefit is lost if 'b' is also tested.
            // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
            if (a == 0) return (true, 0);
            uint256 c = a * b;
            if (c / a != b) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds towards infinity instead
     * of rounding towards zero.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) {
            // Guarantee the same behavior as in a regular Solidity division.
            return a / b;
        }

        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or
     * denominator == 0.
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv) with further edits by
     * Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // use the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0 = x * y; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            if (denominator <= prod1) {
                revert MathOverflowedMulDiv();
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            // Always >= 1. See https://cs.stackexchange.com/q/138556/92363.

            uint256 twos = denominator & (0 - denominator);
            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Flip twos such that it is 2^256 / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256. Now that denominator is an odd number, it has an inverse modulo 2^256 such
            // that denominator * inv = 1 mod 2^256. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also
            // works in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2^256. Since the preconditions guarantee that the outcome is
            // less than 2^256, this is the final result. We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inverse;
            return result;
        }
    }

    /**
     * @notice Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded
     * towards zero.
     *
     * Inspired by Henry S. Warren, Jr.'s "Hacker's Delight" (Chapter 11).
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        // For our first guess, we get the biggest power of 2 which is smaller than the square root of the target.
        //
        // We know that the "msb" (most significant bit) of our target number `a` is a power of 2 such that we have
        // `msb(a) <= a < 2*msb(a)`. This value can be written `msb(a)=2**k` with `k=log2(a)`.
        //
        // This can be rewritten `2**log2(a) <= a < 2**(log2(a) + 1)`
        // → `sqrt(2**k) <= sqrt(a) < sqrt(2**(k+1))`
        // → `2**(k/2) <= sqrt(a) < 2**((k+1)/2) <= 2**(k/2 + 1)`
        //
        // Consequently, `2**(log2(a) / 2)` is a good first approximation of `sqrt(a)` with at least 1 correct bit.
        uint256 result = 1 << (log2(a) >> 1);

        // At this point `result` is an estimation with one bit of precision. We know the true value is a uint128,
        // since it is the square root of a uint256. Newton's method converges quadratically (precision doubles at
        // every iteration). We thus need at most 7 iteration to turn our partial result with one bit of precision
        // into the expected uint128 result.
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return min(result, a / result);
        }
    }

    /**
     * @notice Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + (unsignedRoundsUp(rounding) && result * result < a ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 2 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log2(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 > 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 > 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 > 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + (unsignedRoundsUp(rounding) && 1 << result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 10 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log10(value);
            return result + (unsignedRoundsUp(rounding) && 10 ** result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 256 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 16;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 8;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 4;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 2;
            }
            if (value >> 8 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 256, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + (unsignedRoundsUp(rounding) && 1 << (result << 3) < value ? 1 : 0);
        }
    }

    /**
     * @dev Returns whether a provided rounding mode is considered rounding up for unsigned integers.
     */
    function unsignedRoundsUp(Rounding rounding) internal pure returns (bool) {
        return uint8(rounding) % 2 == 1;
    }
}

// src/lib/ModuleCode.sol

/// @notice Generated by tools/pin_module_code.py. Exact compiler-pinned creation code, no links.
library ModuleCode {
    function hash(uint256 role) internal pure returns (bytes32) {
        if (role == 0) return 0xd6435d02bfa2143c1cb06523dad28201251243efadd4bd240a3a2beea2ffffef; // RewardPool
        if (role == 1) return 0x001e79788b01c24a4e0612d7f52fb4f5aaed995e36054606c3201c4af3c200a3; // FarmRewards
        if (role == 2) return 0x4846b88e5484758ed90201acbda9847e0e8e337dae509e8ed18c29e2778b1a58; // FarmCore
        if (role == 3) return 0xd627320cdc423d7b87c70501f13131f89874bcd4dc85c1aead2309d8e45fd4cb; // FarmItems
        if (role == 4) return 0xda70d8b26423e792c46c5ae5dc880e79ca0b7ab8bab0707ae12725079a5f49fd; // PackSale
        if (role == 5) return 0xae7e9c4e63147f0ad8dd20a6a940a6defea33194bae522541969cda060ab0917; // StarterClaim
        if (role == 6) return 0xf871cf06ad7e841f290482a5a86fede4cae2f6622feb47b024407ff96586b513; // FeeRouter
        if (role == 7) return 0x8ff966ab42ea55f03762202a21f3c44027fe45b54d04b44d1eb56753e973f435; // GridOperator
        if (role == 8) return 0xfb73bb80fa19d21130480751d976292c0201624c6d4c17f28e5f385699656c91; // Season
        if (role == 9) return 0x6aafb48a0f19c15289e8aeeed3e7d066185e4342e9a63ce626d7e37bc0ad4c84; // FarmEngine
        return bytes32(0);
    }
}

// vendor/openzeppelin/contracts/utils/ReentrancyGuard.sol

// OpenZeppelin Contracts (last updated v5.0.0) (utils/ReentrancyGuard.sol)

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}

// src/GameRegistry.sol

interface IApplicationFactory {
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata initCode)
        external
        view
        returns (address);
}

/// @notice No owner and no replacements. Enrollment proves canonical factory deployment of exact initcode.
contract GameRegistry is IGameRegistry {
    address public immutable token;
    address public immutable params;
    address public immutable market;

    bytes32 public immutable starterRoot;
    uint256 public immutable snapshotBlock;
    uint256 public immutable endowment;
    IApplicationFactory public immutable factory;
    mapping(uint256 => address) private modules;
    uint256 public registered;
    event Registered(uint256 indexed role, address indexed module, uint64 launchNumber, uint256 index);

    constructor(
        address token_,
        address params_,
        address market_,
        bytes32 root_,
        uint256 snapshot_,
        uint256 endowment_,
        address factory_
    ) {
        if (
            token_ == address(0) || params_ == address(0) || market_ == address(0) || factory_ == address(0)
                || root_ == bytes32(0) || snapshot_ == 0 || endowment_ > 250_000_000 ether
        ) revert InvalidValue();
        token = token_;
        params = params_;
        market = market_;
        starterRoot = root_;
        snapshotBlock = snapshot_;
        endowment = endowment_;
        factory = IApplicationFactory(factory_);
    }

    function launchTime() external view returns (uint256) {
        uint256 t = ILaunchHook(market).initializedAt();
        if (t == 0) revert NotConfigured();
        return t;
    }

    function module(uint256 role) external view returns (address result) {
        result = modules[role];
        if (result == address(0)) revert NotConfigured();
    }

    function registeredModule(uint256 role) external view returns (address) {
        return modules[role];
    }

    function creationCodeHash(uint256 role) external pure returns (bytes32) {
        if (role >= 10) revert InvalidValue();
        return ModuleCode.hash(role);
    }

    /// @dev Runtime hash alone cannot prove safe initial storage. CREATE2 over exact initcode can.
    function register(uint256 role, uint64 launchNumber, uint256 index, bytes calldata creationCode)
        external
        returns (address deployed)
    {
        if (role >= 10 || index >= 8 || launchNumber == 0 || keccak256(creationCode) != ModuleCode.hash(role)) {
            revert InvalidValue();
        }
        if (modules[role] != address(0)) revert AlreadyDone();
        deployed = factory.predictContract(launchNumber, index, bytes.concat(creationCode, abi.encode(address(this))));
        if (deployed.code.length == 0) revert NotConfigured();
        modules[role] = deployed;
        registered++;
        emit Registered(role, deployed, launchNumber, index);
    }
}

// src/V4Market.sol

interface IHookParams {
    function get(uint8 key) external view returns (uint256);
}

interface IHookRouter {
    function registry() external view returns (address);
    function token() external view returns (address);
    function market() external view returns (address);
    function params() external view returns (address);
    function depositBaseFee() external payable;
    function depositSellTax() external payable;
    function depositLaunchTax() external payable;
}

/// @notice Optional, immutable ETH/token v4 hook + buy adapter. Must be selected as the launch pool's hook.
/// @dev Implements the TOTAL IMD-style fee (not an add-on to a second 1.25% fee hook).
contract V4Market is ReentrancyGuard {
    uint256 public constant TOTAL_CAP_BPS = 1500;
    uint256 public constant NETWORK_BPS = 25;
    uint160 public constant HOOK_FLAGS = 0x10cc; // afterInitialize, before/afterSwap and both swap deltas
    IV4PoolManager public immutable manager;
    address public immutable token;
    address public immutable launcher;
    bytes32 public immutable gameConfigHash;
    IApplicationFactory public immutable applicationFactory;
    IHookParams public params;
    IHookRouter public fees;
    uint256 public heldBase;
    uint256 public heldSellTax;
    uint256 public heldLaunchTax;
    /// @notice Launch protection, fixed in bytecode and anchored to the pool's one-time initialization.
    uint256 public constant LAUNCH_TAX_BPS = 9000;
    uint256 public constant LAUNCH_TAX_DECAY = 30 minutes;
    uint256 public constant LAUNCH_TAX_STEP = 10 minutes;
    event Bound(address indexed router, address indexed params);
    event FeesFlushed(uint256 base, uint256 sellTax);
    event LaunchTaxFlushed(uint256 amount);
    event LaunchTax(address indexed sender, uint256 ethInput, uint256 taxBps, uint256 launchTax);
    address public immutable networkRecipient;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    bytes32 public immutable poolId;
    uint256 public networkCredit;

    struct Volume {
        uint64 period;
        uint192 sells;
        uint192 buys;
    }
    Volume[12] private shortVolumes;
    Volume[24] private longVolumes;

    struct Observation {
        uint64 minute;
        uint256 cumulative;
    }
    Observation[32] private observations;
    uint256 public initializedAt;
    uint256 public updatedAt;
    uint256 public cumulative;
    uint256 public lastPrice;
    uint256 public storedFeeWad = 200 ether;
    uint256 public feeTimestamp;
    bool private buying;
    event PriceObserved(uint256 timestamp, uint256 tokensPerETH);
    event SellFee(
        address indexed sender,
        uint256 ethOutput,
        uint256 feeBps,
        uint256 hourImbalance,
        uint256 dayImbalance,
        uint256 deviation
    );
    event NetworkPaid(uint256 amount);

    constructor(
        address manager_,
        address token_,
        address network_,
        uint24 fee_,
        int24 spacing_,
        address launcher_,
        address factory_,
        bytes32 gameConfigHash_
    ) {
        if (
            gameConfigHash_ == bytes32(0) || launcher_ == address(0) || factory_ == address(0) || manager_ == address(0)
                || token_ == address(0) || network_ == address(0) || spacing_ <= 0 || spacing_ > 32767 || fee_ != 0
        ) revert InvalidValue();
        gameConfigHash = gameConfigHash_;
        launcher = launcher_;
        applicationFactory = IApplicationFactory(factory_);
        manager = IV4PoolManager(manager_);
        token = token_;
        networkRecipient = network_;
        poolFee = fee_;
        tickSpacing = spacing_;
        poolId = keccak256(abi.encode(PoolKey(address(0), token_, fee_, spacing_, address(this))));
        _validateHookAddress();
    }

    /// @notice Permissionless, one-time binding to a canonical factory-deployed registry and its pinned FeeRouter.
    /// The proof supplies only the registry's deployment coordinates. All configuration is read and committed
    /// into its exact creation code; a look-alike registry cannot pass the CREATE2 prediction.
    function bindFeeRouter(address router, uint64 registryLaunch, uint256 registryIndex) external nonReentrant {
        if (address(fees) != address(0)) revert AlreadyDone();
        if (router.code.length == 0) revert InvalidAddress();
        if (registryLaunch == 0 || registryIndex >= 8) revert InvalidValue();
        IHookRouter candidate = IHookRouter(router);
        GameRegistry r = GameRegistry(candidate.registry());
        if (
            address(r.factory()) != address(applicationFactory) || r.token() != token || !_routerMarketValid(r.market())
        ) revert InvalidValue();
        if (
            keccak256(
                    abi.encode(
                        r.params(), r.starterRoot(), r.snapshotBlock(), r.endowment(), registryLaunch, registryIndex
                    )
                ) != gameConfigHash
        ) revert InvalidProof();
        bytes memory args = abi.encode(
            r.token(),
            r.params(),
            r.market(),
            r.starterRoot(),
            r.snapshotBlock(),
            r.endowment(),
            address(applicationFactory)
        );
        // Concatenation has a fixed, pinned creation-code prefix and one ABI tuple; no packed dynamic tuple.
        bytes memory initCode = bytes.concat(type(GameRegistry).creationCode, args);
        if (applicationFactory.predictContract(registryLaunch, registryIndex, initCode) != address(r)) {
            revert InvalidProof();
        }
        // Enrollment proves exact FeeRouter initcode (including registry) and its factory CREATE2 address.
        if (
            r.module(6) != router || candidate.token() != token || candidate.market() != r.market()
                || candidate.params() != r.params()
        ) revert InvalidValue();
        fees = candidate;
        params = IHookParams(r.params());
        emit Bound(router, r.params());
    }

    /// @notice Permissionless forwarding, kept separate so a receiver cannot interrupt pool swaps.
    function flushFees() external nonReentrant {
        if (address(fees) == address(0)) revert NotConfigured();
        uint256 base = heldBase;
        uint256 excess = heldSellTax;
        uint256 launchTax = heldLaunchTax;
        if (base + excess + launchTax == 0) revert InsufficientBalance();
        heldBase = 0;
        heldSellTax = 0;
        heldLaunchTax = 0;
        if (base != 0) fees.depositBaseFee{value: base}();
        if (excess != 0) fees.depositSellTax{value: excess}();
        if (launchTax != 0) fees.depositLaunchTax{value: launchTax}();
        emit FeesFlushed(base, excess);
        if (launchTax != 0) emit LaunchTaxFlushed(launchTax);
    }

    function _routerMarketValid(address market_) internal view virtual returns (bool) {
        return market_ == address(this);
    }

    function _coefficient(uint8 key_, uint256 default_) private view returns (uint256) {
        return address(params) == address(0) ? default_ : params.get(key_);
    }

    function _validateHookAddress() internal view virtual {
        if (uint160(address(this)) & 0x3fff != HOOK_FLAGS) revert InvalidAddress();
    }

    receive() external payable {
        if (msg.sender != address(manager)) revert Unauthorized();
    }

    function key() public view returns (PoolKey memory) {
        return PoolKey(address(0), token, poolFee, tickSpacing, address(this));
    }

    function _check(PoolKey calldata k) private view {
        if (msg.sender != address(manager) || keccak256(abi.encode(k)) != poolId) revert Unauthorized();
    }

    function spot() public view returns (uint256) {
        uint256 sqrt = uint160(uint256(manager.extsload(keccak256(abi.encode(poolId, uint256(6))))));
        if (sqrt == 0) revert NotConfigured();
        uint256 price = Math.mulDiv(Math.mulDiv(sqrt, sqrt, 1 << 96), 1 ether, 1 << 96);
        if (price == 0 || price > 1e40) revert InvalidValue();
        return price;
    }

    function afterInitialize(address sender, PoolKey calldata k, uint160, int24) external returns (bytes4) {
        _check(k);
        if (sender != launcher) revert Unauthorized();
        if (initializedAt != 0) revert AlreadyDone();
        initializedAt = block.timestamp;
        _observe(spot());
        return this.afterInitialize.selector;
    }

    function _observe(uint256 price) private {
        uint256 now_ = block.timestamp;
        if (initializedAt == 0) revert NotConfigured();
        if (updatedAt == 0) {
            updatedAt = now_;
            lastPrice = price;
            emit PriceObserved(now_, price);
            return;
        }
        uint256 first = updatedAt / 60 + 1;
        uint256 last = now_ / 60;
        if (last >= 32 && first < last - 31) first = last - 31;
        for (uint256 minute = first; minute <= last; ++minute) {
            uint256 c = cumulative + (1e60 / lastPrice) * (minute * 60 - updatedAt);
            observations[minute % 32] = Observation(uint64(minute), c);
        }
        cumulative += (1e60 / lastPrice) * (now_ - updatedAt);
        updatedAt = now_;
        lastPrice = price;
        emit PriceObserved(now_, price);
    }

    function _cumulativeAt(uint256 minute) private view returns (uint256) {
        uint256 ts = minute * 60;
        if (ts < initializedAt) revert NotConfigured();
        if (ts >= updatedAt) return cumulative + (1e60 / lastPrice) * (ts - updatedAt);
        Observation memory o = observations[minute % 32];
        if (o.minute != minute) revert NotConfigured();
        return o.cumulative;
    }

    function twap() public view returns (uint256) {
        if (initializedAt == 0 || block.timestamp < initializedAt + 31 minutes) revert NotConfigured();
        uint256 minute = block.timestamp / 60;
        uint256 averageETH = (_cumulativeAt(minute) - _cumulativeAt(minute - 30)) / 30 minutes;
        return 1e60 / averageETH;
    }

    function quote(uint256 ethAmount) external view returns (uint256) {
        uint256 netInput = ethAmount - ethAmount * (projectBps() + NETWORK_BPS) / 10000;
        return Math.mulDiv(netInput, twap(), 1 ether);
    }

    function _record(bool sell, uint256 amount) private {
        if (amount > type(uint192).max) revert InvalidValue();
        uint256 p = block.timestamp / 5 minutes;
        Volume storage a = shortVolumes[p % 12];
        if (a.period != p) {
            delete shortVolumes[p % 12];
            a.period = uint64(p);
        }
        p = block.timestamp / 1 hours;
        Volume storage b = longVolumes[p % 24];
        if (b.period != p) {
            delete longVolumes[p % 24];
            b.period = uint64(p);
        }
        if (sell) {
            a.sells += uint192(amount);
            b.sells += uint192(amount);
        } else {
            a.buys += uint192(amount);
            b.buys += uint192(amount);
        }
    }

    function imbalances() public view returns (uint256 hour, uint256 day) {
        uint256 s;
        uint256 b;
        uint256 current = block.timestamp / 5 minutes;
        for (uint256 i; i < 12; ++i) {
            if (uint256(shortVolumes[i].period) + 12 > current) {
                s += shortVolumes[i].sells;
                b += shortVolumes[i].buys;
            }
        }
        if (s > b) hour = Math.mulDiv(s - b, 10000, s + b + 0.5 ether);
        s = 0;
        b = 0;
        current = block.timestamp / 1 hours;
        for (uint256 i; i < 24; ++i) {
            if (uint256(longVolumes[i].period) + 24 > current) {
                s += longVolumes[i].sells;
                b += longVolumes[i].buys;
            }
        }
        if (s > b) day = Math.mulDiv(s - b, 10000, s + b + 2 ether);
    }

    function projectBps() public pure virtual returns (uint256) {
        return 200;
    }

    /// @notice Seconds since the pool was initialized (token launch). Zero before initialization.
    function sinceLaunch() public view returns (uint256) {
        return initializedAt == 0 ? 0 : block.timestamp - initializedAt;
    }

    /// @notice Immutable total buy-tax steps; the entire stepped tax funds reward buys.
    function currentBuyTaxBps() public view returns (uint256) {
        uint256 t = sinceLaunch();
        if (t < 10 minutes) return 9000;
        if (t < 20 minutes) return 5000;
        if (t < 30 minutes) return 2500;
        return projectBps() + NETWORK_BPS;
    }

    function launchTaxTimeLeft() public view returns (uint256) {
        uint256 t = sinceLaunch();
        return t >= LAUNCH_TAX_DECAY ? 0 : LAUNCH_TAX_DECAY - t;
    }

    function nextStepIn() public view returns (uint256) {
        uint256 t = sinceLaunch();
        return t >= LAUNCH_TAX_DECAY ? 0 : LAUNCH_TAX_STEP - t % LAUNCH_TAX_STEP;
    }

    /// @notice Compatibility views: buys are unlimited from the first block.
    function maxBuy() public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxBuyTimeLeft() public pure returns (uint256) {
        return 0;
    }

    function launchStatus() external view returns (uint256, uint256, uint256, uint256) {
        return (currentBuyTaxBps(), launchTaxTimeLeft(), type(uint256).max, 0);
    }

    function _sellFee(uint256 price) private returns (uint256 fee, uint256 hour, uint256 day, uint256 dev) {
        if (projectBps() == 100) return (100, 0, 0, 0);
        (hour, day) = imbalances();
        uint256 average;
        // Trading is possible during warmup; the deviation component starts only when TWAP is ready.
        if (block.timestamp >= initializedAt + 31 minutes) average = twap();
        if (average != 0 && price > average) dev = Math.min(1000, 10000 - Math.mulDiv(average, 10000, price));
        uint256 target = projectBps() + _coefficient(24, 500) * hour / 10000 + _coefficient(25, 400) * day / 10000
            + _coefficient(26, 5000) * dev / 10000;
        target = Math.min(TOTAL_CAP_BPS - NETWORK_BPS, target) * 1 ether;
        uint256 fall = feeTimestamp == 0 ? 0 : (block.timestamp - feeTimestamp) * 100 ether / 10 minutes;
        uint256 decayed = storedFeeWad > fall ? storedFeeWad - fall : projectBps() * 1 ether;
        storedFeeWad = Math.max(target, decayed);
        feeTimestamp = block.timestamp;
        fee = Math.min(TOTAL_CAP_BPS - NETWORK_BPS, (storedFeeWad + 1 ether - 1) / 1 ether);
    }

    function beforeSwap(address sender, PoolKey calldata k, SwapParams calldata p, bytes calldata)
        external
        returns (bytes4, int256, uint24)
    {
        _check(k);
        if (p.amountSpecified >= 0) revert InvalidValue();
        _observe(spot());
        if (!p.zeroForOne) return (this.beforeSwap.selector, 0, 0);
        uint256 ethIn = uint256(-p.amountSpecified);
        uint256 taxBps = currentBuyTaxBps();
        uint256 fee = ethIn * taxBps / 10000;
        if (fee > uint256(uint128(type(int128).max))) revert InvalidValue();
        if (sinceLaunch() < LAUNCH_TAX_DECAY) {
            manager.take(address(0), address(this), fee);
            heldLaunchTax += fee;
            emit LaunchTax(sender, ethIn, taxBps, fee);
        } else {
            uint256 base = ethIn * projectBps() / 10000;
            _take(base, 0, fee - base);
        }
        return (this.beforeSwap.selector, int256(fee << 128), 0);
    }

    function afterSwap(address sender, PoolKey calldata k, SwapParams calldata p, int256 delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        _check(k);
        if (p.amountSpecified >= 0) revert InvalidValue();
        uint256 price = spot();
        _observe(price);
        int128 ethDelta = int128(delta >> 128);
        if (p.zeroForOne) {
            if (ethDelta >= 0) revert InvalidValue();
            _record(false, uint256(-int256(ethDelta)));
            return (this.afterSwap.selector, 0);
        }
        if (ethDelta <= 0) revert InvalidValue();
        uint256 output = uint256(uint128(ethDelta));
        _record(true, output);
        (uint256 bps, uint256 hour, uint256 day, uint256 dev) = _sellFee(price);
        uint256 base = output * projectBps() / 10000;
        uint256 excess = output * (bps - projectBps()) / 10000;
        uint256 network = output * NETWORK_BPS / 10000;
        _take(base, excess, network);
        emit SellFee(sender, output, bps, hour, day, dev);
        return (this.afterSwap.selector, int128(int256(base + excess + network)));
    }

    function _take(uint256 base, uint256 excess, uint256 network) private {
        uint256 total = base + excess + network;
        if (total != 0) manager.take(address(0), address(this), total);
        heldBase += base;
        heldSellTax += excess;
        networkCredit += network;
    }

    function buy(uint256 minOut, address recipient) external payable nonReentrant returns (uint256 received) {
        if (msg.sender != address(fees) || recipient == address(0) || msg.value == 0 || minOut == 0) {
            revert Unauthorized();
        }
        if (initializedAt == 0 || sinceLaunch() < LAUNCH_TAX_DECAY) revert TooEarly();
        twap();
        buying = true;
        received = abi.decode(manager.unlock(abi.encode(msg.value, minOut, recipient)), (uint256));
        buying = false;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || !buying) revert Unauthorized();
        (uint256 ethIn, uint256 minOut, address recipient) = abi.decode(data, (uint256, uint256, address));
        uint256 base = ethIn * projectBps() / 10000;
        uint256 network = ethIn * 25 / 10000;
        uint256 input = ethIn - base - network;
        _observe(spot());
        // v4 suppresses a hook's callbacks on its own swaps. Account for this system buy explicitly.
        int256 delta = manager.swap(key(), SwapParams(true, -int256(input), 4295128740), "");
        _observe(spot());
        int128 ethDelta = int128(delta >> 128);
        int128 tokenDelta = int128(delta);
        if (
            ethDelta >= 0 || uint256(-int256(ethDelta)) != input || tokenDelta <= 0
                || uint256(uint128(tokenDelta)) < minOut
        ) {
            revert InsufficientBalance();
        }
        _record(false, input);
        manager.settle{value: input}();
        manager.take(token, recipient, uint256(uint128(tokenDelta)));
        networkCredit += network;
        heldBase += base;
        return abi.encode(uint256(uint128(tokenDelta)));
    }

    function withdrawNetwork() external nonReentrant {
        uint256 amount = networkCredit;
        if (amount == 0) revert InsufficientBalance();
        networkCredit = 0;
        (bool ok,) = networkRecipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit NetworkPaid(amount);
    }
}
