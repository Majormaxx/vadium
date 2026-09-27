// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title NativeLiquidityRouter
/// @notice Minimal LP router that adds liquidity to a native-ETH pool and settles
///         the negative deltas: native ETH from this contract's balance, token1
///         via transferFrom from the payer encoded in the callback data. Only used
///         by the AddLiquidity deploy script; not part of the hook security surface.
contract NativeLiquidityRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    address public immutable token1;

    constructor(IPoolManager _manager, address _token1) {
        manager = _manager;
        token1 = _token1;
    }

    /// @notice Packages an unlock call: payer is the token1 spender in the callback.
    function addLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "router: not PoolManager");
        (address payer, PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params) =
            abi.decode(data, (address, PoolKey, IPoolManager.ModifyLiquidityParams));

        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");

        // Native ETH (currency0) is settled first: v4's no-arg `settle{value}` takes
        // the native branch only while the synced-currency slot is still zero, so the
        // USDC `sync` below must not have run yet.
        if (delta.amount0() < 0) {
            manager.settle{value: uint256(int256(-delta.amount0()))}();
        }
        if (delta.amount1() < 0) {
            uint256 amt = uint256(int256(-delta.amount1()));
            // `sync` must record the balance BEFORE the transfer; `settle` then reads
            // the post-transfer balance and pays out the difference. Doing the
            // transfer first makes reservesBefore already include `amt`, so settle
            // pays zero and the token1 delta is left unsettled (CurrencyNotSettled).
            manager.sync(Currency.wrap(token1));
            IERC20Minimal(token1).transferFrom(payer, address(manager), amt);
            manager.settle();
        }
        return abi.encode(delta);
    }

    receive() external payable {}
}
