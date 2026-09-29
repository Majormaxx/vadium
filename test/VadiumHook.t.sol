// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";
import { BeforeSwapDelta } from "v4-core/src/types/BeforeSwapDelta.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { ImmutableState } from "v4-periphery/src/base/ImmutableState.sol";

import { IBondedFlow } from "../src/interfaces/IBondedFlow.sol";
import { IReactiveFlagReceiver } from "../src/interfaces/IReactiveFlagReceiver.sol";
import { IBlockPriceClamp } from "../src/interfaces/IBlockPriceClamp.sol";
import { InsurancePolicy } from "../src/libraries/InsurancePolicy.sol";
import { BondParamsLib } from "../src/libraries/BondParamsLib.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { ReentrantERC20 } from "./mocks/ReentrantERC20.sol";
import { FeeOnTransferERC20 } from "./mocks/FeeOnTransferERC20.sol";
import { TestVadiumHook } from "./mocks/TestVadiumHook.sol";

/// @title VadiumHookTest
/// @notice Unit tests for the hook's bond lifecycle, registry, roles, detector, penalties,
///         refunds, payouts, and guards. Detection is driven through the harness's
///         `recordSwap`; the real-pool paths live in Integration and Economics.
contract VadiumHookTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager internal pm;
    MockERC20 internal token0;
    MockERC20 internal token1;
    TestVadiumHook internal hook;

    PoolKey internal poolKey;
    PoolId internal poolId;

    address internal searcher = makeAddr("searcher");
    address internal searcher2 = makeAddr("searcher2");
    address internal victim = makeAddr("victim");
    address internal watch = makeAddr("watchtower");
    address internal kee = makeAddr("keeper");
    address internal rvm = makeAddr("rvm");

    uint24 constant POOL_FEE = 3_000;
    int24 constant TICK_SPACING = 10;
    address constant CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;
    uint160 constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    address constant HOOK_ADDR = address(uint160(0x20C4));
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    uint256 constant BOND = 100e6;
    uint256 constant MIN_DURATION = 100;
    uint256 constant EXT = 7_200;
    uint256 constant BAN = 216_000;
    uint256 constant CLAIM_WINDOW = 1_000;

    function _params() internal pure returns (IBondedFlow.BondParams memory p) {
        p.minBond = BOND;
        p.minBondDurationBlocks = MIN_DURATION;
        p.firstSlashBps = 5_000;
        p.firstOffenseLockExtensionBlocks = EXT;
        p.repeatOffenseBanBlocks = BAN;
        p.victimRefundBps = 5_000;
        p.refundClaimWindowBlocks = CLAIM_WINDOW;
    }

    function _cfg() internal pure returns (IBondedFlow.PoolConfig memory c) {
        c.clampEnabled = true;
        c.exemptFirstSwapOnly = true;
        c.requireVictimLoss = true;
    }

    function _deployHook(address at, IERC20 bondToken) internal returns (TestVadiumHook h) {
        deployCodeTo(
            "TestVadiumHook.sol:TestVadiumHook",
            abi.encode(IPoolManager(pm), bondToken, address(this), CALLBACK_PROXY, _params()),
            at
        );
        h = TestVadiumHook(payable(at));
    }

    function setUp() public {
        vm.roll(1_000);
        pm = new PoolManager(address(this));

        MockERC20 a = new MockERC20("Wrapped ETH", "WETH", 18);
        MockERC20 b = new MockERC20("USD Coin", "USDC", 6);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        hook = _deployHook(HOOK_ADDR, IERC20(address(token1)));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK_ADDR)
        });
        poolId = poolKey.toId();
        hook.registerPool(poolKey, _cfg(), address(this));
        pm.initialize(poolKey, SQRT_1_1);

        token1.mint(searcher, 10_000e6);
        token1.mint(searcher2, 10_000e6);
        vm.prank(searcher);
        token1.approve(HOOK_ADDR, type(uint256).max);
        vm.prank(searcher2);
        token1.approve(HOOK_ADDR, type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _bond(address who) internal {
        vm.prank(who);
        hook.bond(BOND);
    }

    /// @dev searcher leg 1, victim (hurt), searcher leg 2.
    function _sandwich(address s, uint256 victimLoss) internal returns (uint256 slashed) {
        hook.recordSwap(poolId, s, true, s, 0);
        hook.recordSwap(poolId, victim, true, victim, victimLoss);
        slashed = hook.recordSwap(poolId, s, false, s, 0);
    }

    // -------------------------------------------------------------------------
    // Constructor and permissions
    // -------------------------------------------------------------------------

    function test_constructor_setsImmutablesAndParams() public view {
        assertEq(address(hook.poolManager()), address(pm));
        assertEq(address(hook.bondToken()), address(token1));
        assertEq(hook.owner(), address(this));
        assertEq(hook.callbackProxy(), CALLBACK_PROXY);
        IBondedFlow.BondParams memory p = hook.bondParams();
        assertEq(p.minBond, BOND);
        assertEq(p.firstOffenseLockExtensionBlocks, EXT);
        assertEq(p.repeatOffenseBanBlocks, BAN);
    }

    function test_constructor_revertsOnZeroBondToken() public {
        vm.expectRevert(IBondedFlow.ZeroAddress.selector);
        new TestVadiumHook(pm, IERC20(address(0)), address(this), CALLBACK_PROXY, _params());
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new TestVadiumHook(pm, IERC20(address(token1)), address(0), CALLBACK_PROXY, _params());
    }

    function test_constructor_revertsOnZeroCallbackProxy() public {
        vm.expectRevert(IBondedFlow.ZeroAddress.selector);
        new TestVadiumHook(pm, IERC20(address(token1)), address(this), address(0), _params());
    }

    function test_constructor_revertsOnInvalidParams() public {
        IBondedFlow.BondParams memory p = _params();
        p.firstSlashBps = 10_001;
        vm.expectRevert(IBondedFlow.InvalidParams.selector);
        new TestVadiumHook(pm, IERC20(address(token1)), address(this), CALLBACK_PROXY, p);
    }

    function test_constructor_revertsAtAddressWithoutFlags() public {
        vm.expectRevert();
        new TestVadiumHook(pm, IERC20(address(token1)), address(this), CALLBACK_PROXY, _params());
    }

    function test_getHookPermissions_flags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.beforeDonate);
        assertEq(uint160(HOOK_ADDR) & 0x3FFF, uint160(HOOK_FLAGS));
        assertEq(uint160(HOOK_FLAGS), 0x20C4);
    }

    // -------------------------------------------------------------------------
    // Pool registry
    // -------------------------------------------------------------------------

    function _secondKey(uint24 fee) internal view returns (PoolKey memory k) {
        k = poolKey;
        k.fee = fee;
        k.tickSpacing = 60;
    }

    function test_registerPool_onlyOwner() public {
        vm.prank(searcher);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, searcher)
        );
        hook.registerPool(_secondKey(500), _cfg(), address(this));
    }

    function test_registerPool_wrongHooks_reverts() public {
        PoolKey memory k = _secondKey(500);
        k.hooks = IHooks(address(0));
        vm.expectRevert(IBondedFlow.InvalidPoolKey.selector);
        hook.registerPool(k, _cfg(), address(this));
    }

    function test_registerPool_missingBondToken_reverts() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        PoolKey memory k = _secondKey(500);
        (address lo, address hi) = address(other) < address(token0)
            ? (address(other), address(token0))
            : (address(token0), address(other));
        k.currency0 = Currency.wrap(lo);
        k.currency1 = Currency.wrap(hi);
        vm.expectRevert(IBondedFlow.PoolMissingBondToken.selector);
        hook.registerPool(k, _cfg(), address(this));
    }

    function test_registerPool_twice_reverts() public {
        vm.expectRevert(IBondedFlow.PoolAlreadyRegistered.selector);
        hook.registerPool(poolKey, _cfg(), address(this));
    }

    function test_registerPool_staticFeeWithDiscount_reverts() public {
        IBondedFlow.PoolConfig memory c = _cfg();
        c.feeDiscountBps = 10;
        vm.expectRevert(IBondedFlow.InvalidConfig.selector);
        hook.registerPool(_secondKey(500), c, address(this));
        c.feeDiscountBps = 0;
        c.baseFee = 3_000;
        vm.expectRevert(IBondedFlow.InvalidConfig.selector);
        hook.registerPool(_secondKey(500), c, address(this));
    }

    function test_registerPool_dynamicFee_requiresValidBase() public {
        IBondedFlow.PoolConfig memory c = _cfg();
        c.baseFee = 1_000_001;
        vm.expectRevert(IBondedFlow.InvalidConfig.selector);
        hook.registerPool(_secondKey(LPFeeLibrary.DYNAMIC_FEE_FLAG), c, address(this));
    }

    function test_registerPool_dynamicFee_discountMustBeBelowBase() public {
        IBondedFlow.PoolConfig memory c = _cfg();
        c.baseFee = 1_000;
        c.feeDiscountBps = 10; // 1000 units == base
        vm.expectRevert(IBondedFlow.InvalidConfig.selector);
        hook.registerPool(_secondKey(LPFeeLibrary.DYNAMIC_FEE_FLAG), c, address(this));
        c.feeDiscountBps = 9;
        hook.registerPool(_secondKey(LPFeeLibrary.DYNAMIC_FEE_FLAG), c, address(this));
    }

    function test_registerPool_emitsAndStores() public {
        PoolKey memory k = _secondKey(500);
        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit IBondedFlow.PoolRegistered(k.toId(), searcher, _cfg());
        hook.registerPool(k, _cfg(), searcher);
        assertTrue(hook.isPoolRegistered(k.toId()));
        assertEq(hook.poolOperator(k.toId()), searcher);
        assertEq(hook.poolKeyOf(k.toId()).fee, 500);
        assertEq(hook.unbondedFee(k.toId()), 500);
    }

    function test_initialize_unregisteredPool_reverts() public {
        vm.expectRevert();
        pm.initialize(_secondKey(500), SQRT_1_1);
    }

    function test_initialize_registeredPool_succeeds() public {
        PoolKey memory k = _secondKey(500);
        hook.registerPool(k, _cfg(), address(this));
        pm.initialize(k, SQRT_1_1);
    }

    function test_setPoolConfig_ownerOrOperator() public {
        IBondedFlow.PoolConfig memory c = _cfg();
        c.clampEnabled = false;
        hook.setPoolOperator(poolId, searcher);
        vm.prank(searcher);
        hook.setPoolConfig(poolId, c);
        assertFalse(hook.poolConfig(poolId).clampEnabled);

        c.clampEnabled = true;
        hook.setPoolConfig(poolId, c);
        assertTrue(hook.poolConfig(poolId).clampEnabled);
    }

    function test_setPoolConfig_unauthorized_reverts() public {
        vm.prank(victim);
        vm.expectRevert(IBondedFlow.Unauthorized.selector);
        hook.setPoolConfig(poolId, _cfg());
    }

    function test_setPoolConfig_unregistered_reverts() public {
        vm.expectRevert(IBondedFlow.PoolNotRegistered.selector);
        hook.setPoolConfig(_secondKey(500).toId(), _cfg());
    }

    function test_setPoolOperator_onlyOwnerAndRegistered() public {
        vm.prank(searcher);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, searcher)
        );
        hook.setPoolOperator(poolId, searcher);
        vm.expectRevert(IBondedFlow.PoolNotRegistered.selector);
        hook.setPoolOperator(_secondKey(500).toId(), searcher);
    }

    function test_poolKeyOf_unregistered_reverts() public {
        vm.expectRevert(IBondedFlow.PoolNotRegistered.selector);
        hook.poolKeyOf(_secondKey(500).toId());
    }

    function test_unbondedFee_dynamicPoolUsesBase() public {
        IBondedFlow.PoolConfig memory c = _cfg();
        c.baseFee = 2_500;
        PoolKey memory k = _secondKey(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        hook.registerPool(k, c, address(this));
        assertEq(hook.unbondedFee(k.toId()), 2_500);
    }

    // -------------------------------------------------------------------------
    // Parameters, roles, ownership, pause
    // -------------------------------------------------------------------------

    function test_setBondParams_onlyOwner() public {
        vm.prank(searcher);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, searcher)
        );
        hook.setBondParams(_params());
    }

    function test_setBondParams_rejectsEachBound() public {
        IBondedFlow.BondParams memory p;
        p = _params();
        p.minBond = 0;
        vm.expectRevert(IBondedFlow.InvalidParams.selector);
        hook.setBondParams(p);
        p = _params();
        p.minBondDurationBlocks = 0;
        vm.expectRevert(IBondedFlow.InvalidParams.selector);
        hook.setBondParams(p);
        p = _params();
        p.firstOffenseLockExtensionBlocks = BondParamsLib.MAX_WINDOW_BLOCKS + 1;
        vm.expectRevert(IBondedFlow.InvalidParams.selector);
        hook.setBondParams(p);
        p = _params();
        p.repeatOffenseBanBlocks = BondParamsLib.MAX_WINDOW_BLOCKS + 1;
        vm.expectRevert(IBondedFlow.InvalidParams.selector);
        hook.setBondParams(p);
        p = _params();
        p.victimRefundBps = 10_001;
        vm.expectRevert(IBondedFlow.InvalidParams.selector);
        hook.setBondParams(p);
        p = _params();
        p.refundClaimWindowBlocks = 0;
        vm.expectRevert(IBondedFlow.InvalidParams.selector);
        hook.setBondParams(p);
    }

    function test_setBondParams_appliesAndEmits() public {
        IBondedFlow.BondParams memory p = _params();
        p.minBond = 250e6;
        vm.expectEmit(false, false, false, true, HOOK_ADDR);
        emit IBondedFlow.BondParamsSet(p);
        hook.setBondParams(p);
        assertEq(hook.bondParams().minBond, 250e6);
        vm.prank(searcher);
        vm.expectRevert(abi.encodeWithSelector(IBondedFlow.BondTooSmall.selector, BOND, 250e6));
        hook.bond(BOND);
    }

    function test_unichainDefaults_areValid() public pure {
        assertTrue(BondParamsLib.isValid(BondParamsLib.unichainDefaults()));
    }

    function test_roles_onlyOwnerCanAssign() public {
        vm.startPrank(searcher);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, searcher)
        );
        hook.setWatchtower(watch);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, searcher)
        );
        hook.setKeeper(kee);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, searcher)
        );
        hook.setReactiveRvm(rvm);
        vm.stopPrank();
    }

    function test_roles_rotatableAndEmit() public {
        vm.expectEmit(true, false, false, false, HOOK_ADDR);
        emit IBondedFlow.WatchtowerSet(watch);
        hook.setWatchtower(watch);
        hook.setWatchtower(searcher);
        assertEq(hook.watchtower(), searcher);

        vm.expectEmit(true, false, false, false, HOOK_ADDR);
        emit IBondedFlow.KeeperSet(kee);
        hook.setKeeper(kee);
        hook.setKeeper(address(0));
        assertEq(hook.keeper(), address(0));

        vm.expectEmit(true, false, false, false, HOOK_ADDR);
        emit IReactiveFlagReceiver.ReactiveRvmSet(rvm);
        hook.setReactiveRvm(rvm);
        assertEq(hook.reactiveRvm(), rvm);
    }

    function test_roles_zeroDisablesEntrypoint() public {
        assertEq(hook.keeper(), address(0));
        address[] memory list = new address[](1);
        list[0] = searcher;
        vm.prank(address(0));
        vm.expectRevert(IBondedFlow.Unauthorized.selector);
        hook.drainFlagged(poolId, list, 1);
        vm.prank(address(0));
        vm.expectRevert(IBondedFlow.Unauthorized.selector);
        hook.flagFromWatchtower(poolId, searcher, 0, block.number + 1, bytes32("e"));
    }

    function test_ownership_twoStep() public {
        address next = makeAddr("next");
        hook.transferOwnership(next);
        assertEq(hook.owner(), address(this));
        assertEq(hook.pendingOwner(), next);
        vm.prank(next);
        hook.acceptOwnership();
        assertEq(hook.owner(), next);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        hook.setKeeper(kee);
    }

    function test_pause_onlyOwner() public {
        vm.prank(searcher);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, searcher)
        );
        hook.pause();
    }

    function test_pause_blocksBondAndClaimsButNeverWithdraw() public {
        _bond(searcher);
        hook.pause();
        vm.prank(searcher2);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.bond(BOND);
        vm.prank(victim);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.claimRefund();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.claimCoverage(poolId, 1);
        vm.expectRevert(IBlockPriceClamp.ClampPaused.selector);
        hook.flushWithheld(poolId);
        assertFalse(hook.isExempt(poolId, searcher), "pause strips exemption");

        vm.roll(block.number + MIN_DURATION);
        vm.prank(searcher);
        hook.withdrawBond();
        assertEq(hook.bondedBalance(searcher), 0);

        hook.unpause();
        vm.prank(searcher2);
        hook.bond(BOND);
        assertTrue(hook.isExempt(poolId, searcher2));
    }

    // -------------------------------------------------------------------------
    // Bond lifecycle
    // -------------------------------------------------------------------------

    function test_bond_successfulDeposit() public {
        vm.expectEmit(true, false, false, true, HOOK_ADDR);
        emit IBondedFlow.Bonded(searcher, BOND, block.number);
        _bond(searcher);
        assertEq(hook.bondedBalance(searcher), BOND);
        assertTrue(hook.isBonded(searcher));
        assertEq(hook.totalBonded(), BOND);
        assertEq(token1.balanceOf(HOOK_ADDR), BOND);
        (uint128 amount, uint48 dep,,,) = hook.bonds(searcher);
        assertEq(amount, BOND);
        assertEq(dep, block.number);
    }

    function test_bond_exactMinBoundary_succeeds() public {
        vm.prank(searcher);
        hook.bond(BOND);
    }

    function test_bond_revertsOnTooSmall() public {
        vm.prank(searcher);
        vm.expectRevert(abi.encodeWithSelector(IBondedFlow.BondTooSmall.selector, BOND - 1, BOND));
        hook.bond(BOND - 1);
    }

    function test_bond_revertsOnDoubleBond() public {
        _bond(searcher);
        vm.prank(searcher);
        vm.expectRevert(IBondedFlow.BondAlreadyActive.selector);
        hook.bond(BOND);
    }

    function test_bond_revertsOnTooLarge() public {
        vm.prank(searcher);
        vm.expectRevert(IBondedFlow.BondTooLarge.selector);
        hook.bond(uint256(type(uint128).max) + 1);
    }

    function test_bond_rejectsFeeOnTransferToken() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        // The bond token must be a pool currency; build a hook whose bond token is the
        // fee-on-transfer token to exercise the balance check.
        TestVadiumHook h = _deployHook(address(uint160(0x1_20C4)), IERC20(address(fot)));
        fot.mint(searcher, 1_000e6);
        vm.startPrank(searcher);
        fot.approve(address(h), type(uint256).max);
        vm.expectRevert(IBondedFlow.TransferAmountMismatch.selector);
        h.bond(BOND);
        vm.stopPrank();
    }

    function test_withdrawBond_revertsOnNotMatured() public {
        _bond(searcher);
        vm.roll(block.number + MIN_DURATION - 1);
        vm.prank(searcher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBondedFlow.BondNotMatured.selector, block.number, block.number + 1
            )
        );
        hook.withdrawBond();
    }

    function test_withdrawBond_succeedsAfterMaturity() public {
        _bond(searcher);
        vm.roll(block.number + MIN_DURATION);
        uint256 before = token1.balanceOf(searcher);
        vm.expectEmit(true, false, false, true, HOOK_ADDR);
        emit IBondedFlow.BondWithdrawn(searcher, BOND);
        vm.prank(searcher);
        hook.withdrawBond();
        assertEq(token1.balanceOf(searcher), before + BOND);
        assertEq(hook.bondedBalance(searcher), 0);
        assertEq(hook.totalBonded(), 0);
    }

    function test_withdrawBond_revertsOnNoBond() public {
        vm.prank(searcher);
        vm.expectRevert(IBondedFlow.NoBond.selector);
        hook.withdrawBond();
    }

    function test_withdrawBond_revertsWhenBanned() public {
        _bond(searcher);
        _sandwich(searcher, 1);
        vm.roll(block.number + 1);
        _sandwich(searcher, 1);
        assertTrue(hook.isBanned(searcher));
        vm.prank(searcher);
        vm.expectRevert();
        hook.withdrawBond();
    }

    function test_withdrawBond_struckBondWaitsForExtension() public {
        _bond(searcher);
        vm.roll(block.number + 50);
        _sandwich(searcher, 1);
        uint256 strikeBlock = block.number;
        vm.roll(strikeBlock + EXT - 1);
        vm.prank(searcher);
        vm.expectRevert();
        hook.withdrawBond();
        vm.roll(strikeBlock + EXT);
        vm.prank(searcher);
        hook.withdrawBond();
        assertEq(hook.bondedBalance(searcher), 0);
    }

    function test_strikePersistsAcrossRebond_repeatInsideWindow() public {
        _bond(searcher);
        _sandwich(searcher, 1);
        uint256 strikeBlock = block.number;
        (,,, uint32 strikes, uint48 last) = hook.bonds(searcher);
        assertEq(strikes, 1);
        assertEq(last, strikeBlock);

        // Wait out the lock, withdraw, rebond immediately, and sandwich again while the
        // escalation window is still open: that is a repeat, not a fresh first offense.
        vm.roll(strikeBlock + EXT);
        vm.prank(searcher);
        hook.withdrawBond();
        _bond(searcher);
        (,,, strikes,) = hook.bonds(searcher);
        assertEq(strikes, 1, "rebond keeps the strike");

        // Push the window by a fresh strike from the watchtower, then a same-address
        // sandwich inside the new window must ban.
        hook.setWatchtower(watch);
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher, 1, block.number + 10, bytes32("e"));
        vm.roll(block.number + 11);
        _sandwich(searcher, 1);
        assertTrue(hook.isBanned(searcher), "repeat inside window after rebond bans");
        assertEq(hook.bondedBalance(searcher), 0);
    }

    function test_strikePersistsAcrossRebond_outsideWindowIsFirstOffenseAgain() public {
        _bond(searcher);
        _sandwich(searcher, 1);
        uint256 strikeBlock = block.number;
        vm.roll(strikeBlock + EXT);
        vm.prank(searcher);
        hook.withdrawBond();
        _bond(searcher);
        _sandwich(searcher, 1);
        assertFalse(hook.isBanned(searcher));
        assertEq(hook.bondedBalance(searcher), BOND / 2);
        (,,, uint32 strikes,) = hook.bonds(searcher);
        assertEq(strikes, 2);
    }

    // -------------------------------------------------------------------------
    // Exemption
    // -------------------------------------------------------------------------

    function test_isExempt_falseWhenUnbonded() public view {
        assertFalse(hook.isExempt(poolId, searcher));
    }

    function test_isExempt_trueWhenBonded() public {
        _bond(searcher);
        assertTrue(hook.isExempt(poolId, searcher));
    }

    function test_isExempt_falseWhenFlagged() public {
        _bond(searcher);
        hook.setWatchtower(watch);
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher, 0, block.number + 5, bytes32("e"));
        assertFalse(hook.isExempt(poolId, searcher));
        assertTrue(hook.isBonded(searcher), "isBonded ignores flags");
        vm.roll(block.number + 5);
        assertTrue(hook.isExempt(poolId, searcher));
    }

    function test_isExempt_falseWhenBanned() public {
        _bond(searcher);
        _sandwich(searcher, 1);
        vm.roll(block.number + 1);
        _sandwich(searcher, 1);
        assertFalse(hook.isExempt(poolId, searcher));
        assertFalse(hook.isBonded(searcher));
    }

    function test_isExempt_firstSwapOnly_secondSwapInBlockNotExempt() public {
        _bond(searcher);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        assertFalse(hook.isExempt(poolId, searcher));
        vm.roll(block.number + 1);
        assertTrue(hook.isExempt(poolId, searcher));
    }

    function test_isExempt_firstSwapOnlyDisabled_everySwapExempt() public {
        IBondedFlow.PoolConfig memory c = _cfg();
        c.exemptFirstSwapOnly = false;
        hook.setPoolConfig(poolId, c);
        _bond(searcher);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        assertTrue(hook.isExempt(poolId, searcher));
    }

    function test_isExempt_isPerPool() public {
        PoolKey memory k = _secondKey(500);
        hook.registerPool(k, _cfg(), address(this));
        _bond(searcher);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        assertFalse(hook.isExempt(poolId, searcher));
        assertTrue(hook.isExempt(k.toId(), searcher), "first-swap rule is per pool");
    }

    // -------------------------------------------------------------------------
    // Detector via recordSwap
    // -------------------------------------------------------------------------

    function test_recordSwap_noDetection_onFirstSwapInBlock() public {
        _bond(searcher);
        assertEq(hook.recordSwap(poolId, searcher, true, searcher, 0), 0);
        assertEq(hook.bondedBalance(searcher), BOND);
    }

    function test_recordSwap_detectsTrueSandwich() public {
        _bond(searcher);
        uint256 slashed = _sandwich(searcher, 1);
        assertEq(slashed, BOND / 2);
        assertEq(hook.bondedBalance(searcher), BOND / 2);
    }

    function test_recordSwap_detectsReverseSandwich() public {
        _bond(searcher);
        hook.recordSwap(poolId, searcher, false, searcher, 0);
        hook.recordSwap(poolId, victim, false, victim, 1);
        assertEq(hook.recordSwap(poolId, searcher, true, searcher, 0), BOND / 2);
    }

    function test_recordSwap_noDetection_whenSameDirection() public {
        _bond(searcher);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        hook.recordSwap(poolId, victim, true, victim, 1);
        assertEq(hook.recordSwap(poolId, searcher, true, searcher, 0), 0);
    }

    function test_recordSwap_noDetection_whenNoInterveningSwapper() public {
        _bond(searcher);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        assertEq(hook.recordSwap(poolId, searcher, false, searcher, 0), 0);
    }

    function test_recordSwap_noDetection_whenAcrossBlocks() public {
        _bond(searcher);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        vm.roll(block.number + 1);
        hook.recordSwap(poolId, victim, true, victim, 1);
        assertEq(hook.recordSwap(poolId, searcher, false, searcher, 0), 0);
    }

    function test_recordSwap_noDetection_muleAddresses() public {
        _bond(searcher);
        _bond(searcher2);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        hook.recordSwap(poolId, victim, true, victim, 1);
        assertEq(hook.recordSwap(poolId, searcher2, false, searcher2, 0), 0);
        assertEq(hook.bondedBalance(searcher), BOND);
        assertEq(hook.bondedBalance(searcher2), BOND);
    }

    function test_recordSwap_noDetection_victimUnhurt_whenRequired() public {
        _bond(searcher);
        assertEq(_sandwich(searcher, 0), 0);
        assertEq(hook.bondedBalance(searcher), BOND);
    }

    function test_recordSwap_detects_victimUnhurt_whenNotRequired() public {
        IBondedFlow.PoolConfig memory c = _cfg();
        c.requireVictimLoss = false;
        hook.setPoolConfig(poolId, c);
        _bond(searcher);
        assertEq(_sandwich(searcher, 0), BOND / 2);
    }

    function test_recordSwap_unbonded_noPenaltyNoFlag() public {
        assertEq(_sandwich(searcher, 1), 0);
        assertEq(hook.flaggedUntil(searcher), 0);
        assertEq(hook.insuranceReserve(poolId), 0);
        (,,, uint32 strikes,) = hook.bonds(searcher);
        assertEq(strikes, 0);
    }

    function test_recordSwap_multipleSequentialSwapsInBlock_noFalsePositive() public {
        _bond(searcher);
        hook.recordSwap(poolId, victim, true, victim, 0);
        hook.recordSwap(poolId, victim, false, victim, 0);
        hook.recordSwap(poolId, victim, true, victim, 0);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        // The searcher's reversal follows its own leg with nothing in between.
        assertEq(hook.recordSwap(poolId, searcher, false, searcher, 0), 0);
    }

    function test_recordSwap_updatesBlockState() public {
        hook.recordSwap(poolId, victim, true, searcher2, 77);
        (uint48 blk, address last, address vk, uint96 loss) = hook.poolBlockState(poolId);
        assertEq(blk, block.number);
        assertEq(last, victim);
        assertEq(vk, searcher2);
        assertEq(loss, 77);
        (uint48 sb, bool dir) = hook.lastSwapOf(poolId, victim);
        assertEq(sb, block.number);
        assertTrue(dir);
    }

    function test_recordSwap_shortfallCappedAtUint96() public {
        hook.recordSwap(poolId, victim, true, victim, type(uint256).max);
        (,,, uint96 loss) = hook.poolBlockState(poolId);
        assertEq(loss, type(uint96).max);
    }

    function test_recordSwap_poolsAreIsolated() public {
        PoolKey memory k = _secondKey(500);
        hook.registerPool(k, _cfg(), address(this));
        PoolId other = k.toId();
        _bond(searcher);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        // The victim swaps on the other pool: it is not an intervening swap on pool A.
        hook.recordSwap(other, victim, true, victim, 1);
        assertEq(hook.recordSwap(poolId, searcher, false, searcher, 0), 0);
        assertEq(hook.insuranceReserve(other), 0);
    }

    // -------------------------------------------------------------------------
    // Collective slash (opt-in)
    // -------------------------------------------------------------------------

    function _mule(address a, address b, uint256 victimLoss) internal returns (uint256) {
        hook.recordSwap(poolId, a, true, a, 0);
        hook.recordSwap(poolId, victim, true, victim, victimLoss);
        return hook.recordSwap(poolId, b, false, b, 0);
    }

    function test_collectiveSlash_offByDefault_muleUntouched() public {
        _bond(searcher);
        _bond(searcher2);
        assertFalse(hook.collectiveSlashEnabled(poolId));
        assertEq(_mule(searcher, searcher2, 1), 0);
        assertEq(hook.bondedBalance(searcher2), BOND);
    }

    function test_collectiveSlash_setterAuthAndEvent() public {
        vm.prank(victim);
        vm.expectRevert(IBondedFlow.Unauthorized.selector);
        hook.setCollectiveSlash(poolId, true);
        vm.expectRevert(IBondedFlow.PoolNotRegistered.selector);
        hook.setCollectiveSlash(_secondKey(500).toId(), true);
        hook.setPoolOperator(poolId, searcher);
        vm.expectEmit(true, false, false, true, HOOK_ADDR);
        emit IBondedFlow.CollectiveSlashSet(poolId, true);
        vm.prank(searcher);
        hook.setCollectiveSlash(poolId, true);
        assertTrue(hook.collectiveSlashEnabled(poolId));
    }

    function test_collectiveSlash_penalizesClosingLeg() public {
        hook.setCollectiveSlash(poolId, true);
        _bond(searcher);
        _bond(searcher2);
        uint256 slashed = _mule(searcher, searcher2, 10e6);
        assertEq(slashed, BOND / 2, "closing bonded leg slashed");
        assertEq(hook.bondedBalance(searcher2), BOND / 2);
        assertEq(hook.bondedBalance(searcher), BOND, "opening leg untouched");
        assertEq(hook.claimableRefund(victim), 10e6, "victim refunded from the closer");
        assertTrue(hook.flaggedUntil(searcher2) > block.number);
    }

    function test_collectiveSlash_unbondedOpener_stillPenalizesBondedCloser() public {
        hook.setCollectiveSlash(poolId, true);
        _bond(searcher2);
        assertEq(_mule(searcher, searcher2, 1), BOND / 2);
    }

    function test_collectiveSlash_requiresVictimLoss_evenWhenConfigDoesNot() public {
        hook.setCollectiveSlash(poolId, true);
        IBondedFlow.PoolConfig memory c = _cfg();
        c.requireVictimLoss = false;
        hook.setPoolConfig(poolId, c);
        _bond(searcher);
        _bond(searcher2);
        assertEq(_mule(searcher, searcher2, 0), 0, "unhurt middle swap: no collective slash");
    }

    function test_collectiveSlash_sameDirectionOpener_noSlash() public {
        hook.setCollectiveSlash(poolId, true);
        _bond(searcher2);
        hook.recordSwap(poolId, searcher, false, searcher, 0);
        hook.recordSwap(poolId, victim, true, victim, 1);
        assertEq(hook.recordSwap(poolId, searcher2, false, searcher2, 0), 0);
    }

    function test_collectiveSlash_openerMustBeSameBlock() public {
        hook.setCollectiveSlash(poolId, true);
        _bond(searcher2);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        vm.roll(block.number + 1);
        hook.recordSwap(poolId, victim, true, victim, 1);
        assertEq(hook.recordSwap(poolId, searcher2, false, searcher2, 0), 0);
    }

    function test_collectiveSlash_unbondedCloser_noPenalty() public {
        hook.setCollectiveSlash(poolId, true);
        _bond(searcher);
        assertEq(_mule(searcher, searcher2, 1), 0);
        assertEq(hook.flaggedUntil(searcher2), 0);
    }

    function test_collectiveSlash_disablingClearsPrior() public {
        hook.setCollectiveSlash(poolId, true);
        _bond(searcher2);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        hook.recordSwap(poolId, victim, true, victim, 1);
        hook.setCollectiveSlash(poolId, false);
        assertEq(hook.recordSwap(poolId, searcher2, false, searcher2, 0), 0);
    }

    // -------------------------------------------------------------------------
    // Penalties, flags, reserve, refunds
    // -------------------------------------------------------------------------

    function test_firstOffense_takesHalfFlagsAndExtendsLock() public {
        _bond(searcher);
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        hook.recordSwap(poolId, victim, true, victim, 1);
        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit IBondedFlow.Sandwiched(
            poolId, searcher, BOND / 2, false, BOND / 2, block.number + 2 * EXT, 1
        );
        hook.recordSwap(poolId, searcher, false, searcher, 0);
        assertEq(hook.flaggedUntil(searcher), block.number + 2 * EXT);
        assertEq(hook.insuranceReserve(poolId), BOND / 2 - 1);
        assertEq(hook.claimableRefund(victim), 1);
        assertEq(hook.totalReserve(), BOND / 2 - 1);
        assertEq(hook.totalClaimable(), 1);
        assertEq(hook.totalBonded(), BOND / 2);
    }

    function test_repeatOffense_slashesAllAndBans() public {
        _bond(searcher);
        _sandwich(searcher, 1);
        vm.roll(block.number + 1);
        _sandwich(searcher, 1);
        assertEq(hook.bondedBalance(searcher), 0);
        assertTrue(hook.isBanned(searcher));
        assertEq(hook.flaggedUntil(searcher), block.number + BAN);
        (,, uint48 bannedUntil,,) = hook.bonds(searcher);
        assertEq(bannedUntil, block.number + BAN);
    }

    function test_banPreventsReBond_untilExpiry() public {
        _bond(searcher);
        _sandwich(searcher, 1);
        vm.roll(block.number + 1);
        _sandwich(searcher, 1);
        vm.prank(searcher);
        vm.expectRevert(abi.encodeWithSelector(IBondedFlow.Banned.selector, block.number + BAN));
        hook.bond(BOND);
        vm.roll(block.number + BAN);
        vm.prank(searcher);
        hook.bond(BOND);
    }

    function test_onPoolSlash_neverShortensLongerFlag() public {
        _bond(searcher);
        hook.setWatchtower(watch);
        uint256 far = block.number + 10 * EXT;
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher, 0, far, bytes32("e"));
        _sandwich(searcher, 1);
        assertEq(hook.flaggedUntil(searcher), far);
    }

    function test_refund_isMinOfShortfallAndCap() public {
        _bond(searcher);
        // shortfall below cap
        _sandwich(searcher, 10e6);
        assertEq(hook.claimableRefund(victim), 10e6);
        assertEq(hook.insuranceReserve(poolId), BOND / 2 - 10e6);
        // second bond, shortfall above cap (cap = 50% of 25e6 = 12.5e6)
        vm.roll(block.number + EXT + 1);
        _sandwich(searcher, 1_000e6);
        uint256 slashed2 = (BOND / 2) / 2;
        assertEq(hook.claimableRefund(victim), 10e6 + slashed2 / 2);
    }

    function test_refund_zeroBpsSendsAllToReserve() public {
        IBondedFlow.BondParams memory p = _params();
        p.victimRefundBps = 0;
        hook.setBondParams(p);
        _bond(searcher);
        _sandwich(searcher, 10e6);
        assertEq(hook.claimableRefund(victim), 0);
        assertEq(hook.insuranceReserve(poolId), BOND / 2);
    }

    function test_refund_creditedToAttributedKey() public {
        _bond(searcher);
        address principal = makeAddr("principal");
        hook.recordSwap(poolId, searcher, true, searcher, 0);
        hook.recordSwap(poolId, victim, true, principal, 5e6);
        vm.expectEmit(true, true, true, true, HOOK_ADDR);
        emit IBondedFlow.VictimRefundCredited(poolId, principal, searcher, 5e6);
        hook.recordSwap(poolId, searcher, false, searcher, 0);
        assertEq(hook.claimableRefund(principal), 5e6);
        assertEq(hook.claimableRefund(victim), 0);
    }

    function test_claimRefund_transfersAndEmits() public {
        _bond(searcher);
        _sandwich(searcher, 10e6);
        uint256 before = token1.balanceOf(victim);
        vm.expectEmit(true, false, false, true, HOOK_ADDR);
        emit IBondedFlow.RefundClaimed(victim, 10e6);
        vm.prank(victim);
        uint256 got = hook.claimRefund();
        assertEq(got, 10e6);
        assertEq(token1.balanceOf(victim), before + 10e6);
        assertEq(hook.claimableRefund(victim), 0);
        assertEq(hook.totalClaimable(), 0);
    }

    function test_claimRefund_nothing_reverts() public {
        vm.prank(victim);
        vm.expectRevert(IBondedFlow.NothingToClaim.selector);
        hook.claimRefund();
    }

    function test_sweepUnclaimed_windowOpen_reverts() public {
        _bond(searcher);
        _sandwich(searcher, 10e6);
        vm.roll(block.number + CLAIM_WINDOW);
        vm.expectRevert(IBondedFlow.RefundWindowOpen.selector);
        hook.sweepUnclaimed(victim, poolId);
    }

    function test_sweepUnclaimed_afterWindow_movesToReserve() public {
        _bond(searcher);
        _sandwich(searcher, 10e6);
        uint256 reserveBefore = hook.insuranceReserve(poolId);
        vm.roll(block.number + CLAIM_WINDOW + 1);
        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit IBondedFlow.UnclaimedSwept(victim, poolId, 10e6);
        hook.sweepUnclaimed(victim, poolId);
        assertEq(hook.claimableRefund(victim), 0);
        assertEq(hook.insuranceReserve(poolId), reserveBefore + 10e6);
        assertEq(hook.totalClaimable(), 0);
    }

    function test_sweepUnclaimed_nothingOrUnregistered_reverts() public {
        vm.expectRevert(IBondedFlow.NothingToClaim.selector);
        hook.sweepUnclaimed(victim, poolId);
        _bond(searcher);
        _sandwich(searcher, 10e6);
        vm.roll(block.number + CLAIM_WINDOW + 1);
        vm.expectRevert(IBondedFlow.PoolNotRegistered.selector);
        hook.sweepUnclaimed(victim, _secondKey(500).toId());
    }

    function test_repeatSlash_accumulatesReserveAcrossSearchers() public {
        _bond(searcher);
        _bond(searcher2);
        _sandwich(searcher, 1);
        _sandwich(searcher2, 1);
        assertEq(hook.insuranceReserve(poolId), BOND - 2);
        assertEq(hook.slashedPledged(poolId), BOND - 2);
        assertEq(hook.remainingCoverage(poolId), BOND - 2);
    }

    // -------------------------------------------------------------------------
    // Watchtower
    // -------------------------------------------------------------------------

    function test_flagFromWatchtower_onlyWatchtower() public {
        hook.setWatchtower(watch);
        vm.prank(searcher);
        vm.expectRevert(IBondedFlow.Unauthorized.selector);
        hook.flagFromWatchtower(poolId, searcher, 0, block.number + 1, bytes32("e"));
    }

    function test_flagFromWatchtower_slashesBondIntoReserve() public {
        hook.setWatchtower(watch);
        _bond(searcher);
        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit IBondedFlow.Flagged(searcher, poolId, 30e6, bytes32("e"), block.number + 50);
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher, 30e6, block.number + 50, bytes32("e"));
        assertEq(hook.bondedBalance(searcher), BOND - 30e6);
        assertEq(hook.insuranceReserve(poolId), 30e6);
        assertEq(hook.flaggedUntil(searcher), block.number + 50);
        assertEq(hook.flagEvidence(searcher), bytes32("e"));
        (,,, uint32 strikes,) = hook.bonds(searcher);
        assertEq(strikes, 1);
    }

    function test_flagFromWatchtower_capsSlashAtBond() public {
        hook.setWatchtower(watch);
        _bond(searcher);
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher, 1_000e6, block.number + 50, bytes32("e"));
        assertEq(hook.bondedBalance(searcher), 0);
        assertEq(hook.insuranceReserve(poolId), BOND);
    }

    function test_flagFromWatchtower_unbondedOrZeroAmount_flagOnly() public {
        hook.setWatchtower(watch);
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher, 5, block.number + 50, bytes32("e"));
        assertEq(hook.flaggedUntil(searcher), block.number + 50);
        (,,, uint32 strikes,) = hook.bonds(searcher);
        assertEq(strikes, 0, "no strike without a bond to slash");

        _bond(searcher2);
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher2, 0, block.number + 50, bytes32("e"));
        assertEq(hook.bondedBalance(searcher2), BOND);
        assertEq(hook.flaggedUntil(searcher2), block.number + 50);
    }

    function test_flagFromWatchtower_validation() public {
        hook.setWatchtower(watch);
        vm.startPrank(watch);
        vm.expectRevert(IBondedFlow.ZeroAddress.selector);
        hook.flagFromWatchtower(poolId, address(0), 0, block.number + 1, bytes32("e"));
        vm.expectRevert(IBondedFlow.MissingEvidence.selector);
        hook.flagFromWatchtower(poolId, searcher, 0, block.number + 1, bytes32(0));
        vm.expectRevert(IBondedFlow.FlagExpired.selector);
        hook.flagFromWatchtower(poolId, searcher, 0, block.number, bytes32("e"));
        vm.expectRevert(IBondedFlow.PoolNotRegistered.selector);
        hook.flagFromWatchtower(_secondKey(500).toId(), searcher, 0, block.number + 1, bytes32("e"));
        vm.stopPrank();
    }

    function test_flagFromWatchtower_extendsActiveFlagWithoutRevert() public {
        hook.setWatchtower(watch);
        vm.startPrank(watch);
        hook.flagFromWatchtower(poolId, searcher, 0, block.number + 50, bytes32("a"));
        hook.flagFromWatchtower(poolId, searcher, 0, block.number + 20, bytes32("b"));
        assertEq(hook.flaggedUntil(searcher), block.number + 50, "shorter flag does not shorten");
        assertEq(hook.flagEvidence(searcher), bytes32("b"), "latest evidence recorded");
        hook.flagFromWatchtower(poolId, searcher, 0, block.number + 90, bytes32("c"));
        assertEq(hook.flaggedUntil(searcher), block.number + 90);
        vm.stopPrank();
    }

    function test_flagFromWatchtower_escalatesLikeOnPool() public {
        hook.setWatchtower(watch);
        _bond(searcher);
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher, 10e6, block.number + 50, bytes32("a"));
        vm.roll(block.number + 1);
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher, 10e6, block.number + 50, bytes32("b"));
        assertTrue(hook.isBanned(searcher), "second watchtower slash inside the window bans");
        assertEq(hook.bondedBalance(searcher), BOND - 20e6, "watchtower slashes only its amount");
    }

    function test_watchtowerStrike_thenOnPoolSlash_isRepeat() public {
        hook.setWatchtower(watch);
        _bond(searcher);
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher, 10e6, block.number + 5, bytes32("a"));
        vm.roll(block.number + 6);
        _sandwich(searcher, 1);
        assertTrue(hook.isBanned(searcher));
        assertEq(hook.bondedBalance(searcher), 0);
    }

    // -------------------------------------------------------------------------
    // Reactive flag receiver
    // -------------------------------------------------------------------------

    function test_onWatchtowerFlag_onlyCallbackProxy() public {
        hook.setReactiveRvm(rvm);
        vm.prank(searcher);
        vm.expectRevert(IBondedFlow.Unauthorized.selector);
        hook.onWatchtowerFlag(rvm, searcher, block.number + 5);
    }

    function test_onWatchtowerFlag_requiresBoundAndMatchingRvm() public {
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(IBondedFlow.Unauthorized.selector);
        hook.onWatchtowerFlag(rvm, searcher, block.number + 5);
        hook.setReactiveRvm(rvm);
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(IBondedFlow.Unauthorized.selector);
        hook.onWatchtowerFlag(makeAddr("other"), searcher, block.number + 5);
    }

    function test_onWatchtowerFlag_setsFlagOnlyAndEmits() public {
        hook.setReactiveRvm(rvm);
        _bond(searcher);
        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit IBondedFlow.Flagged(searcher, PoolId.wrap(0), 0, bytes32(0), block.number + 5);
        vm.prank(CALLBACK_PROXY);
        hook.onWatchtowerFlag(rvm, searcher, block.number + 5);
        assertEq(hook.flaggedUntil(searcher), block.number + 5);
        assertEq(hook.bondedBalance(searcher), BOND, "no slash from a relayed flag");
        assertFalse(hook.isExempt(poolId, searcher));
    }

    function test_onWatchtowerFlag_validation() public {
        hook.setReactiveRvm(rvm);
        vm.startPrank(CALLBACK_PROXY);
        vm.expectRevert(IBondedFlow.ZeroAddress.selector);
        hook.onWatchtowerFlag(rvm, address(0), block.number + 5);
        vm.expectRevert(IBondedFlow.FlagExpired.selector);
        hook.onWatchtowerFlag(rvm, searcher, block.number);
        vm.stopPrank();
    }

    function test_onWatchtowerFlag_zeroDefaultsToMinDuration() public {
        hook.setReactiveRvm(rvm);
        vm.prank(CALLBACK_PROXY);
        hook.onWatchtowerFlag(rvm, searcher, 0);
        assertEq(hook.flaggedUntil(searcher), block.number + MIN_DURATION);
    }

    function test_onWatchtowerFlag_extendOnly() public {
        hook.setReactiveRvm(rvm);
        vm.startPrank(CALLBACK_PROXY);
        hook.onWatchtowerFlag(rvm, searcher, block.number + 50);
        hook.onWatchtowerFlag(rvm, searcher, block.number + 20);
        assertEq(hook.flaggedUntil(searcher), block.number + 50);
        hook.onWatchtowerFlag(rvm, searcher, block.number + 80);
        assertEq(hook.flaggedUntil(searcher), block.number + 80);
        vm.stopPrank();
    }

    function test_receiveAndPay_fundReactiveFees() public {
        (bool ok,) = HOOK_ADDR.call{ value: 1 ether }("");
        assertTrue(ok);
        assertEq(HOOK_ADDR.balance, 1 ether);
        vm.prank(searcher);
        vm.expectRevert(IBondedFlow.Unauthorized.selector);
        hook.pay(0.1 ether);
        uint256 before = CALLBACK_PROXY.balance;
        vm.prank(CALLBACK_PROXY);
        hook.pay(0.1 ether);
        assertEq(CALLBACK_PROXY.balance, before + 0.1 ether);
    }

    function test_rescueNative_onlyOwner() public {
        (bool ok,) = HOOK_ADDR.call{ value: 1 ether }("");
        assertTrue(ok);
        vm.prank(searcher);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, searcher)
        );
        hook.rescueNative(payable(searcher), 1 ether);
        vm.expectRevert(IBondedFlow.ZeroAddress.selector);
        hook.rescueNative(payable(address(0)), 1 ether);
        address payable to = payable(makeAddr("to"));
        hook.rescueNative(to, 1 ether);
        assertEq(to.balance, 1 ether);
    }

    // -------------------------------------------------------------------------
    // Drain and claim coverage
    // -------------------------------------------------------------------------

    function _flaggedList() internal view returns (address[] memory l) {
        l = new address[](1);
        l[0] = searcher;
    }

    function test_drainFlagged_onlyKeeper() public {
        hook.setKeeper(kee);
        vm.prank(searcher);
        vm.expectRevert(IBondedFlow.Unauthorized.selector);
        hook.drainFlagged(poolId, _flaggedList(), 1);
    }

    function test_drainFlagged_requiresActiveFlag() public {
        hook.setKeeper(kee);
        _bond(searcher);
        _sandwich(searcher, 1);
        vm.prank(kee);
        hook.drainFlagged(poolId, _flaggedList(), 1);
        vm.roll(block.number + 2 * EXT);
        vm.prank(kee);
        vm.expectRevert(IBondedFlow.NotFlagged.selector);
        hook.drainFlagged(poolId, _flaggedList(), 1);
    }

    function test_drainFlagged_emptyListOrZeroCap_reverts() public {
        hook.setKeeper(kee);
        _bond(searcher);
        _sandwich(searcher, 1);
        vm.startPrank(kee);
        vm.expectRevert(IBondedFlow.NotFlagged.selector);
        hook.drainFlagged(poolId, new address[](0), 1);
        vm.expectRevert(IBondedFlow.ZeroAmount.selector);
        hook.drainFlagged(poolId, _flaggedList(), 0);
        vm.stopPrank();
    }

    function test_drainFlagged_capLimitsAndNeverExceedsReserve() public {
        hook.setKeeper(kee);
        _bond(searcher);
        _sandwich(searcher, 1);
        uint256 reserve = hook.insuranceReserve(poolId);
        vm.prank(kee);
        uint256 got = hook.drainFlagged(poolId, _flaggedList(), 10e6);
        assertEq(got, 10e6);
        assertEq(hook.insuranceReserve(poolId), reserve - 10e6);
        assertEq(hook.lastDonationAmount1(), 10e6);
        assertEq(hook.lastDonationAmount0(), 0);
        vm.prank(kee);
        got = hook.drainFlagged(poolId, _flaggedList(), type(uint256).max);
        assertEq(got, reserve - 10e6);
        assertEq(hook.insuranceReserve(poolId), 0);
        assertEq(hook.totalWithdrawn(poolId), reserve);
        assertEq(hook.totalReserve(), 0);
    }

    function test_drainFlagged_emptyReserve_reverts() public {
        hook.setKeeper(kee);
        hook.setWatchtower(watch);
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher, 0, block.number + 5, bytes32("e"));
        vm.prank(kee);
        vm.expectRevert(InsurancePolicy.ZeroPayout.selector);
        hook.drainFlagged(poolId, _flaggedList(), 1);
    }

    function test_drainFlagged_multiSearchers_allActive_oneExpired() public {
        hook.setKeeper(kee);
        hook.setWatchtower(watch);
        _bond(searcher);
        _sandwich(searcher, 1);
        vm.prank(watch);
        hook.flagFromWatchtower(poolId, searcher2, 0, block.number + 5, bytes32("e"));
        address[] memory l = new address[](2);
        l[0] = searcher;
        l[1] = searcher2;
        vm.prank(kee);
        hook.drainFlagged(poolId, l, 1);
        vm.roll(block.number + 5);
        vm.prank(kee);
        vm.expectRevert(IBondedFlow.NotFlagged.selector);
        hook.drainFlagged(poolId, l, 1);
    }

    function test_drainFlagged_unregisteredPool_reverts() public {
        hook.setKeeper(kee);
        _bond(searcher);
        _sandwich(searcher, 1);
        vm.prank(kee);
        vm.expectRevert(IBondedFlow.PoolNotRegistered.selector);
        hook.drainFlagged(_secondKey(500).toId(), _flaggedList(), 1);
    }

    function test_drainFlagged_emitsCoverageClaimed() public {
        hook.setKeeper(kee);
        _bond(searcher);
        _sandwich(searcher, 1);
        uint256 reserve = hook.insuranceReserve(poolId);
        vm.expectEmit(true, false, false, true, HOOK_ADDR);
        emit IBondedFlow.CoverageClaimed(poolId, 5e6, reserve - 5e6);
        vm.prank(kee);
        hook.drainFlagged(poolId, _flaggedList(), 5e6);
    }

    function test_claimCoverage_onlyOwner() public {
        vm.prank(searcher);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, searcher)
        );
        hook.claimCoverage(poolId, 1);
    }

    function test_claimCoverage_drainsPartialAndFull() public {
        _bond(searcher);
        _sandwich(searcher, 1);
        uint256 reserve = hook.insuranceReserve(poolId);
        assertEq(hook.claimCoverage(poolId, 7e6), 7e6);
        assertEq(hook.insuranceReserve(poolId), reserve - 7e6);
        assertEq(hook.claimCoverage(poolId, reserve - 7e6), reserve - 7e6);
        assertEq(hook.insuranceReserve(poolId), 0);
        assertEq(hook.lastDonationAmount1(), reserve);
    }

    function test_claimCoverage_zeroOrExceeds_reverts() public {
        _bond(searcher);
        _sandwich(searcher, 1);
        uint256 reserve = hook.insuranceReserve(poolId);
        vm.expectRevert(InsurancePolicy.ZeroPayout.selector);
        hook.claimCoverage(poolId, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsurancePolicy.PayoutExceedsReserve.selector, reserve + 1, reserve
            )
        );
        hook.claimCoverage(poolId, reserve + 1);
        vm.expectRevert(IBondedFlow.PoolNotRegistered.selector);
        hook.claimCoverage(_secondKey(500).toId(), 1);
    }

    // -------------------------------------------------------------------------
    // Sweeps
    // -------------------------------------------------------------------------

    function test_sweepToken_bondTokenLimitedToFree() public {
        _bond(searcher);
        token1.mint(HOOK_ADDR, 5e6); // stray
        assertEq(hook.freeBalance(), 5e6);
        vm.expectRevert(abi.encodeWithSelector(IBondedFlow.SweepExceedsFree.selector, 6e6, 5e6));
        hook.sweepToken(IERC20(address(token1)), address(this), 6e6);
        hook.sweepToken(IERC20(address(token1)), address(this), 5e6);
        assertEq(hook.freeBalance(), 0);
        assertEq(token1.balanceOf(HOOK_ADDR), BOND);
    }

    function test_sweepToken_otherTokenAndGuards() public {
        token0.mint(HOOK_ADDR, 1e18);
        vm.prank(searcher);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, searcher)
        );
        hook.sweepToken(IERC20(address(token0)), searcher, 1e18);
        vm.expectRevert(IBondedFlow.ZeroAddress.selector);
        hook.sweepToken(IERC20(address(token0)), address(0), 1e18);
        vm.expectEmit(true, true, false, true, HOOK_ADDR);
        emit IBondedFlow.TokenSwept(address(token0), address(this), 1e18);
        hook.sweepToken(IERC20(address(token0)), address(this), 1e18);
    }

    // -------------------------------------------------------------------------
    // Guards and reentrancy
    // -------------------------------------------------------------------------

    function test_hookEntrypoints_onlyPoolManager() public {
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0
        });
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(searcher, poolKey, sp, "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(searcher, poolKey, sp, BalanceDeltaLibrary.ZERO_DELTA, "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(searcher, poolKey, SQRT_1_1);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_beforeSwap_unregisteredPool_reverts() public {
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0
        });
        vm.prank(address(pm));
        vm.expectRevert(IBondedFlow.PoolNotRegistered.selector);
        hook.beforeSwap(searcher, _secondKey(500), sp, "");
    }

    function test_reentrancy_bondTokenCannotReenter() public {
        ReentrantERC20 re = new ReentrantERC20();
        TestVadiumHook h = _deployHook(address(uint160(0x2_20C4)), IERC20(address(re)));
        re.mint(searcher, 1_000e6);
        vm.prank(searcher);
        re.approve(address(h), type(uint256).max);

        // Re-enter bond() from inside the bond transfer.
        re.arm(address(h), abi.encodeCall(IBondedFlow.bond, (BOND)));
        vm.prank(searcher);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        h.bond(BOND);

        // Bond normally, then re-enter withdrawBond() from inside the withdrawal transfer.
        re.disarm();
        vm.prank(searcher);
        h.bond(BOND);
        vm.roll(block.number + MIN_DURATION);
        re.arm(address(h), abi.encodeCall(IBondedFlow.withdrawBond, ()));
        vm.prank(searcher);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        h.withdrawBond();
    }

    // -------------------------------------------------------------------------
    // Unused IHooks callbacks return their selectors
    // -------------------------------------------------------------------------

    function test_unusedHookCallbacks_returnSelectors() public view {
        IPoolManager.ModifyLiquidityParams memory lp;
        assertEq(
            hook.afterInitialize(address(0), poolKey, SQRT_1_1, 0), IHooks.afterInitialize.selector
        );
        assertEq(
            hook.beforeAddLiquidity(address(0), poolKey, lp, ""), IHooks.beforeAddLiquidity.selector
        );
        (bytes4 s1, BalanceDelta d1) = hook.afterAddLiquidity(
            address(0),
            poolKey,
            lp,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );
        assertEq(s1, IHooks.afterAddLiquidity.selector);
        assertEq(BalanceDelta.unwrap(d1), 0);
        assertEq(
            hook.beforeRemoveLiquidity(address(0), poolKey, lp, ""),
            IHooks.beforeRemoveLiquidity.selector
        );
        (bytes4 s2, BalanceDelta d2) = hook.afterRemoveLiquidity(
            address(0),
            poolKey,
            lp,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );
        assertEq(s2, IHooks.afterRemoveLiquidity.selector);
        assertEq(BalanceDelta.unwrap(d2), 0);
        assertEq(hook.beforeDonate(address(0), poolKey, 0, 0, ""), IHooks.beforeDonate.selector);
        assertEq(hook.afterDonate(address(0), poolKey, 0, 0, ""), IHooks.afterDonate.selector);
    }

    function test_unlockCallback_unknownKind_reverts() public {
        vm.prank(address(pm));
        vm.expectRevert(IBondedFlow.UnknownUnlockKind.selector);
        hook.unlockCallback(abi.encode(uint8(9), bytes("")));
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function test_views_defaults() public view {
        assertFalse(hook.isBanned(searcher));
        assertFalse(hook.isBonded(searcher));
        assertEq(hook.bondedBalance(searcher), 0);
        assertEq(hook.freeBalance(), 0);
        assertEq(hook.insuranceReserve(poolId), 0);
        assertEq(hook.checkpoint(poolId).blockNumber, 0);
        assertEq(hook.withheld(poolId, Currency.wrap(address(token1))), 0);
    }
}
