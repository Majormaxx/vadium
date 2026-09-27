// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";

import { IBondedFlow } from "../src/interfaces/IBondedFlow.sol";
import { IBlockPriceClamp } from "../src/interfaces/IBlockPriceClamp.sol";
import { VadiumTestBase, SwapRouter } from "./utils/VadiumTestBase.sol";

/// @title VadiumIntegrationTest
/// @notice End-to-end against a real PoolManager: bonds, a real front-run sandwich,
///         slash, refund, reserve drain through unlock/donate/settle, multi-pool state,
///         and the withheld-claims flush.
contract VadiumIntegrationTest is VadiumTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Searcher front-runs (zeroForOne), victim goes the same way and gets a worse
    ///      price, searcher back-runs (oneForZero).
    function _realSandwich(address s, SwapRouter r) internal {
        _swapThrough(s, r, true, -int256(SWAP_AMOUNT));
        _swapThrough(victim, victimRouter, true, -int256(SWAP_AMOUNT));
        _swapThrough(s, r, false, -int256(SWAP_AMOUNT));
    }

    function test_fullLoop_bondSandwichSlashRefundReserve() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        assertTrue(hook.isBonded(address(searcherRouter)));
        assertTrue(hook.isExempt(poolId, address(searcherRouter)));
        uint256 escrowBefore = token1.balanceOf(HOOK_ADDR);

        _realSandwich(searcher, searcherRouter);

        assertEq(hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT / 2, "50% slash");
        uint256 refund = hook.claimableRefund(address(victimRouter));
        assertGt(refund, 0, "victim refund credited");
        assertLe(refund, BOND_AMOUNT / 4, "refund capped at half the slash");
        assertEq(hook.insuranceReserve(poolId), BOND_AMOUNT / 2 - refund, "rest to reserve");
        assertEq(token1.balanceOf(HOOK_ADDR), escrowBefore, "escrow unchanged until payout");
        assertTrue(hook.flaggedUntil(address(searcherRouter)) > block.number, "flagged");
        assertFalse(hook.isExempt(poolId, address(searcherRouter)), "flag strips exemption");

        // The victim's router claims the refund for its user.
        uint256 before = token1.balanceOf(victim);
        vm.prank(victim);
        victimRouter.claimRefund(hook);
        assertEq(token1.balanceOf(victim), before + refund);
    }

    function test_victimAttributedViaHookData() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        address principal = makeAddr("principal");
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        _swapThroughLimit(
            victim, victimRouter, true, -int256(SWAP_AMOUNT), MIN_PRICE_LIMIT, abi.encode(principal)
        );
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));
        assertGt(hook.claimableRefund(principal), 0);
        assertEq(hook.claimableRefund(address(victimRouter)), 0);
        uint256 amount = hook.claimableRefund(principal);
        vm.prank(principal);
        hook.claimRefund();
        assertEq(token1.balanceOf(principal), amount);
    }

    function test_exemption_bondedFirstSwapNotClamped_unbondedIs() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        // Bonded searcher moves the price (exempt, nothing withheld).
        _swapThrough(searcher, searcherRouter, true, -int256(20 * SWAP_AMOUNT));
        assertEq(hook.withheld(poolId, currency0), 0);
        assertEq(hook.withheld(poolId, currency1), 0);

        // Unbonded follower going the favorable way gets clamped.
        _swapThrough(other, otherRouter, false, -int256(SWAP_AMOUNT));
        assertGt(hook.withheld(poolId, currency0), 0, "gain beyond block start withheld");
        assertEq(pm.balanceOf(HOOK_ADDR, currency0.toId()), hook.withheld(poolId, currency0));
    }

    function test_noDetection_crossBlock() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        vm.roll(block.number + 1);
        _swapThrough(victim, victimRouter, true, -int256(SWAP_AMOUNT));
        vm.roll(block.number + 1);
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));
        assertEq(hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT);
    }

    function test_noDetection_victimOppositeDirection_isNotAVictim() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        // Opposite direction: this swap benefits from the searcher's move (and is clamped).
        _swapThrough(victim, victimRouter, false, -int256(SWAP_AMOUNT));
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));
        assertEq(hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT, "no victim, no slash");
    }

    function test_repeatOffense_fullSlashAndBan_thenCannotRebond() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _realSandwich(searcher, searcherRouter);
        assertEq(hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT / 2);
        vm.roll(block.number + 1);
        _realSandwich(searcher, searcherRouter);
        assertEq(hook.bondedBalance(address(searcherRouter)), 0);
        assertTrue(hook.isBanned(address(searcherRouter)));
        vm.prank(address(searcherRouter));
        vm.expectRevert();
        hook.bond(BOND_AMOUNT);
    }

    function test_withdrawBond_afterMaturity() public {
        vm.prank(searcher);
        hook.bond(BOND_AMOUNT);
        vm.prank(searcher);
        vm.expectRevert();
        hook.withdrawBond();
        vm.roll(block.number + MIN_DURATION);
        uint256 before = token1.balanceOf(searcher);
        vm.prank(searcher);
        hook.withdrawBond();
        assertEq(token1.balanceOf(searcher), before + BOND_AMOUNT);
    }

    function test_reserveDrain_landsInPoolManager() public {
        hook.setKeeper(makeAddr("kee"));
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _realSandwich(searcher, searcherRouter);
        uint256 reserve = hook.insuranceReserve(poolId);
        assertGt(reserve, 0);

        uint256 hookBefore = token1.balanceOf(HOOK_ADDR);
        uint256 pmBefore = token1.balanceOf(address(pm));
        (, uint256 fg1Before) = IPoolManager(address(pm)).getFeeGrowthGlobals(poolId);

        address[] memory flagged = new address[](1);
        flagged[0] = address(searcherRouter);
        vm.prank(hook.keeper());
        uint256 drained = hook.drainFlagged(poolId, flagged, type(uint256).max);

        assertEq(drained, reserve);
        assertEq(hook.insuranceReserve(poolId), 0);
        assertEq(hook.totalWithdrawn(poolId), reserve);
        assertEq(token1.balanceOf(address(pm)), pmBefore + reserve, "PM received the donation");
        assertEq(token1.balanceOf(HOOK_ADDR), hookBefore - reserve, "escrow dropped");
        (, uint256 fg1After) = IPoolManager(address(pm)).getFeeGrowthGlobals(poolId);
        assertGt(fg1After, fg1Before, "LPs credited");
    }

    function test_partialDrain_afterWithdrawal_preservesSolvency() public {
        hook.setKeeper(makeAddr("kee"));
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _realSandwich(searcher, searcherRouter);
        uint256 reserve = hook.insuranceReserve(poolId);
        uint256 refund = hook.claimableRefund(address(victimRouter));
        assertEq(token1.balanceOf(HOOK_ADDR), BOND_AMOUNT, "escrow = bond + reserve + refund");
        assertEq(BOND_AMOUNT / 2 + reserve + refund, BOND_AMOUNT);

        vm.roll(block.number + EXT);
        vm.prank(address(searcherRouter));
        hook.withdrawBond();
        assertEq(token1.balanceOf(HOOK_ADDR), reserve + refund);

        address[] memory flagged = new address[](1);
        flagged[0] = address(searcherRouter);
        vm.prank(hook.keeper());
        hook.drainFlagged(poolId, flagged, type(uint256).max);
        assertEq(token1.balanceOf(HOOK_ADDR), refund, "only the refund credit remains");
        assertEq(hook.freeBalance(), 0);
    }

    function test_secondPool_stateIsolated() public {
        PoolKey memory k2 = poolKey;
        k2.fee = 500;
        k2.tickSpacing = 60;
        PoolId id2 = k2.toId();
        vm.expectRevert();
        pm.initialize(k2, SQRT_1_1);
        hook.registerPool(k2, _cfg(), address(this));
        pm.initialize(k2, SQRT_1_1);
        liqRouter.modifyLiquidity(
            k2,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_220, tickUpper: 887_220, liquidityDelta: LIQUIDITY, salt: 0
            })
        );

        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(SWAP_AMOUNT));
        // Victim trades on pool 2: not an intervening swap on pool 1.
        vm.prank(victim);
        victimRouter.swap(
            k2,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(SWAP_AMOUNT),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            })
        );
        _swapThrough(searcher, searcherRouter, false, -int256(SWAP_AMOUNT));
        assertEq(hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT, "no cross-pool slash");
        assertEq(hook.checkpoint(id2).blockNumber, block.number, "pool 2 has its own checkpoint");
        assertEq(hook.insuranceReserve(id2), 0);
    }

    function test_flushWithheld_donatesToLPsAndBurnsClaims() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(20 * SWAP_AMOUNT));
        _swapThrough(other, otherRouter, false, -int256(SWAP_AMOUNT));
        uint256 w0 = hook.withheld(poolId, currency0);
        assertGt(w0, 0);
        (uint256 fg0Before,) = IPoolManager(address(pm)).getFeeGrowthGlobals(poolId);

        vm.expectEmit(true, false, false, true, HOOK_ADDR);
        emit IBlockPriceClamp.WithheldFlushed(poolId, w0, 0);
        vm.prank(other);
        (uint256 a0, uint256 a1) = hook.flushWithheld(poolId);
        assertEq(a0, w0);
        assertEq(a1, 0);
        assertEq(hook.withheld(poolId, currency0), 0);
        assertEq(pm.balanceOf(HOOK_ADDR, currency0.toId()), 0, "claims burned");
        (uint256 fg0After,) = IPoolManager(address(pm)).getFeeGrowthGlobals(poolId);
        assertGt(fg0After, fg0Before, "LPs credited with the withheld token0");

        vm.expectRevert(IBlockPriceClamp.NothingToFlush.selector);
        hook.flushWithheld(poolId);
    }

    function test_flushWithheld_revertsWithoutLiquidity() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(20 * SWAP_AMOUNT));
        _swapThrough(other, otherRouter, false, -int256(SWAP_AMOUNT));
        _addLiquidity(-LIQUIDITY);
        assertEq(IPoolManager(address(pm)).getLiquidity(poolId), 0);
        vm.expectRevert(IBlockPriceClamp.NoLiquidityToReceive.selector);
        hook.flushWithheld(poolId);
    }

    function test_clampDisabled_noWithholding() public {
        IBondedFlow.PoolConfig memory c = _cfg();
        c.clampEnabled = false;
        hook.setPoolConfig(poolId, c);
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(20 * SWAP_AMOUNT));
        _swapThrough(other, otherRouter, false, -int256(SWAP_AMOUNT));
        assertEq(hook.withheld(poolId, currency0), 0);
    }

    function test_dynamicFeePool_overridesBaseAndDiscount() public {
        PoolKey memory k = poolKey;
        k.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        k.tickSpacing = 60;
        IBondedFlow.PoolConfig memory c = _cfg();
        c.baseFee = 3_000;
        c.feeDiscountBps = 10;
        hook.registerPool(k, c, address(this));
        pm.initialize(k, SQRT_1_1);

        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        vm.prank(address(pm));
        (,, uint24 unbonded) = hook.beforeSwap(address(otherRouter), k, sp, "");
        assertEq(unbonded, 3_000 | LPFeeLibrary.OVERRIDE_FEE_FLAG);

        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        vm.prank(address(pm));
        (,, uint24 bonded) = hook.beforeSwap(address(searcherRouter), k, sp, "");
        assertEq(bonded, 2_000 | LPFeeLibrary.OVERRIDE_FEE_FLAG);

        // Static pool: no override at all, regardless of bond.
        vm.prank(address(pm));
        (,, uint24 none) = hook.beforeSwap(address(searcherRouter), poolKey, sp, "");
        assertEq(none, 0);
    }

    function test_checkpoint_takenOncePerBlock() public {
        _swapThrough(other, otherRouter, true, -int256(SWAP_AMOUNT));
        IBlockPriceClamp.Checkpoint memory c1 = hook.checkpoint(poolId);
        assertEq(c1.blockNumber, block.number);
        assertEq(c1.sqrtPriceX96, SQRT_1_1);
        assertEq(c1.liquidity, uint128(uint256(LIQUIDITY)));
        assertEq(c1.fee, POOL_FEE);
        _swapThrough(other, otherRouter, true, -int256(SWAP_AMOUNT));
        assertEq(hook.checkpoint(poolId).sqrtPriceX96, SQRT_1_1, "unchanged within block");
        vm.roll(block.number + 1);
        _swapThrough(other, otherRouter, true, -int256(SWAP_AMOUNT));
        assertLt(hook.checkpoint(poolId).sqrtPriceX96, SQRT_1_1, "next block reflects moves");
    }

    // -------------------------------------------------------------------------
    // Gas (lower bounds only; the snapshot file carries the exact figures)
    // -------------------------------------------------------------------------

    function test_gas_bond() public {
        uint256 before = gasleft();
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        assertGt(before - gasleft(), 50_000);
    }

    function test_gas_unbondedSwap() public {
        uint256 before = gasleft();
        _swapThrough(other, otherRouter, true, -int256(SWAP_AMOUNT));
        assertGt(before - gasleft(), 100_000);
    }

    function test_gas_sandwichSlash() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        uint256 before = gasleft();
        _realSandwich(searcher, searcherRouter);
        assertGt(before - gasleft(), 150_000);
    }

    function test_gas_withdrawBond() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        vm.roll(block.number + MIN_DURATION);
        uint256 before = gasleft();
        vm.prank(address(searcherRouter));
        hook.withdrawBond();
        assertGt(before - gasleft(), 10_000);
    }
}
