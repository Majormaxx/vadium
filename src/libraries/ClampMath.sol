// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SwapMath } from "v4-core/src/libraries/SwapMath.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { FixedPoint96 } from "v4-core/src/libraries/FixedPoint96.sol";
import { ProtocolFeeLibrary } from "v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @title ClampMath
/// @notice Pure math for the block-start price clamp: what a swap would have received
///         (or paid) at the block-start price, how far the real execution deviated from
///         that, and conversion of a deviation into bond-token units.
///
/// @dev    The target is a constant-liquidity fill from the block-start price using
///         `SwapMath.computeSwapStep` with an unbounded price limit. This is exactly
///         the fill OpenZeppelin's AntiSandwichHook computes, because its simulated
///         `Pool.swap` runs on a copied state whose tick bitmap is empty and so never
///         crosses a tick. For a pool whose liquidity is all full-range the target is
///         exact; for concentrated pools it ignores liquidity outside the block-start
///         band, which the host can replace by overriding `_targetUnspecified`.
///
/// @custom:security  Pure library. Reverts only on `liquidity == 0`, which callers
///                   guard.
library ClampMath {
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    /// @notice The swap fee (LP fee plus protocol fee) a swap in `zeroForOne` pays.
    function swapFee(uint24 lpFee, uint24 protocolFee, bool zeroForOne)
        internal
        pure
        returns (uint24)
    {
        uint16 pf = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        return pf == 0 ? lpFee : pf.calculateSwapFee(lpFee);
    }

    /// @notice Unspecified amount a swap would have moved at the block-start price.
    /// @param sqrtPriceX96    Block-start sqrt price.
    /// @param liquidity       Block-start in-range liquidity. Must be non-zero.
    /// @param feePips         Swap fee in pips for this direction.
    /// @param zeroForOne      Swap direction.
    /// @param exactInput      Whether the specified amount is the input.
    /// @param filledSpecified Absolute specified amount the real swap moved.
    /// @return target         Output for exact input; input including fee for exact output.
    function targetUnspecified(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint24 feePips,
        bool zeroForOne,
        bool exactInput,
        uint256 filledSpecified
    ) internal pure returns (uint256 target) {
        uint160 sqrtLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        int256 amountRemaining = exactInput ? -int256(filledSpecified) : int256(filledSpecified);
        (, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtPriceX96, sqrtLimit, liquidity, amountRemaining, feePips);
        return exactInput ? amountOut : amountIn + feeAmount;
    }

    /// @notice Split the deviation between the real unspecified amount and the target.
    /// @return excess     How much better than block start the swap did (to withhold).
    /// @return shortfall  How much worse than block start the swap did (victim loss).
    function split(bool exactInput, uint256 actual, uint256 target)
        internal
        pure
        returns (uint256 excess, uint256 shortfall)
    {
        if (exactInput) {
            // Output: more than target is a gain, less is a loss.
            if (actual > target) excess = actual - target;
            else shortfall = target - actual;
        } else {
            // Input: less than target is a gain, more is a loss.
            if (actual < target) excess = target - actual;
            else shortfall = actual - target;
        }
    }

    /// @notice Convert an amount of one pool currency into bond-token units at the
    ///         block-start price.
    /// @param amount           Amount to convert.
    /// @param amountIsCurrency0 Whether `amount` is denominated in currency0.
    /// @param bondIsCurrency0   Whether the bond token is currency0.
    /// @param sqrtPriceX96      Block-start sqrt price (currency1 per currency0).
    function toBondUnits(
        uint256 amount,
        bool amountIsCurrency0,
        bool bondIsCurrency0,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256) {
        if (amountIsCurrency0 == bondIsCurrency0) return amount;
        if (amountIsCurrency0) {
            // amount1 = amount0 * price
            return FullMath.mulDiv(
                FullMath.mulDiv(amount, sqrtPriceX96, FixedPoint96.Q96),
                sqrtPriceX96,
                FixedPoint96.Q96
            );
        }
        // amount0 = amount1 / price
        return FullMath.mulDiv(
            FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
        );
    }
}
