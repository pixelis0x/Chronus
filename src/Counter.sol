// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IStrategy} from "./DefaultStrategy.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

// import console
import "forge-std/console.sol";

contract Counter is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using SafeCast for int128;
    using Pool for Pool.State;
    using StateLibrary for IPoolManager;

    address public strategy;
    address public manager;
    uint256 public lastPaidTimestamp;
    address public feeRecipient;
    uint256 public leaseIv; // in 1e6 units
    bool public leaseInToken0;

    uint24 DEFAULT_SWAP_FEE = 3000;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function afterInitialize(address, PoolKey calldata, uint160, int24, bytes calldata params)
        external
        override
        returns (bytes4)
    {
        (strategy) = abi.decode(params, (address));
        leaseIv = 1e6; // 100%

        return BaseHook.afterInitialize.selector;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _payLease(key);

        if (address(strategy) == address(0)) {
            return
                (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), DEFAULT_SWAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        uint128 fee = IStrategy(strategy).getFee();
        int256 fees = params.amountSpecified * uint256(fee).toInt256() / 1e6;
        int256 absFees = fees > 0 ? fees : -fees;

        bool exactOut = params.amountSpecified > 0;
        Currency feeCurrency = exactOut != params.zeroForOne ? key.currency0 : key.currency1;

        poolManager.take(feeCurrency, feeRecipient, absFees.toUint256());

        return (this.beforeSwap.selector, toBeforeSwapDelta(absFees.toInt128(), 0), LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _payLease(PoolKey calldata key) internal {
        // skip if lease was already paid
        if (lastPaidTimestamp == block.timestamp) return;

        PoolId id = key.toId();
        // get current pool liquidity
        uint128 liquidity = poolManager.getLiquidity(id);
        // current price
        (, int24 tick,,) = poolManager.getSlot0(id);
        // get tick info
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);

        uint256 annualLeaseIncentive = getAnnualLeaseAmount(key.fee, liquidity, sqrtPriceX96);

        uint256 leaseIncentive = annualLeaseIncentive * (block.timestamp - lastPaidTimestamp) / 365 days;

        // donate leaseIncentive to the pool
        poolManager.take(key.currency0, address(this), leaseIncentive);
    }

    function getAnnualLeaseAmount(uint24 poolFee, uint128 liquidity, uint160 sqrtPriceX96)
        public
        view
        returns (uint256)
    {
        uint256 currentLiquidityInToken0 = uint256(liquidity) * 2 ** 96 / sqrtPriceX96 * poolFee / 1e6;
        console.log("currentLiquidityInToken0", currentLiquidityInToken0);

        return poolFee * currentLiquidityInToken0 * (leaseIv / 2 / poolFee) ** 2 / 1e6;
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        return (BaseHook.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        return BaseHook.beforeRemoveLiquidity.selector;
    }
}
