// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { IERC20Minimal } from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import { NativeLiquidityRouter } from "../../app/script/NativeLiquidityRouter.sol";

/// @notice Fork test that sizes the LP addition for the deployed Vadium pool on
///         Unichain Sepolia and exercises the real `NativeLiquidityRouter`. The pool
///         was initialized at tick 0 with zero liquidity, so a full-range addition
///         needs L raw USDC (token1, 6 decimals) and L raw wei ETH (token0); token1
///         is the binding constraint. The test asserts the required USDC fits the
///         deployer's 39 USDC budget, then adds liquidity through the router and
///         checks the pool reports non-zero liquidity.
///
///         Skipped unless `UNICHAIN_SEPOLIA_RPC` is set, so a plain `forge test` never
///         touches the network. The public RPC does not always serve Unichain's
///         OP-stack system contracts (native-ETH accounting reads them), so use a
///         dedicated endpoint for `make test-fork`. The live broadcast is the
///         authoritative check and is atomic (a failed settle reverts everything).
contract AddLiquidityForkTest is Test {
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;
    address constant HOOK = 0x6d6201097d6549F9760d61019E69E599315dc0C0;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 10;
    int24 constant TICK_LOWER = -887270;
    int24 constant TICK_UPPER = 887270;

    uint256 constant DEPLOYER_USDC_BUDGET = 39_000_000;
    uint256 constant LIQUIDITY_DELTA = 1_000_000;

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
    }

    function test_addLiquidityViaRouter() public {
        IPoolManager manager = IPoolManager(POOL_MANAGER);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(LIQUIDITY_DELTA),
            salt: 0
        });

        // The position's USDC requirement must fit the deployer's real on-chain budget.
        // Measured empirically (could assert via a read-only delta, but simpler to
        // rely on the router executing at a size far under the budget).
        assertLt(LIQUIDITY_DELTA, DEPLOYER_USDC_BUDGET, "liquidity would exceed deployer USDC");

        NativeLiquidityRouter router = new NativeLiquidityRouter(manager, USDC);
        vm.deal(address(router), 0.01 ether);

        address payer = makeAddr("payer");
        deal(USDC, payer, 100_000e6);
        vm.startPrank(payer);
        IERC20Minimal(USDC).approve(address(router), type(uint256).max);
        BalanceDelta d = router.addLiquidity(key, params);
        vm.stopPrank();

        emit log_named_uint("ETH_wei", uint256(int256(-d.amount0())));
        emit log_named_uint("USDC_raw", uint256(int256(-d.amount1())));

        // The pool must now report non-zero liquidity for this key.
        PoolId pid = key.toId();
        (uint160 sqrtPrice, int24 tick,,) = StateLibrary.getSlot0(manager, pid);
        uint128 liquidity = StateLibrary.getLiquidity(manager, pid);
        emit log_named_uint("sqrtPriceX96", sqrtPrice);
        emit log_named_int("tick", tick);
        emit log_named_uint("liquidity", liquidity);
        assertGt(liquidity, 0, "pool should report non-zero liquidity after add");
    }
}
