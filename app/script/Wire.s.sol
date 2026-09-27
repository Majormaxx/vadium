// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { VadiumHook } from "../../src/hooks/VadiumHook.sol";
import { Chains } from "./Chains.sol";

/// @title WireVadium
/// @notice Post-deploy role wiring: keeper, watchtower, and the Reactive RVM id.
///
/// @dev    Reads the hook from `deployments/<chainId>.json`. When the broadcaster owns
///         the hook the calls are sent; otherwise (mainnet Safe) the calldata is printed
///         for the Safe transaction builder and nothing is broadcast.
///
///         Environment: PRIVATE_KEY, KEEPER, WATCHTOWER (optional), REACTIVE_RVM (optional).
contract WireVadium is Script {
    function run() external {
        Chains.get(block.chainid); // reverts on unsupported chains
        uint256 key = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(key);
        string memory json =
            vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        VadiumHook hook = VadiumHook(payable(vm.parseJsonAddress(json, ".hook")));

        address keeper = vm.envAddress("KEEPER");
        address watchtower = vm.envOr("WATCHTOWER", address(0));
        address rvm = vm.envOr("REACTIVE_RVM", address(0));

        console2.log("Hook:      ", address(hook));
        console2.log("Owner:     ", hook.owner());
        console2.log("Keeper:    ", keeper);
        console2.log("Watchtower:", watchtower);
        console2.log("Rvm:       ", rvm);

        if (hook.owner() == sender) {
            vm.startBroadcast(key);
            if (hook.keeper() != keeper) hook.setKeeper(keeper);
            if (watchtower != address(0) && hook.watchtower() != watchtower) {
                hook.setWatchtower(watchtower);
            }
            if (rvm != address(0) && hook.reactiveRvm() != rvm) hook.setReactiveRvm(rvm);
            vm.stopBroadcast();
            console2.log("Wired.");
            return;
        }

        console2.log("Broadcaster is not the owner. Submit from the owner:");
        console2.log("  setKeeper calldata:");
        console2.logBytes(abi.encodeCall(hook.setKeeper, (keeper)));
        if (watchtower != address(0)) {
            console2.log("  setWatchtower calldata:");
            console2.logBytes(abi.encodeCall(hook.setWatchtower, (watchtower)));
        }
        if (rvm != address(0)) {
            console2.log("  setReactiveRvm calldata:");
            console2.logBytes(abi.encodeCall(hook.setReactiveRvm, (rvm)));
        }
    }
}
