// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ServiceSink
/// @notice Trivial payee standing in for a paid service. The agent approves gUSD
///         and calls pay; the Paid event drives the UI.
contract ServiceSink {
    IERC20 public immutable token;

    event Paid(address indexed agent, uint256 amount);

    error PaymentFailed();

    constructor(IERC20 token_) {
        token = token_;
    }

    function pay(uint256 amount) external {
        if (!token.transferFrom(msg.sender, address(this), amount)) revert PaymentFailed();
        emit Paid(msg.sender, amount);
    }
}
