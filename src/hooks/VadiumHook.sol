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

import { IVadiumHook } from "../interfaces/IVadiumHook.sol";
import { IBondedFlow } from "../interfaces/IBondedFlow.sol";
import { BondedFlow } from "../base/BondedFlow.sol";
import { BlockPriceClamp } from "../base/BlockPriceClamp.sol";
import { ReactiveFlagReceiver } from "../base/ReactiveFlagReceiver.sol";
import { ClampMath } from "../libraries/ClampMath.sol";
import { FeeDiscount } from "../libraries/FeeDiscount.sol";

/// @title VadiumHook
/// @notice Accountable arbitrage for Uniswap v4 pools.
///
///         Unbonded flow is clamped: no swap in a block executes at a better price than
///         the pool offered at the start of that block, so a sandwich cannot capture
///         its victim's price impact, whether the legs share an address or not. Bonded
///         flow is exempt and trades at the real price, because it is slashable: a
///         bonded address that completes a same-block sandwich around a swap that was
///         hurt loses part of its bond, the victim is refunded first, and the rest funds
///         the pool's LP insurance reserve.
///
///         The bond therefore buys the right to arbitrage the pool within the block,
///         which is what keeps the block-start price tracking the market. Bonded
///         arbitrageurs are the only agents who move it; everyone else follows with one
///         block of lag.
///
/// @dev    Composition of `BondedFlow` (bonds, strikes, reserves, refunds, roles),
///         `BlockPriceClamp` (checkpoint, withhold, flush) and `ReactiveFlagReceiver`
///         (cross-chain flags). The hook serves any number of pools that the owner
///         pre-registers; each must contain the bond token.
///
///         Permissions: `beforeInitialize`, `beforeSwap`, `afterSwap`,
///         `afterSwapReturnDelta`. The address must carry mask `0x20C4`.
///
/// @custom:security  Unaudited. See `docs/THREAT-MODEL.md` for the trust assumptions
///                   and the disclosed holes.
contract VadiumHook is IVadiumHook, IHooks, SafeCallback, ReactiveFlagReceiver, BlockPriceClamp {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    /// @param _poolManager   The Uniswap v4 PoolManager.
    /// @param _bondToken     ERC-20 bonds and reserves are denominated in.
    /// @param _owner         Initial owner. Passed explicitly because a CREATE2 broadcast
    ///                       makes `msg.sender` the factory.
    /// @param _callbackProxy Reactive Network callback proxy on this chain.
    /// @param _params        Initial bond economics.
    constructor(
        IPoolManager _poolManager,
        IERC20 _bondToken,
        address _owner,
        address _callbackProxy,
        IBondedFlow.BondParams memory _params
    )
        SafeCallback(_poolManager)
        BondedFlow(_bondToken, _owner, _params)
        ReactiveFlagReceiver(_callbackProxy)
    {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ---------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------

    /// @inheritdoc IVadiumHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // IHooks: initialize
    // ---------------------------------------------------------------------

    /// @notice Only pre-registered pools may be initialized with this hook.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        _bfBeforeInitialize(key);
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    // ---------------------------------------------------------------------
    // IHooks: swap
    // ---------------------------------------------------------------------

    /// @notice Checkpoint the pool on the first swap of a block and, on a dynamic-fee
    ///         pool, override the fee: the base fee for everyone, the discounted fee for
    ///         an exempt sender.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24 overrideFee) {
        PoolId id = key.toId();
        PoolState storage p = _pools[id];
        if (!p.registered) revert PoolNotRegistered();

        uint24 base = _unbondedFee(p);
        _clampCheckpoint(key, base);

        if (key.fee.isDynamicFee()) {
            uint24 fee = base;
            if (p.cfg.feeDiscountBps > 0 && _isExempt(id, sender)) {
                fee = FeeDiscount.discountedFee(base, p.cfg.feeDiscountBps);
            }
            overrideFee = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overrideFee);
    }

    /// @notice Clamp a non-exempt sender to the block-start price, measure the swap's
    ///         shortfall, and run sandwich detection against the previous swap.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        return (
            IHooks.afterSwap.selector,
            _afterSwap(sender, key, params, delta, _victimKey(sender, hookData))
        );
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        address victimKey
    ) private returns (int128) {
        PoolId id = key.toId();
        // Exemption is evaluated before the swap is recorded, so "first swap in the
        // block" refers to the swaps before this one.
        ClampResult memory r = _clampAfterSwap(key, sender, params, delta, _isExempt(id, sender));
        _bfRecordSwap(id, sender, params.zeroForOne, victimKey, _shortfallInBond(id, r));
        return r.hookDelta;
    }

    /// @dev The swap's shortfall converted to bond-token units at the checkpoint price.
    function _shortfallInBond(PoolId id, ClampResult memory r) private view returns (uint256) {
        if (r.shortfall == 0) return 0;
        return ClampMath.toBondUnits(
            r.shortfall, r.unspecifiedIs0, _pools[id].bondIsCurrency0, r.sqrtPriceX96
        );
    }

    /// @dev A router may attribute the swap to a principal by passing exactly 32 bytes
    ///      of hookData holding an address; a refund for this swap is then credited
    ///      there. The exemption never reads hookData, so a router cannot borrow a
    ///      bonded principal's privilege. A router that lies only redirects its own
    ///      user's refund.
    function _victimKey(address sender, bytes calldata hookData) private pure returns (address) {
        if (hookData.length != 32) return sender;
        return address(uint160(uint256(bytes32(hookData[0:32]))));
    }

    // ---------------------------------------------------------------------
    // IHooks: unused callbacks (pure selectors)
    // ---------------------------------------------------------------------

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

    // ---------------------------------------------------------------------
    // Unlock dispatch and base wiring
    // ---------------------------------------------------------------------

    /// @dev Reserve payouts and flushes both run inside a PoolManager unlock; the
    ///      payload's first word says which.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (uint8 kind, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (kind == UNLOCK_KIND_PAYOUT) return _bfUnlockCallback(payload);
        if (kind == UNLOCK_KIND_FLUSH) return _clampUnlockCallback(payload);
        revert UnknownUnlockKind();
    }

    function _clampEnabled(PoolId poolId) internal view override returns (bool) {
        return _pools[poolId].cfg.clampEnabled;
    }

    function _clampPaused() internal view override returns (bool) {
        return paused();
    }

    function _clampPoolKey(PoolId poolId) internal view override returns (PoolKey memory) {
        return poolKeyOf(poolId);
    }
}
