// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {VadiumReactive} from "../../src/reactive/VadiumReactive.sol";

/// @title DeployVadiumReactive
/// @notice Deploys VadiumReactive to Reactive Network Lasna Testnet (chain 5318007).
///
/// @dev    The sidecar watches VadiumHook's `Sandwiched` events on Unichain Sepolia
///         (origin chain 1301) and issues cross-chain `onWatchtowerFlag` callbacks
///         back to the hook. The hook owner then binds `watchtower` to this
///         contract's ReactVM ID (the deployer's RVM).
///
///         Run with:
///           source .env
///           forge script app/script/DeployReactive.s.sol:DeployVadiumReactive \
///             --rpc-url "$REACTIVE_LASNA_RPC" \
///             --broadcast -vvvv
///
/// @custom:chain  Reactive Lasna Testnet — chain ID 5318007
contract DeployVadiumReactive is Script {
    // -------------------------------------------------------------------------
    // Unichain Sepolia / Lasna addresses
    // -------------------------------------------------------------------------

    // Unichain Sepolia — origin chain id of the hook
    uint256 constant ORIGIN_CHAIN_ID = 1301;

    // Gas budget for the cross-chain callback delivered to the hook.
    uint64 constant CALLBACK_GAS_LIMIT = 300_000;

    // -------------------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------------------

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address hookAddress = vm.envAddress("VADIUM_HOOK_ADDRESS");

        console2.log("=== Vadium Reactive deploy ===");
        console2.log("Deployer:       ", deployer);
        console2.log("Origin chain:   ", ORIGIN_CHAIN_ID);
        console2.log("Hook address:   ", hookAddress);

        vm.startBroadcast(deployerKey);

        VadiumReactive rc = new VadiumReactive{value: 2 ether}(
            ORIGIN_CHAIN_ID,
            hookAddress,
            hookAddress,
            CALLBACK_GAS_LIMIT,
            deployer
        );

        console2.log("VadiumReactive: ", address(rc));
        console2.log("Owner:          ", rc.owner());
        console2.log("=== Deployment complete ===");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. On Unichain: setWatchtower(<RVM ID of deployer>) on the hook");
        console2.log("  2. Trigger a sandwich on the hook; the sidecar flags it for LP payout");
        console2.log("  3. Verify on Reactscan (lasna.reactscan.net)");
    }
}
