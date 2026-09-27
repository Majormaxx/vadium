// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { FeeDiscount } from "../../src/libraries/FeeDiscount.sol";

contract FeeDiscountTest is Test {
    function test_discount_appliesToStandardFee() public pure {
        assertEq(FeeDiscount.discountedFee(3_000, 10), 2_000);
        assertEq(FeeDiscount.discountedFee(3_000, 5), 2_500);
    }

    function test_discount_zeroBpsIsIdentity() public pure {
        assertEq(FeeDiscount.discountedFee(3_000, 0), 3_000);
    }

    function test_discount_floorsAtMinFee() public pure {
        assertEq(FeeDiscount.discountedFee(1_050, 10), FeeDiscount.MIN_FEE);
        assertEq(FeeDiscount.discountedFee(1_000, 10), FeeDiscount.MIN_FEE);
    }

    function test_discount_exceedingBase_floorsAtMinFee() public pure {
        assertEq(FeeDiscount.discountedFee(500, 10), FeeDiscount.MIN_FEE);
    }

    function test_discount_baseAtOrBelowFloor_returnsBase() public pure {
        // The regression: a discount must never raise the fee.
        assertEq(FeeDiscount.discountedFee(100, 10), 100);
        assertEq(FeeDiscount.discountedFee(50, 10), 50);
        assertEq(FeeDiscount.discountedFee(0, 10), 0);
    }

    function test_discount_maxLpFee() public pure {
        assertEq(FeeDiscount.discountedFee(1_000_000, 10), 999_000);
    }

    function test_fuzz_discountNeverRaisesFee(uint24 baseFee, uint24 bps) public pure {
        baseFee = uint24(bound(baseFee, 0, 1_000_000));
        bps = uint24(bound(bps, 0, 20_000));
        uint24 out = FeeDiscount.discountedFee(baseFee, bps);
        assertLe(out, baseFee);
        if (baseFee > FeeDiscount.MIN_FEE) assertGe(out, FeeDiscount.MIN_FEE);
    }

    function test_fuzz_discountIsExactWhenAboveFloor(uint24 baseFee, uint8 bps) public pure {
        baseFee = uint24(bound(baseFee, 30_000, 1_000_000));
        bps = uint8(bound(bps, 0, 200));
        uint24 out = FeeDiscount.discountedFee(baseFee, bps);
        assertEq(out, baseFee - uint24(bps) * 100);
    }
}
