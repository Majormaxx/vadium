// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";

import { IBondedFlow } from "../../src/interfaces/IBondedFlow.sol";

/// @title SimSwapRouter
/// @notice A one-owner swap router that is also a bonded identity. The hook sees this
///         contract as `sender`, so bonding here and swapping through here is how one
///         actor holds one accountable identity. Native currency is paid from
///         `msg.value`; ERC-20s are pulled from the owner; outputs go to the owner.
///         Used by the simulator and by anyone who wants a private router; not part of
///         the hook's security surface.
contract SimSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;
    address public immutable owner;

    error NotOwner();
    error NotPoolManager();
    error NativeTransferFailed();

    constructor(IPoolManager _manager, address _owner) {
        manager = _manager;
        owner = _owner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Swap through this identity. `hookData` of 32 bytes names the refund
    ///         recipient; empty credits this router.
    function swap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external payable onlyOwner returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(key, params, hookData)), (BalanceDelta));
        uint256 leftover = address(this).balance;
        if (leftover > 0) _sendNative(owner, leftover);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        (PoolKey memory key, IPoolManager.SwapParams memory params, bytes memory hookData) =
            abi.decode(data, (PoolKey, IPoolManager.SwapParams, bytes));
        BalanceDelta delta = manager.swap(key, params, hookData);
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    /// @notice Bond this identity. Pulls the bond token from the owner.
    function bond(IBondedFlow hook, uint256 amount) external onlyOwner {
        IERC20 token = hook.bondToken();
        token.safeTransferFrom(owner, address(this), amount);
        token.forceApprove(address(hook), amount);
        hook.bond(amount);
    }

    /// @notice Withdraw this identity's bond to the owner.
    function withdrawBond(IBondedFlow hook) external onlyOwner {
        hook.withdrawBond();
        IERC20 token = hook.bondToken();
        token.safeTransfer(owner, token.balanceOf(address(this)));
    }

    /// @notice Claim a refund credited to this identity, to the owner.
    function claimRefund(IBondedFlow hook) external onlyOwner returns (uint256 amount) {
        amount = hook.claimRefund();
        hook.bondToken().safeTransfer(owner, amount);
    }

    /// @notice Recover any token left here.
    function sweep(IERC20 token) external onlyOwner {
        token.safeTransfer(owner, token.balanceOf(address(this)));
    }

    function _settle(Currency currency, int128 amount) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{ value: owed }();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).safeTransferFrom(owner, address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, owner, uint256(uint128(amount)));
        }
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
    }

    receive() external payable { }
}
