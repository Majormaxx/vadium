// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { VadiumReactive } from "../../src/reactive/VadiumReactive.sol";
import { Chains } from "./Chains.sol";

/// @title DeployVadiumReactive
/// @notice Deploys the Reactive sidecar on Lasna (testnet) or Reactive mainnet.
///
/// @dev    Experimental path. The hook must also hold native balance on the origin
///         chain for the callback proxy's fees (send ETH to the hook; it has `receive`).
///
///         Environment: PRIVATE_KEY, ORIGIN_CHAIN_ID (default 1301),
///         VADIUM_HOOK_ADDRESS (default: read from deployments/<origin>.json),
///         REACTIVE_FUND_WEI (default 2 ether), CALLBACK_GAS_LIMIT (default 300000).
contract DeployVadiumReactive is Script {
    function run() external {
        require(
            block.chainid == Chains.REACTIVE_LASNA || block.chainid == Chains.REACTIVE_MAINNET,
            "DeployReactive: wrong chain, expected Lasna (5318007) or Reactive (1597)"
        );
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        uint256 originChainId = vm.envOr("ORIGIN_CHAIN_ID", uint256(Chains.UNICHAIN_SEPOLIA));
        address hookAddress = vm.envOr("VADIUM_HOOK_ADDRESS", address(0));
        if (hookAddress == address(0)) {
            string memory json =
                vm.readFile(string.concat("deployments/", vm.toString(originChainId), ".json"));
            hookAddress = vm.parseJsonAddress(json, ".hook");
        }
        uint256 fund = vm.envOr("REACTIVE_FUND_WEI", uint256(2 ether));
        uint64 gasLimit = uint64(vm.envOr("CALLBACK_GAS_LIMIT", uint256(300_000)));

        console2.log("=== Vadium Reactive deploy ===");
        console2.log("Deployer:     ", deployer);
        console2.log("Origin chain: ", originChainId);
        console2.log("Hook:         ", hookAddress);

        vm.startBroadcast(key);
        VadiumReactive rc = new VadiumReactive{ value: fund }(
            originChainId, hookAddress, hookAddress, gasLimit, deployer
        );
        vm.stopBroadcast();

        console2.log("VadiumReactive:", address(rc));
        console2.log("Next: on the origin chain, setReactiveRvm(<deployer RVM id>) via Wire.s.sol");
        console2.log("      and fund the hook with native balance for callback fees");
    }
}
