// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";
import { BeforeSwapDelta } from "v4-core/src/types/BeforeSwapDelta.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
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
    address constant CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

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
            TICK_SPACING,
            address(this),
            CALLBACK_PROXY
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
            TICK_SPACING,
            address(this),
            CALLBACK_PROXY
        );
    }

    function test_constructor_revertsOnFeeOutOfRange() public {
        vm.expectRevert("Vadium: pool fee out of range");
        new TestVadiumHook(
            IPoolManager(pmAddr),
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            1_000_001, // above MAX_LP_FEE
            TICK_SPACING,
            address(this),
            CALLBACK_PROXY
        );
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert("Vadium: zero owner");
        new TestVadiumHook(
            IPoolManager(pmAddr),
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            POOL_FEE,
            TICK_SPACING,
            address(0),
            CALLBACK_PROXY
        );
    }

    function test_constructor_revertsOnZeroCallbackProxy() public {
        vm.expectRevert("Vadium: zero callback proxy");
        new TestVadiumHook(
            IPoolManager(pmAddr),
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            POOL_FEE,
            TICK_SPACING,
            address(this),
            address(0)
        );
    }

    function test_constructor_setsExplicitOwner() public view {
        assertEq(hook.owner(), address(this), "owner is the explicit constructor arg");
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
        hook.flagFromWatchtower(searcher, type(uint256).max, block.number + 10);
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

    // -------------------------------------------------------------------------
    // onWatchtowerFlag (Reactive Network cross-chain flag)
    // -------------------------------------------------------------------------

    /// @dev Helper: deliver a cross-chain flag from the callback proxy.
    function _watchtowerFlag(address rvmId, address target, uint256 banUntil) internal {
        vm.prank(CALLBACK_PROXY);
        hook.onWatchtowerFlag(rvmId, target, banUntil);
    }

    function test_onWatchtowerFlag_onlyCallbackProxy() public {
        // First-but-wrong caller: anyone (including the watchtower role itself) must
        // fail unless the message originates from the chain's callback proxy.
        address watch = makeAddr("watch");
        hook.setWatchtower(watch);
        vm.prank(watch);
        vm.expectRevert();
        hook.onWatchtowerFlag(watch, searcher, block.number + 10);
    }

    function test_onWatchtowerFlag_requiresMatchingRvmId() public {
        // Proxy is authoritative as the transport, but the injected RVM ID must still
        // match the assigned watchtower.
        hook.setWatchtower(makeAddr("watch"));
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert();
        hook.onWatchtowerFlag(makeAddr("imposter"), searcher, block.number + 10);
    }

    function test_onWatchtowerFlag_zeroSearcher_reverts() public {
        hook.setWatchtower(address(this));
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert("Vadium: zero searcher");
        hook.onWatchtowerFlag(address(this), address(0), block.number + 10);
    }

    function test_onWatchtowerFlag_setsFlagOnly() public {
        // The cross-chain path records the flag for a later keeper drain; it does not
        // slash (bond confiscation is the on-pool detector's job and would run here too,
        // but the two messenger flows stay coupled only through the flag record).
        hook.setWatchtower(address(this));

        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        _watchtowerFlag(address(this), searcher, block.number + 10);

        assertEq(hook.flaggedUntil(searcher), block.number + 10);
        // No on-pool slash happened here: the bond stays whole and the reserve intact.
        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT);
        assertEq(hook.insuranceReserve(), 0);
    }

    function test_onWatchtowerFlag_expiredBan_reverts() public {
        hook.setWatchtower(address(this));
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert("Vadium: flag already expired");
        hook.onWatchtowerFlag(address(this), searcher, block.number);
    }

    function test_onWatchtowerFlag_activeFlag_isNoop() public {
        hook.setWatchtower(address(this));

        _watchtowerFlag(address(this), searcher, block.number + 10);
        uint256 first = hook.flaggedUntil(searcher);

        // A second flag while the first is still active must not silently extend the
        // window — it is a no-op, not a re-flag race.
        _watchtowerFlag(address(this), searcher, block.number + 20);
        assertEq(hook.flaggedUntil(searcher), first);
    }

    function test_onWatchtowerFlag_zeroBanUntil_defaults() public {
        hook.setWatchtower(address(this));
        // Detector recorded no ban window: fall back to the minimum bond duration.
        _watchtowerFlag(address(this), searcher, 0);
        assertEq(
            hook.flaggedUntil(searcher), block.number + hook.DEFAULT_MIN_BOND_DURATION_BLOCKS()
        );
    }

    function test_onWatchtowerFlag_usedWhenExpired() public {
        hook.setWatchtower(address(this));

        // Once an existing flag passes, a fresh flag may take effect again.
        _watchtowerFlag(address(this), searcher, block.number + 5);
        vm.roll(block.number + 10); // old flag now expired

        _watchtowerFlag(address(this), searcher, block.number + 10);
        assertEq(hook.flaggedUntil(searcher), block.number + 10);
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
    // Adversarial edge cases
    // -------------------------------------------------------------------------

    function test_initializeOwner_revertsWhenAlreadySet() public {
        // On a normal deployment the constructor sets owner, so the permissionless
        // bootstrap path is inert: it can never be grabbed once ownership exists.
        vm.prank(searcher);
        vm.expectRevert();
        hook.initializeOwner(searcher);
    }

    function test_watchtowerSlashes_escalateLikeOnPool() public {
        address watch = makeAddr("watch");
        hook.setWatchtower(watch);

        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // First watchtower flag slashes half the bond, records a strike, and extends
        // the lock — but does not yet ban.
        vm.prank(watch);
        hook.flagFromWatchtower(searcher, BOND_AMOUNT / 2, block.number + 3);
        (uint256 amt,, uint256 bannedUntil, uint256 strikes) = hook.bonds(searcher);
        assertEq(amt, BOND_AMOUNT / 2);
        assertEq(bannedUntil, 0, "first watchtower flag has not banned");
        assertEq(strikes, 1, "first watchtower flag counts a strike");
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2);

        // A repeat flag is refused while the prior flag is still live.
        vm.prank(watch);
        vm.expectRevert();
        hook.flagFromWatchtower(searcher, 0, block.number + 1_000);

        // Once the first (short) flag expires but we are still inside the extended
        // lock, a second watchtower slash escalates to a full ban and drains the
        // residual bond.
        vm.roll(block.number + 4);
        vm.prank(watch);
        hook.flagFromWatchtower(searcher, type(uint256).max, block.number + 3);
        assertEq(hook.bondedBalance(searcher), 0);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT);
        assertTrue(hook.isBanned(searcher), "repeat watchtower slash draws the ban");
    }

    function test_withdrawLock_firstOffenseExtendsTo7200Blocks() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // First offense at block 1000 slashes 50% and records a strike.
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);
        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT / 2);

        // Withdrawal is gated on the extended first-offense lock (7,200 blocks), not
        // the 100-block minimum, so the residual bond cannot be discharged instantly.
        uint256 ext = hook.FIRST_OFFENSE_LOCK_EXTENSION_BLOCKS();
        uint256 depositBlock = block.number;

        vm.roll(depositBlock + 100);
        vm.prank(searcher);
        vm.expectRevert();
        hook.withdrawBond();

        vm.roll(depositBlock + ext - 1);
        vm.prank(searcher);
        vm.expectRevert();
        hook.withdrawBond();

        vm.roll(depositBlock + ext);
        vm.prank(searcher);
        hook.withdrawBond();
        assertEq(hook.bondedBalance(searcher), 0);
    }

    function test_drainFlagged_rejectsExpiredFlag() public {
        // drainFlagged only pays out while a listed address holds an active flag; an
        // expired flag no longer justifies a payout.
        address watch = makeAddr("watch");
        hook.setWatchtower(watch);
        hook.setKeeper(makeAddr("kee"));

        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2);

        // Still active: keeper drains.
        vm.prank(watch);
        hook.flagFromWatchtower(searcher, 0, block.number + 3);
        address[] memory flagged = new address[](1);
        flagged[0] = searcher;
        vm.prank(hook.keeper());
        uint256 drained = hook.drainFlagged(flagged);
        assertEq(drained, BOND_AMOUNT / 2, "active flag drains the reserve");
        assertEq(hook.insuranceReserve(), 0);

        // A fresh offense into a second bond, flagged with a short expiry: once the
        // flag lapses, the same drain is rejected.
        address searcher2 = makeAddr("searcher2");
        address victim2 = makeAddr("victim2");
        vm.startPrank(searcher2);
        token1.mint(searcher2, 10_000e6);
        token1.approve(address(hook), type(uint256).max);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();
        vm.roll(2000);
        hook.recordSwap(searcher2, true);
        hook.recordSwap(victim2, false);
        hook.recordSwap(searcher2, false);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2);

        vm.prank(watch);
        hook.flagFromWatchtower(searcher2, 0, block.number + 3);
        vm.roll(block.number + 5);
        address[] memory flagged2 = new address[](1);
        flagged2[0] = searcher2;
        vm.prank(hook.keeper());
        vm.expectRevert();
        hook.drainFlagged(flagged2);
    }

    function test_beforeSwap_flagStripsDiscount() public {
        address watch = makeAddr("watch");
        hook.setWatchtower(watch);

        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // Confirm the discount is active before any flag.
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({ amountSpecified: 0, zeroForOne: true, sqrtPriceLimitX96: 0 });
        vm.prank(pmAddr);
        (,, uint24 pre) = hook.beforeSwap(searcher, poolKey, params, "");
        assertTrue(pre != 0, "bonded address has a discount");

        // A live watchtower flag strips the discount even though the address is not
        // banned.
        vm.prank(watch);
        hook.flagFromWatchtower(searcher, 0, block.number + 10);
        vm.prank(pmAddr);
        (,, uint24 post) = hook.beforeSwap(searcher, poolKey, params, "");
        assertTrue(post == 0, "flagged address loses the discount");

        // Once the flag expires, the discount returns.
        vm.roll(block.number + 11);
        vm.prank(pmAddr);
        (,, uint24 postExpiry) = hook.beforeSwap(searcher, poolKey, params, "");
        assertTrue(postExpiry != 0, "discount returns after the flag expires");
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

    // -------------------------------------------------------------------------
    // Role management — zero-address reverts
    // -------------------------------------------------------------------------

    function test_setWatchtower_zeroAddress_reverts() public {
        vm.expectRevert("Vadium: zero watchtower");
        hook.setWatchtower(address(0));
    }

    function test_setKeeper_zeroAddress_reverts() public {
        vm.expectRevert("Vadium: zero keeper");
        hook.setKeeper(address(0));
    }

    // -------------------------------------------------------------------------
    // Bond lifecycle — boundary and error selector tests
    // -------------------------------------------------------------------------

    function test_bond_exactMinBoundary_succeeds() public {
        uint256 minBond = hook.DEFAULT_MIN_BOND();
        vm.prank(searcher);
        hook.bond(minBond);
        assertEq(hook.bondedBalance(searcher), minBond);
    }

    function test_bond_revertsWithBondTooSmall_selector() public {
        vm.prank(searcher);
        vm.expectRevert(abi.encodeWithSelector(VadiumHook.BondTooSmall.selector, 99e6, 100e6));
        hook.bond(99e6);
    }

    function test_bond_revertsWithBanned_selector() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // First offense → repeat → ban.
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);
        vm.roll(1001);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        uint256 expectedBannedUntil = 1001 + hook.REPEAT_OFFENSE_BAN_BLOCKS();
        (,, uint256 bannedUntil,) = hook.bonds(searcher);
        assertEq(bannedUntil, expectedBannedUntil, "ban duration is correct");

        vm.prank(searcher);
        vm.expectRevert(abi.encodeWithSelector(VadiumHook.Banned.selector, bannedUntil));
        hook.bond(BOND_AMOUNT);
    }

    function test_withdrawBond_revertsWithBondNotMatured_selector() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);

        // Bond at block.number (currently 1), maturity = depositBlock + MIN_DURATION = 1 + 100 = 101.
        vm.roll(50);
        uint256 maturity = 1 + hook.DEFAULT_MIN_BOND_DURATION_BLOCKS();
        vm.expectRevert(
            abi.encodeWithSelector(VadiumHook.BondNotMatured.selector, block.number, maturity)
        );
        hook.withdrawBond();
    }

    function test_withdrawBond_revertsWhenBanned() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // First offense → repeat → ban.
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);
        vm.roll(1001);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        vm.prank(searcher);
        vm.expectRevert();
        hook.withdrawBond();
    }

    function test_withdrawBond_noBondAfterRepeatSlash() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        // First offense → repeat → full slash.
        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);
        vm.roll(1001);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        assertEq(hook.bondedBalance(searcher), 0, "bond zeroed after repeat slash");

        vm.prank(searcher);
        vm.expectRevert(VadiumHook.NoBond.selector);
        hook.withdrawBond();
    }

    // -------------------------------------------------------------------------
    // flagFromWatchtower — additional edge cases
    // -------------------------------------------------------------------------

    function test_flagFromWatchtower_zeroAmountOnLiveBond() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        address watch = makeAddr("watch");
        hook.setWatchtower(watch);

        vm.prank(watch);
        hook.flagFromWatchtower(searcher, 0, block.number + 10);

        // No slash occurred, bond intact; flag recorded; strike NOT counted
        // because toSlash == 0 skips the entire slash/escalation block.
        assertEq(hook.bondedBalance(searcher), BOND_AMOUNT);
        assertEq(hook.insuranceReserve(), 0);
        assertEq(hook.flaggedUntil(searcher), block.number + 10);
        (,,, uint256 strikes) = hook.bonds(searcher);
        assertEq(strikes, 0, "zero-slash flag does not count a strike");
    }

    function test_flagFromWatchtower_expiredBan_reverts() public {
        address watch = makeAddr("watch");
        hook.setWatchtower(watch);

        vm.prank(watch);
        vm.expectRevert("Vadium: flag already expired");
        hook.flagFromWatchtower(searcher, 0, block.number);
    }

    function test_flagFromWatchtower_emitsFlaggedEvent() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        address watch = makeAddr("watch");
        hook.setWatchtower(watch);

        vm.expectEmit(true, false, false, true, address(hook));
        emit VadiumHook.Flagged(searcher, BOND_AMOUNT / 2, block.number + 10);

        vm.prank(watch);
        hook.flagFromWatchtower(searcher, BOND_AMOUNT / 2, block.number + 10);
    }

    function test_flagFromWatchtower_zeroSearcher_reverts() public {
        address watch = makeAddr("watch");
        hook.setWatchtower(watch);

        vm.prank(watch);
        vm.expectRevert("Vadium: zero searcher");
        hook.flagFromWatchtower(address(0), 0, block.number + 10);
    }

    // -------------------------------------------------------------------------
    // drainFlagged — multi-element and cross-function
    // -------------------------------------------------------------------------

    function test_drainFlagged_multiSearchers_allActive_succeeds() public {
        // Build reserve from two searchers' slashes.
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
        hook.recordSwap(searcher, false);
        hook.recordSwap(searcher2, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher2, false);

        address watch = makeAddr("watch");
        hook.setWatchtower(watch);
        vm.prank(watch);
        hook.flagFromWatchtower(searcher, 0, block.number + 10);
        vm.prank(watch);
        hook.flagFromWatchtower(searcher2, 0, block.number + 10);

        address[] memory flagged = new address[](2);
        flagged[0] = searcher;
        flagged[1] = searcher2;

        vm.prank(hook.keeper());
        uint256 drained = hook.drainFlagged(flagged);
        assertEq(drained, BOND_AMOUNT, "drained both slashes");
        assertEq(hook.insuranceReserve(), 0);
    }

    function test_drainFlagged_multiSearchers_oneExpired_reverts() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        address watch = makeAddr("watch");
        hook.setWatchtower(watch);

        // Flag searcher with a short window, searcher2 with a long one.
        vm.prank(watch);
        hook.flagFromWatchtower(searcher, 0, block.number + 3);
        vm.prank(watch);
        hook.flagFromWatchtower(searcher2, 0, block.number + 100);

        // Expire searcher's flag.
        vm.roll(block.number + 5);

        address[] memory flagged = new address[](2);
        flagged[0] = searcher;
        flagged[1] = searcher2;

        vm.prank(hook.keeper());
        vm.expectRevert();
        hook.drainFlagged(flagged);
    }

    // -------------------------------------------------------------------------
    // claimCoverage — edge cases
    // -------------------------------------------------------------------------

    function test_claimCoverage_zeroAmount_reverts() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        vm.expectRevert("Vadium: zero payout");
        hook.claimCoverage(0);
    }

    function test_claimCoverage_partialDrain() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 2);

        // Claim half.
        hook.claimCoverage(BOND_AMOUNT / 4);
        assertEq(hook.insuranceReserve(), BOND_AMOUNT / 4);
        assertEq(hook.totalWithdrawn(), BOND_AMOUNT / 4);

        // Claim the rest.
        hook.claimCoverage(BOND_AMOUNT / 4);
        assertEq(hook.insuranceReserve(), 0);
        assertEq(hook.totalWithdrawn(), BOND_AMOUNT / 2);
    }

    // -------------------------------------------------------------------------
    // remainingCoverage view
    // -------------------------------------------------------------------------

    function test_remainingCoverage_matchesReserve() public {
        assertEq(hook.remainingCoverage(), hook.insuranceReserve());

        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.stopPrank();

        vm.roll(1000);
        hook.recordSwap(searcher, true);
        hook.recordSwap(victim, false);
        hook.recordSwap(searcher, false);

        assertEq(hook.remainingCoverage(), hook.insuranceReserve());
        assertEq(hook.remainingCoverage(), BOND_AMOUNT / 2);
    }

    // -------------------------------------------------------------------------
    // Event emission tests
    // -------------------------------------------------------------------------

    function test_bond_emitsBondedEvent() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit VadiumHook.Bonded(searcher, BOND_AMOUNT, block.number);

        vm.prank(searcher);
        hook.bond(BOND_AMOUNT);
    }

    function test_withdrawBond_emitsEvent() public {
        vm.startPrank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.roll(block.number + 100);

        vm.expectEmit(true, false, false, false, address(hook));
        emit VadiumHook.BondWithdrawn(searcher, BOND_AMOUNT);
        hook.withdrawBond();
    }

    function test_setWatchtower_emitsEvent() public {
        address watch = makeAddr("watch");
        vm.expectEmit(true, false, false, false, address(hook));
        emit VadiumHook.WatchtowerSet(watch);
        hook.setWatchtower(watch);
    }

    function test_setKeeper_emitsEvent() public {
        address kee = makeAddr("kee");
        vm.expectEmit(true, false, false, false, address(hook));
        emit VadiumHook.KeeperSet(kee);
        hook.setKeeper(kee);
    }

    // -------------------------------------------------------------------------
    // Access control — onlyPoolManager on callbacks
    // -------------------------------------------------------------------------

    function test_beforeSwap_onlyPoolManager_reverts() public {
        vm.prank(searcher);
        vm.expectRevert();
        hook.beforeSwap(
            searcher,
            poolKey,
            IPoolManager.SwapParams({ amountSpecified: 0, zeroForOne: true, sqrtPriceLimitX96: 0 }),
            ""
        );
    }

    function test_afterSwap_onlyPoolManager_reverts() public {
        vm.prank(searcher);
        vm.expectRevert();
        hook.afterSwap(
            searcher,
            poolKey,
            IPoolManager.SwapParams({ amountSpecified: 0, zeroForOne: true, sqrtPriceLimitX96: 0 }),
            BalanceDelta.wrap(0),
            ""
        );
    }

    // -------------------------------------------------------------------------
    // initializeOwner — multiple AlreadySet paths
    // -------------------------------------------------------------------------

    function test_initializeOwner_revertsWhenWatchtowerAlreadySet() public {
        // Deploy a fresh hook with no constructor (use etch to skip owner setting).
        address freshImpl = makeAddr("freshImpl");
        vm.etch(freshImpl, address(hook).code);

        // Can't easily simulate the uninitialized-owner path on the same hook
        // because the constructor already set owner. This test confirms the
        // AlreadySet revert fires when owner is set.
        vm.expectRevert(VadiumHook.AlreadySet.selector);
        hook.initializeOwner(makeAddr("newOwner"));
    }

    // -------------------------------------------------------------------------
    // onWatchtowerFlag — zero banUntil when already flagged
    // -------------------------------------------------------------------------

    function test_onWatchtowerFlag_zeroBanWhenAlreadyFlagged_isNoop() public {
        hook.setWatchtower(address(this));

        _watchtowerFlag(address(this), searcher, block.number + 10);
        uint256 first = hook.flaggedUntil(searcher);

        // banUntil=0 becomes DEFAULT_MIN_BOND_DURATION_BLOCKS, but flaggedUntil is
        // already >= block.number, so it is a no-op.
        _watchtowerFlag(address(this), searcher, 0);
        assertEq(hook.flaggedUntil(searcher), first);
    }
}
