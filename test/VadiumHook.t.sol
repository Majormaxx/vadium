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
        assertEq(hook.insuranceReserve(), 0);
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

        // Donate amount stays zero at slash time; the slashed capital is parked in the
        // LP insurance reserve, not donated instantly.
        assertEq(hook.lastDonationAmount(), 0);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2);
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

    function test_reserveAmount_matchesSlashedAmount() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        // First offense: 50% of 100e6 = 50e6 parks in the reserve. Pledged follows.
        assertEq(hook.insuranceReserve(), 50e6);
        assertEq(hook.slashedPledged(), 50e6);
        assertEq(hook.totalWithdrawn(), 0);
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
    // Watchtower + insurance reserve
    // -------------------------------------------------------------------------

    function test_roles_onlyOwnerCanAssign() public {
        address watch = makeAddr("watch");
        address kee = makeAddr("kee");

        vm.prank(searcher);
        vm.expectRevert();
        hook.setWatchtower(watch);

        vm.prank(searcher);
        vm.expectRevert();
        hook.setKeeper(kee);

        assertEq(hook.watchtower(), address(0), "watchtower unset");
        assertEq(hook.keeper(), address(0), "keeper unset");
    }

    function test_setWatchtower_onceThenReverts() public {
        address watch = makeAddr("watch");
        // owner == this (the test contract deployed the hook).
        hook.setWatchtower(watch);
        assertEq(hook.watchtower(), watch);

        vm.expectRevert();
        hook.setWatchtower(makeAddr("watch2"));
    }

    function test_setKeeper_onceThenReverts() public {
        address kee = makeAddr("kee");
        hook.setKeeper(kee);
        assertEq(hook.keeper(), kee);

        vm.expectRevert();
        hook.setKeeper(makeAddr("kee2"));
    }

    function test_flagFromWatchtower_onlyWatchtower() public {
        vm.expectRevert();
        hook.flagFromWatchtower(searcher, 0, block.number + 10);
    }

    function test_flagFromWatchtower_slashesBondIntoReserve() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        address watch = makeAddr("watch");
        hook.setWatchtower(watch);

        vm.prank(watch);
        hook.flagFromWatchtower(searcher, BOND_AMOUNT / 2, block.number + 10);

        // Bond split: half stays, half moves into the reserve. Flag recorded.
        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT / 2);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2);
        assertEq(hook.slashedPledged(), BOND_AMOUNT / 2);
        assertEq(hook.flaggedUntil(searcher), block.number + 10);
    }

    function test_flagFromWatchtower_capsSlashAtBond() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        address watch = makeAddr("watch");
        hook.setWatchtower(watch);

        // Request more than the full bond; the slash is capped at the bond balance.
        vm.prank(watch);
        hook.flagFromWatchtower(searcher, type(uint256).max, block.number);
        assertEq(hook.bondedBalance(searcher), 0);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT);
    }

    function test_flagFromWatchtower_unbondedFlagOnly() public {
        address watch = makeAddr("watch");
        hook.setWatchtower(watch);

        vm.prank(watch);
        hook.flagFromWatchtower(searcher, BOND_AMOUNT, block.number + 20);

        // No bond to slash, but the flag is recorded for a later keeper drain.
        assertEq(hook.insuranceReserve(), 0);
        assertEq(hook.flaggedUntil(searcher), block.number + 20);
    }

    function test_claimCoverage_onlyOwner() public {
        address kee = makeAddr("kee");
        hook.setKeeper(kee);

        vm.prank(kee);
        vm.expectRevert();
        hook.claimCoverage(1);
    }

    function test_claimCoverage_drainsReserve() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // Build a 50e6 reserve via a sandwich slash.
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2);

        // Owner (this) claims the reserve. The mocked _donate records the payout.
        hook.claimCoverage(BOND_AMOUNT / 2);
        assertEq(hook.insuranceReserve(), 0);
        assertEq(hook.slashedPledged(), BOND_AMOUNT / 2);
        assertEq(hook.totalWithdrawn(), BOND_AMOUNT / 2);
        assertEq(hook.lastDonationAmount(), BOND_AMOUNT / 2);
    }

    function test_claimCoverage_exceedsReserve_reverts() public {
        assertEq(hook.insuranceReserve(), 0);
        vm.expectRevert();
        hook.claimCoverage(1);
    }

    function test_drainFlagged_onlyKeeper() public {
        address watch = makeAddr("watch");
        hook.setWatchtower(watch);

        vm.prank(watch);
        hook.flagFromWatchtower(victim, 0, block.number + 10);

        address[] memory flagged = new address[](1);
        flagged[0] = victim;

        // Random caller, not the keeper -> unauthorized.
        vm.prank(searcher);
        vm.expectRevert();
        hook.drainFlagged(flagged);
    }

    function test_drainFlagged_requiresFlag() public {
        hook.setKeeper(makeAddr("kee"));

        address[] memory flagged = new address[](1);
        flagged[0] = victim; // never flagged

        vm.prank(hook.keeper());
        vm.expectRevert();
        hook.drainFlagged(flagged);
    }

    function test_drainFlagged_emptyList_reverts() public {
        hook.setKeeper(makeAddr("kee"));

        address[] memory flagged = new address[](0);
        vm.prank(hook.keeper());
        vm.expectRevert();
        hook.drainFlagged(flagged);
    }

    function test_drainFlagged_pushesReserve() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // Build a reserve with two slashes credited to the same flagged address.
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2);

        address watch = makeAddr("watch");
        hook.setWatchtower(watch);
        vm.prank(watch);
        hook.flagFromWatchtower(searcher, 0, block.number + 10);

        address[] memory flagged = new address[](1);
        flagged[0] = searcher;

        uint256 hookBalBefore = token1.balanceOf(address(hook));
        vm.prank(hook.keeper());
        uint256 drained = hook.drainFlagged(flagged);

        assertEq(drained, BOND_AMOUNT / 2, "drain returns the full reserve");
        assertEq(hook.insuranceReserve(), 0);
        assertEq(hook.totalWithdrawn(), BOND_AMOUNT / 2);
        // The mocked _donate does not move real tokens; it records the payout.
        assertEq(hook.lastDonationAmount(), BOND_AMOUNT / 2);
        assertEq(token1.balanceOf(address(hook)), hookBalBefore, "mock donate leaves escrow alone");
    }

    function test_repeatSlash_accumulatesReserve() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // First offense: 50e6 into reserve, bond 50e6.
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2);

        // Repeat offense within the lock: the remaining 50e6 is fully slashed and
        // added on top of the reserve.
        vm.roll(1001);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        assertEq(hook.bondedBalance(searcher), 0);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT);
        assertEq(hook.slashedPledged(), BOND_AMOUNT);
        assertTrue(hook.isBanned(searcher));
    }

    // -------------------------------------------------------------------------
    // Errors and edge cases
    // -------------------------------------------------------------------------

    function test_unlockCallback_onlyPoolManager() public {
        // unlockCallback must only be reachable from the PoolManager; any other caller
        // reverts. The pool manager then runs the hook's _unlockCallback, which now
        // performs the reserve payout.
        vm.prank(address(0xBEEF));
        vm.expectRevert();
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
