// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";

import { VadiumHook } from "../../src/hooks/VadiumHook.sol";
import { IBondedFlow } from "../../src/interfaces/IBondedFlow.sol";
import { BondParamsLib } from "../../src/libraries/BondParamsLib.sol";
import { Chains } from "./Chains.sol";

/// @title DeployVadium
/// @notice Deploys VadiumHook at a CREATE2-mined permission address, registers and
///         initializes the ETH/USDC pool, and writes `deployments/<chainId>.json`.
///
/// @dev    Environment:
///           PRIVATE_KEY          deployer (broadcaster); also the initial owner
///           OWNER                optional final owner (a Safe on mainnet); ownership is
///                                offered two-step and must be accepted from that address
///           INITIAL_SQRT_PRICE   optional pool price; defaults to tick 0 (1:1 raw units,
///                                only sensible on testnet)
///           GIT_SHA              optional source commit recorded in the deployment file
///
///         Run: forge script app/script/Deploy.s.sol:DeployVadium --rpc-url unichain_sepolia --broadcast
contract DeployVadium is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 3_000;
    int24 constant TICK_SPACING = 10;
    address constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        Chains.Config memory chain = Chains.get(block.chainid);
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address finalOwner = vm.envOr("OWNER", deployer);
        uint160 initialSqrtPrice = uint160(vm.envOr("INITIAL_SQRT_PRICE", uint256(SQRT_PRICE_1_1)));

        if (block.chainid == Chains.UNICHAIN) {
            require(finalOwner.code.length > 0, "Deploy: mainnet OWNER must be a contract (Safe)");
            require(initialSqrtPrice != SQRT_PRICE_1_1, "Deploy: set INITIAL_SQRT_PRICE on mainnet");
        }

        IBondedFlow.BondParams memory params = BondParamsLib.unichainDefaults();
        IBondedFlow.PoolConfig memory cfg = IBondedFlow.PoolConfig({
            clampEnabled: true,
            exemptFirstSwapOnly: true,
            requireVictimLoss: true,
            baseFee: 0,
            feeDiscountBps: 0
        });

        console2.log("=== Vadium deploy ===");
        console2.log("Chain:        ", chain.name);
        console2.log("Deployer:     ", deployer);
        console2.log("Final owner:  ", finalOwner);

        // 1. Mine the CREATE2 salt. The owner passed to the constructor is the deployer,
        //    so the setup calls below can run in the same broadcast.
        bytes memory creationCode = abi.encodePacked(
            type(VadiumHook).creationCode,
            abi.encode(
                IPoolManager(chain.poolManager),
                IERC20(chain.usdc),
                deployer,
                chain.reactiveCallbackProxy,
                params
            )
        );
        (bytes32 salt, address hookAddress) = _mine(keccak256(creationCode));
        console2.log("Hook address: ", hookAddress);
        console2.log("Salt:         ", uint256(salt));

        vm.startBroadcast(deployerKey);

        // 2. Deploy at the mined address.
        VadiumHook hook = new VadiumHook{ salt: salt }(
            IPoolManager(chain.poolManager),
            IERC20(chain.usdc),
            deployer,
            chain.reactiveCallbackProxy,
            params
        );
        require(address(hook) == hookAddress, "Deploy: address mismatch, re-mine");

        // 3. Register and initialize the ETH/USDC pool.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(chain.usdc),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        hook.registerPool(key, cfg, finalOwner);
        IPoolManager(chain.poolManager).initialize(key, initialSqrtPrice);

        // 4. Offer ownership to the final owner (two-step; it must accept).
        if (finalOwner != deployer) hook.transferOwnership(finalOwner);

        vm.stopBroadcast();

        _writeDeployment(chain, address(hook), key, salt, deployer, finalOwner);

        console2.log("=== Done ===");
        console2.log("Pool id:");
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("Next: forge script app/script/Wire.s.sol:WireVadium (keeper, watchtower)");
        if (finalOwner != deployer) {
            console2.log("Then: acceptOwnership() from", finalOwner);
        }
    }

    function _mine(bytes32 initCodeHash) internal pure returns (bytes32 salt, address addr) {
        for (uint256 i = 0; i < 1_000_000; i++) {
            salt = bytes32(i);
            addr = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, initCodeHash)
                        )
                    )
                )
            );
            if (uint160(addr) & 0x3FFF == HOOK_FLAGS) return (salt, addr);
        }
        revert("Deploy: no salt found");
    }

    function _writeDeployment(
        Chains.Config memory chain,
        address hook,
        PoolKey memory key,
        bytes32 salt,
        address deployer,
        address finalOwner
    ) internal {
        string memory k = "poolKey";
        vm.serializeAddress(k, "currency0", Currency.unwrap(key.currency0));
        vm.serializeAddress(k, "currency1", Currency.unwrap(key.currency1));
        vm.serializeUint(k, "fee", key.fee);
        vm.serializeInt(k, "tickSpacing", key.tickSpacing);
        string memory keyJson = vm.serializeAddress(k, "hooks", address(key.hooks));

        string memory r = "root";
        vm.serializeUint(r, "chainId", chain.chainId);
        vm.serializeString(r, "chainName", chain.name);
        vm.serializeString(r, "commit", vm.envOr("GIT_SHA", string("")));
        vm.serializeUint(r, "block", block.number);
        vm.serializeUint(r, "timestamp", block.timestamp);
        vm.serializeAddress(r, "hook", hook);
        vm.serializeAddress(r, "poolManager", chain.poolManager);
        vm.serializeAddress(r, "stateView", chain.stateView);
        vm.serializeAddress(r, "bondToken", chain.usdc);
        vm.serializeAddress(r, "callbackProxy", chain.reactiveCallbackProxy);
        vm.serializeAddress(r, "deployer", deployer);
        vm.serializeAddress(r, "owner", finalOwner);
        vm.serializeBytes32(r, "salt", salt);
        vm.serializeString(r, "poolKey", keyJson);
        vm.serializeString(r, "reactive", "");
        string memory out = vm.serializeBytes32(r, "poolId", PoolId.unwrap(key.toId()));

        string memory path = string.concat("deployments/", vm.toString(chain.chainId), ".json");
        vm.writeJson(out, path);
        console2.log("Wrote", path);
    }
}
