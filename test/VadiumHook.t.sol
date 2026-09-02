// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";
import { BeforeSwapDelta } from "v4-core/src/types/BeforeSwapDelta.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";

import { VadiumHook } from "../src/core/VadiumHook.sol";
import { BondManager } from "../src/core/libraries/BondManager.sol";
import { FeeDiscount } from "../src/core/libraries/FeeDiscount.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { TestVadiumHook } from "./mocks/TestVadiumHook.sol";

/// @title VadiumHookTest
/// @notice Unit tests for VadiumHook lifecycle and internal logic.
///         Uses the TestVadiumHook harness to call recordSwap and slash without
///         routing through a real PoolManager.
contract VadiumHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using BondManager for BondManager.Bond;
    using CurrencyLibrary for Currency;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    PoolManager internal poolManager;
    MockERC20 internal token0;
    MockERC20 internal token1;
    TestVadiumHook internal hook;

    // Non-zero address that acts as a "poolManager" for the onlyPoolManager gate.
    address internal pmAddr;

    address internal searcher = makeAddr("searcher");
    address internal searcher2 = makeAddr("searcher2");
    address internal victim = makeAddr("victim");

    PoolKey internal poolKey;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 10;

    uint256 constant BOND_AMOUNT = 100e6;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        // Deploy mock tokens (token0 must sort below token1).
        token0 = new MockERC20("Wrapped ETH", "WETH", 18);
        token1 = new MockERC20("USD Coin", "USDC", 6);

        // Ensure token0.address < token1.address — if not, swap.
        if (address(token0) > address(token1)) {
            MockERC20 tmp = token0;
            token0 = token1;
            token1 = tmp;
        }

        // Deploy a dummy PoolManager address for the onlyPoolManager gate.
        // The actual PoolManager contract is only needed for real swap callbacks;
        // this harness never calls donate, so a bare address suffices.
        poolManager = new PoolManager(address(this));
        pmAddr = address(poolManager);

        // Deploy the hook with a static fee (no dynamic-fee requirement).
        hook = new TestVadiumHook(
            IPoolManager(pmAddr),
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            POOL_FEE,
            TICK_SPACING
        );

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Mint and fund searcher for bonding.
        token1.mint(searcher, 10_000e6);
        vm.startPrank(searcher);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    function test_constructor_setsImmutables() public view {
        assertEq(address(hook.poolManager()), pmAddr);
        assertEq(Currency.unwrap(hook.currency0()), address(token0));
        assertEq(Currency.unwrap(hook.currency1()), address(token1));
        assertEq(hook.fee(), POOL_FEE);
        assertEq(hook.tickSpacing(), TICK_SPACING);
    }

    function test_constructor_revertsOnZeroBondToken() public {
        vm.expectRevert("Vadium: bond token cannot be zero address");
        new TestVadiumHook(
            IPoolManager(pmAddr),
            Currency.wrap(address(token0)),
            Currency.wrap(address(0)), // token1 = zero → invalid bond token
            POOL_FEE,
            TICK_SPACING
        );
    }

    function test_constructor_revertsOnFeeOutOfRange() public {
        vm.expectRevert("Vadium: pool fee out of range");
        new TestVadiumHook(
            IPoolManager(pmAddr),
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            1_000_001, // above MAX_LP_FEE
            TICK_SPACING
        );
    }

    // -------------------------------------------------------------------------
    // getHookPermissions
    // -------------------------------------------------------------------------

    function test_getHookPermissions_onlySwapFlags() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertFalse(perms.beforeInitialize);
        assertFalse(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
    }

    // -------------------------------------------------------------------------
    // Bond lifecycle
    // -------------------------------------------------------------------------

    function test_bond_successfulDeposit() public {
        vm.prank(searcher);
        hook.bond(BOND_AMOUNT);

        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT);
        assertTrue(hook.isBonded(searcher));
    }

    function test_bond_revertsOnTooSmall() public {
        vm.prank(searcher);
        vm.expectRevert();
        hook.bond(BOND_AMOUNT - 1);
    }

    function test_bond_revertsOnDoubleBond() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.expectRevert(VadiumHook.BondAlreadyActive.selector);
        hook.bond(BOND_AMOUNT);
    }

    function test_withdrawBond_revertsOnNotMatured() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);

        vm.expectRevert();
        hook.withdrawBond();
    }

    function test_withdrawBond_succeedsAfterMaturity() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);

        // DEFAULT_MIN_BOND_DURATION_BLOCKS = 100
        vm.roll(block.number + 100);
        uint256 balBefore = token1.balanceOf(searcher);
        hook.withdrawBond();

        assertEq(token1.balanceOf(searcher), balBefore + BOND_AMOUNT);
        assertEq(hook.bondedBalance(searcher), 0);
    }

    function test_withdrawBond_revertsOnNoBond() public {
        vm.expectRevert(VadiumHook.NoBond.selector);
        hook.withdrawBond();
    }

    // -------------------------------------------------------------------------
    // beforeSwap — fee override
    // -------------------------------------------------------------------------

    function test_beforeSwap_returnsNoOverride_whenUnbonded() public {
        // beforeSwap is only callable by the pool manager. sender = searcher (unbonded).
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({ amountSpecified: 0, zeroForOne: true, sqrtPriceLimitX96: 0 });
        vm.prank(pmAddr);
        (bytes4 selector,, uint24 overrideFee) = hook.beforeSwap(searcher, poolKey, params, "");

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(overrideFee, 0);
    }

    function test_beforeSwap_returnsDiscountedFee_whenBonded() public {
        // Bond the searcher directly.
        vm.prank(searcher);
        hook.bond(BOND_AMOUNT);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({ amountSpecified: 0, zeroForOne: true, sqrtPriceLimitX96: 0 });
        vm.prank(pmAddr);
        (bytes4 ignoreSel, BeforeSwapDelta ignoreDelta, uint24 overrideFee) =
            hook.beforeSwap(searcher, poolKey, params, "");

        uint24 expectedDiscounted =
            POOL_FEE - (hook.DEFAULT_FEE_DISCOUNT_BPS() * FeeDiscount.BPS_TO_FEE_UNITS);
        uint24 expectedOverride = expectedDiscounted | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        assertEq(overrideFee, expectedOverride);
    }

    function test_beforeSwap_returnsNoOverride_whenBanned() public {
        // Bond, then slash (repeat) to trigger a ban.
        vm.prank(searcher);
        hook.bond(BOND_AMOUNT);

        // Drive a first-offense sandwich to extend lock.
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false); // intervene
        hook.recordSwap(searcher, false); // first offense → 50% slash, lock extension

        // Drive a second sandwich while locked → repeat → banned.
        vm.roll(1001);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        // While banned, beforeSwap returns no override.
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({ amountSpecified: 0, zeroForOne: true, sqrtPriceLimitX96: 0 });
        vm.prank(pmAddr);
        (bytes4 ignoreSel, BeforeSwapDelta ignoreDelta, uint24 overrideFee) =
            hook.beforeSwap(searcher, poolKey, params, "");

        assertEq(overrideFee, 0);
    }

    // -------------------------------------------------------------------------
    // recordSwap — detection state machine
    // -------------------------------------------------------------------------

    function test_recordSwap_noDetection_onFirstSwapInBlock() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);

        // Bond still intact.
        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT);
        assertTrue(hook.isBonded(searcher));
    }

    function test_recordSwap_detectsTrueSandwich() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false); // first offense

        // 50% slash.
        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT / 2);
    }

    function test_recordSwap_detectsReverseSandwich() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, false);
        hook.recordSwap(victim, true);
        hook.recordSwap(searcher, true); // first offense

        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT / 2);
    }

    function test_recordSwap_noDetection_whenSameDirection() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, true); // same direction, not a reversal

        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT);
    }

    function test_recordSwap_noDetection_whenNoInterveningSwapper() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);
        // No intervening different swapper.
        hook.recordSwap(searcher, false);

        // Detection requires interveningDifferent — here the immediately preceding
        // swapper is searcher (itself), so interveningDifferent = false.
        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT);
    }

    function test_recordSwap_noDetection_whenAcrossBlocks() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);

        vm.roll(1001);
        hook.recordSwap(victim, false);

        vm.roll(1002);
        hook.recordSwap(searcher, false); // different block — no detection

        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT);
    }

    function test_recordSwap_noDetection_muleAddresses() public {
        // Two different bonded addresses: attacker uses searcher for leg1, searcher2 for leg2.
        // No single address triggers same-address detection.
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();
        vm.startPrank(searcher2);
        token1.mint(searcher2, 10_000e6);
        token1.approve(address(hook), type(uint256).max);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher2, false); // leg2 on a different address

        // searcher's bond intact — no same-address sandwich.
        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT);
        assertEq(hook.bondedBalance(searcher2), BOND_AMOUNT);
    }

    function test_recordSwap_slashNotDonation_whenUnbonded() public {
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        // Not bonded — _slash sees b.amount == 0 and returns early; nothing slashed.
        assertEq(hook.lastDonationAmount(), 0);
    }

    // -------------------------------------------------------------------------
    // Slash accounting
    // -------------------------------------------------------------------------

    function test_firstOffense_takesHalfAndExtendsLock() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        // 50% slash: half remains.
        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT / 2);

        // lock extension: depositBlock is now 1000 (the block of the first offense).
        (uint256 amountAfter, uint256 depositAfter,, uint256 strikesAfter) = hook.bonds(searcher);
        assertEq(amountAfter, BOND_AMOUNT / 2);
        assertEq(depositAfter, 1000);
        assertEq(strikesAfter, 1);

        // Donate amount equals the slashed amount.
        assertEq(hook.lastDonationAmount(), BOND_AMOUNT / 2);
    }

    function test_repeatOffense_slashesAndBans() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // First offense.
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        uint256 afterFirst = BOND_AMOUNT / 2;
        assertEq(hook.bondedBalance(searcher), afterFirst);

        // Repeat offense within the extended lock (7200 blocks from depositBlock=1000).
        vm.roll(1001);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        // Full remaining slashed, address banned.
        assertEq(hook.bondedBalance(searcher), 0);
        assertTrue(hook.isBanned(searcher));
        (,, uint256 bannedUntil,) = hook.bonds(searcher);
        assertGt(bannedUntil, block.number);
    }

    function test_banPreventsReBond() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // First offense.
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        // Repeat offense → banned.
        vm.roll(1001);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        // Re-bond while banned should revert.
        vm.prank(searcher);
        vm.expectRevert();
        hook.bond(BOND_AMOUNT);
    }

    function test_donationAmount_matchesSlashedAmount() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        // First offense: 50% of 100e6 = 50e6.
        assertEq(hook.lastDonationAmount(), 50e6);
    }

    function test_multipleSequentialSwapsInBlock_noFalsePositive() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(victim, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(victim, true);
        hook.recordSwap(searcher, true);
        hook.recordSwap(searcher, false);

        // Multiple non-reversal swaps intermixed — no sandwich detected for searcher.
        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT);
    }

    // -------------------------------------------------------------------------
    // Errors and edge cases
    // -------------------------------------------------------------------------

    function test_unsupportedOperation_reverts() public {
        // unlockCallback is only callable by the pool manager; it then runs the
        // hook's _unlockCallback, which reverts with UnsupportedOperation.
        vm.prank(pmAddr);
        vm.expectRevert(VadiumHook.UnsupportedOperation.selector);
        hook.unlockCallback("");
    }

    function test_isBanned_falseWhenNotBanned() public view {
        assertFalse(hook.isBanned(searcher));
    }

    function test_isBonded_falseWhenNoBond() public view {
        assertFalse(hook.isBonded(searcher));
    }

    function test_bondedBalance_zeroWhenNoBond() public view {
        assertEq(hook.bondedBalance(searcher), 0);
    }
}
