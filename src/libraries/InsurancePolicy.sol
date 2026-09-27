// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title InsurancePolicy
/// @notice Stateless accounting for a pool's LP insurance reserve.
///
/// @dev    Slashed bond capital is not handed to LPs per sandwich. It accumulates in a
///         per-pool reserve, and an authorized actor pushes it out in bounded
///         settlements through a single PoolManager `unlock`.
///
///         Invariants: `reserve == slashedPledged - withdrawn` and
///         `withdrawn <= slashedPledged`.
///
/// @custom:security  Stateless library. It only mutates the caller-supplied struct.
library InsurancePolicy {
    /// @notice Reverts when a requested payout exceeds the live reserve.
    error PayoutExceedsReserve(uint256 amount, uint256 reserve);

    /// @notice Reverts when a payout of zero is requested.
    error ZeroPayout();

    /// @notice A pool's insurance fund.
    /// @param reserve          Capital currently held as live coverage.
    /// @param slashedPledged   Cumulative capital credited into coverage. Monotonic.
    /// @param withdrawn        Cumulative capital paid out to LPs. Monotonic.
    struct InsuranceState {
        uint256 reserve;
        uint256 slashedPledged;
        uint256 withdrawn;
    }

    /// @notice Credit slashed capital into the reserve.
    function credit(InsuranceState storage self, uint256 amount) internal {
        if (amount == 0) return;
        self.reserve += amount;
        self.slashedPledged += amount;
    }

    /// @notice Take `amount` out of the live reserve for an LP payout.
    /// @return taken  The amount released (always `amount`).
    function take(InsuranceState storage self, uint256 amount) internal returns (uint256 taken) {
        if (amount == 0) revert ZeroPayout();
        if (amount > self.reserve) revert PayoutExceedsReserve(amount, self.reserve);

        self.reserve -= amount;
        self.withdrawn += amount;
        return amount;
    }

    /// @notice Live coverage still in the reserve.
    function remaining(InsuranceState storage self) internal view returns (uint256) {
        return self.reserve;
    }
}
