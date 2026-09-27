// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IBondedFlow } from "../interfaces/IBondedFlow.sol";

/// @title BondParamsLib
/// @notice Default bond parameters and their bounds.
///
/// @dev    Block counts assume Unichain's one-second blocks. A host on a chain with a
///         different cadence passes its own parameters; the bounds are generous enough
///         for twelve-second chains as well.
library BondParamsLib {
    /// @notice Upper bound on any lock or window: one year of one-second blocks.
    uint256 internal constant MAX_WINDOW_BLOCKS = 31_536_000;

    /// @notice Reference parameters for a USDC-bonded pool on Unichain.
    /// @return p  100 USDC minimum, 2-hour lock, 50% first slash, 1-day escalation
    ///            window, 30-day ban, 50% of a slash refundable to the victim, 30-day
    ///            refund claim window.
    function unichainDefaults() internal pure returns (IBondedFlow.BondParams memory p) {
        p.minBond = 100e6;
        p.minBondDurationBlocks = 7_200;
        p.firstSlashBps = 5_000;
        p.firstOffenseLockExtensionBlocks = 86_400;
        p.repeatOffenseBanBlocks = 2_592_000;
        p.victimRefundBps = 5_000;
        p.refundClaimWindowBlocks = 2_592_000;
    }

    /// @notice Whether a parameter set is within bounds.
    function isValid(IBondedFlow.BondParams memory p) internal pure returns (bool) {
        if (p.minBond == 0) return false;
        if (p.minBondDurationBlocks == 0 || p.minBondDurationBlocks > MAX_WINDOW_BLOCKS) {
            return false;
        }
        if (p.firstSlashBps > 10_000) return false;
        if (
            p.firstOffenseLockExtensionBlocks == 0
                || p.firstOffenseLockExtensionBlocks > MAX_WINDOW_BLOCKS
        ) {
            return false;
        }
        if (p.repeatOffenseBanBlocks > MAX_WINDOW_BLOCKS) return false;
        if (p.victimRefundBps > 10_000) return false;
        if (p.refundClaimWindowBlocks == 0 || p.refundClaimWindowBlocks > MAX_WINDOW_BLOCKS) {
            return false;
        }
        return true;
    }
}
