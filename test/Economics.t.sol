// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";

import { IBondedFlow } from "../src/interfaces/IBondedFlow.sol";
import { ClampMath } from "../src/libraries/ClampMath.sol";
import { VadiumTestBase, SwapRouter } from "./utils/VadiumTestBase.sol";

/// @title EconomicsTest
/// @notice Proves the mechanism's economic claims on a real pool: an unbonded sandwich
///         cannot profit under the clamp, a bonded sandwich is slashed and the victim
///         refunded, a bonded market maker is not a false positive, and the disclosed
///         bonded-mule hole is what it is.
contract EconomicsTest is VadiumTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant ATTACK = 5_000e6;
    uint256 constant VICTIM = 20_000e6;

    /// @dev Attacker sells `ATTACK` token0, victim sells `VICTIM` token0, attacker sells
    ///      back all token1 it received. Returns token0 received on leg 2.
    function _roundTrip(address a, SwapRouter r) internal returns (uint256 in0, uint256 out0) {
        BalanceDelta d1 = _swapThrough(a, r, true, -int256(ATTACK));
        in0 = _abs(d1.amount0());
        uint256 got1 = _abs(d1.amount1());
        _swapThrough(victim, victimRouter, true, -int256(VICTIM));
        BalanceDelta d2 = _swapThrough(a, r, false, -int256(got1));
        out0 = _abs(d2.amount0());
    }

    function test_sandwichProfitable_withoutClamp() public {
        IBondedFlow.PoolConfig memory c = _cfg();
        c.clampEnabled = false;
        hook.setPoolConfig(poolId, c);
        (uint256 in0, uint256 out0) = _roundTrip(other, otherRouter);
        assertGt(out0, in0, "the attack is profitable when nothing clamps it");
    }

    function test_unbondedSandwich_profitNonPositive_underClamp() public {
        (uint256 in0, uint256 out0) = _roundTrip(other, otherRouter);
        assertLe(out0, in0, "clamped back-run cannot beat block-start price");
        assertGt(hook.withheld(poolId, currency0), 0, "the gain was withheld for LPs");
        assertEq(hook.insuranceReserve(poolId), 0, "no bond, nothing to slash");
    }

    function test_unbondedMule_profitNonPositive_underClamp() public {
        BalanceDelta d1 = _swapThrough(other, otherRouter, true, -int256(ATTACK));
        uint256 in0 = _abs(d1.amount0());
        uint256 got1 = _abs(d1.amount1());
        _swapThrough(victim, victimRouter, true, -int256(VICTIM));
        // A second, unrelated address closes the position.
        address mule = makeAddr("mule");
        SwapRouter muleRouter = new SwapRouter(pm);
        _fund(mule, muleRouter);
        token1.mint(mule, got1);
        BalanceDelta d2 = _swapThrough(mule, muleRouter, false, -int256(got1));
        assertLe(_abs(d2.amount0()), in0, "mule leg is clamped like any other");
    }

    function test_victimLoss_measuredAgainstBlockStart() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(ATTACK));
        (uint160 sqrtBefore,,,) = IPoolManager(address(pm)).getSlot0(poolId);
        assertLt(sqrtBefore, SQRT_1_1, "front-run moved the price");

        BalanceDelta dv = _swapThrough(victim, victimRouter, true, -int256(VICTIM));
        uint256 actualOut = _abs(dv.amount1());
        uint256 target = ClampMath.targetUnspecified(
            SQRT_1_1, uint128(uint256(LIQUIDITY)), POOL_FEE, true, true, VICTIM
        );
        assertGt(target, actualOut, "victim got less than at block start");
        (,,, uint96 recorded) = hook.poolBlockState(poolId);
        assertEq(recorded, target - actualOut, "shortfall recorded in bond units");
    }

    function test_bondedSandwich_slashedAndVictimRefunded() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        (uint256 in0, uint256 out0) = _roundTrip(searcher, searcherRouter);
        assertLe(out0, in0, "second bonded leg is clamped under exemptFirstSwapOnly");
        assertEq(hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT / 2, "slashed");
        uint256 refund = hook.claimableRefund(address(victimRouter));
        uint256 cap = (BOND_AMOUNT / 2) / 2;
        assertEq(refund, cap, "loss exceeds the cap, so the cap applies");
        assertEq(hook.insuranceReserve(poolId), BOND_AMOUNT / 2 - refund);
    }

    function test_bondedSecondLeg_clampedBeforeSlash() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(ATTACK));
        _swapThrough(victim, victimRouter, true, -int256(VICTIM));
        uint256 wBefore = hook.withheld(poolId, currency0);
        _swapThrough(searcher, searcherRouter, false, -int256(ATTACK));
        assertGt(hook.withheld(poolId, currency0), wBefore, "leg 2 withheld");
    }

    function test_bondedArb_movesPrice_followerClampedThenFreeNextBlock() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(ATTACK));
        uint256 target = ClampMath.targetUnspecified(
            SQRT_1_1, uint128(uint256(LIQUIDITY)), POOL_FEE, false, true, SWAP_AMOUNT
        );
        BalanceDelta d = _swapThrough(other, otherRouter, false, -int256(SWAP_AMOUNT));
        assertEq(_abs(d.amount0()), target, "follower receives exactly the block-start fill");
        assertGt(hook.withheld(poolId, currency0), 0);

        vm.roll(block.number + 1);
        uint256 w = hook.withheld(poolId, currency0);
        BalanceDelta d2 = _swapThrough(other, otherRouter, false, -int256(SWAP_AMOUNT));
        assertEq(hook.withheld(poolId, currency0), w, "new block, new reference, nothing withheld");
        assertGt(_abs(d2.amount0()), 0);
    }

    function test_bondedMarketMaker_noFalsePositive_withVictimLossRequired() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(ATTACK));
        // An unrelated trader goes the other way: it benefits (and is clamped), no loss.
        _swapThrough(other, otherRouter, false, -int256(SWAP_AMOUNT));
        _swapThrough(searcher, searcherRouter, false, -int256(ATTACK));
        assertEq(hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT, "not slashed");

        // Same sequence with the evidence requirement off: it is slashed.
        IBondedFlow.PoolConfig memory c = _cfg();
        c.requireVictimLoss = false;
        hook.setPoolConfig(poolId, c);
        vm.roll(block.number + 1);
        _swapThrough(searcher, searcherRouter, true, -int256(ATTACK));
        _swapThrough(other, otherRouter, false, -int256(SWAP_AMOUNT));
        _swapThrough(searcher, searcherRouter, false, -int256(ATTACK));
        assertEq(hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT / 2, "slashed");
    }

    function test_exactOutput_clampTakesExtraInput() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(ATTACK));
        uint256 want0 = 500e6;
        uint256 targetIn = ClampMath.targetUnspecified(
            SQRT_1_1, uint128(uint256(LIQUIDITY)), POOL_FEE, false, false, want0
        );
        BalanceDelta d = _swapThrough(other, otherRouter, false, int256(want0));
        assertEq(_abs(d.amount0()), want0);
        assertEq(_abs(d.amount1()), targetIn, "pays the block-start input, not the cheaper one");
        assertGt(hook.withheld(poolId, currency1), 0);
    }

    function test_partialFillAgainstLimit_noRevertNoFalseWithhold() public {
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _swapThrough(searcher, searcherRouter, true, -int256(ATTACK));
        (uint160 sqrtNow,,,) = IPoolManager(address(pm)).getSlot0(poolId);
        // Sell token0 with a limit just below the current price: a tiny partial fill.
        uint160 limit = uint160((uint256(sqrtNow) * 9_999) / 10_000);
        BalanceDelta d = _swapThroughLimit(other, otherRouter, true, -int256(VICTIM), limit, "");
        assertLt(_abs(d.amount0()), VICTIM, "partial fill");
        assertEq(hook.withheld(poolId, currency1), 0, "worse than block start: nothing withheld");
    }

    function test_KNOWN_bondedMuleHole() public {
        // Two bonded addresses split the legs. Each is its own first swap of the block,
        // so both are exempt; no address reverses, so nothing is slashed. This is the
        // disclosed limit of same-address detection; the watchtower path exists for it.
        address mule = makeAddr("mule");
        SwapRouter muleRouter = new SwapRouter(pm);
        _fund(mule, muleRouter);
        _bondThrough(searcher, searcherRouter, BOND_AMOUNT);
        _bondThrough(mule, muleRouter, BOND_AMOUNT);

        BalanceDelta d1 = _swapThrough(searcher, searcherRouter, true, -int256(ATTACK));
        uint256 in0 = _abs(d1.amount0());
        uint256 got1 = _abs(d1.amount1());
        _swapThrough(victim, victimRouter, true, -int256(VICTIM));
        token1.mint(mule, got1);
        BalanceDelta d2 = _swapThrough(mule, muleRouter, false, -int256(got1));

        assertGt(_abs(d2.amount0()), in0, "KNOWN: bonded mule pair profits");
        assertEq(hook.bondedBalance(address(searcherRouter)), BOND_AMOUNT);
        assertEq(hook.bondedBalance(address(muleRouter)), BOND_AMOUNT);
    }
}
