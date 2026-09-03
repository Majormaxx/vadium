// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";

import { VadiumHook } from "../../src/core/VadiumHook.sol";

/// @title TestVadiumHook
/// @notice Test harness that exposes VadiumHook internals for unit testing.
///
/// @dev    Overrides `_donate` to record the donation without touching the real
///         PoolManager (donate routing is covered by Integration.t.sol).
contract TestVadiumHook is VadiumHook {
    address public lastDonationRecipient;
    uint256 public lastDonationAmount;

    constructor(
        IPoolManager _poolManager,
        Currency _currency0,
        Currency _currency1,
        uint24 _fee,
        int24 _tickSpacing,
        address _owner
    ) VadiumHook(_poolManager, _currency0, _currency1, _fee, _tickSpacing, _owner) { }

    /// @dev Expose the internal swap-recording logic for unit testing.
    function recordSwap(address sender, bool zeroForOne) external {
        _recordSwap(sender, zeroForOne);
    }

    /// @dev Stub — records the donation amount and recipient without routing to the PoolManager.
    function _donate(uint256 amount1) internal override {
        lastDonationRecipient = address(poolManager);
        lastDonationAmount += amount1;
    }
}
