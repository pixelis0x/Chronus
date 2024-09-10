// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategy {
    function getFee() external view returns (uint256);
}

contract DefaultStrategy is IStrategy {
    uint256 private FEE = 3000;

    function getFee() external view returns (uint256) {
        return FEE;
    }
}
