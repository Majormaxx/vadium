// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FeeDiscount
/// @notice Computes the swap-fee override an exempt (bonded) swapper receives on a
///         dynamic-fee pool.
///
/// @dev    Uniswap v4 only honors a `beforeSwap` fee override on dynamic-fee pools
///         (`Hooks.beforeSwap` parses the returned fee only when `key.fee` carries the
///         dynamic flag). A hook that wants to discount must therefore run a dynamic
///         pool and override the fee on every swap: the base fee for everyone, the
///         discounted fee for exempt swappers.
///
///         Fee units follow the v4 convention of hundredths of a bip: 3000 = 0.30%.
///         One basis point is 100 units.
///
/// @custom:security  Pure library. The result is never above `baseFee`.
library FeeDiscount {
    /// @notice Floor on the discounted fee (0.01%), applied only when the base fee is
    ///         above it. A discount never raises the fee.
    uint24 public constant MIN_FEE = 100;

    /// @notice Conversion between basis points and v4 fee units.
    uint24 public constant BPS_TO_FEE_UNITS = 100;

    /// @notice Apply a fixed discount to a base fee.
    /// @param baseFee     The unbonded fee in v4 units.
    /// @param discountBps The discount in basis points (10 = 0.10%).
    /// @return fee        `baseFee` minus the discount, floored at `MIN_FEE` when the
    ///                    base fee is above the floor, and never above `baseFee`.
    function discountedFee(uint24 baseFee, uint24 discountBps) internal pure returns (uint24) {
        if (baseFee <= MIN_FEE) return baseFee;

        uint256 discountUnits = uint256(discountBps) * BPS_TO_FEE_UNITS;
        if (discountUnits >= baseFee) return MIN_FEE;

        uint24 discounted = baseFee - uint24(discountUnits);
        return discounted < MIN_FEE ? MIN_FEE : discounted;
    }
}
