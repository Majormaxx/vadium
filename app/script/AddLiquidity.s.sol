// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { IERC20Minimal } from "v4-core/src/interfaces/external/IERC20Minimal.sol";

import { NativeLiquidityRouter } from "./NativeLiquidityRouter.sol";
import { Chains } from "./Chains.sol";

/// @title AddLiquidity
/// @notice Seeds full-range liquidity in the deployed Vadium pool through a
///         `NativeLiquidityRouter` owned by the deployer, so the position can be removed
///         later with `removeLiquidity`.
///
/// @dev    Reads the pool from `deployments/<chainId>.json`.
///         Environment: PRIVATE_KEY, LIQUIDITY_DELTA (default 1_000_000), ETH_BUDGET_WEI
///         (default 0.01 ether), ROUTER (optional: reuse an existing router).
contract AddLiquidity is Script {
    int24 constant TICK_LOWER = -887_270;
    int24 constant TICK_UPPER = 887_270;

    function run() external {
        Chains.Config memory chain = Chains.get(block.chainid);
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        string memory json =
            vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(vm.parseJsonAddress(json, ".poolKey.currency0")),
            currency1: Currency.wrap(vm.parseJsonAddress(json, ".poolKey.currency1")),
            fee: uint24(vm.parseJsonUint(json, ".poolKey.fee")),
            tickSpacing: int24(vm.parseJsonInt(json, ".poolKey.tickSpacing")),
            hooks: IHooks(vm.parseJsonAddress(json, ".hook"))
        });
        require(
            Currency.unwrap(poolKey.currency0) == address(0),
            "AddLiquidity: expects native currency0"
        );

        uint256 liquidity = vm.envOr("LIQUIDITY_DELTA", uint256(1_000_000));
        uint256 ethBudget = vm.envOr("ETH_BUDGET_WEI", uint256(0.01 ether));
        address existing = vm.envOr("ROUTER", address(0));

        console2.log("=== Add liquidity ===");
        console2.log("Chain:     ", chain.name);
        console2.log("Hook:      ", address(poolKey.hooks));
        console2.log("Liquidity: ", liquidity);

        vm.startBroadcast(key);

        NativeLiquidityRouter router = existing == address(0)
            ? new NativeLiquidityRouter(
                IPoolManager(chain.poolManager), Currency.unwrap(poolKey.currency1), deployer
            )
            : NativeLiquidityRouter(payable(existing));

        (bool funded,) = address(router).call{ value: ethBudget }("");
        require(funded, "AddLiquidity: router funding failed");
        IERC20Minimal(Currency.unwrap(poolKey.currency1))
            .approve(address(router), type(uint256).max);

        BalanceDelta delta = router.addLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(liquidity),
                salt: 0
            })
        );
        router.withdrawNative();

        vm.stopBroadcast();

        console2.log("Router:    ", address(router));
        console2.log("ETH delta: ", int256(delta.amount0()));
        console2.log("USDC delta:", int256(delta.amount1()));
        console2.log("Position is held by the router; remove with router.removeLiquidity");
    }
}
