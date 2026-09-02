// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { SandwichDetector } from "../src/core/libraries/SandwichDetector.sol";

/// @title SandwichDetectorTest
/// @notice Tests the pure sandwich-detection logic.
///
/// @dev    The detector flags a same-address, same-block, opposite-direction swap with
///         an intervening different-address swap. These tests pin the exact boundary
///         conditions of each condition so a regression can't silently widen or narrow
///         the detection window.
contract SandwichDetectorTest is Test {
    // -------------------------------------------------------------------------
    // True positive
    // -------------------------------------------------------------------------

    function test_detect_flags_trueSandwich() public pure {
        // Searcher bought (zeroForOne=true) then sold (zeroForOne=false) in the same
        // block with a victim in between.
        bool verdict = SandwichDetector.detect({
            hadPriorSameBlock: true,
            priorDirection: true,
            currentDirection: false,
            interveningDifferent: true
        });
        assertTrue(verdict);
    }

    function test_detect_flags_reverseOrderSandwich() public pure {
        // Sold first, then bought — direction reversal in the other order.
        bool verdict = SandwichDetector.detect({
            hadPriorSameBlock: true,
            priorDirection: false,
            currentDirection: true,
            interveningDifferent: true
        });
        assertTrue(verdict);
    }

    // -------------------------------------------------------------------------
    // Cross-block — must NOT flag
    // -------------------------------------------------------------------------

    function test_detect_notFlag_whenPriorInDifferentBlock() public pure {
        // The two legs are in different blocks, so this is not a same-block sandwich.
        bool verdict = SandwichDetector.detect({
            hadPriorSameBlock: false,
            priorDirection: true,
            currentDirection: false,
            interveningDifferent: true
        });
        assertFalse(verdict);
    }

    // -------------------------------------------------------------------------
    // Same direction — must NOT flag
    // -------------------------------------------------------------------------

    function test_detect_notFlag_whenSameDirection() public pure {
        // Buy then buy again — a legitimate accumulator, not a reversal.
        bool verdict = SandwichDetector.detect({
            hadPriorSameBlock: true,
            priorDirection: true,
            currentDirection: true,
            interveningDifferent: true
        });
        assertFalse(verdict);
    }

    // -------------------------------------------------------------------------
    // Missing intervening different swapper — must NOT flag
    // -------------------------------------------------------------------------

    function test_detect_notFlag_whenNoInterveningSwapper() public pure {
        // Reversal but no victim between the two legs — a self-pair of buyer/seller
        // without a victim is just an arbitrage, not a sandwich.
        bool verdict = SandwichDetector.detect({
            hadPriorSameBlock: true,
            priorDirection: true,
            currentDirection: false,
            interveningDifferent: false
        });
        assertFalse(verdict);
    }

    // -------------------------------------------------------------------------
    // All-negating combos
    // -------------------------------------------------------------------------

    function test_detect_notFlag_whenNoPriorAndSameDirection() public pure {
        assertFalse(
            SandwichDetector.detect({
                hadPriorSameBlock: false,
                priorDirection: true,
                currentDirection: true,
                interveningDifferent: true
            })
        );
    }

    function test_detect_notFlag_whenNoPriorAndNoIntervening() public pure {
        assertFalse(
            SandwichDetector.detect({
                hadPriorSameBlock: false,
                priorDirection: true,
                currentDirection: false,
                interveningDifferent: false
            })
        );
    }

    function test_detect_notFlag_whenSameDirectionAndNoIntervening() public pure {
        assertFalse(
            SandwichDetector.detect({
                hadPriorSameBlock: true,
                priorDirection: true,
                currentDirection: true,
                interveningDifferent: false
            })
        );
    }

    // -------------------------------------------------------------------------
    // Fuzz: each condition is necessary
    // -------------------------------------------------------------------------

    /// @notice Every combination should flag ONLY when all three conditions hold.
    function test_fuzz_detect_exactlyWhenAllConditionsHold(
        bool priorSame,
        bool priorDir,
        bool curDir,
        bool intervening
    ) public pure {
        bool expected = priorSame && (priorDir != curDir) && intervening;
        bool actual = SandwichDetector.detect(priorSame, priorDir, curDir, intervening);
        assertEq(actual, expected);
    }
}
