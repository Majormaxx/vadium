// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";

import { SimSwapRouter } from "../app/script/SimSwapRouter.sol";
import { IBondedFlow } from "../src/interfaces/IBondedFlow.sol";
import { VadiumTestBase } from "./utils/VadiumTestBase.sol";

/// @notice The simulator's router is a bonded identity: it bonds, swaps, gets slashed,
///         and forwards refunds and withdrawals to its owner.
contract SimSwapRouterTest is VadiumTestBase {
    SimSwapRouter internal sRouter;
    SimSwapRouter internal vRouter;

    function setUp() public override {
        super.setUp();
        sRouter = new SimSwapRouter(pm, searcher);
        vRouter = new SimSwapRouter(pm, victim);
        vm.startPrank(searcher);
        token0.approve(address(sRouter), type(uint256).max);
        token1.approve(address(sRouter), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(victim);
        token0.approve(address(vRouter), type(uint256).max);
        token1.approve(address(vRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address u, SimSwapRouter r, bool zeroForOne, uint256 amount, bytes memory hd)
        internal
        returns (BalanceDelta)
    {
        vm.prank(u);
        return r.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            hd
        );
    }

    function test_onlyOwnerCanSwapOrBond() public {
        vm.prank(other);
        vm.expectRevert(SimSwapRouter.NotOwner.selector);
        sRouter.bond(IBondedFlow(HOOK_ADDR), BOND_AMOUNT);
        vm.prank(other);
        vm.expectRevert(SimSwapRouter.NotOwner.selector);
        sRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            ""
        );
    }

    function test_bondSandwichRefundWithdraw_roundTrip() public {
        vm.prank(searcher);
        sRouter.bond(IBondedFlow(HOOK_ADDR), BOND_AMOUNT);
        assertTrue(hook.isExempt(poolId, address(sRouter)));

        uint256 victim0Before = token0.balanceOf(victim);
        _swap(searcher, sRouter, true, 5_000e6, "");
        _swap(victim, vRouter, true, 20_000e6, abi.encode(victim));
        _swap(searcher, sRouter, false, 5_000e6, "");
        assertEq(token0.balanceOf(victim), victim0Before - 20_000e6, "victim paid token0");

        assertEq(hook.bondedBalance(address(sRouter)), BOND_AMOUNT / 2, "slashed");
        uint256 refund = hook.claimableRefund(victim);
        assertGt(refund, 0, "hookData attributed the refund to the victim wallet");
        uint256 victim1Before = token1.balanceOf(victim);
        vm.prank(victim);
        hook.claimRefund();
        assertEq(token1.balanceOf(victim), victim1Before + refund);

        vm.roll(block.number + EXT);
        uint256 s1Before = token1.balanceOf(searcher);
        vm.prank(searcher);
        sRouter.withdrawBond(IBondedFlow(HOOK_ADDR));
        assertEq(token1.balanceOf(searcher), s1Before + BOND_AMOUNT / 2);
    }

    function test_refundWithoutHookData_creditsRouter_andClaimForwards() public {
        vm.prank(searcher);
        sRouter.bond(IBondedFlow(HOOK_ADDR), BOND_AMOUNT);
        _swap(searcher, sRouter, true, 5_000e6, "");
        _swap(victim, vRouter, true, 20_000e6, "");
        _swap(searcher, sRouter, false, 5_000e6, "");
        uint256 refund = hook.claimableRefund(address(vRouter));
        assertGt(refund, 0);
        uint256 before = token1.balanceOf(victim);
        vm.prank(victim);
        vRouter.claimRefund(IBondedFlow(HOOK_ADDR));
        assertEq(token1.balanceOf(victim), before + refund);
    }

    function test_sweepRecoversStrandedTokens() public {
        token1.mint(address(sRouter), 7e6);
        vm.prank(searcher);
        sRouter.sweep(IERC20(address(token1)));
        assertEq(token1.balanceOf(address(sRouter)), 0);
    }
}
