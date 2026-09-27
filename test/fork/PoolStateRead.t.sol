// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";

/// @notice Fork test that reads the deployed Vadium pool on Unichain Sepolia and checks
///         the on-chain state agrees with `deployments/1301.json`.
///
///         Skipped unless `UNICHAIN_SEPOLIA_RPC` is set, so a plain `forge test` never
///         touches the network. Run with `make test-fork`.
contract PoolStateReadForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal pm;
    PoolKey internal key;
    bytes32 internal expectedPoolId;

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        string memory json = vm.readFile("deployments/1301.json");
        pm = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        key = PoolKey({
            currency0: Currency.wrap(vm.parseJsonAddress(json, ".poolKey.currency0")),
            currency1: Currency.wrap(vm.parseJsonAddress(json, ".poolKey.currency1")),
            fee: uint24(vm.parseJsonUint(json, ".poolKey.fee")),
            tickSpacing: int24(vm.parseJsonInt(json, ".poolKey.tickSpacing")),
            hooks: IHooks(vm.parseJsonAddress(json, ".hook"))
        });
        expectedPoolId = vm.parseJsonBytes32(json, ".poolId");
    }

    function test_deploymentRecordMatchesChain() public view {
        assertEq(
            PoolId.unwrap(key.toId()), expectedPoolId, "poolId in deployments/1301.json is stale"
        );
        assertGt(address(key.hooks).code.length, 0, "hook has no code at the recorded address");

        (uint160 sqrtP, int24 tick, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(key.toId());
        assertGt(sqrtP, 0, "pool not initialized");
        assertGe(sqrtP, TickMath.MIN_SQRT_PRICE, "sqrtPrice below MIN");
        assertLe(sqrtP, TickMath.MAX_SQRT_PRICE, "sqrtPrice above MAX");
        assertEq(TickMath.getTickAtSqrtPrice(sqrtP), tick, "tick disagrees with sqrtPrice");
        assertEq(lpFee, key.fee, "lp fee disagrees with pool key");
        assertEq(protocolFee, 0, "protocol fee unexpectedly set");
    }
}
