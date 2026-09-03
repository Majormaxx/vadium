// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { CurrencySettler } from "v4-core/test/utils/CurrencySettler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TransientStateLibrary } from "v4-core/src/libraries/TransientStateLibrary.sol";

import { VadiumHook } from "../src/core/VadiumHook.sol";
import { BondManager } from "../src/core/libraries/BondManager.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

// ---------------------------------------------------------------------------
// Helpers: unlock-pattern routers for swaps and liquidity
// ---------------------------------------------------------------------------

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
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        address user;
        PoolKey memory key;
        IPoolManager.SwapParams memory params;
        (user, key, params) = abi.decode(data, (address, PoolKey, IPoolManager.SwapParams));

        BalanceDelta delta = manager.swap(key, params, "");

        _settleDelta(key.currency0, user, delta.amount0());
        _settleDelta(key.currency1, user, delta.amount1());

        return abi.encode(delta);
    }

    function bond(VadiumHook hook, uint256 amount) external {
        address token = address(hook.bondToken());
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        IERC20(token).approve(address(hook), amount);
        hook.bond(amount);
    }

    function withdrawBond(VadiumHook hook) external {
        hook.withdrawBond();
        address token = address(hook.bondToken());
        IERC20(token).transfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }

    function _settleDelta(Currency currency, address user, int128 amount) internal {
        if (amount < 0) {
            currency.settle(manager, user, uint256(int256(-amount)), false);
        } else if (amount > 0) {
            currency.take(manager, user, uint256(int256(amount)), false);
        }
    }
}

contract LiquidityRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function addLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        address user;
        PoolKey memory key;
        IPoolManager.ModifyLiquidityParams memory params;
        (user, key, params) =
            abi.decode(data, (address, PoolKey, IPoolManager.ModifyLiquidityParams));

        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");

        _settleDelta(key.currency0, user, delta.amount0());
        _settleDelta(key.currency1, user, delta.amount1());

        return abi.encode(delta);
    }

    function _settleDelta(Currency currency, address user, int128 amount) internal {
        if (amount < 0) {
            currency.settle(manager, user, uint256(int256(-amount)), false);
        } else if (amount > 0) {
            currency.take(manager, user, uint256(int256(amount)), false);
        }
    }
}

// ---------------------------------------------------------------------------
// Integration test
// ---------------------------------------------------------------------------

contract VadiumIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BondManager for BondManager.Bond;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // --- Infrastructure ---
    PoolManager internal pm;
    LiquidityRouter internal liqRouter;

    // --- Per-user routers (each user gets their own so the PM sees a unique sender) ---
    SwapRouter internal searcherRouter;
    SwapRouter internal victimRouter;

    // --- Tokens ---
    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;

    // --- Hook ---
    VadiumHook internal hook;

    // --- Pool ---
    PoolKey internal poolKey;
    PoolId internal poolId;

    // --- Actors ---
    address internal lp = makeAddr("lp");
    address internal searcher = makeAddr("searcher");
    address internal victim = makeAddr("victim");

    // --- Constants ---
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 10;
    uint256 constant BOND_AMOUNT = 100e6;
    uint256 constant SWAP_AMOUNT = 1000e6;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        // 1. Deploy PoolManager
        pm = new PoolManager(address(this));

        // 2. Deploy per-user SwapRouters (each router appears as a unique sender to the hook)
        searcherRouter = new SwapRouter(pm);
        victimRouter = new SwapRouter(pm);
        liqRouter = new LiquidityRouter(pm);

        // 3. Deploy and sort tokens
        MockERC20 tA = new MockERC20("Wrapped ETH", "WETH", 18);
        MockERC20 tB = new MockERC20("USD Coin", "USDC", 6);
        if (address(tA) < address(tB)) {
            token0 = tA;
            token1 = tB;
        } else {
            token0 = tB;
            token1 = tA;
        }
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // 4. Deploy VadiumHook at address with correct permission bits
        //    beforeSwap (bit 7) + afterSwap (bit 6) = 0x00C0
        uint160 hookFlags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        address hookAddr = address(uint160(hookFlags));
        VadiumHook hookImpl = new VadiumHook(pm, currency0, currency1, POOL_FEE, TICK_SPACING);
        vm.etch(hookAddr, address(hookImpl).code);
        hook = VadiumHook(hookAddr);

        // The etch-copied contract never ran its constructor, so the owner slot is
        // zero. Bootstrap the owner once (this can only fire while owner is unset).
        hook.initializeOwner(address(this));

        // 5. Initialize pool
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        poolId = poolKey.toId();
        pm.initialize(poolKey, SQRT_PRICE_1_1);

        // 6. Fund the test contract and approve liquidity router
        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e6);
        token0.approve(address(liqRouter), type(uint256).max);
        token1.approve(address(liqRouter), type(uint256).max);

        // 7. Add full-range liquidity
        IPoolManager.ModifyLiquidityParams memory liqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -887270, tickUpper: 887270, liquidityDelta: 1e11, salt: 0
        });
        liqRouter.addLiquidity(poolKey, liqParams);

        // 8. Fund searcher and victim with both tokens
        token0.mint(searcher, 100e18);
        token1.mint(searcher, 10_000e6);
        token0.mint(victim, 100e18);
        token1.mint(victim, 10_000e6);

        // Each user approves their own per-user router for token transfers.
        // CurrencySettler calls transferFrom(user, manager, amount) from the router's
        // context, so the user must have approved the router as spender.
        vm.startPrank(searcher);
        token0.approve(address(searcherRouter), type(uint256).max);
        token1.approve(address(searcherRouter), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(victim);
        token0.approve(address(victimRouter), type(uint256).max);
        token1.approve(address(victimRouter), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Swap through a specific user's router. The PM sees the router as `sender`.
    ///      vm.prank(user) ensures the router settles from the user's token balances.
    function _swapThrough(address user, SwapRouter router, bool zeroForOne, int256 amount)
        internal
        returns (BalanceDelta)
    {
        vm.prank(user);
        return router.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            })
        );
    }

    /// @dev Bond via a specific user's router (bonds on the router's address).
    function _bondThrough(address user, SwapRouter router, uint256 amount) internal {
        vm.prank(user);
        router.bond(hook, amount);
    }

    // -------------------------------------------------------------------------
    // Test: full loop — bond, fee-discounted swap, sandwich, slash, reserve
    // -------------------------------------------------------------------------

    function test_fullLoop_bondSwapSandwichSlashReserve() public {
        // --- Step 1: Searcher bonds via their router ---
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        assertTrue(hook.isBonded(address(searcherRouter)));
        assertEq(hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT);

        uint256 hookBalBefore = token1.balanceOf(address(hook));

        // --- Step 2: Leg 1 — searcher buys token1 (zeroForOne) ---
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));

        // --- Step 3: Victim swaps in the opposite direction ---
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));

        // --- Step 4: Leg 2 — searcher sells token0 (oneForZero) -> sandwich detected ---
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));

        // --- Step 5: Verify slash ---
        // First offense: 50% slash
        assertEq(
            hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT / 2, "bond should be halved"
        );

        // --- Step 6: Verify reserve (not immediate donation) ---
        // The slashed capital parks in the insurance reserve. The hook physically
        // retains its full token1 escrow (BOND_AMOUNT total), reclassified from the
        // searcher's bond into the pooled reserve. Nothing reaches the PoolManager's
        // LP payouts until a drain.
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2, "reserve holds the slashed amount");
        assertEq(token1.balanceOf(address(hook)), hookBalBefore, "hook still escrows all token1");
    }

    // -------------------------------------------------------------------------
    // Test: fee discount applied to bonded swapper
    // -------------------------------------------------------------------------

    function test_feeDiscount_bondedSwapperGetsDiscountedFee() public {
        vm.prank(searcher);
        hook.bond(BOND_AMOUNT);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({ amountSpecified: 0, zeroForOne: true, sqrtPriceLimitX96: 0 });
        vm.prank(address(pm));
        (bytes4 selector,, uint24 overrideFee) = hook.beforeSwap(searcher, poolKey, params, "");

        uint24 expectedDiscounted = POOL_FEE - (hook.DEFAULT_FEE_DISCOUNT_BPS() * 100);
        uint24 expectedOverride = expectedDiscounted | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(overrideFee, expectedOverride, "bonded swapper should get discounted fee");
    }

    function test_feeDiscount_unbondedSwapperGetsNoOverride() public {
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({ amountSpecified: 0, zeroForOne: true, sqrtPriceLimitX96: 0 });
        vm.prank(address(pm));
        (bytes4 selector,, uint24 overrideFee) = hook.beforeSwap(victim, poolKey, params, "");

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(overrideFee, 0, "unbonded swapper should get no fee override");
    }

    // -------------------------------------------------------------------------
    // Test: no detection across blocks
    // -------------------------------------------------------------------------

    function test_noDetection_crossBlock() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);

        // Leg 1 in block 1000
        vm.roll(1000);
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));

        // Victim in block 1001
        vm.roll(1001);
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));

        // Leg 2 in block 1002 — different block, no detection
        vm.roll(1002);
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));

        assertEq(
            hook.bondedBalance(address(searcherRouter)),
            BOND_AMOUNT,
            "cross-block swap should not be slashed"
        );
    }

    // -------------------------------------------------------------------------
    // Test: no detection with mule addresses
    // -------------------------------------------------------------------------

    function test_noDetection_muleAddresses() public {
        address mule = makeAddr("mule");
        token0.mint(mule, 100e18);
        token1.mint(mule, 10_000e6);
        SwapRouter muleRouter = new SwapRouter(pm);
        vm.startPrank(mule);
        token0.approve(address(muleRouter), type(uint256).max);
        token1.approve(address(muleRouter), type(uint256).max);
        muleRouter.bond(hook, BOND_AMOUNT);
        vm.stopPrank();

        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);

        // Leg 1: searcher
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));

        // Victim
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));

        // Leg 2: mule (different address) — no same-address detection
        _swapThrough(mule, muleRouter, false, -int256(SWAP_AMOUNT));

        assertEq(
            hook.bondedBalance(address(searcherRouter)),
            BOND_AMOUNT,
            "mule leg2 should not slash searcher"
        );
        assertEq(hook.bondedBalance(address(muleRouter)), BOND_AMOUNT, "mule bond intact");
    }

    // -------------------------------------------------------------------------
    // Test: repeat offense escalates to full slash + ban
    // -------------------------------------------------------------------------

    function test_repeatOffense_fullSlashAndBan() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);

        // First offense at block 1000
        vm.roll(1000);
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));
        assertEq(
            hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT / 2, "first offense: 50% slash"
        );

        // Repeat offense at block 1001 (within extended lock window)
        vm.roll(1001);
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));

        assertEq(hook.bondedBalance(address(searcherRouter)), 0, "repeat offense: full slash");
        assertTrue(hook.isBanned(address(searcherRouter)), "repeat offense: address banned");
    }

    // -------------------------------------------------------------------------
    // Test: banned address cannot re-bond
    // -------------------------------------------------------------------------

    function test_bannedAddress_cannotReBond() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);

        // First offense
        vm.roll(1000);
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));

        // Repeat offense -> banned
        vm.roll(1001);
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));
        assertTrue(hook.isBanned(address(searcherRouter)));

        // Re-bond while banned should revert (called from the banned router address)
        vm.prank(address(searcherRouter));
        vm.expectRevert();
        hook.bond(BOND_AMOUNT);
    }

    // -------------------------------------------------------------------------
    // Test: bond withdrawal after maturity
    // -------------------------------------------------------------------------

    function test_withdrawBond_afterMaturity() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // Cannot withdraw before maturity
        vm.prank(searcher);
        vm.expectRevert();
        hook.withdrawBond();

        // Can withdraw after DEFAULT_MIN_BOND_DURATION_BLOCKS (100)
        vm.roll(block.number + 100);
        uint256 balBefore = token1.balanceOf(searcher);
        vm.prank(searcher);
        hook.withdrawBond();

        assertEq(token1.balanceOf(searcher), balBefore + BOND_AMOUNT);
        assertEq(hook.bondedBalance(searcher), 0);
    }

    // -------------------------------------------------------------------------
    // Test: donation amount matches slashed amount
    // -------------------------------------------------------------------------

    function test_reserveAmount_matchesSlashed() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);

        uint256 hookBalBefore = token1.balanceOf(address(hook));

        // Sandwich -> first offense -> 50% slash, parked in the insurance reserve
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));

        uint256 slashed = BOND_AMOUNT / 2;

        // The slashed amount is credited to the reserve; the hook physically retains
        // all token1 escrow. The pool manager receives nothing special for LPs until a
        // drain (swap fees still accrue to it, so we only assert the hook's escrow).
        assertEq(hook.insuranceReserve(), slashed, "reserve holds the slashed amount");
        assertEq(token1.balanceOf(address(hook)), hookBalBefore, "hook still escrows all token1");
    }

    // Test: real reserve drain reaches the PoolManager via unlock
    // -------------------------------------------------------------------------

    function test_reserveDrain_landsInPoolManager() public {
        // Set roles. owner == this (the test contract deployed the hook impl).
        address watch = makeAddr("watch");
        hook.setWatchtower(watch);
        hook.setKeeper(makeAddr("kee"));

        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);

        // Build a 50e6 reserve via a real sandwich.
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2);

        // The watchtower flags the searcher so the keeper drain has a justification.
        vm.prank(watch);
        hook.flagFromWatchtower(address(searcherRouter), 0, block.number + 100);

        uint256 hookBalBefore = token1.balanceOf(address(hook));
        uint256 pmBalBefore = token1.balanceOf(address(pm));

        // The keeper drains the full reserve through a real unlock/donate/settle.
        address[] memory flagged = new address[](1);
        flagged[0] = address(searcherRouter);
        vm.prank(hook.keeper());
        uint256 drained = hook.drainFlagged(flagged);

        assertEq(drained, BOND_AMOUNT / 2, "drain returns the full reserve");
        assertEq(hook.insuranceReserve(), 0);
        assertEq(hook.totalWithdrawn(), BOND_AMOUNT / 2);

        // The donation physically lands in the PoolManager. Swap fees accrued during
        // the sandwich also hit the PM, so it must hold the drained amount on top of
        // its pre-drain balance. The hook's escrow drops by exactly the drained amount.
        assertGe(
            token1.balanceOf(address(pm)) - pmBalBefore,
            BOND_AMOUNT / 2,
            "PM received the drained reserve"
        );
        assertEq(
            token1.balanceOf(address(hook)),
            hookBalBefore - BOND_AMOUNT / 2,
            "hook escrow drops by the drained reserve"
        );
    }

    // -------------------------------------------------------------------------
    // Test: reserve invariant holds across partial drain + bond withdrawal
    // -------------------------------------------------------------------------

    function test_partialDrain_afterWithdrawal_preservesSolvency() public {
        address watch = makeAddr("watch");
        hook.setWatchtower(watch);
        hook.setKeeper(makeAddr("kee"));
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);

        // Build a 50e6 reserve via a real sandwich; bond falls to 50e6.
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2);
        assertEq(hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT / 2);

        // The searcher's remaining bond and the reserve are both still physically held.
        uint256 escrowBefore = token1.balanceOf(address(hook));
        assertEq(escrowBefore, BOND_AMOUNT, "escrow equals bond + reserve");

        // Searcher matures and withdraws their remaining bond. A struck bond is gated
        // on the extended first-offense lock, not the 100-block minimum.
        vm.roll(block.number + hook.FIRST_OFFENSE_LOCK_EXTENSION_BLOCKS());
        vm.prank(address(searcherRouter));
        hook.withdrawBond();
        assertEq(hook.bondedBalance(address(searcherRouter)), 0);
        // Escrow now only backs the reserve.
        assertEq(token1.balanceOf(address(hook)), BOND_AMOUNT / 2, "escrow = reserve only");

        // Flag so the keeper drain is justified, then drain the reserve against a
        // solvent hook.
        vm.prank(watch);
        hook.flagFromWatchtower(address(searcherRouter), 0, block.number + 100);
        address[] memory flagged = new address[](1);
        flagged[0] = address(searcherRouter);
        vm.prank(hook.keeper());
        uint256 drained = hook.drainFlagged(flagged);
        assertEq(drained, BOND_AMOUNT / 2, "drain moves the full reserve");
        assertEq(hook.insuranceReserve(), 0);
        assertEq(token1.balanceOf(address(hook)), 0, "hook escrow fully discharged");
    }

    // -------------------------------------------------------------------------
    // Gas benchmark — hook per-operation costs
    // -------------------------------------------------------------------------
    // The hook is etch-deployed at its permission-derived address, so foundry does
    // not attribute its gas to a contract in --gas-report. These measurements capture
    // the marginal cost of each hook entry point directly.

    function test_gas_bond() public {
        uint256 before = gasleft();
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        uint256 gasAfter = gasleft();
        uint256 used = before - gasAfter;
        // Verify the hook bond + escrow transfer path executes (~121k incl. router + ERC20)
        assertTrue(used > 50_000, "bond should cost a meaningful amount of gas");
    }

    function test_gas_nonSandwichSwap() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);

        uint256 before = gasleft();
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        uint256 gasAfter = gasleft();
        uint256 used = before - gasAfter;
        // Full swap through the hook: beforeSwap (fee override) + afterSwap detection.
        assertTrue(used > 100_000, "non-sandwich swap should cost a meaningful amount of gas");
    }

    function test_gas_sandwichSlashReserve() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);

        uint256 before = gasleft();
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));
        uint256 gasAfter = gasleft();
        uint256 used = before - gasAfter;
        // Sandwich detection + slash + reserve credit execute within the final afterSwap.
        assertTrue(used > 150_000, "sandwich slash path should cost a meaningful amount of gas");
    }

    function test_gas_withdrawBond() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        vm.roll(block.number + 100);

        uint256 before = gasleft();
        vm.prank(address(searcherRouter));
        hook.withdrawBond();
        uint256 gasAfter = gasleft();
        uint256 used = before - gasAfter;
        assertTrue(used > 10_000, "withdraw should cost a meaningful amount of gas");
    }
}
