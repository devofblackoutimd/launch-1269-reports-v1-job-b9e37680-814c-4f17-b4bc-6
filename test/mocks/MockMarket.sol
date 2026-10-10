// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarket} from "../../src/interfaces/Interfaces.sol";

contract MockMarket is IMarket {
    IERC20 public token;
    uint256 public rate = 1_000_000 ether;
    bool public fail;
    uint256 public fillBps = 10000;

    constructor(address token_) {
        token = IERC20(token_);
    }

    function setFailure(bool value) external {
        fail = value;
    }

    function setFill(uint256 value) external {
        fillBps = value;
    }

    function setRate(uint256 value) external {
        rate = value;
    }

    function quote(uint256 ethAmount) external view returns (uint256) {
        return ethAmount * rate / 1 ether;
    }

    function buy(uint256, address recipient) external payable returns (uint256 amount) {
        require(!fail, "market failure");
        amount = msg.value * rate / 1 ether * fillBps / 10000;
        token.transfer(recipient, amount);
    }
}
