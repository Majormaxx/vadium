// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title BondManager
/// @notice Stateless helpers for two-tier bond slashing, strike escalation, and bond
///         maturity.
///
/// @dev    The slash policy is calibrated against false positives: a same-block,
///         same-address, direction-reversal pattern around a swap that got a worse
///         price is a strong sandwich signal but not proof beyond doubt. So a first
///         strike slashes only a portion of the bond, and only a repeat strike while
///         the previous strike's window is still open escalates to a full slash plus
///         a re-bonding ban. Strikes never reset: withdrawing and re-bonding does not
///         launder a record.
///
/// @custom:security  Stateless library. All functions are `internal view/pure` and
///                   operate on the caller's Bond struct.
library BondManager {
    /// @notice A searcher's live bond and strike record. Packed into two slots.
    /// @param amount           Remaining bonded amount (post-slashes).
    /// @param depositBlock     Block the current bond was posted.
    /// @param bannedUntil      Block after which the address may bond again. 0 = never banned.
    /// @param strikeCount      Lifetime strikes recorded against the address.
    /// @param lastStrikeBlock  Block of the most recent strike. 0 = no strike yet.
    struct Bond {
        uint128 amount;
        uint48 depositBlock;
        uint48 bannedUntil;
        uint32 strikeCount;
        uint48 lastStrikeBlock;
    }

    /// @notice Whether a strike at `currentBlock` is a repeat offense: a prior strike
    ///         exists and its escalation window (`extension` blocks) is still open.
    function isRepeat(Bond storage self, uint256 extension, uint256 currentBlock)
        internal
        view
        returns (bool)
    {
        return self.strikeCount > 0 && currentBlock < uint256(self.lastStrikeBlock) + extension;
    }

    /// @notice Block at which the bond may be withdrawn: the later of the deposit
    ///         lock and, when struck, the last strike plus the escalation window.
    function maturityBlock(Bond storage self, uint256 minDuration, uint256 extension)
        internal
        view
        returns (uint256 maturity)
    {
        maturity = uint256(self.depositBlock) + minDuration;
        if (self.strikeCount > 0) {
            uint256 struck = uint256(self.lastStrikeBlock) + extension;
            if (struck > maturity) maturity = struck;
        }
    }

    /// @notice Compute the slashed amount for a violation.
    /// @param self           The bond being slashed.
    /// @param isRepeat_      True for a repeat violation inside the open window.
    /// @param firstSlashBps  Portion slashed on a first offense, in bps (5000 = 50%).
    /// @return slashed       Amount to confiscate from the bond.
    function computeSlash(Bond storage self, bool isRepeat_, uint256 firstSlashBps)
        internal
        view
        returns (uint256 slashed)
    {
        if (isRepeat_) return self.amount;
        return (uint256(self.amount) * firstSlashBps) / 10_000;
    }
}
