// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title BondManager
/// @notice Stateless helpers for Vadium's two-tier bond slashing and bond expiry.
///
/// @dev    The slash policy is intentionally calibrated against false positives:
///         a same-block, same-address, opposite-direction pattern is a strong
///         sandwich signal but not proof beyond doubt (a market maker rebalancing
///         could occasionally trigger it). So the first flag slashes only a portion
///         of the bond, and only a repeat violation within an active lock window
///         results in a full slash plus a re-bonding ban.
///
/// @custom:security  Stateless library — no storage, no reentrancy, no external calls.
///                   All functions are `internal view/pure` and operate on the caller's
///                   Bond struct.
library BondManager {
    // -------------------------------------------------------------------------
    // Bond struct
    // -------------------------------------------------------------------------

    /// @notice A searcher's live bond.
    /// @param amount           Remaining bonded amount in token1 (post-slashes).
    /// @param depositBlock     Block the bond (or the latest lock extension) landed.
    /// @param bannedUntil      Block after which the address may re-bond. 0 = not banned.
    /// @param strikeCount      Number of slashing strikes recorded in the lock window.
    struct Bond {
        uint256 amount;
        uint256 depositBlock;
        uint256 bannedUntil;
        uint256 strikeCount;
    }

    // -------------------------------------------------------------------------
    // Expiry
    // -------------------------------------------------------------------------

    /// @notice Whether a bond's minimum duration has elapsed.
    ///
    /// @param self            The bond to check.
    /// @param minDuration     Minimum lock duration in blocks.
    /// @param currentBlock    Current block number.
    ///
    /// @return true once `currentBlock >= depositBlock + minDuration`.
    function isMatured(Bond storage self, uint256 minDuration, uint256 currentBlock)
        internal
        view
        returns (bool)
    {
        return currentBlock >= self.depositBlock + minDuration;
    }

    /// @notice Whether the bond's lock was extended to cover the current block.
    ///
    /// @dev    First offenses extend the minimum-duration window by `extension` blocks
    ///         without raising the full slash to 100%. A second strike while this
    ///         extended lock is still active is what escalates to a full slash.
    ///
    /// @return true while `currentBlock < depositBlock + extension`.
    function isWithinExtendedLock(Bond storage self, uint256 extension, uint256 currentBlock)
        internal
        view
        returns (bool)
    {
        return currentBlock < self.depositBlock + extension;
    }

    // -------------------------------------------------------------------------
    // Slash math
    // -------------------------------------------------------------------------

    /// @notice Compute the slashed amount for a violation.
    ///
    /// @dev    Whether a strike is a "repeat" is decided on-chain by the caller:
    ///         `strikeCount > 0 && isWithinExtendedLock(...)` means the address is
    ///         still inside the window of a prior first offense, so the full slash
    ///         applies. Otherwise it is a first offense and only `firstSlashBps`
    ///         is taken.
    ///
    /// @param self           The bond being slashed.
    /// @param isRepeat       True for a repeat violation within the active lock window.
    /// @param firstSlashBps  Portion of the bond slashed on first offense, in bps
    ///                       (5000 = 50%).
    ///
    /// @return slashed       Token1 amount to confiscate from the bond.
    function computeSlash(Bond storage self, bool isRepeat, uint256 firstSlashBps)
        internal
        view
        returns (uint256 slashed)
    {
        if (isRepeat) return self.amount; // full slash of the remaining bond

        return (self.amount * firstSlashBps) / 10_000;
    }
}
