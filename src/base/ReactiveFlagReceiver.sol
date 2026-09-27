// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "v4-core/src/types/PoolId.sol";

import { IReactiveFlagReceiver } from "../interfaces/IReactiveFlagReceiver.sol";
import { BondedFlow } from "./BondedFlow.sol";

/// @title ReactiveFlagReceiver
/// @notice Optional extension of `BondedFlow` that accepts flags delivered cross-chain
///         by the Reactive Network and pays the network's destination-chain fees.
///
/// @dev    Two checks gate a delivery: the message must arrive through the chain's
///         Reactive callback proxy, and the first payload argument, which the network
///         overwrites with the sending ReactVM id, must equal the bound `reactiveRvm`.
///         The role is separate from `watchtower`, so an EOA or multisig can still flag
///         with evidence while a reactive contract relays observations.
///
///         The callback proxy collects its fee by calling `pay`, and blocklists targets
///         that cannot pay, so the receiver accepts native funding via `receive`.
abstract contract ReactiveFlagReceiver is BondedFlow, IReactiveFlagReceiver {
    /// @notice Reactive Network callback proxy on this chain. Locked at construction.
    address public immutable override callbackProxy;

    /// @notice ReactVM id whose callbacks are accepted. Owner-settable; zero disables.
    address public override reactiveRvm;

    modifier onlyCallbackProxy() {
        if (msg.sender != callbackProxy) revert Unauthorized();
        _;
    }

    constructor(address callbackProxy_) {
        if (callbackProxy_ == address(0)) revert ZeroAddress();
        callbackProxy = callbackProxy_;
    }

    /// @notice Bind (or unbind, with zero) the ReactVM id whose flags are accepted.
    function setReactiveRvm(address rvm) external override onlyOwner {
        reactiveRvm = rvm;
        emit ReactiveRvmSet(rvm);
    }

    /// @notice Persist a cross-chain flag. Extend-only: never shortens an active flag.
    function onWatchtowerFlag(address rvmId, address searcher, uint256 flaggedUntil_)
        external
        override
        onlyCallbackProxy
    {
        if (reactiveRvm == address(0) || rvmId != reactiveRvm) revert Unauthorized();
        if (searcher == address(0)) revert ZeroAddress();
        if (flaggedUntil_ == 0) flaggedUntil_ = block.number + _params.minBondDurationBlocks;
        if (flaggedUntil_ <= block.number) revert FlagExpired();
        if (_extendFlag(searcher, flaggedUntil_)) {
            emit Flagged(searcher, PoolId.wrap(bytes32(0)), 0, bytes32(0), flaggedUntil_);
        }
    }

    /// @notice Accept native funding for Reactive callback fees.
    receive() external payable { }

    /// @notice Reactive Network fee collection. Callback-proxy-only.
    function pay(uint256 amount) external override onlyCallbackProxy {
        _sendNative(payable(msg.sender), amount);
    }

    /// @notice Move native balance out. Owner-only.
    function rescueNative(address payable to, uint256 amount) external override onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _sendNative(to, amount);
        emit NativeRescued(to, amount);
    }

    function _sendNative(address payable to, uint256 amount) private {
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
    }
}
