// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { BondManager } from "../../src/libraries/BondManager.sol";

contract BondManagerTest is Test {
    using BondManager for BondManager.Bond;

    BondManager.Bond internal b;

    uint256 constant EXT = 7_200;
    uint256 constant MIN_DURATION = 100;

    function setUp() public {
        b.amount = 100e6;
        b.depositBlock = 1_000;
        vm.roll(1_000);
    }

    // --- isRepeat ---

    function test_isRepeat_falseWithoutStrike() public view {
        assertFalse(b.isRepeat(EXT, block.number));
    }

    function test_isRepeat_trueInsideWindow() public {
        b.strikeCount = 1;
        b.lastStrikeBlock = 1_000;
        assertTrue(b.isRepeat(EXT, 1_000 + EXT - 1));
    }

    function test_isRepeat_falseAtWindowEnd() public {
        b.strikeCount = 1;
        b.lastStrikeBlock = 1_000;
        assertFalse(b.isRepeat(EXT, 1_000 + EXT));
    }

    function test_isRepeat_usesLastStrikeNotDeposit() public {
        b.strikeCount = 1;
        b.lastStrikeBlock = 5_000;
        b.depositBlock = 1_000;
        assertTrue(b.isRepeat(EXT, 5_000 + EXT - 1));
        assertFalse(b.isRepeat(EXT, 5_000 + EXT));
    }

    // --- maturityBlock ---

    function test_maturity_depositPlusMinDuration_whenUnstruck() public view {
        assertEq(b.maturityBlock(MIN_DURATION, EXT), 1_000 + MIN_DURATION);
    }

    function test_maturity_lastStrikePlusExtension_whenStruckLater() public {
        b.strikeCount = 1;
        b.lastStrikeBlock = 2_000;
        assertEq(b.maturityBlock(MIN_DURATION, EXT), 2_000 + EXT);
    }

    function test_maturity_takesLaterOfTheTwo() public {
        // Re-bonded long after an old strike: the deposit lock wins.
        b.strikeCount = 1;
        b.lastStrikeBlock = 10;
        b.depositBlock = 100_000;
        assertEq(b.maturityBlock(MIN_DURATION, EXT), 100_000 + MIN_DURATION);
    }

    // --- computeSlash ---

    function test_computeSlash_firstOffenseTakesBps() public view {
        assertEq(b.computeSlash(false, 5_000), 50e6);
        assertEq(b.computeSlash(false, 1_000), 10e6);
    }

    function test_computeSlash_repeatTakesAll() public view {
        assertEq(b.computeSlash(true, 5_000), 100e6);
    }

    function test_computeSlash_roundsDown() public {
        b.amount = 3;
        assertEq(b.computeSlash(false, 5_000), 1);
        b.amount = 1;
        assertEq(b.computeSlash(false, 5_000), 0);
    }

    function test_fuzz_slashBounds(uint128 amount, uint16 bps) public {
        bps = uint16(bound(bps, 0, 10_000));
        b.amount = amount;
        uint256 first = b.computeSlash(false, bps);
        uint256 repeat = b.computeSlash(true, bps);
        assertLe(first, amount);
        assertEq(repeat, amount);
        assertEq(first, (uint256(amount) * bps) / 10_000);
    }

    function test_fuzz_maturityNeverBeforeDepositLock(uint48 dep, uint48 strike, uint32 strikes)
        public
    {
        b.depositBlock = dep;
        b.lastStrikeBlock = strike;
        b.strikeCount = strikes;
        uint256 m = b.maturityBlock(MIN_DURATION, EXT);
        assertGe(m, uint256(dep) + MIN_DURATION);
        if (strikes > 0) assertGe(m, uint256(strike) + EXT);
    }
}
