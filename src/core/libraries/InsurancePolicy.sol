// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title InsurancePolicy
/// @notice Stateless accounting for Vadium's LP insurance reserve.
///
/// @dev    When the hook slashes a searcher, the confiscated token1 is not handed to
///         LPs instantly. It is parked in a pooled reserve that accumulates across
///         many slashes. Only an authorized actor (owner or keeper) can push reserve
///         capital out to in-range LPs via a single PoolManager `unlock`. Pooling the
///         slashes into one reserve, and releasing them in discrete payouts, is what
///         makes the Reactive watchtower useful: an off-chain observer can flag an
///         address, and the payout it triggers is one atomic settlement instead of a
///         per-sandwich trickle.
///
/// @custom:security  Stateless library — no storage, no external calls. It only
///                   mutates the caller-supplied InsuranceState struct.
library InsurancePolicy {
    /// @notice Reverts when a requested payout exceeds the live reserve.
    error PayoutExceedsReserve(uint256 amount, uint256 reserve);

    // -------------------------------------------------------------------------
    // Insurance state
    // -------------------------------------------------------------------------

    /// @notice The pooled LP insurance fund.
    /// @param reserve          Token1 currently held as live coverage. Advances on each
    ///                         slash, shrinks on each payout.
    /// @param slashedPledged   Cumulative token1 slashed and credited into coverage.
    ///                         Monotonic; never decreases.
    /// @param withdrawn        Cumulative token1 paid out of the reserve to LPs.
    ///                         Monotonic; never exceeds `slashedPledged`.
    struct InsuranceState {
        uint256 reserve;
        uint256 slashedPledged;
        uint256 withdrawn;
    }

    // -------------------------------------------------------------------------
    // Credit (slash -> reserve)
    // -------------------------------------------------------------------------

    /// @notice Credit a slashed amount into the reserve.
    function credit(InsuranceState storage self, uint256 amount) internal {
        if (amount == 0) return;
        self.reserve += amount;
        self.slashedPledged += amount;
    }

    // -------------------------------------------------------------------------
    // Payout (reserve -> LPs)
    // -------------------------------------------------------------------------

    /// @notice Take `amount` out of the live reserve for an LP payout, after bounds
    ///         checks. Throws if the reserve cannot cover the requested payout.
    ///
    /// @return taken  The amount actually released (always `amount`, held in reserve).
    function take(InsuranceState storage self, uint256 amount) internal returns (uint256 taken) {
        if (amount == 0) revert("Vadium: zero payout");
        if (amount > self.reserve) revert PayoutExceedsReserve(amount, self.reserve);

        self.reserve -= amount;
        self.withdrawn += amount;

        return amount;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Live coverage still in the reserve.
    function remaining(InsuranceState storage self) internal view returns (uint256) {
        return self.reserve;
    }
}
