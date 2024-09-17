// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary, PoolKey} from "v4-core/src/types/PoolId.sol";

interface IStrategy {
    function getFee(address caller, PoolKey calldata, IPoolManager.SwapParams calldata swapParams)
        external
        returns (uint128);
}

/**
 * @title ChronusStrategy
 * Strategy that increases the fee linearly over time
 * The fee starts at 0.05% and increases to 1% over 5 minutes
 * The fee is reset to 0.05% when the manager performs an arbitrage
 */
contract ChronusStrategy is IStrategy {
    using PoolIdLibrary for PoolKey;

    uint128 private startFee = 500; // 0.05%
    uint128 private endFee = 10000; // 1%
    uint256 risingTime = 5 minutes;

    uint256 lastArbitraged = block.timestamp;
    address managerAddress;

    constructor(address _managerAddress) {
        managerAddress = _managerAddress;
    }

    function getFee(address caller, PoolKey calldata, IPoolManager.SwapParams calldata swapParams)
        public
        returns (uint128)
    {
        uint256 timeElapsed = block.timestamp - lastArbitraged;

        // If the caller is the manager, means he performs arbitrage resetting pool price to market price
        if (caller == managerAddress) {
            lastArbitraged = block.timestamp;
            return 0;
        }
        // Max fee for the end period
        if (timeElapsed > risingTime) {
            return endFee;
        }

        // Compute gradually increasing fee
        return uint128(startFee + ((endFee - startFee) * timeElapsed) / risingTime);
    }
}
