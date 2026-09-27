// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { SandwichDetector } from "../../src/libraries/SandwichDetector.sol";

contract SandwichDetectorTest is Test {
    function test_detect_trueSandwich() public pure {
        assertTrue(SandwichDetector.detect(true, true, false, true, true));
        assertTrue(SandwichDetector.detect(true, false, true, true, true));
    }

    function test_detect_falseWithoutPriorSameBlock() public pure {
        assertFalse(SandwichDetector.detect(false, true, false, true, true));
    }

    function test_detect_falseWhenSameDirection() public pure {
        assertFalse(SandwichDetector.detect(true, true, true, true, true));
        assertFalse(SandwichDetector.detect(true, false, false, true, true));
    }

    function test_detect_falseWithoutIntervening() public pure {
        assertFalse(SandwichDetector.detect(true, true, false, false, true));
    }

    function test_detect_falseWhenVictimUnhurt() public pure {
        assertFalse(SandwichDetector.detect(true, true, false, true, false));
    }

    function test_fuzz_detect_exactlyWhenAllConditionsHold(
        bool prior,
        bool dirA,
        bool dirB,
        bool intervening,
        bool suffered
    ) public pure {
        bool expected = prior && dirA != dirB && intervening && suffered;
        assertEq(SandwichDetector.detect(prior, dirA, dirB, intervening, suffered), expected);
    }
}
