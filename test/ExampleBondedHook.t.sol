// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";

import { ExampleBondedHook } from "../src/examples/ExampleBondedHook.sol";
import { IBondedFlow } from "../src/interfaces/IBondedFlow.sol";
import { SwapRouter, LiquidityRouter } from "./utils/VadiumTestBase.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @notice Proves the module composes without the reference hook: a third-party hook
///         inherits `BondedFlow`, grants a fee discount to exempt senders, and slashes a
///         same-block reversal into the reserve.
contract ExampleBondedHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager pm;
    MockERC20 token0;
    MockERC20 token1;
    ExampleBondedHook hook;
    PoolKey key;
    PoolId id;
    LiquidityRouter liq;
    SwapRouter sRouter;
    SwapRouter vRouter;
    address searcher = makeAddr("searcher");
    address victim = makeAddr("victim");

    address constant HOOK_ADDR = address(uint160(0x20C0));
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    function _params() internal pure returns (IBondedFlow.BondParams memory p) {
        p.minBond = 100e6;
        p.minBondDurationBlocks = 100;
        p.firstSlashBps = 5_000;
        p.firstOffenseLockExtensionBlocks = 7_200;
        p.repeatOffenseBanBlocks = 216_000;
        p.victimRefundBps = 5_000;
        p.refundClaimWindowBlocks = 1_000;
    }

    function setUp() public {
        vm.roll(1_000);
        pm = new PoolManager(address(this));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 6);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        deployCodeTo(
            "ExampleBondedHook.sol:ExampleBondedHook",
            abi.encode(IPoolManager(pm), IERC20(address(token1)), address(this), _params()),
            HOOK_ADDR
        );
        hook = ExampleBondedHook(HOOK_ADDR);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDR)
        });
        id = key.toId();
        IBondedFlow.PoolConfig memory c;
        c.baseFee = 3_000;
        c.requireVictimLoss = false;
        hook.registerPool(key, c, address(this));
        pm.initialize(key, SQRT_1_1);

        liq = new LiquidityRouter(pm);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(liq), type(uint256).max);
        token1.approve(address(liq), type(uint256).max);
        liq.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 1e11, salt: 0
            })
        );

        sRouter = new SwapRouter(pm);
        vRouter = new SwapRouter(pm);
        _fund(searcher, sRouter);
        _fund(victim, vRouter);
    }

    function _fund(address u, SwapRouter r) internal {
        token0.mint(u, 1e24);
        token1.mint(u, 1e12);
        vm.startPrank(u);
        token0.approve(address(r), type(uint256).max);
        token1.approve(address(r), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address u, SwapRouter r, bool zeroForOne, uint256 amount) internal {
        vm.prank(u);
        r.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function test_permissionsAndAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertFalse(p.afterSwapReturnDelta);
        assertEq(uint160(HOOK_ADDR) & 0x3FFF, 0x20C0);
    }

    function test_discountOnlyForExempt() public {
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.prank(address(pm));
        (,, uint24 unbonded) = hook.beforeSwap(address(sRouter), key, sp, "");
        assertEq(unbonded, 3_000 | LPFeeLibrary.OVERRIDE_FEE_FLAG);

        _bondRouter(sRouter);
        vm.prank(address(pm));
        (,, uint24 bonded) = hook.beforeSwap(address(sRouter), key, sp, "");
        assertEq(bonded, 2_500 | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_reversalAroundOtherSwapper_slashesIntoReserve() public {
        _bondRouter(sRouter);
        _swap(searcher, sRouter, true, 1_000e6);
        _swap(victim, vRouter, true, 1_000e6);
        _swap(searcher, sRouter, false, 1_000e6);
        assertEq(hook.bondedBalance(address(sRouter)), 50e6);
        assertEq(hook.insuranceReserve(id), 50e6, "no shortfall measured, all to reserve");

        uint256 pmBefore = token1.balanceOf(address(pm));
        hook.claimCoverage(id, 50e6);
        assertEq(token1.balanceOf(address(pm)), pmBefore + 50e6, "reserve donated to LPs");
    }

    function test_dynamicFee_actuallyCharged() public {
        // Unbonded swap pays 30 bps: output is below the fee-free constant-product fill.
        (uint160 sqrtBefore,,,) = IPoolManager(address(pm)).getSlot0(id);
        assertEq(sqrtBefore, SQRT_1_1);
        _swap(victim, vRouter, true, 1_000e6);
        (uint160 sqrtAfter,,,) = IPoolManager(address(pm)).getSlot0(id);
        assertLt(sqrtAfter, sqrtBefore);
        (, uint256 fg1) = IPoolManager(address(pm)).getFeeGrowthGlobals(id);
        (uint256 fg0,) = IPoolManager(address(pm)).getFeeGrowthGlobals(id);
        assertGt(fg0, 0, "fee accrued on the input token");
        assertEq(fg1, 0);
    }

    /// @dev Bond on the router's address: the hook sees the router as `sender`.
    function _bondRouter(SwapRouter r) internal {
        token1.mint(address(r), 100e6);
        vm.startPrank(address(r));
        token1.approve(HOOK_ADDR, 100e6);
        hook.bond(100e6);
        vm.stopPrank();
    }
}
