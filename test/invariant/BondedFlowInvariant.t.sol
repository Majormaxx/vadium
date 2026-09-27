// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";

import { VadiumHook } from "../../src/hooks/VadiumHook.sol";
import { IBondedFlow } from "../../src/interfaces/IBondedFlow.sol";
import { VadiumTestBase, SwapRouter } from "../utils/VadiumTestBase.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Random actor driving every user-facing and role-gated entrypoint.
contract VadiumHandler is Test {
    VadiumHook public hook;
    PoolManager public pm;
    PoolKey public key;
    PoolId public id;
    MockERC20 public token0;
    MockERC20 public token1;

    address[] public users;
    SwapRouter[] public routers;
    address public keeperAddr = makeAddr("keeper");
    address public watchAddr = makeAddr("watch");
    address public ownerAddr;

    mapping(address => uint32) public maxStrikes;
    uint256 public calls;

    uint160 constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    constructor(
        VadiumHook _hook,
        PoolManager _pm,
        PoolKey memory _key,
        PoolId _id,
        MockERC20 _t0,
        MockERC20 _t1,
        address _owner
    ) {
        hook = _hook;
        pm = _pm;
        key = _key;
        id = _id;
        token0 = _t0;
        token1 = _t1;
        ownerAddr = _owner;
        for (uint256 i = 0; i < 5; i++) {
            address u = makeAddr(string(abi.encodePacked("actor", i)));
            SwapRouter r = new SwapRouter(pm);
            users.push(u);
            routers.push(r);
            token0.mint(u, 1e30);
            token1.mint(u, 1e30);
            vm.startPrank(u);
            token0.approve(address(r), type(uint256).max);
            token1.approve(address(r), type(uint256).max);
            vm.stopPrank();
        }
    }

    function routerCount() external view returns (uint256) {
        return routers.length;
    }

    function _pick(uint256 seed) internal view returns (address u, SwapRouter r) {
        uint256 i = seed % users.length;
        return (users[i], routers[i]);
    }

    function _track(address a) internal {
        (,,, uint32 s,) = hook.bonds(a);
        if (s > maxStrikes[a]) maxStrikes[a] = s;
    }

    function bond(uint256 seed, uint256 amount) external {
        calls++;
        (address u, SwapRouter r) = _pick(seed);
        amount = bound(amount, 100e6, 10_000e6);
        vm.prank(u);
        try r.bond(hook, amount) { } catch { }
    }

    function withdraw(uint256 seed) external {
        calls++;
        (address u, SwapRouter r) = _pick(seed);
        vm.prank(u);
        try r.withdrawBond(hook) { } catch { }
    }

    function swap(uint256 seed, bool zeroForOne, bool exactIn, uint256 amount) external {
        calls++;
        (address u, SwapRouter r) = _pick(seed);
        amount = bound(amount, 1e6, 5_000e6);
        int256 spec = exactIn ? -int256(amount) : int256(amount);
        vm.prank(u);
        try r.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: spec,
                sqrtPriceLimitX96: zeroForOne ? MIN_LIMIT : MAX_LIMIT
            })
        ) { }
            catch { }
        _track(address(r));
    }

    function roll(uint256 n) external {
        calls++;
        vm.roll(block.number + bound(n, 1, 300));
    }

    function flag(uint256 seed, uint256 amount, uint256 until) external {
        calls++;
        (, SwapRouter r) = _pick(seed);
        until = block.number + bound(until, 1, 10_000);
        amount = bound(amount, 0, 200e6);
        vm.prank(watchAddr);
        try hook.flagFromWatchtower(id, address(r), amount, until, bytes32("evidence")) { }
            catch { }
        _track(address(r));
    }

    function drain(uint256 seed, uint256 max) external {
        calls++;
        (, SwapRouter r) = _pick(seed);
        address[] memory l = new address[](1);
        l[0] = address(r);
        max = bound(max, 1, 1_000e6);
        vm.prank(keeperAddr);
        try hook.drainFlagged(id, l, max) { } catch { }
    }

    function claimCoverage(uint256 amount) external {
        calls++;
        amount = bound(amount, 1, 1_000e6);
        vm.prank(ownerAddr);
        try hook.claimCoverage(id, amount) { } catch { }
    }

    function claimRefund(uint256 seed) external {
        calls++;
        (address u, SwapRouter r) = _pick(seed);
        vm.prank(u);
        try r.claimRefund(hook) { } catch { }
    }

    function flush() external {
        calls++;
        try hook.flushWithheld(id) { } catch { }
    }

    function togglePause(bool p) external {
        calls++;
        vm.prank(ownerAddr);
        if (p) {
            try hook.pause() { } catch { }
        } else {
            try hook.unpause() { } catch { }
        }
    }
}

contract BondedFlowInvariantTest is VadiumTestBase {
    VadiumHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VadiumHandler(hook, pm, poolKey, poolId, token0, token1, address(this));
        hook.setKeeper(handler.keeperAddr());
        hook.setWatchtower(handler.watchAddr());
        targetContract(address(handler));
    }

    function invariant_solvency() public view {
        assertGe(
            token1.balanceOf(HOOK_ADDR),
            hook.totalBonded() + hook.totalReserve() + hook.totalClaimable(),
            "hook holds every obligation"
        );
    }

    function invariant_reserveAccounting() public view {
        uint256 pledged = hook.slashedPledged(poolId);
        uint256 withdrawn = hook.totalWithdrawn(poolId);
        assertLe(withdrawn, pledged);
        assertEq(hook.insuranceReserve(poolId), pledged - withdrawn);
        assertEq(hook.totalReserve(), hook.insuranceReserve(poolId), "single pool");
    }

    function invariant_exemptImpliesBondedUnbannedUnflaggedUnpaused() public view {
        for (uint256 i = 0; i < handler.routerCount(); i++) {
            address a = address(handler.routers(i));
            if (!hook.isExempt(poolId, a)) continue;
            assertGt(hook.bondedBalance(a), 0);
            assertFalse(hook.isBanned(a));
            assertLe(hook.flaggedUntil(a), block.number);
            assertFalse(hook.paused());
        }
    }

    function invariant_withheldBackedByClaims() public view {
        assertGe(pm.balanceOf(HOOK_ADDR, currency0.toId()), hook.withheld(poolId, currency0));
        assertGe(pm.balanceOf(HOOK_ADDR, currency1.toId()), hook.withheld(poolId, currency1));
    }

    function invariant_strikesNeverDecrease() public view {
        for (uint256 i = 0; i < handler.routerCount(); i++) {
            address a = address(handler.routers(i));
            (,,, uint32 s,) = hook.bonds(a);
            assertEq(s, handler.maxStrikes(a));
        }
    }

    function invariant_bondsSumMatchesTotal() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.routerCount(); i++) {
            sum += hook.bondedBalance(address(handler.routers(i)));
        }
        assertEq(sum, hook.totalBonded());
    }
}
