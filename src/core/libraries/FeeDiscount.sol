// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FeeDiscount
/// @notice Computes the dynamic swap-fee override that bonded searchers receive.
///
/// @dev    Vadium returns the discounted fee from `beforeSwap` as a fee override with
///         the OVERRIDE_FEE_FLAG (0x400000) set. v4 honors the override on static-fee
///         pools too — the override replaces the pool's stored LP fee for that swap.
///         Bonded, non-banned addresses get the pool's static fee minus a fixed
///         discount.
///
///         Fee units follow Uniswap v4 convention — hundredths of a bip, so 1 bip =
///         0.01% and 3000 = 0.30%. Because 1 basis point = 0.01%, a 10 bps discount
///         equals 1000 fee units (10 × 100).
///
/// @custom:security  Pure library — no storage, no reentrancy, no external calls.
library FeeDiscount {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Hard floor on the discounted fee. A 0-fee swap is never returned,
    ///         both to keep the pool economically viable and to avoid the edge case
    ///         where a bonded searcher pays nothing at all.
    uint24 public constant MIN_FEE = 100; // 0.01%

    /// @notice Conversion between basis points and v4 fee units.
    ///         1 bps = 0.01% = 100 units (hundredths of a bip).
    uint24 public constant BPS_TO_FEE_UNITS = 100;

    // -------------------------------------------------------------------------
    // Core function
    // -------------------------------------------------------------------------

    /// @notice Apply a fixed fee discount to a base pool fee.
    ///
    /// @param baseFee     The pool's static LP fee in v4 units.
    /// @param discountBps The discount in basis points (e.g. 10 = 0.10%).
    ///
    /// @return fee        The discounted fee in v4 units, floored at MIN_FEE.
    function discountedFee(uint24 baseFee, uint24 discountBps) internal pure returns (uint24) {
        if (baseFee <= MIN_FEE) return MIN_FEE;

        uint24 discountUnits = discountBps * BPS_TO_FEE_UNITS;

        // Either the full discount leaves enough, or the floor applies.
        if (baseFee <= discountUnits) return MIN_FEE;
        uint24 discounted = baseFee - discountUnits;
        return discounted < MIN_FEE ? MIN_FEE : discounted;
    }
}
