// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./lib/Errors.sol";

interface IGeneratorFarm {
    function refresh(address) external;
    function generatorRequirement(address) external view returns (uint256);
}

/// @notice Voluntary seven-day token pledge. Principal cannot be spent by the game.
contract Generator is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable token;
    IGeneratorFarm public immutable farm;
    mapping(address => uint256) public locked;
    mapping(address => uint256) public unlockAt;
    event Locked(address indexed player, uint256 amount, uint256 until);
    event Unlocked(address indexed player, uint256 amount);

    constructor(address token_, address farm_) {
        if (token_ == address(0) || farm_ == address(0)) revert InvalidAddress();
        token = IERC20(token_);
        farm = IGeneratorFarm(farm_);
    }

    function lock(uint256 amount) external nonReentrant {
        uint256 required = farm.generatorRequirement(msg.sender);
        if (required == 0 || amount < required || locked[msg.sender] != 0) revert InvalidValue();
        locked[msg.sender] = amount;
        unlockAt[msg.sender] = block.timestamp + 7 days;
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - beforeBalance != amount) revert InvalidValue();
        farm.refresh(msg.sender);
        emit Locked(msg.sender, amount, unlockAt[msg.sender]);
    }

    function unlock() external nonReentrant {
        uint256 amount = locked[msg.sender];
        if (amount == 0) revert InsufficientBalance();
        if (block.timestamp < unlockAt[msg.sender]) revert TooEarly();
        locked[msg.sender] = 0;
        unlockAt[msg.sender] = 0;
        farm.refresh(msg.sender);
        token.safeTransfer(msg.sender, amount);
        emit Unlocked(msg.sender, amount);
    }
}
