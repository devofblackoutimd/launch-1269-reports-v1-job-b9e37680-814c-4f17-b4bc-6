// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Params} from "./Params.sol";
import {IEmission, IMarket} from "./interfaces/Interfaces.sol";
import "./lib/Errors.sol";

/// @notice ETH splits are immutable. There is no pool withdrawal or arbitrary-call facility.
contract FeeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable token;
    Params public immutable params;
    IMarket public immutable market;
    address public immutable rewardPool;
    address public immutable burnVault;
    address public immutable packSale;
    address public immutable grid;
    address public immutable heartbeatRecipient;
    address public team;
    uint256 public rewardETH;
    uint256 public burnETH;
    uint256 public lastBuy;
    mapping(address => uint256) public credit;
    event Routed(uint8 indexed stream, uint256 amount);
    event Bought(bool indexed burn, uint256 ethAmount, uint256 tokenAmount);
    event Withdrawn(address indexed recipient, uint256 amount);
    event TeamChanged(address indexed oldTeam, address indexed newTeam);

    constructor(
        address token_,
        address params_,
        address market_,
        address pool_,
        address burn_,
        address packs_,
        address grid_,
        address team_,
        address heartbeat_
    ) {
        if (
            token_ == address(0) || params_ == address(0) || market_ == address(0) || pool_ == address(0)
                || burn_ == address(0) || packs_ == address(0) || grid_ == address(0) || team_ == address(0)
                || heartbeat_ == address(0)
        ) revert InvalidAddress();
        token = IERC20(token_);
        params = Params(params_);
        market = IMarket(market_);
        rewardPool = pool_;
        burnVault = burn_;
        packSale = packs_;
        grid = grid_;
        team = team_;
        heartbeatRecipient = heartbeat_;
    }

    receive() external payable {
        _route(1, 3000, 4000, 2000);
    }

    function depositPack() external payable {
        if (msg.sender != packSale) revert Unauthorized();
        _route(0, 6500, 1000, 1500);
    }

    function depositBaseFee() external payable {
        _route(1, 3000, 4000, 2000);
    }

    function depositSellTax() external payable {
        _route(2, 4000, 3500, 1500);
    }

    function depositLobby() external payable {
        if (msg.sender != grid) revert Unauthorized();
        _route(3, 0, 8500, 1000);
    }

    function _route(uint8 stream, uint256 rewardBps, uint256 burnBps, uint256 teamBps) private {
        if (msg.value == 0) revert InvalidValue();
        uint256 r = msg.value * rewardBps / 10000;
        uint256 b = msg.value * burnBps / 10000;
        uint256 t = msg.value * teamBps / 10000;
        rewardETH += r;
        burnETH += b;
        credit[team] += t;
        credit[heartbeatRecipient] += msg.value - r - b - t;
        emit Routed(stream, msg.value);
    }

    function changeTeam(address next) external {
        if (msg.sender != team) revert Unauthorized();
        if (next == address(0) || next == address(this)) revert InvalidAddress();
        emit TeamChanged(team, next);
        team = next;
    }

    function withdraw() external nonReentrant {
        uint256 amount = credit[msg.sender];
        if (amount == 0) revert InsufficientBalance();
        credit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    function executeBuys(bool burn, uint256 ethAmount, uint256 minOut)
        external
        nonReentrant
        returns (uint256 received)
    {
        if (ethAmount == 0 || ethAmount > params.get(Params.Key.BuyBatch)) {
            revert InvalidValue();
        }
        if (lastBuy != 0 && block.timestamp < lastBuy + 10 minutes) revert TooEarly();
        uint256 quote = market.quote(ethAmount);
        if (quote == 0 || minOut < quote * (10000 - params.get(Params.Key.SlippageBps)) / 10000) revert InvalidValue();
        if (burn) burnETH -= ethAmount;
        else rewardETH -= ethAmount;
        lastBuy = block.timestamp;
        address recipient = burn ? burnVault : rewardPool;
        // Checkpoint before a new donation can affect a previous interval.
        if (!params.emission().checkpoint(64)) revert CatchUpRequired();
        uint256 beforeBalance = token.balanceOf(recipient);
        market.buy{value: ethAmount}(minOut, recipient);
        received = token.balanceOf(recipient) - beforeBalance;
        if (received < minOut) revert InsufficientBalance();
        emit Bought(burn, ethAmount, received);
    }
}
