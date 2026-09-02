// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IVadiumHook
/// @notice Public interface for the Vadium hook — bonding, detection, slashing, and the
///         LP insurance reserve.
///
/// @dev    A Vadium-enabled pool lets searchers post a bond (denominated in the pool's
///         token1) in exchange for a swap-fee discount. Searchers whose own on-chain
///         behavior matches a sandwich pattern within the same block get slashed, and
///         the slashed capital accumulates in a pooled insurance reserve. Authorized
///         actors push that reserve out to in-range LPs in discrete drip payouts.
interface IVadiumHook {
    // -------------------------------------------------------------------------
    // Bond lifecycle
    // -------------------------------------------------------------------------

    /// @notice Post a bond of `amount` units of the pool's token1.
    ///
    /// @dev    Transfers token1 from the caller to the hook. Reverts if `amount` is
    ///         below the current `minimumBond`. Bonding grants the fee discount and
    ///         starts the minimum-duration lock.
    ///
    /// @param amount  Amount of token1 to bond (in the token's native decimals).
    function bond(uint256 amount) external;

    /// @notice Withdraw the full bonded amount back to the caller.
    ///
    /// @dev    Reverts if the minimum duration has not elapsed, or if the caller is
    ///         currently banned. Only withdraws the *remaining* bond (slashed amounts
    ///         are already parked in the insurance reserve).
    function withdrawBond() external;

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Whether `searcher` currently holds a live bond and is eligible for
    ///         the fee discount.
    /// @param searcher  Address to check.
    /// @return true if bonded and not banned, false otherwise.
    function isBonded(address searcher) external view returns (bool);

    /// @notice Remaining bond balance of `searcher` (after any slashes).
    /// @param searcher  Address to check.
    /// @return Remaining bonded token1 amount.
    function bondedBalance(address searcher) external view returns (uint256);

    /// @notice Whether `searcher` is currently banned from re-bonding.
    /// @param searcher  Address to check.
    /// @return true if banned (until `bannedUntil`), false otherwise.
    function isBanned(address searcher) external view returns (bool);

    /// @notice Token1 currently held in the LP insurance reserve.
    function insuranceReserve() external view returns (uint256);

    /// @notice Live coverage still available to pay out.
    function remainingCoverage() external view returns (uint256);

    /// @notice Cumulative token1 slashed and credited into the insurance reserve.
    function slashedPledged() external view returns (uint256);

    /// @notice Cumulative token1 paid out of the reserve to LPs.
    function totalWithdrawn() external view returns (uint256);
}
