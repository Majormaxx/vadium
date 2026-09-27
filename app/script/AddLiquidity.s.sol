// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {NativeLiquidityRouter} from "./NativeLiquidityRouter.sol";

/// @title AddLiquidity
/// @notice Adds LP liquidity to the deployed Vadium pool on Unichain Sepolia
///         (chain ID 1301).
///
///         Pool: ETH (native, token0) / USDC (token1), 30 bps, tick spacing 10,
///         hook at 0x6d6201097d6549F9760d61019E69E599315dc0C0. The pool was
///         initialized at tick 0 with zero liquidity.
///
///         Settlement runs through the deployed `NativeLiquidityRouter`, not the
///         ephemeral script contract: forge's script `address(this)` has restricted
///         native settle, but a deployed router carries its own ETH balance and
///         settles the token1 via transferFrom from the caller (the deployer).
///         The deployer must approve the router to pull USDC.
///
///         For a full-range position at tick 0 the required deltas are L raw USDC
///         (token1, 6 decimals) and L raw wei ETH (token0), so LIQUIDITY_DELTA of
///         30_000_000 spends ~30 USDC of the deployer's 39 USDC balance.
///
///         Run with:
///           forge script app/script/AddLiquidity.s.sol:AddLiquidity \
///             --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
///             --broadcast -vvvv
contract AddLiquidity is Script {
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;
    address constant HOOK = 0x6d6201097d6549F9760d61019E69E599315dc0C0;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 10;
    int24 constant TICK_LOWER = -887270;
    int24 constant TICK_UPPER = 887270;

    // Full-range liquidity. At tick-0 init this spends ~LIQUIDITY_DELTA USDC.
    // Set to 1_000_000 (1 USDC) for the first smoke-test broadcast; scale up after
    // verifying the pool reports liquidity > 0.
    uint256 constant LIQUIDITY_DELTA = 1_000_000;

    // Native ETH budget sent to the router to settle the token0 leg. amount0 ==
    // LIQUIDITY_DELTA raw wei, so a small buffer over that covers it.
    uint256 constant ETH_BUDGET = 0.01 ether;

    function run() external {
        require(block.chainid == 1301, "AddLiquidity: wrong chain - expected Unichain Sepolia (1301)");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        IPoolManager manager = IPoolManager(POOL_MANAGER);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(LIQUIDITY_DELTA),
            salt: 0
        });

        console2.log("=== Add LP liquidity via NativeLiquidityRouter ===");
        console2.log("Deployer:   ", deployer);
        console2.log("Hook:       ", HOOK);
        console2.log("Liquidity:  ", LIQUIDITY_DELTA);
        console2.log("ETH budget: ", ETH_BUDGET);

        vm.startBroadcast(deployerKey);

        // 1. Deploy the router that carries the native ETH leg and settles USDC.
        NativeLiquidityRouter router = new NativeLiquidityRouter(manager, USDC);

        // 2. Fund the router's native ETH balance (token0 of the pool).
        (bool funded,) = address(router).call{value: ETH_BUDGET}("");
        require(funded, "AddLiquidity: router funding failed");

        // 3. Authorize the router to pull USDC from the deployer (token1).
        IERC20Minimal(USDC).approve(address(router), type(uint256).max);

        // 4. Add liquidity. The router's unlock callback settles ETH from its own
        //    balance and USDC via transferFrom from the deployer.
        BalanceDelta delta = router.addLiquidity(key, params);

        console2.log("ETH delta:  ", int256(int128(delta.amount0())));
        console2.log("USDC delta: ", int256(int128(delta.amount1())));

        // 5. Refund any unused ETH to the deployer.
        uint256 leftover = address(router).balance;
        if (leftover > 0) {
            (bool ok,) = deployer.call{value: leftover}("");
            require(ok, "AddLiquidity: ETH refund failed");
        }

        console2.log("=== Liquidity added (LP position held by router) ===");
        vm.stopBroadcast();
    }
}
