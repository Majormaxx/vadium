// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Derived from OpenZeppelin uniswap-hooks v1.2.2 `AntiSandwichHook` and
// `BaseDynamicAfterFee` (MIT). Changes: the checkpoint is a static snapshot instead of
// a mutating shadow pool, both swap directions are clamped, the target is computed in
// O(1) from the filled amount after the swap instead of a simulated `Pool.swap` before
// it, and hosts can exempt a sender.

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { SafeCast } from "v4-core/src/libraries/SafeCast.sol";
import { ImmutableState } from "v4-periphery/src/base/ImmutableState.sol";

import { IBlockPriceClamp } from "../interfaces/IBlockPriceClamp.sol";
import { ClampMath } from "../libraries/ClampMath.sol";

/// @title BlockPriceClamp
/// @notice Composable base that holds clamped swaps to the block-start price.
///
/// @dev    At the first swap of a block the host calls `_clampCheckpoint`, which snapshots
///         the pool's sqrt price, in-range liquidity, and fees. In `afterSwap` the host
///         calls `_clampAfterSwap`, which computes what the swap would have moved at the
///         checkpoint price and, for a non-exempt sender, withholds any gain beyond it as
///         ERC-6909 claims owned by the hook. The withheld claims are later donated to
///         the pool's LPs by anyone via `flushWithheld`.
///
///         The same computation yields the swap's shortfall (how much worse than block
///         start it executed), which the host feeds to its sandwich detector as the
///         victim-loss signal.
///
///         Because the checkpoint is static, an exempt sender that moves the price does
///         not move the reference for later clamped swaps in the same block: they get
///         the worse of block-start and current price, and LPs receive the difference.
///         The next block's checkpoint includes the move.
abstract contract BlockPriceClamp is IBlockPriceClamp, ImmutableState {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    /// @notice Unlock payload discriminator for a flush.
    uint8 internal constant UNLOCK_KIND_FLUSH = 2;

    /// @notice Result of `_clampAfterSwap` for the host.
    /// @param hookDelta      Amount the host must return from `afterSwap` (already minted
    ///                       as claims).
    /// @param shortfall      How much worse than block start the swap executed, in the
    ///                       unspecified currency. 0 when it did not suffer.
    /// @param unspecifiedIs0 Whether the unspecified currency is currency0.
    /// @param sqrtPriceX96   The checkpoint price, for unit conversion by the host.
    struct ClampResult {
        int128 hookDelta;
        uint256 shortfall;
        bool unspecifiedIs0;
        uint160 sqrtPriceX96;
    }

    mapping(PoolId => Checkpoint) internal _checkpoints;

    /// @inheritdoc IBlockPriceClamp
    mapping(PoolId => mapping(Currency => uint256)) public override withheld;

    // ---------------------------------------------------------------------
    // Host integration points
    // ---------------------------------------------------------------------

    /// @notice Snapshot the pool at the first swap of a block. No-op afterwards.
    /// @param key         The pool.
    /// @param unbondedFee Fee an unbonded swapper pays on this pool, in pips.
    function _clampCheckpoint(PoolKey calldata key, uint24 unbondedFee) internal {
        PoolId id = key.toId();
        Checkpoint storage cp = _checkpoints[id];
        if (cp.blockNumber == uint48(block.number)) return;

        (uint160 sqrtPriceX96,, uint24 protocolFee,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);

        cp.blockNumber = uint48(block.number);
        cp.sqrtPriceX96 = sqrtPriceX96;
        cp.liquidity = liquidity;
        cp.fee = unbondedFee;
        cp.protocolFee = protocolFee;
        emit Checkpointed(id, uint48(block.number), sqrtPriceX96, liquidity);
    }

    /// @notice Compare the real execution with the block-start target and withhold any
    ///         gain from a clamped sender.
    /// @param key     The pool.
    /// @param sender  The swapper.
    /// @param params  Swap parameters.
    /// @param delta   The swap's balance delta as the PoolManager reports it.
    /// @param exempt  Whether the sender is exempt from the clamp.
    function _clampAfterSwap(
        PoolKey calldata key,
        address sender,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bool exempt
    ) internal returns (ClampResult memory r) {
        PoolId id = key.toId();
        Checkpoint memory cp = _checkpoints[id];
        r.sqrtPriceX96 = cp.sqrtPriceX96;

        bool exactInput = params.amountSpecified < 0;
        bool specifiedIs0 = params.zeroForOne == exactInput;
        r.unspecifiedIs0 = !specifiedIs0;

        (uint256 filled, uint256 actual) = _amounts(delta, specifiedIs0);
        if (filled == 0 || cp.liquidity == 0) return r;

        uint256 target = _targetUnspecified(cp, params.zeroForOne, exactInput, filled);
        (uint256 excess, uint256 shortfall) = ClampMath.split(exactInput, actual, target);
        r.shortfall = shortfall;

        if (excess == 0 || exempt || !_clampEnabled(id)) return r;

        Currency unspecified = specifiedIs0 ? key.currency1 : key.currency0;
        poolManager.mint(address(this), unspecified.toId(), excess);
        withheld[id][unspecified] += excess;
        emit ClampWithheld(id, sender, unspecified, excess);
        r.hookDelta = excess.toInt128();
    }

    /// @dev Absolute specified and unspecified amounts the swap moved.
    function _amounts(BalanceDelta delta, bool specifiedIs0)
        private
        pure
        returns (uint256 filled, uint256 actual)
    {
        int128 spec = specifiedIs0 ? delta.amount0() : delta.amount1();
        int128 unspec = specifiedIs0 ? delta.amount1() : delta.amount0();
        filled = spec < 0 ? uint256(uint128(-spec)) : uint256(uint128(spec));
        actual = unspec < 0 ? uint256(uint128(-unspec)) : uint256(uint128(unspec));
    }

    /// @notice What the swap would have moved at the checkpoint. Constant-liquidity by
    ///         default; override for a tick-walking target.
    function _targetUnspecified(
        Checkpoint memory cp,
        bool zeroForOne,
        bool exactInput,
        uint256 filledSpecified
    ) internal view virtual returns (uint256) {
        uint24 fee = ClampMath.swapFee(cp.fee, cp.protocolFee, zeroForOne);
        return ClampMath.targetUnspecified(
            cp.sqrtPriceX96, cp.liquidity, fee, zeroForOne, exactInput, filledSpecified
        );
    }

    /// @notice Whether the clamp withholds on this pool. Hosts override per pool.
    function _clampEnabled(PoolId) internal view virtual returns (bool) {
        return true;
    }

    /// @notice Whether flushing is paused. Hosts override.
    function _clampPaused() internal view virtual returns (bool) {
        return false;
    }

    /// @notice The pool key for a pool this hook serves. Hosts implement from their registry.
    function _clampPoolKey(PoolId poolId) internal view virtual returns (PoolKey memory);

    // ---------------------------------------------------------------------
    // Flush
    // ---------------------------------------------------------------------

    /// @inheritdoc IBlockPriceClamp
    function flushWithheld(PoolId poolId)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        if (_clampPaused()) revert ClampPaused();
        PoolKey memory key = _clampPoolKey(poolId);
        amount0 = withheld[poolId][key.currency0];
        amount1 = withheld[poolId][key.currency1];
        if (amount0 == 0 && amount1 == 0) revert NothingToFlush();
        if (poolManager.getLiquidity(poolId) == 0) revert NoLiquidityToReceive();

        withheld[poolId][key.currency0] = 0;
        withheld[poolId][key.currency1] = 0;
        poolManager.unlock(
            abi.encode(UNLOCK_KIND_FLUSH, abi.encode(PoolId.unwrap(poolId), amount0, amount1))
        );
        emit WithheldFlushed(poolId, amount0, amount1);
    }

    /// @notice Executes a flush inside the PoolManager unlock: donate, then burn the
    ///         claims that back the donation. The host routes its `_unlockCallback` here
    ///         for `UNLOCK_KIND_FLUSH`.
    function _clampUnlockCallback(bytes memory payload) internal virtual returns (bytes memory) {
        (bytes32 idRaw, uint256 amount0, uint256 amount1) =
            abi.decode(payload, (bytes32, uint256, uint256));
        PoolKey memory key = _clampPoolKey(PoolId.wrap(idRaw));
        poolManager.donate(key, amount0, amount1, "");
        if (amount0 > 0) poolManager.burn(address(this), key.currency0.toId(), amount0);
        if (amount1 > 0) poolManager.burn(address(this), key.currency1.toId(), amount1);
        return abi.encode(amount0, amount1);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IBlockPriceClamp
    function checkpoint(PoolId poolId) external view override returns (Checkpoint memory) {
        return _checkpoints[poolId];
    }
}
