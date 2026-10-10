// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IEmission} from "./interfaces/Interfaces.sol";
import "./lib/Errors.sol";

contract RewardPool is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable token;
    address public immutable rewards;
    uint256 public reserved;
    event Donated(address indexed sender, uint256 amount);
    event Reserved(uint256 amount);
    event Recycled(uint256 amount);
    event Paid(address indexed to, uint256 amount);

    constructor(address token_, address rewards_) {
        if (token_ == address(0) || rewards_ == address(0)) revert InvalidAddress();
        token = IERC20(token_);
        rewards = rewards_;
    }
    modifier onlyRewards() {
        if (msg.sender != rewards) revert Unauthorized();
        _;
    }

    function available() public view returns (uint256) {
        return token.balanceOf(address(this)) - reserved;
    }

    function donate(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidValue();
        if (!IEmission(rewards).checkpoint(64)) revert CatchUpRequired();
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - beforeBalance != amount) revert InvalidValue();
        emit Donated(msg.sender, amount);
    }

    function reserve(uint256 amount) external onlyRewards {
        if (amount > available()) revert InsufficientBalance();
        reserved += amount;
        emit Reserved(amount);
    }

    function recycle(uint256 amount) external onlyRewards {
        reserved -= amount;
        emit Recycled(amount);
    }

    function pay(address to, uint256 amount) external onlyRewards {
        if (to == address(0)) revert InvalidAddress();
        reserved -= amount;
        token.safeTransfer(to, amount);
        emit Paid(to, amount);
    }
}
