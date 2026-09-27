// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IReactiveFlagReceiver
/// @notice Cross-chain flag delivery from the Reactive Network, plus the fee plumbing
///         the network's callback proxy expects on the destination chain.
interface IReactiveFlagReceiver {
    event ReactiveRvmSet(address indexed rvm);
    event NativeRescued(address indexed to, uint256 amount);

    error NativeTransferFailed();

    function callbackProxy() external view returns (address);
    function reactiveRvm() external view returns (address);
    function setReactiveRvm(address rvm) external;

    /// @notice Cross-chain flag delivered by the Reactive Network callback proxy.
    /// @param rvmId         Injected by the network; must equal `reactiveRvm`.
    /// @param searcher      Address to flag.
    /// @param flaggedUntil_ Block until which the flag is active; 0 selects the minimum
    ///                      bond duration.
    function onWatchtowerFlag(address rvmId, address searcher, uint256 flaggedUntil_) external;

    /// @notice Reactive Network fee collection on the destination chain.
    function pay(uint256 amount) external;
    function rescueNative(address payable to, uint256 amount) external;
}
