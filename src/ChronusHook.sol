// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {IStrategy} from "./DefaultStrategy.sol";

import "forge-std/console.sol";

contract ChronusHook is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using SafeCast for int128;
    using Pool for Pool.State;
    using StateLibrary for IPoolManager;

    struct CallbackData {
        PoolKey key;
        address sender;
        uint256 depositAmount;
        uint256 withdrawAmount;
    }

    struct Bid {
        address strategy;
        address manager;
        address feeRecipient;
        uint256 leaseIv;
    }

    struct PoolState {
        Bid activeBid;
        Bid nextBid;
        bool leaseInToken0;
        uint256 lastPaidTimestamp;
        uint256 activeBidLockedUntil;
        uint256 nextBidDelayedUntil;
    }

    uint24 DEFAULT_SWAP_FEE = 3000;
    uint256 period = 1 hours;
    uint256 nextBidDelay = 10 minutes;

    mapping(PoolId => mapping(address => uint256)) public collateral;
    mapping(PoolId => PoolState) public pools;

    uint256 MIN_IV_INCREASE = 0.01e6; // 1%

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // @notice Used by managers to place a bid to manage a pool
    function placeBid(PoolKey calldata key, address strategy, address feeRecipient, uint256 leaseIv) external {
        PoolId id = key.toId();
        PoolState storage pool = pools[id];

        // bid should be MIN_IV_INCREASE higher than another next bid
        require(leaseIv > pool.nextBid.leaseIv + MIN_IV_INCREASE, "Bid should be higher than next bid");
        pool.nextBid = Bid(strategy, msg.sender, feeRecipient, leaseIv);
        pool.nextBidDelayedUntil = block.timestamp + nextBidDelay;
    }

    function _proceedWithState(PoolKey calldata key) internal {
        // TODO: check next bid delay time
        PoolId id = key.toId();
        PoolState storage pool = pools[id];
        // if there is a next bid and its bid delay is passed
        if (pool.nextBid.strategy != address(0) && pool.nextBidDelayedUntil < block.timestamp) {
            // if next manager is not equal to current, update it only if there is increase in iv or if no active bid
            if (
                (
                    pool.nextBid.leaseIv > pool.activeBid.leaseIv + MIN_IV_INCREASE
                        && pool.activeBidLockedUntil < block.timestamp
                ) || pool.activeBid.strategy == address(0)
            ) {
                pool.activeBid = pool.nextBid;
                pool.activeBidLockedUntil = block.timestamp + period;
                pool.nextBid = Bid(address(0), address(0), address(0), 0);
            }
        }
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata params)
        external
        override
        returns (bytes4)
    {
        (bool leaseInToken0) = abi.decode(params, (bool));
        Bid memory defaultBid = Bid(address(0), address(0), address(0), 0);
        pools[key.toId()] = PoolState(defaultBid, defaultBid, leaseInToken0, block.timestamp, 0, 0);

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
        _payLeaseToLps(key);
        PoolId id = key.toId();
        Bid storage activeBid = pools[id].activeBid;

        if (activeBid.strategy == address(0)) {
            return
                (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), DEFAULT_SWAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        uint128 fee = IStrategy(activeBid.strategy).getFee();
        int256 fees = params.amountSpecified * uint256(fee).toInt256() / 1e6;
        int256 absFees = fees > 0 ? fees : -fees;

        bool exactOut = params.amountSpecified > 0;
        Currency feeCurrency = exactOut != params.zeroForOne ? key.currency0 : key.currency1;

        // pay fees to highest bidder
        feeCurrency.take(poolManager, activeBid.feeRecipient, absFees.toUint256(), true);

        return (this.beforeSwap.selector, toBeforeSwapDelta(absFees.toInt128(), 0), LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Deposit tokens into this contract. Deposits are used to cover rent payments as the manager.
    function depositCollateral(PoolKey calldata key, uint256 amount) external {
        // Deposit 6909 claim tokens to Uniswap V4 PoolManager. The claim tokens are owned by this contract.
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, amount, 0)));
        collateral[key.toId()][msg.sender] += amount;
    }

    // @notice Pays lease to LPs considering bid IV, liquidity and last paid timestamp
    function _payLeaseToLps(PoolKey memory key) internal {
        PoolId id = key.toId();
        PoolState storage pool = pools[id];

        // skip if lease was already paid or no active manager
        if (pool.lastPaidTimestamp == block.timestamp || pool.activeBid.manager == address(0)) return;

        // get current pool liquidity
        uint128 liquidity = poolManager.getLiquidity(id);
        // current price, using tick because currently its more pricise than sqrtPriceX96 from slot0
        (, int24 tick,,) = poolManager.getSlot0(id);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);

        uint256 annualLeaseIncentive =
            getAnnualLeaseAmount(key.fee, liquidity, sqrtPriceX96, pool.activeBid.leaseIv, pool.leaseInToken0);
        uint256 leaseIncentive = annualLeaseIncentive * (block.timestamp - pool.lastPaidTimestamp) / 365 days;
        uint256 managerCollateral = collateral[id][pool.activeBid.manager];

        if (managerCollateral < leaseIncentive) {
            leaseIncentive = managerCollateral;
        }

        Currency incentiveCurrency = pool.leaseInToken0 ? key.currency0 : key.currency1;

        collateral[id][pool.activeBid.manager] -= leaseIncentive;

        uint256 zero = 0;
        (uint256 amount0, uint256 amount1) = pool.leaseInToken0 ? (leaseIncentive, zero) : (zero, leaseIncentive);
        poolManager.donate(key, amount0, amount1, "");

        uint256 liquidationThreshold = annualLeaseIncentive * nextBidDelay / 365 days;

        if (collateral[id][pool.activeBid.manager] < liquidationThreshold) {
            _liquidateActive(key);
        }
    }

    // @notice Resets active bid to allow replacing right away
    function _liquidateActive(PoolKey memory key) private {
        PoolId id = key.toId();
        PoolState storage pool = pools[id];
        Bid storage activeBid = pool.activeBid;

        Currency incentiveCurrency = pool.leaseInToken0 ? key.currency0 : key.currency1;
        incentiveCurrency.settle(poolManager, activeBid.manager, collateral[id][activeBid.manager], false);
        collateral[id][activeBid.manager] = 0;
        pool.activeBid = Bid(address(0), address(0), address(0), 0);
    }

    // @notice Estimates annual liquidity in range lease cost
    function getAnnualLeaseAmount(
        uint24 poolFee,
        uint128 liquidity,
        uint160 sqrtPriceX96,
        uint256 leaseIv,
        bool leaseInToken0
    )
        public // for test purposes
        pure
        returns (uint256)
    {
        //liquidity in current tick from reserves
        uint256 tickLiquidity = uint256(liquidity) * poolFee / 1e6;
        uint256 tickLiquidityInLeaseToken =
            leaseInToken0 ? tickLiquidity * 2 ** 96 / sqrtPriceX96 : tickLiquidity * sqrtPriceX96 / 2 ** 96;

        return poolFee * tickLiquidityInLeaseToken * (leaseIv / 2 / poolFee) ** 2 / 1e6;
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
        _payLeaseToLps(key);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        _payLeaseToLps(key);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /// @notice Deposit or withdraw 6909 claim tokens and distribute rent to LPs.
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.depositAmount > 0) {
            PoolId poolId = data.key.toId();
            PoolState storage pool = pools[poolId];
            Currency currency = pool.leaseInToken0 ? data.key.currency0 : data.key.currency1;
            currency.take(poolManager, address(this), data.depositAmount, true); // Mint 6909
            currency.settle(poolManager, data.sender, data.depositAmount, false); // Transfer ERC20
        }
        if (data.withdrawAmount > 0) {
            PoolId poolId = data.key.toId();
            PoolState storage pool = pools[poolId];
            Currency currency = pool.leaseInToken0 ? data.key.currency0 : data.key.currency1;
            currency.settle(poolManager, address(this), data.withdrawAmount, true); // Burn 6909
            currency.take(poolManager, data.sender, data.withdrawAmount, false); // Claim ERC20
        }

        _payLeaseToLps(data.key);
        return "";
    }
}
