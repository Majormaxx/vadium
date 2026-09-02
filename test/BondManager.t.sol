// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { BondManager } from "../src/core/libraries/BondManager.sol";

/// @title BondManagerTest
/// @notice Tests the bond expiry and two-tier slash math.
contract BondManagerTest is Test {
    using BondManager for BondManager.Bond;

    BondManager.Bond internal bond;
    BondManager.Bond internal scratch;

    function setUp() public {
        bond = BondManager.Bond({
            amount: 10_000e6, depositBlock: 1000, bannedUntil: 0, strikeCount: 0
        });
    }

    // -------------------------------------------------------------------------
    // Expiry
    // -------------------------------------------------------------------------

    function test_isMatured_returnsFalse_beforeWindow() public view {
        assertFalse(bond.isMatured(100, 1099));
    }

    function test_isMatured_returnsTrue_atExactlyMaturity() public view {
        // 1000 + 100 = 1100
        assertTrue(bond.isMatured(100, 1100));
    }

    function test_isMatured_returnsTrue_afterWindow() public view {
        assertTrue(bond.isMatured(100, 1200));
    }

    function test_isMatured_zeroDurationMaturesImmediately() public {
        bond.depositBlock = 500;
        assertTrue(bond.isMatured(0, 500));
    }

    // -------------------------------------------------------------------------
    // Extended lock window
    // -------------------------------------------------------------------------

    function test_isWithinExtendedLock_beforeWindowEnd() public {
        // deposit = 1000, extension = 7200 → locked until 8200
        bond.depositBlock = 1000;
        assertTrue(bond.isWithinExtendedLock(7200, 8199));
    }

    function test_isWithinExtendedLock_atWindowEndIsExpired() public {
        bond.depositBlock = 1000;
        assertFalse(bond.isWithinExtendedLock(7200, 8200));
    }

    function test_isWithinExtendedLock_whenNotExtended() public {
        // A fresh bond (depositBlock = block of deposit) is within its own window,
        // so a violation there IS a "repeat" candidate only if strikes exist.
        bond.depositBlock = 1000;
        bond.strikeCount = 1;
        assertTrue(bond.isWithinExtendedLock(7200, 1001));
    }

    // -------------------------------------------------------------------------
    // Slash math
    // -------------------------------------------------------------------------

    function test_computeSlash_firstOffenseTakesFiftyPercent() public view {
        assertEq(bond.computeSlash(false, 5000), 5_000e6);
    }

    function test_computeSlash_repeatTakesFullRemaining() public view {
        assertEq(bond.computeSlash(true, 5000), 10_000e6);
    }

    function test_computeSlash_firstOffenseWithCustomBps() public view {
        assertEq(bond.computeSlash(false, 1000), 1_000e6); // 10%
    }

    function test_computeSlash_afterPartialSlash() public {
        // Bond already reduced by a prior slash; repeat takes whatever remains.
        bond.amount = 4_000e6;
        assertEq(bond.computeSlash(true, 5000), 4_000e6);
    }

    function test_computeSlash_zeroAmountBond() public {
        bond.amount = 0;
        assertEq(bond.computeSlash(false, 5000), 0);
        assertEq(bond.computeSlash(true, 5000), 0);
    }

    // -------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------

    /// @notice A repeat slash never exceeds the bond; a first slash is at most 100%
    ///         of the bond (using a realistic bps ceiling).
    function test_fuzz_slashBounds(uint256 amount, uint256 bps, bool isRepeat) public {
        amount = bound(amount, 0, type(uint128).max);
        bps = bound(bps, 0, 10_000);

        scratch.amount = amount;
        scratch.depositBlock = 1;
        scratch.bannedUntil = 0;
        scratch.strikeCount = isRepeat ? 1 : 0;

        uint256 slashed = scratch.computeSlash(isRepeat, bps);

        assertLe(slashed, amount, "slash never exceeds bond");
        if (!isRepeat) {
            // First offense: proportional to the bps ratio.
            assertEq(slashed, (amount * bps) / 10_000, "first slash is proportional");
        } else {
            assertEq(slashed, amount, "repeat slash takes everything");
        }
    }
}
