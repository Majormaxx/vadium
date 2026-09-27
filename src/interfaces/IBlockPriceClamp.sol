// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";

/// @title IBlockPriceClamp
/// @notice Block-start price clamp: no clamped swap in a block executes at a better
///         price than the pool offered at the start of that block. The gain is withheld
///         as ERC-6909 claims and later donated to the pool's LPs.
interface IBlockPriceClamp {
    /// @notice Pool state captured at the first swap of a block.
    /// @param blockNumber   Block the checkpoint belongs to.
    /// @param sqrtPriceX96  Pool sqrt price at block start.
    /// @param liquidity     In-range liquidity at block start.
    /// @param fee           Fee an unbonded swapper pays on this pool, in pips.
    /// @param protocolFee   Packed protocol fee at block start.
    struct Checkpoint {
        uint48 blockNumber;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint24 fee;
        uint24 protocolFee;
    }

    event Checkpointed(
        PoolId indexed poolId, uint48 blockNumber, uint160 sqrtPriceX96, uint128 liquidity
    );
    event ClampWithheld(
        PoolId indexed poolId, address indexed sender, Currency currency, uint256 amount
    );
    event WithheldFlushed(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    error NothingToFlush();
    error NoLiquidityToReceive();
    error ClampPaused();

    /// @notice Donate all withheld claims for `poolId` to its in-range LPs.
    function flushWithheld(PoolId poolId) external returns (uint256 amount0, uint256 amount1);

    function checkpoint(PoolId poolId) external view returns (Checkpoint memory);
    function withheld(PoolId poolId, Currency currency) external view returns (uint256);
}
