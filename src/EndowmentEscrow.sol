// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGameRegistry} from "./interfaces/IGameRegistry.sol";
import {SwarmCode} from "./lib/SwarmCode.sol";
import {ModuleCode} from "./lib/ModuleCode.sol";
import "./lib/Errors.sol";

interface IEscrowFactory {
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata initCode)
        external
        view
        returns (address);
}

interface IEscrowRecords {
    function isRecorded(uint64 launchNumber) external view returns (bool);
}

interface IEscrowRegistry is IGameRegistry {
    function factory() external view returns (address);
}

interface IEscrowDesk {
    function registry() external view returns (address);
}

interface IEscrowParams {
    function swarmWallet() external view returns (address);
}

/// @notice v3.8 remainderTo target of the token launch. Ownerless, no withdrawal, one exit only:
/// forward the whole balance of the canonical game's token to its authenticated RewardPool, once.
/// @dev Deployed after the SwarmDesk bootstrap and before the token launch, so it needs no launch
/// number: the canonical game is the one the pinned Desk bound to, proven at forward time with the
/// ProjectFactory's CREATE2 prediction, its launch record and the pinned Registry/RewardPool code.
contract EndowmentEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public immutable records;
    address public immutable desk;
    bool public forwarded;
    event Forwarded(address indexed registry, address indexed pool, address indexed token, uint256 amount);

    constructor(address factory_, address records_, address desk_) {
        if (factory_ == address(0) || records_ == address(0) || desk_ == address(0) || factory_ == desk_) {
            revert InvalidValue();
        }
        factory = factory_;
        records = records_;
        desk = desk_;
    }

    /// @notice Permissionless. Proves `registry` is the canonical factory-deployed GameRegistry the pinned
    /// Desk bound to, that its RewardPool was deployed by the factory from the pinned creation code, then
    /// sends the entire token balance there. Nothing else can ever move the balance.
    function forward(
        address registry,
        uint64 registryLaunch,
        uint256 registryIndex,
        bytes calldata registryCode,
        uint64 poolLaunch,
        uint256 poolIndex,
        bytes calldata poolCode
    ) external nonReentrant returns (uint256 amount) {
        if (forwarded) revert AlreadyDone();
        if (registryLaunch == 0 || registryIndex >= 8 || poolLaunch == 0 || poolIndex >= 8) revert InvalidValue();
        if (keccak256(registryCode) != SwarmCode.REGISTRY || keccak256(poolCode) != ModuleCode.hash(0)) {
            revert InvalidProof();
        }
        if (IEscrowDesk(desk).registry() != registry) revert InvalidProof();
        IEscrowRegistry r = IEscrowRegistry(registry);
        if (r.factory() != factory || IEscrowParams(r.params()).swarmWallet() != desk) revert InvalidProof();
        if (!IEscrowRecords(records).isRecorded(registryLaunch) || !IEscrowRecords(records).isRecorded(poolLaunch)) {
            revert InvalidProof();
        }
        bytes memory args = abi.encode(
            r.token(), r.params(), r.market(), r.starterRoot(), r.freeRoot(), r.snapshotBlock(), r.endowment(), factory
        );
        if (
            IEscrowFactory(factory).predictContract(registryLaunch, registryIndex, bytes.concat(registryCode, args))
                != registry
        ) revert InvalidProof();
        address pool = r.module(0);
        if (
            pool.code.length == 0
                || IEscrowFactory(factory)
                        .predictContract(poolLaunch, poolIndex, bytes.concat(poolCode, abi.encode(registry))) != pool
        ) revert InvalidProof();
        IERC20 token = IERC20(r.token());
        amount = token.balanceOf(address(this));
        if (amount == 0) revert InsufficientBalance();
        forwarded = true;
        token.safeTransfer(pool, amount);
        emit Forwarded(registry, pool, address(token), amount);
    }
}
