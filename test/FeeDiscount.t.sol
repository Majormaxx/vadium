// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { FeeDiscount } from "../src/core/libraries/FeeDiscount.sol";

/// @title FeeDiscountTest
/// @notice Tests the bonded fee-discount math.
contract FeeDiscountTest is Test {
    using FeeDiscount for uint24;

    // -------------------------------------------------------------------------
    // Happy path
    // -------------------------------------------------------------------------

    function test_discountedFee_reducesByDiscount() public pure {
        // Pool at 0.30% (3000 units); 10 bps discount → 2000 units (0.20%).
        assertEq(FeeDiscount.discountedFee(3000, 10), 2000);
    }

    function test_discountedFee_zeroDiscountReturnsBase() public pure {
        assertEq(FeeDiscount.discountedFee(3000, 0), 3000);
    }

    function test_discountedFee_exactDiscountHitsFloorSafely() public pure {
        // 30 bps pool fee, 30 bps discount → floor (0.01%), not zero.
        assertEq(FeeDiscount.discountedFee(3000, 30), FeeDiscount.MIN_FEE);
    }

    function test_discountedFee_overDiscountedClippedToFloor() public pure {
        // 50 bps discount on a 30 bps pool → floor, never negative.
        assertEq(FeeDiscount.discountedFee(3000, 50), FeeDiscount.MIN_FEE);
    }

    // -------------------------------------------------------------------------
    // Floor boundaries
    // -------------------------------------------------------------------------

    function test_discountedFee_floorAppliedWhenBaseBelowFloor() public pure {
        // Base fee already at/below floor stays there (never goes to zero).
        assertEq(FeeDiscount.discountedFee(100, 10), FeeDiscount.MIN_FEE);
        assertEq(FeeDiscount.discountedFee(50, 10), FeeDiscount.MIN_FEE);
    }

    function test_discountedFee_staticFeePoolBaseline() public pure {
        // The hook passes the pool's static fee as the base; the discount is always
        // measured from a valid, plain LP fee.
        uint24 base = 3000;
        uint24 discounted = FeeDiscount.discountedFee(base, 10);
        assertLt(discounted, base);
        assertGt(discounted, 0);
    }

    // -------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------

    /// @notice The discounted fee is never below MIN_FEE and never exceeds the base fee
    ///         when the base fee is itself a valid, protocol-level pool fee.
    function test_fuzz_discountedFee_bounds(uint24 baseFee, uint24 discountBps) public pure {
        baseFee = uint24(bound(baseFee, FeeDiscount.MIN_FEE, 1_000_000));
        discountBps = uint24(bound(discountBps, 0, 100));

        uint24 result = FeeDiscount.discountedFee(baseFee, discountBps);

        assertGe(result, FeeDiscount.MIN_FEE, "never below floor");
        assertLe(result, baseFee, "never above base");
    }
}
