// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SandwichDetector
/// @notice Pure sandwich-pattern detection for a single Uniswap v4 pool.
///
/// @dev    Every swap against a given pool passes through that pool's hook in the same
///         order the swaps are included in the block, so the hook has fully ordered,
///         same-block visibility into every swap hitting its own pool.
///
///         The detector flags the buildable subset of a sandwich: same-address,
///         same-block, direction-reversal with an intervening swap from a different
///         address. This mirrors the dominant real-world sandwich pattern, where a
///         searcher front-runs a victim, the victim swaps, and the searcher back-runs.
///
///         It is explicitly NOT a full sandwich detector: it cannot see the mempool,
///         other pools, or cross-block spreads, and it is evadable by mule addresses
///         (two different bonded addresses per leg). See the repo README's Adversarial
///         Analysis for the stated scope cuts.
///
/// @custom:security  Pure library — the verdict depends only on its inputs. All state
///                   sequencing is the caller's responsibility.
library SandwichDetector {
    // -------------------------------------------------------------------------
    // Detection
    // -------------------------------------------------------------------------

    /// @notice Evaluate whether the current swap completes a sandwich pattern.
    ///
    /// @dev    The caller must only pass `interveningDifferent = true` when a swap from
    ///         an address different than the current sender was recorded strictly
    ///         between the sender's prior swap and the current swap in block order.
    ///
    /// @param hadPriorSameBlock  Whether the sender already swapped earlier in this
    ///                           exact block (prior record exists and matches the
    ///                           current block number).
    /// @param priorDirection     Direction (zeroForOne) of the sender's prior swap.
    /// @param currentDirection   Direction (zeroForOne) of the current swap.
    /// @param interveningDifferent  Whether a different-address swap sits strictly
    ///                           between the sender's prior swap and this one.
    ///
    /// @return verdict           true if the current swap completes a same-address,
    ///                           same-block, opposite-direction sandwich with an
    ///                           intervening different-address swap.
    function detect(
        bool hadPriorSameBlock,
        bool priorDirection,
        bool currentDirection,
        bool interveningDifferent
    ) internal pure returns (bool verdict) {
        // The two legs must both happen in this exact block.
        if (!hadPriorSameBlock) return false;

        // The two legs must be in opposite directions (buy then sell, or vice versa).
        if (priorDirection == currentDirection) return false;

        // Some other address must have swapped strictly between the two legs.
        if (!interveningDifferent) return false;

        verdict = true;
    }
}
