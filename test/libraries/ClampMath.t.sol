// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { SqrtPriceMath } from "v4-core/src/libraries/SqrtPriceMath.sol";
import { FixedPoint96 } from "v4-core/src/libraries/FixedPoint96.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { ClampMath } from "../../src/libraries/ClampMath.sol";

contract ClampMathTest is Test {
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;
    uint128 constant L = 1e11;
    uint24 constant FEE = 3_000;

    // --- swapFee ---

    function test_swapFee_noProtocolFee_isLpFee() public pure {
        assertEq(ClampMath.swapFee(3_000, 0, true), 3_000);
        assertEq(ClampMath.swapFee(3_000, 0, false), 3_000);
    }

    function test_swapFee_protocolFee_perDirection() public pure {
        // protocolFee packs oneForZero in the upper 12 bits, zeroForOne in the lower.
        uint24 packed = (uint24(1_000) << 12) | uint24(500);
        // pf + lp - pf*lp/1e6 with integer division: 500 + 3000 - 1, 1000 + 3000 - 3.
        assertEq(uint256(ClampMath.swapFee(3_000, packed, true)), 3_499);
        assertEq(uint256(ClampMath.swapFee(3_000, packed, false)), 3_997);
    }

    // --- targetUnspecified ---

    function test_target_exactInput_zeroForOne_matchesSqrtPriceMath() public pure {
        uint256 amountIn = 1e9;
        uint256 lessFee = (amountIn * (1_000_000 - FEE)) / 1_000_000;
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(SQRT_1_1, L, lessFee, true);
        uint256 expected = SqrtPriceMath.getAmount1Delta(next, SQRT_1_1, L, false);
        assertEq(ClampMath.targetUnspecified(SQRT_1_1, L, FEE, true, true, amountIn), expected);
    }

    function test_target_exactInput_oneForZero_matchesSqrtPriceMath() public pure {
        uint256 amountIn = 1e9;
        uint256 lessFee = (amountIn * (1_000_000 - FEE)) / 1_000_000;
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(SQRT_1_1, L, lessFee, false);
        uint256 expected = SqrtPriceMath.getAmount0Delta(SQRT_1_1, next, L, false);
        assertEq(ClampMath.targetUnspecified(SQRT_1_1, L, FEE, false, true, amountIn), expected);
    }

    function test_target_exactOutput_includesFee() public pure {
        uint256 amountOut = 1e9;
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromOutput(SQRT_1_1, L, amountOut, true);
        uint256 amountIn = SqrtPriceMath.getAmount0Delta(next, SQRT_1_1, L, true);
        uint256 fee = FullMath.mulDivRoundingUp(amountIn, FEE, 1_000_000 - FEE);
        assertEq(
            ClampMath.targetUnspecified(SQRT_1_1, L, FEE, true, false, amountOut), amountIn + fee
        );
    }

    function test_target_zeroFilled_isZero() public pure {
        assertEq(ClampMath.targetUnspecified(SQRT_1_1, L, FEE, true, true, 0), 0);
    }

    function test_fuzz_target_monotoneInAmount(uint64 a, uint64 b, bool zeroForOne, bool exactIn)
        public
        pure
    {
        a = uint64(bound(a, 1, 1e12));
        b = uint64(bound(b, 1, 1e12));
        if (a > b) (a, b) = (b, a);
        uint256 ta = ClampMath.targetUnspecified(SQRT_1_1, L, FEE, zeroForOne, exactIn, a);
        uint256 tb = ClampMath.targetUnspecified(SQRT_1_1, L, FEE, zeroForOne, exactIn, b);
        assertLe(ta, tb);
    }

    function test_fuzz_target_exactInputBelowInput_atParity(uint64 amountIn) public pure {
        amountIn = uint64(bound(amountIn, 1, 1e12));
        // At a 1:1 price with a fee and price impact, output never exceeds input.
        assertLe(ClampMath.targetUnspecified(SQRT_1_1, L, FEE, true, true, amountIn), amountIn);
    }

    // --- split ---

    function test_split_exactInput() public pure {
        (uint256 e, uint256 s) = ClampMath.split(true, 110, 100);
        assertEq(e, 10);
        assertEq(s, 0);
        (e, s) = ClampMath.split(true, 90, 100);
        assertEq(e, 0);
        assertEq(s, 10);
        (e, s) = ClampMath.split(true, 100, 100);
        assertEq(e, 0);
        assertEq(s, 0);
    }

    function test_split_exactOutput() public pure {
        (uint256 e, uint256 s) = ClampMath.split(false, 90, 100);
        assertEq(e, 10);
        assertEq(s, 0);
        (e, s) = ClampMath.split(false, 110, 100);
        assertEq(e, 0);
        assertEq(s, 10);
    }

    function test_fuzz_split_exactlyOneSideNonZero(bool exactIn, uint128 actual, uint128 target)
        public
        pure
    {
        (uint256 e, uint256 s) = ClampMath.split(exactIn, actual, target);
        assertTrue(e == 0 || s == 0);
        uint256 diff = actual > target ? actual - target : target - actual;
        assertEq(e + s, diff);
    }

    // --- toBondUnits ---

    function test_toBondUnits_sameCurrency_identity() public pure {
        assertEq(ClampMath.toBondUnits(123, true, true, SQRT_1_1), 123);
        assertEq(ClampMath.toBondUnits(123, false, false, SQRT_1_1), 123);
    }

    function test_toBondUnits_parity_isIdentity() public pure {
        assertEq(ClampMath.toBondUnits(1e9, true, false, SQRT_1_1), 1e9);
        assertEq(ClampMath.toBondUnits(1e9, false, true, SQRT_1_1), 1e9);
    }

    function test_toBondUnits_priceFour() public pure {
        // sqrtPrice = 2 -> price = 4 token1 per token0.
        uint160 sqrtP = uint160(2 * FixedPoint96.Q96);
        assertEq(ClampMath.toBondUnits(10, true, false, sqrtP), 40);
        assertEq(ClampMath.toBondUnits(40, false, true, sqrtP), 10);
    }

    function test_fuzz_toBondUnits_roundTripWithinRounding(uint64 amount, int256 tickRaw)
        public
        pure
    {
        int24 tick = int24(bound(tickRaw, -100_000, 100_000));
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 asOne = ClampMath.toBondUnits(amount, true, false, sqrtP);
        uint256 back = ClampMath.toBondUnits(asOne, false, true, sqrtP);
        // Two floor divisions each way; the round trip can only lose value.
        assertLe(back, amount);
    }
}
