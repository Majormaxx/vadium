// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SandwichDetector
/// @notice Pure sandwich-pattern detection for one Uniswap v4 pool.
///
/// @dev    Every swap against a pool passes through that pool's hook in block order,
///         so the hook has fully ordered same-block visibility into its own pool.
///
///         The detector flags the buildable subset of a sandwich: the same address
///         reverses direction within one block, a different address swapped strictly
///         between the two legs, and (when the host requires it) that intervening swap
///         got a worse price than the block-start price. The last condition is what
///         separates a front-run from a market maker reversing around an unrelated
///         trade that was not hurt.
///
///         It is explicitly not a full detector: no mempool, no cross-pool, no
///         cross-block, and evadable by splitting the legs across two addresses.
///
/// @custom:security  Pure library. The verdict depends only on its inputs.
library SandwichDetector {
    /// @notice Evaluate whether the current swap completes a sandwich pattern.
    /// @param hadPriorSameBlock    The sender already swapped earlier in this block.
    /// @param priorDirection       Direction (zeroForOne) of the sender's prior swap.
    /// @param currentDirection     Direction (zeroForOne) of the current swap.
    /// @param interveningDifferent A different address swapped strictly between the legs.
    /// @param victimSuffered       The intervening swap executed worse than block start
    ///                             (or the host does not require that evidence).
    function detect(
        bool hadPriorSameBlock,
        bool priorDirection,
        bool currentDirection,
        bool interveningDifferent,
        bool victimSuffered
    ) internal pure returns (bool verdict) {
        if (!hadPriorSameBlock) return false;
        if (priorDirection == currentDirection) return false;
        if (!interveningDifferent) return false;
        if (!victimSuffered) return false;
        verdict = true;
    }
}
