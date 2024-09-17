// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {ChronusHook} from "../src/ChronusHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PositionConfig} from "v4-periphery/src/libraries/PositionConfig.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import {IStrategy, DefaultStrategy} from "../src/DefaultStrategy.sol";

contract ChronusHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ChronusHook hook;
    PoolId poolId;

    uint256 tokenId;
    PositionConfig config;

    IStrategy strategy;

    address manager1 = address(0x11);

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        // TODO: Add all the necessary constructor arguments from the hook
        bytes memory constructorArgs = abi.encode(manager);
        deployCodeTo("ChronusHook.sol:ChronusHook", constructorArgs, flags);
        hook = ChronusHook(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();

        // Deploy strategy
        strategy = new DefaultStrategy();

        // Create the pool
        bytes memory afterInitializeParams = abi.encode(true);
        manager.initialize(key, SQRT_PRICE_1_1, afterInitializeParams);

        // Provide full-range liquidity to the pool
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });
        (tokenId,) = posm.mint(
            config,
            1e12,
            MAX_SLIPPAGE_ADD_LIQUIDITY,
            MAX_SLIPPAGE_ADD_LIQUIDITY,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );

        seedBalance(manager1);
        vm.prank(manager1);
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function testAfterInitialize() public {
        (ChronusHook.Bid memory activeBid,,,,,) = hook.pools(key.toId());
        // pool is initialized with proper strategy
        assertEq(address(0), activeBid.strategy);
    }

    function testTickTvl() public {
        // real world estimations check for usdc-weth 0.05% pool
        uint160 sqrtPriceX96 = 1635008161405954009941460910080473;
        uint128 liquidity = 7464885187306878302;

        uint256 annualLease = hook.getAnnualLeaseAmount(liquidity, sqrtPriceX96, 1e6, true);

        assertEq(annualLease, 90432138311422);
        uint256 currentLiquidityInToken0 = uint256(liquidity) * 2 ** 96 / sqrtPriceX96 / 2;

        // check apr
        assertEq(annualLease * 1e6 / currentLiquidityInToken0, 499999); // 50% apr
    }

    function testNextBidIsPlaced() public {
        uint256 iv = 0.1e6; //10%
        vm.prank(manager1);
        // fails since no collateral
        vm.expectRevert(abi.encodeWithSelector(ChronusHook.InsufficientCollateral.selector));
        hook.placeBid(key, address(strategy), manager1, iv);

        vm.prank(manager1);
        hook.depositCollateral(key, 1e6);

        vm.prank(manager1);
        // succeds because collateral is enough
        hook.placeBid(key, address(strategy), manager1, iv);

        (ChronusHook.Bid memory activeBid, ChronusHook.Bid memory nextBid,,,,) = hook.pools(poolId);
        // pool is initialized with proper strategy
        assertEq(nextBid.strategy, address(strategy));
    }

    function testNextBidBecomesActive() public {
        uint256 iv = 0.1e6; //10%
        vm.prank(manager1);
        hook.depositCollateral(key, 1e6);

        vm.prank(manager1);
        hook.placeBid(key, address(strategy), manager1, iv);

        //trigger swap bidders state update
        swap(key, true, 1e4, "");
        (ChronusHook.Bid memory activeBid, ChronusHook.Bid memory nextBid,,,,) = hook.pools(poolId);
        // pool is initialized with proper strategy
        assertEq(nextBid.strategy, address(strategy));
        assertEq(activeBid.strategy, address(0));

        // make 10 minutes pass
        vm.warp(block.timestamp + 601);

        //next manager becomes active after time passes
        //trigger swap bidders state update
        swap(key, true, 1e4, "");
        (activeBid, nextBid,,,,) = hook.pools(poolId);
        // pool is initialized with proper strategy
        assertEq(nextBid.strategy, address(0));
        assertEq(activeBid.strategy, address(strategy));
    }
}
