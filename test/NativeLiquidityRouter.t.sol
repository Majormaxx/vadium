// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Minimal } from "v4-core/src/interfaces/external/IERC20Minimal.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { NativeLiquidityRouter } from "../app/script/NativeLiquidityRouter.sol";

/// @notice Deterministic gate test for NativeLiquidityRouter. Exercises the exact
///         dual-leg settlement the router performs against a real local PoolManager
///         with a genuinely native-ETH currency0: the native leg via `settle{value}`,
///         the ERC20 leg via `sync` + `transferFrom` + `settle`. This is the code path
///         that shipped a real bug (sync was called after the transfer, so the token1
///         leg settled as zero and unlock reverted CurrencyNotSettled), which only the
///         on-PoolManager/live-chain exercise caught. Regression test added with the fix.
contract NativeLiquidityRouterTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_BITS = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 10;

    PoolManager internal pm;
    MockERC20 internal token1;
    PoolKey internal key;
    NativeLiquidityRouter internal router;

    function setUp() public {
        pm = new PoolManager(address(this));
        token1 = new MockERC20("USD Coin", "USDC", 6);

        // Native-ETH pool: currency0 is the zero address (like the deployed Vadium
        // pool on Unichain), currency1 is the ERC20 bond/deposit token.
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK_BITS)
        });
        pm.initialize(key, 79228162514264337593543950336); // tick 0

        router = new NativeLiquidityRouter(pm, address(token1));
    }

    function test_addLiquidity_setsPoolLiquidity() public {
        // Fund the router for the native ETH leg and approve the router to pull the
        // ERC20 leg from this contract (the `addLiquidity` caller is the payer).
        vm.deal(address(router), 1 ether);
        token1.mint(address(this), 100_000e6);
        token1.approve(address(router), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -887270, tickUpper: 887270, liquidityDelta: 1_000_000, salt: 0
        });

        router.addLiquidity(key, params);

        // The pool must report non-zero liquidity for the full-range position.
        PoolId pid = key.toId();
        uint128 liquidity = StateLibrary.getLiquidity(pm, pid);
        assertEq(liquidity, 1_000_000, "pool liquidity after native+erc20 settle");
    }

    function test_addLiquidity_consumes_erc20FromPayer() public {
        vm.deal(address(router), 1 ether);
        token1.mint(address(this), 100_000e6);
        token1.approve(address(router), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -887270, tickUpper: 887270, liquidityDelta: 500_000, salt: 0
        });

        uint256 before = token1.balanceOf(address(this));
        router.addLiquidity(key, params);

        // The ERC20 (token1) leg must actually be pulled from the payer, not left
        // unsettled. amount1 == liquidityDelta for a full-range straddle at tick 0.
        assertEq(before - token1.balanceOf(address(this)), 500_000, "payer USDC spent");
    }

    function test_addLiquidity_revertsIfEthUnfunded() public {
        // No ETH on the router: the native leg cannot settle, so the whole call must
        // revert atomically (v4 unlock rollback) without touching the ERC20.
        token1.mint(address(this), 100_000e6);
        token1.approve(address(router), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -887270, tickUpper: 887270, liquidityDelta: 1_000_000, salt: 0
        });

        vm.expectRevert();
        router.addLiquidity(key, params);

        // Atomic rollback: no liquidity was minted.
        PoolId pid = key.toId();
        assertEq(StateLibrary.getLiquidity(pm, pid), 0, "no liquidity on failure");
    }
}
