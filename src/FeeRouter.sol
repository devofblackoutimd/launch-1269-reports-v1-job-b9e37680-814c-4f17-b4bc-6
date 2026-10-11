// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Params} from "./Params.sol";
import {IMarket} from "./interfaces/Interfaces.sol";
import "./lib/Errors.sol";

contract FeeRouter is ReentrancyGuard {
    address public constant team = 0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007;
    uint256 public constant HEARTBEAT_CAP = 1 ether;
    IERC20 public immutable token;
    Params public immutable params;
    IMarket public immutable market;
    address public immutable rewardPool;
    address public immutable packSale;
    address public immutable grid;
    address public immutable rewards;
    uint256 public rewardETH;
    uint256 public heartbeatBalance;
    uint256 public lastBuy;
    mapping(address => uint256) public credit;
    event Routed(uint8 indexed stream, uint256 amount);
    event Bought(uint256 ethAmount, uint256 tokenAmount);
    event Withdrawn(address indexed recipient, uint256 amount);
    event Bounty(address indexed caller, uint256 amount);

    constructor(
        address token_,
        address params_,
        address market_,
        address pool_,
        address packs_,
        address grid_,
        address rewards_
    ) {
        if (
            token_ == address(0) || params_ == address(0) || market_ == address(0) || pool_ == address(0)
                || packs_ == address(0) || grid_ == address(0) || rewards_ == address(0)
        ) revert InvalidAddress();
        token = IERC20(token_);
        params = Params(params_);
        market = IMarket(market_);
        rewardPool = pool_;
        packSale = packs_;
        grid = grid_;
        rewards = rewards_;
    }

    receive() external payable {
        _base();
    }

    function depositBaseFee() external payable {
        _base();
    }

    function _base() private {
        if (msg.value == 0) revert InvalidValue();
        uint256 t = msg.value / 2;
        credit[team] += t;
        rewardETH += msg.value - t;
        emit Routed(0, msg.value);
    }

    function depositPack() external payable {
        if (msg.sender != packSale) revert Unauthorized();
        _route(1);
    }

    function depositLobby() external payable {
        if (msg.sender != grid) revert Unauthorized();
        _route(2);
    }

    function depositSellTax() external payable {
        if (msg.sender != address(market)) revert Unauthorized();
        _route(3);
    }

    function _route(uint8 stream) private {
        if (msg.value == 0) revert InvalidValue();
        uint256 t = msg.value * 1300 / 10000;
        uint256 h = msg.value * 200 / 10000;
        uint256 room = HEARTBEAT_CAP - heartbeatBalance;
        if (h > room) h = room;
        credit[team] += t;
        heartbeatBalance += h;
        rewardETH += msg.value - t - h;
        emit Routed(stream, msg.value);
    }

    function payBounty(address caller) external {
        if (msg.sender != rewards) revert Unauthorized();
        uint256 b = params.get(Params.Key.Bounty);
        if (b > heartbeatBalance) b = heartbeatBalance;
        heartbeatBalance -= b;
        credit[caller] += b;
        emit Bounty(caller, b);
    }

    function withdraw() external nonReentrant {
        uint256 a = credit[msg.sender];
        if (a == 0) revert InsufficientBalance();
        credit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: a}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, a);
    }

    function executeBuys(uint256 ethAmount, uint256 minOut) external nonReentrant returns (uint256 received) {
        if (ethAmount == 0 || ethAmount > params.get(Params.Key.BuyBatch) || ethAmount > rewardETH) {
            revert InvalidValue();
        }
        uint256 q = market.quote(ethAmount);
        if (q == 0 || minOut == 0 || minOut < q * (10000 - params.get(Params.Key.SlippageBps)) / 10000) {
            revert InvalidValue();
        }
        rewardETH -= ethAmount;
        lastBuy = block.timestamp;
        uint256 before_ = token.balanceOf(rewardPool);
        market.buy{value: ethAmount}(minOut, rewardPool);
        received = token.balanceOf(rewardPool) - before_;
        if (received < minOut) revert InsufficientBalance();
        emit Bought(ethAmount, received);
    }
}
