// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Hooks } from "v4-core/src/libraries/Hooks.sol";

import { IBondedFlow } from "./IBondedFlow.sol";
import { IBlockPriceClamp } from "./IBlockPriceClamp.sol";
import { IReactiveFlagReceiver } from "./IReactiveFlagReceiver.sol";

/// @title IVadiumHook
/// @notice The reference accountable-arbitrage hook: bonded flow plus the block-start
///         clamp plus an optional Reactive Network flag relay.
interface IVadiumHook is IBondedFlow, IBlockPriceClamp, IReactiveFlagReceiver {
    function getHookPermissions() external pure returns (Hooks.Permissions memory);
}
