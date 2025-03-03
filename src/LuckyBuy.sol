// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

contract LuckyBuy {
    uint256 public balance;

    function _depositTreasury(uint256 amount) internal {
        balance += amount;
    }

    receive() external payable {
        _depositTreasury(msg.value);
    }
}
