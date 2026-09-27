// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { SafeCallback } from "v4-periphery/src/base/SafeCallback.sol";

import { IBondedFlow } from "../interfaces/IBondedFlow.sol";
import { BondedFlow } from "../base/BondedFlow.sol";
import { FeeDiscount } from "../libraries/FeeDiscount.sol";

/// @title ExampleBondedHook
/// @notice The smallest hook that composes `BondedFlow`: a dynamic-fee pool where
///         bonded, unflagged addresses pay 5 bps less than everyone else, and a bonded
///         address that reverses direction around another swapper in the same block is
///         slashed into the pool's reserve.
///
/// @dev    No clamp, no victim-loss measurement, so pools should be registered with
///         `requireVictimLoss = false`. The four integration points with the base are
///         marked below; the rest is `IHooks` boilerplate.
contract ExampleBondedHook is IHooks, SafeCallback, BondedFlow {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    uint24 public constant DISCOUNT_BPS = 5;

    constructor(
        IPoolManager _poolManager,
        IERC20 _bondToken,
        address _owner,
        IBondedFlow.BondParams memory _params
    ) SafeCallback(_poolManager) BondedFlow(_bondToken, _owner, _params) {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    // Integration point 1: only registered pools.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        _bfBeforeInitialize(key);
        return IHooks.beforeInitialize.selector;
    }

    // Integration point 2: the privilege is a fee discount for exempt senders.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24 overrideFee) {
        PoolId id = key.toId();
        uint24 base = _pools[id].cfg.baseFee;
        uint24 fee = _isExempt(id, sender) ? FeeDiscount.discountedFee(base, DISCOUNT_BPS) : base;
        overrideFee = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overrideFee);
    }

    // Integration point 3: record every swap; the base detects and slashes.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _bfRecordSwap(key.toId(), sender, params.zeroForOne, sender, 0);
        return (IHooks.afterSwap.selector, 0);
    }

    // Integration point 4: reserve payouts run through the base's unlock handler.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (uint8 kind, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (kind == UNLOCK_KIND_PAYOUT) return _bfUnlockCallback(payload);
        revert UnknownUnlockKind();
    }

    // ---- IHooks boilerplate ------------------------------------------------

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
