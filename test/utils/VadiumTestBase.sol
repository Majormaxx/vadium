// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { CurrencySettler } from "v4-core/test/utils/CurrencySettler.sol";

import { VadiumHook } from "../../src/hooks/VadiumHook.sol";
import { IBondedFlow } from "../../src/interfaces/IBondedFlow.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Unlock-pattern swap router. One instance per actor, because the hook sees
///         the router as `sender`.
contract SwapRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params)
        external
        returns (BalanceDelta delta)
    {
        return swapWithData(key, params, "");
    }

    function swapWithData(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        bytes memory hookData
    ) public returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(abi.encode(msg.sender, key, params, hookData)), (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address user, PoolKey memory key, IPoolManager.SwapParams memory params, bytes memory hd) =
            abi.decode(data, (address, PoolKey, IPoolManager.SwapParams, bytes));
        BalanceDelta delta = manager.swap(key, params, hd);
        _settleDelta(key.currency0, user, delta.amount0());
        _settleDelta(key.currency1, user, delta.amount1());
        return abi.encode(delta);
    }

    function bond(VadiumHook hook, uint256 amount) external {
        IERC20 token = hook.bondToken();
        token.transferFrom(msg.sender, address(this), amount);
        token.approve(address(hook), amount);
        hook.bond(amount);
    }

    function withdrawBond(VadiumHook hook) external {
        hook.withdrawBond();
        IERC20 token = hook.bondToken();
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }

    function claimRefund(VadiumHook hook) external returns (uint256 amount) {
        amount = hook.claimRefund();
        hook.bondToken().transfer(msg.sender, amount);
    }

    function _settleDelta(Currency currency, address user, int128 amount) internal {
        if (amount < 0) currency.settle(manager, user, uint256(int256(-amount)), false);
        else if (amount > 0) currency.take(manager, user, uint256(int256(amount)), false);
    }
}

/// @notice Unlock-pattern liquidity router.
contract LiquidityRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address user, PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params) =
            abi.decode(data, (address, PoolKey, IPoolManager.ModifyLiquidityParams));
        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");
        _settleDelta(key.currency0, user, delta.amount0());
        _settleDelta(key.currency1, user, delta.amount1());
        return abi.encode(delta);
    }

    function _settleDelta(Currency currency, address user, int128 amount) internal {
        if (amount < 0) currency.settle(manager, user, uint256(int256(-amount)), false);
        else if (amount > 0) currency.take(manager, user, uint256(int256(amount)), false);
    }
}

/// @notice Shared fixture: a real PoolManager, two mock tokens (the bond token is
///         currency1), the hook at its permission address, one registered and
///         initialized pool with full-range liquidity, and funded actors with their own
///         routers.
abstract contract VadiumTestBase is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager internal pm;
    LiquidityRouter internal liqRouter;
    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;
    VadiumHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    address internal lp = makeAddr("lp");
    address internal searcher = makeAddr("searcher");
    address internal victim = makeAddr("victim");
    address internal other = makeAddr("other");
    SwapRouter internal searcherRouter;
    SwapRouter internal victimRouter;
    SwapRouter internal otherRouter;

    uint24 constant POOL_FEE = 3_000;
    int24 constant TICK_SPACING = 10;
    address constant CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;
    address constant HOOK_ADDR = address(uint160(0x20C4));
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint256 constant BOND_AMOUNT = 100e6;
    uint256 constant SWAP_AMOUNT = 1_000e6;
    int256 constant LIQUIDITY = 1e11;
    uint256 constant MIN_DURATION = 100;
    uint256 constant EXT = 7_200;
    uint256 constant BAN = 216_000;

    function _params() internal pure returns (IBondedFlow.BondParams memory p) {
        p.minBond = BOND_AMOUNT;
        p.minBondDurationBlocks = MIN_DURATION;
        p.firstSlashBps = 5_000;
        p.firstOffenseLockExtensionBlocks = EXT;
        p.repeatOffenseBanBlocks = BAN;
        p.victimRefundBps = 5_000;
        p.refundClaimWindowBlocks = 1_000;
    }

    function _cfg() internal pure returns (IBondedFlow.PoolConfig memory c) {
        c.clampEnabled = true;
        c.exemptFirstSwapOnly = true;
        c.requireVictimLoss = true;
    }

    function setUp() public virtual {
        vm.roll(1_000);
        pm = new PoolManager(address(this));
        liqRouter = new LiquidityRouter(pm);
        searcherRouter = new SwapRouter(pm);
        victimRouter = new SwapRouter(pm);
        otherRouter = new SwapRouter(pm);

        MockERC20 a = new MockERC20("Wrapped ETH", "WETH", 18);
        MockERC20 b = new MockERC20("USD Coin", "USDC", 6);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        deployCodeTo(
            "VadiumHook.sol:VadiumHook",
            abi.encode(
                IPoolManager(pm), IERC20(address(token1)), address(this), CALLBACK_PROXY, _params()
            ),
            HOOK_ADDR
        );
        hook = VadiumHook(payable(HOOK_ADDR));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK_ADDR)
        });
        poolId = poolKey.toId();
        hook.registerPool(poolKey, _cfg(), address(this));
        pm.initialize(poolKey, SQRT_1_1);

        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e6);
        token0.approve(address(liqRouter), type(uint256).max);
        token1.approve(address(liqRouter), type(uint256).max);
        _addLiquidity(LIQUIDITY);

        _fund(searcher, searcherRouter);
        _fund(victim, victimRouter);
        _fund(other, otherRouter);
    }

    function _addLiquidity(int256 delta) internal {
        liqRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_270, tickUpper: 887_270, liquidityDelta: delta, salt: 0
            })
        );
    }

    function _fund(address user, SwapRouter router) internal {
        token0.mint(user, 1_000e18);
        token1.mint(user, 1_000_000e6);
        vm.startPrank(user);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token1.approve(HOOK_ADDR, type(uint256).max);
        vm.stopPrank();
    }

    function _swapThrough(address user, SwapRouter router, bool zeroForOne, int256 amount)
        internal
        returns (BalanceDelta)
    {
        return _swapThroughLimit(
            user, router, zeroForOne, amount, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT, ""
        );
    }

    function _swapThroughLimit(
        address user,
        SwapRouter router,
        bool zeroForOne,
        int256 amount,
        uint160 limit,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        vm.prank(user);
        return router.swapWithData(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit
            }),
            hookData
        );
    }

    function _bondThrough(address user, SwapRouter router, uint256 amount) internal {
        vm.prank(user);
        router.bond(hook, amount);
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }
}
