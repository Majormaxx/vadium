// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { IERC20Minimal } from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title NativeLiquidityRouter
/// @notice Minimal LP router for a native-ETH pool. The router holds the position; its
///         owner can add liquidity (paying ETH from the router's balance and token1 via
///         transferFrom) and remove it (receiving both tokens back). Used by the
///         liquidity scripts and the fork tests; not part of the hook's security surface.
contract NativeLiquidityRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    address public immutable token1;
    address public immutable owner;

    error NotOwner();
    error NotPoolManager();
    error NativeTransferFailed();

    constructor(IPoolManager _manager, address _token1, address _owner) {
        manager = _manager;
        token1 = _token1;
        owner = _owner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Add liquidity. The caller pays token1; ETH comes from this contract.
    function addLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        onlyOwner
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
    }

    /// @notice Remove liquidity. Both tokens are paid out to the owner.
    function removeLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        onlyOwner
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        (address payer, PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params) =
            abi.decode(data, (address, PoolKey, IPoolManager.ModifyLiquidityParams));

        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");

        // Native ETH (currency0) first: v4's no-arg `settle{value}` takes the native
        // branch only while the synced-currency slot is still zero.
        if (delta.amount0() < 0) {
            manager.settle{ value: uint256(int256(-delta.amount0())) }();
        } else if (delta.amount0() > 0) {
            manager.take(key.currency0, payer, uint256(int256(delta.amount0())));
        }
        if (delta.amount1() < 0) {
            uint256 amt = uint256(int256(-delta.amount1()));
            // `sync` records the balance before the transfer; `settle` pays the difference.
            manager.sync(Currency.wrap(token1));
            IERC20Minimal(token1).transferFrom(payer, address(manager), amt);
            manager.settle();
        } else if (delta.amount1() > 0) {
            manager.take(key.currency1, payer, uint256(int256(delta.amount1())));
        }
        return abi.encode(delta);
    }

    /// @notice Return the router's ETH balance to the owner.
    function withdrawNative() external onlyOwner {
        (bool ok,) = owner.call{ value: address(this).balance }("");
        if (!ok) revert NativeTransferFailed();
    }

    receive() external payable { }
}
