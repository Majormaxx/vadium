// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";

import { VadiumHook } from "../../src/hooks/VadiumHook.sol";
import { IBondedFlow } from "../../src/interfaces/IBondedFlow.sol";

/// @title TestVadiumHook
/// @notice Test harness that exposes the base's swap-recording entrypoint and stubs the
///         reserve donation so unit tests can run without a live pool.
contract TestVadiumHook is VadiumHook {
    address public lastDonationRecipient;
    uint256 public lastDonationAmount0;
    uint256 public lastDonationAmount1;

    constructor(
        IPoolManager _poolManager,
        IERC20 _bondToken,
        address _owner,
        address _callbackProxy,
        IBondedFlow.BondParams memory _params
    ) VadiumHook(_poolManager, _bondToken, _owner, _callbackProxy, _params) { }

    /// @dev Drive the detector directly, as `afterSwap` would.
    function recordSwap(
        PoolId poolId,
        address sender,
        bool zeroForOne,
        address victimKey,
        uint256 victimShortfallBond
    ) external returns (uint256 slashed) {
        return _bfRecordSwap(poolId, sender, zeroForOne, victimKey, victimShortfallBond);
    }

    /// @dev Records the donation instead of routing it through the PoolManager.
    function _donate(PoolKey memory, uint256 amount0, uint256 amount1) internal override {
        lastDonationRecipient = address(poolManager);
        lastDonationAmount0 += amount0;
        lastDonationAmount1 += amount1;
    }
}
