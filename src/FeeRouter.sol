// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GameModule} from "./lib/GameModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Params} from "./Params.sol";
import {IMarket} from "./interfaces/Interfaces.sol";
import "./lib/Errors.sol";

contract FeeRouter is GameModule, ReentrancyGuard {
    address public constant team = 0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007;

    function HEARTBEAT_CAP() public view returns (uint256) {
        return params().get(Params.Key.HeartbeatCap);
    }

    uint256 public rewardETH;
    uint256 public heartbeatBalance;
    uint256 public lastBuy;
    mapping(address => uint256) public credit;
    event Routed(uint8 indexed stream, uint256 amount);
    event Bought(uint256 ethAmount, uint256 tokenAmount);
    event Withdrawn(address indexed recipient, uint256 amount);
    event Bounty(address indexed caller, uint256 amount);
    event WorkBounty(address indexed caller, Params.Key indexed kind, uint256 units, uint256 amount);

    constructor(address registry_) GameModule(registry_) {}

    function token() public view returns (IERC20) {
        return IERC20(registry.token());
    }

    function params() public view returns (Params) {
        return Params(registry.params());
    }

    function market() public view returns (IMarket) {
        return IMarket(registry.market());
    }

    function rewardPool() public view returns (address) {
        return registry.module(0);
    }

    function packSale() public view returns (address) {
        return registry.module(4);
    }

    function grid() public view returns (address) {
        return registry.module(7);
    }

    function rewards() public view returns (address) {
        return registry.module(1);
    }

    function season() public view returns (address) {
        return registry.module(8);
    }

    function starter() public view returns (address) {
        return registry.module(5);
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
        if (msg.sender != packSale()) revert Unauthorized();
        _route(1);
    }

    function depositLobby() external payable {
        if (msg.sender != grid()) revert Unauthorized();
        _route(2);
    }

    function depositSellTax() external payable {
        if (msg.sender != address(market())) revert Unauthorized();
        _route(3);
    }

    function _route(uint8 stream) private {
        if (msg.value == 0) revert InvalidValue();
        uint256 t = msg.value * 1300 / 10000;
        uint256 h = msg.value * params().get(Params.Key.HeartbeatBps) / 10000;
        uint256 cap = HEARTBEAT_CAP();
        uint256 room = cap > heartbeatBalance ? cap - heartbeatBalance : 0;
        if (h > room) h = room;
        credit[team] += t;
        heartbeatBalance += h;
        rewardETH += msg.value - t - h;
        emit Routed(stream, msg.value);
    }

    function payBounty(address caller) external {
        if (msg.sender != rewards()) revert Unauthorized();
        uint256 b = _creditBounty(caller, params().get(Params.Key.Bounty));
        emit Bounty(caller, b);
    }

    /// @dev Only immutable work producers can request credits, after advancing their monotonic cursors.
    function payWork(address caller, Params.Key kind, uint256 units, uint256 gasUsed) external {
        bool allowed = (msg.sender == grid() || msg.sender == packSale() || msg.sender == starter())
            && kind == Params.Key.EntropyBounty;
        allowed = allowed || msg.sender == season() && kind == Params.Key.SeasonBounty;
        if (!allowed) revert Unauthorized();
        if (units == 0 || units > 64) revert InvalidValue();
        uint256 amount = _creditBounty(caller, _workAmount(params().get(kind) * units, gasUsed));
        emit WorkBounty(caller, kind, units, amount);
    }

    /// @dev Reimburse measured work plus transaction/payment overhead, with a 25% bot margin.
    /// Caps prevent high gas-price bidding or calldata padding from drawing an unbounded amount.
    function _workAmount(uint256 cap, uint256 gasUsed) private view returns (uint256) {
        uint256 price = tx.gasprice;
        uint256 ceiling = params().get(Params.Key.KeeperGasPrice);
        if (price > ceiling) price = ceiling;
        uint256 wanted = (gasUsed + 80_000) * price * 125 / 100;
        return wanted > cap ? cap : wanted;
    }

    function _creditBounty(address caller, uint256 requested) private returns (uint256 amount) {
        if (caller == address(0)) revert InvalidAddress();
        amount = requested > heartbeatBalance ? heartbeatBalance : requested;
        heartbeatBalance -= amount;
        credit[caller] += amount;
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
        uint256 startGas = gasleft();
        if (ethAmount == 0 || ethAmount > params().get(Params.Key.BuyBatch) || ethAmount > rewardETH) {
            revert InvalidValue();
        }
        uint256 q = market().quote(ethAmount);
        if (q == 0 || minOut == 0 || minOut < q * (10000 - params().get(Params.Key.SlippageBps)) / 10000) {
            revert InvalidValue();
        }
        rewardETH -= ethAmount;
        lastBuy = block.timestamp;
        uint256 before_ = token().balanceOf(rewardPool());
        market().buy{value: ethAmount}(minOut, rewardPool());
        received = token().balanceOf(rewardPool()) - before_;
        if (received < minOut) revert InsufficientBalance();
        // The aggregate cap is proportional to ETH bought, even when a caller splits a buy.
        uint256 bounty = params().get(Params.Key.BuyBounty) * ethAmount / params().get(Params.Key.BuyBatch);
        uint256 paid = _creditBounty(msg.sender, _workAmount(bounty, startGas - gasleft()));
        emit WorkBounty(msg.sender, Params.Key.BuyBounty, ethAmount, paid);
        emit Bought(ethAmount, received);
    }
}
