// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";

import { ReactiveTest } from "reactive-test-lib/base/ReactiveTest.sol";
import { ReactiveSimulator } from "reactive-test-lib/simulator/ReactiveSimulator.sol";
import { ReactiveConstants } from "reactive-test-lib/constants/ReactiveConstants.sol";
import {
    CallbackResult,
    LogRecord,
    IReactive
} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";
import { IReactive as IReactiveVM } from "reactive-lib/interfaces/IReactive.sol";

import { VadiumReactive } from "../src/reactive/VadiumReactive.sol";
import { VadiumHook } from "../src/hooks/VadiumHook.sol";
import { IBondedFlow } from "../src/interfaces/IBondedFlow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @title SandwichOrigin
/// @notice Fixture standing in for the hook on the origin chain: emits the exact
///         `Sandwiched` event the hook emits, so the sidecar sees an identical log while
///         the callback still lands on the real hook.
contract SandwichOrigin {
    event Sandwiched(
        bytes32 indexed poolId,
        address indexed searcher,
        uint256 slashed,
        bool isRepeat,
        uint256 remaining,
        uint256 flaggedUntil,
        uint256 refunded
    );

    function emitSandwiched(
        bytes32 poolId,
        address searcher,
        uint256 slashed,
        bool isRepeat,
        uint256 remaining,
        uint256 flaggedUntil,
        uint256 refunded
    ) external {
        emit Sandwiched(poolId, searcher, slashed, isRepeat, remaining, flaggedUntil, refunded);
    }
}

/// @title ReactTest
/// @notice End-to-end test of the Reactive sidecar against the real hook using
///         reactive-test-lib's simulator (RVM id injection + callback proxy).
contract ReactTest is ReactiveTest {
    uint256 constant ORIGIN_CHAIN_ID = 1301;
    address constant HOOK_ADDR = address(uint160(0x20C4));
    bytes32 constant POOL_ID = bytes32(uint256(0xabcdef));
    string constant SIG = "Sandwiched(bytes32,address,uint256,bool,uint256,uint256,uint256)";

    event Callback(
        uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload
    );

    SandwichOrigin internal origin;
    VadiumHook internal hook;
    VadiumReactive internal rc;
    address internal searcher = makeAddr("searcher");
    uint256 internal constant TX_HASH = 0xabc123;

    function _params() internal pure returns (IBondedFlow.BondParams memory p) {
        p.minBond = 100e6;
        p.minBondDurationBlocks = 100;
        p.firstSlashBps = 5_000;
        p.firstOffenseLockExtensionBlocks = 7_200;
        p.repeatOffenseBanBlocks = 216_000;
        p.victimRefundBps = 5_000;
        p.refundClaimWindowBlocks = 1_000;
    }

    function setUp() public override {
        super.setUp();
        origin = new SandwichOrigin();
        MockERC20 token1 = new MockERC20("USDC", "USDC", 6);

        // Real hook whose callback proxy is the simulator's proxy and whose reactive rvm is
        // the injected RVM id (address(this) in the ReactiveTest harness).
        deployCodeTo(
            "VadiumHook.sol:VadiumHook",
            abi.encode(
                IPoolManager(makeAddr("poolManager")),
                IERC20(address(token1)),
                address(this),
                address(proxy),
                _params()
            ),
            HOOK_ADDR
        );
        hook = VadiumHook(payable(HOOK_ADDR));
        hook.setReactiveRvm(address(this));

        rc = new VadiumReactive(
            ORIGIN_CHAIN_ID, address(origin), address(hook), 300_000, address(this)
        );
        enableVmMode(address(rc));
    }

    function _emitArgs(uint256 flaggedUntil) internal view returns (bytes memory) {
        return abi.encodeCall(
            SandwichOrigin.emitSandwiched, (POOL_ID, searcher, 50e6, false, 50e6, flaggedUntil, 1e6)
        );
    }

    function _sandwichLog(address s, uint256 flaggedUntil, uint256 txHash)
        internal
        view
        returns (LogRecord memory)
    {
        return LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(origin),
            topic_0: uint256(keccak256(bytes(SIG))),
            topic_1: uint256(POOL_ID),
            topic_2: uint256(uint160(s)),
            topic_3: 0,
            data: abi.encode(uint256(50e6), false, uint256(50e6), flaggedUntil, uint256(1e6)),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: 0
        });
    }

    function _vmLog(uint256 topic0, uint256 chainId, uint256 flaggedUntil)
        internal
        view
        returns (IReactiveVM.LogRecord memory)
    {
        return IReactiveVM.LogRecord({
            chain_id: chainId,
            _contract: address(origin),
            topic_0: topic0,
            topic_1: uint256(POOL_ID),
            topic_2: uint256(uint160(searcher)),
            topic_3: 0,
            data: abi.encode(uint256(50e6), false, uint256(50e6), flaggedUntil, uint256(1e6)),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: TX_HASH,
            log_index: 0
        });
    }

    // --- Constructor ---

    function test_constructor_registersSubscription() public view {
        assertEq(rc.originContract(), address(origin));
        assertEq(rc.callbackTarget(), address(hook));
        assertEq(rc.originChainId(), ORIGIN_CHAIN_ID);
        assertTrue(rc.enabled());
        assertEq(sys.subscriptionCount(), 1);
    }

    function test_constructor_topicMatchesSandwiched() public view {
        assertEq(rc.sandwichedTopic(), uint256(keccak256(bytes(SIG))));
    }

    function test_constructor_revertsOnZeros() public {
        vm.expectRevert("Vadium: zero origin");
        new VadiumReactive(ORIGIN_CHAIN_ID, address(0), address(hook), 300_000, address(this));
        vm.expectRevert("Vadium: zero callback target");
        new VadiumReactive(ORIGIN_CHAIN_ID, address(origin), address(0), 300_000, address(this));
        vm.expectRevert("Vadium: zero owner");
        new VadiumReactive(ORIGIN_CHAIN_ID, address(origin), address(hook), 300_000, address(0));
    }

    // --- End to end ---

    function test_endToEnd_sandwichFlagsSearcherOnHook() public {
        uint256 until = block.number + 5_000_000;
        CallbackResult[] memory results =
            triggerAndReact(address(origin), _emitArgs(until), ORIGIN_CHAIN_ID);
        assertEq(results.length, 1);
        assertEq(results[0].target, address(hook));
        assertEq(results[0].chainId, ORIGIN_CHAIN_ID);
        assertTrue(results[0].success, "hook accepted the cross-chain flag");
        assertEq(hook.flaggedUntil(searcher), until);
    }

    function test_endToEnd_callbackCarriesInjectedRvmId() public {
        uint256 until = block.number + 500;
        CallbackResult[] memory results =
            triggerAndReact(address(origin), _emitArgs(until), ORIGIN_CHAIN_ID);
        assertEq(results[0].payload.length, 4 + 32 * 3);
        assertEq(
            bytes4(results[0].payload),
            bytes4(keccak256("onWatchtowerFlag(address,address,uint256)"))
        );
        assertEq(hook.flaggedUntil(searcher), until);
    }

    function test_endToEnd_zeroFlaggedUntilDefaults() public {
        CallbackResult[] memory results =
            triggerAndReact(address(origin), _emitArgs(0), ORIGIN_CHAIN_ID);
        assertTrue(results[0].success);
        assertEq(
            hook.flaggedUntil(searcher), block.number + hook.bondParams().minBondDurationBlocks
        );
    }

    function test_endToEnd_extendOnly() public {
        triggerAndReact(address(origin), _emitArgs(block.number + 500), ORIGIN_CHAIN_ID);
        assertEq(hook.flaggedUntil(searcher), block.number + 500);
        // A later, shorter delivery through the proxy does not shorten the flag.
        vm.prank(address(proxy));
        hook.onWatchtowerFlag(address(this), searcher, block.number + 100);
        assertEq(hook.flaggedUntil(searcher), block.number + 500);
        vm.prank(address(proxy));
        hook.onWatchtowerFlag(address(this), searcher, block.number + 900);
        assertEq(hook.flaggedUntil(searcher), block.number + 900);
    }

    function test_endToEnd_hookRejectsFlag_wrongRvm() public {
        vm.prank(address(proxy));
        vm.expectRevert(IBondedFlow.Unauthorized.selector);
        hook.onWatchtowerFlag(makeAddr("wrongRvm"), searcher, block.number + 500);
        assertEq(hook.flaggedUntil(searcher), 0);
    }

    function test_endToEnd_hookRejectsFlag_unboundRvm() public {
        hook.setReactiveRvm(address(0));
        CallbackResult[] memory results =
            triggerAndReact(address(origin), _emitArgs(block.number + 500), ORIGIN_CHAIN_ID);
        assertFalse(results[0].success, "hook rejects when no rvm is bound");
        assertEq(hook.flaggedUntil(searcher), 0);
    }

    // --- react() ---

    function test_react_emitsCallbackWithZeroPlaceholder() public {
        uint256 until = block.number + 500;
        bytes memory expected = abi.encodeWithSignature(
            "onWatchtowerFlag(address,address,uint256)", address(0), searcher, until
        );
        vm.expectEmit(true, true, true, true, address(rc));
        emit Callback(ORIGIN_CHAIN_ID, address(hook), 300_000, expected);
        vm.prank(address(ReactiveConstants.SERVICE_ADDR));
        rc.react(_vmLog(uint256(keccak256(bytes(SIG))), ORIGIN_CHAIN_ID, until));
    }

    function test_react_emitsWatchtowerFlagQueued() public {
        uint256 until = block.number + 500;
        vm.expectEmit(true, true, false, true, address(rc));
        emit VadiumReactive.WatchtowerFlagQueued(ORIGIN_CHAIN_ID, searcher, until, block.number);
        vm.prank(address(ReactiveConstants.SERVICE_ADDR));
        rc.react(_vmLog(uint256(keccak256(bytes(SIG))), ORIGIN_CHAIN_ID, until));
    }

    function test_react_dedupsByOriginTxHash() public {
        LogRecord memory log = _sandwichLog(searcher, block.number + 500, TX_HASH);
        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
        assertTrue(rc.processed(TX_HASH));
        vm.recordLogs();
        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
        assertEq(vm.getRecordedLogs().length, 0, "no duplicate callback");
    }

    function test_react_differentTxHashesBothProduceCallbacks() public {
        ReactiveSimulator.deliverRawEvent(
            vm, IReactive(address(rc)), _sandwichLog(searcher, block.number + 500, 0xaaa)
        );
        ReactiveSimulator.deliverRawEvent(
            vm, IReactive(address(rc)), _sandwichLog(searcher, block.number + 500, 0xbbb)
        );
        assertTrue(rc.processed(0xaaa));
        assertTrue(rc.processed(0xbbb));
    }

    function test_react_wrongOriginIgnored() public {
        LogRecord memory log = _sandwichLog(searcher, block.number + 500, TX_HASH);
        log._contract = makeAddr("imposter");
        vm.recordLogs();
        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(rc.processed(TX_HASH));
    }

    function test_react_wrongTopicIgnored() public {
        vm.recordLogs();
        vm.prank(address(ReactiveConstants.SERVICE_ADDR));
        rc.react(_vmLog(uint256(keccak256("SomeOtherEvent(address)")), ORIGIN_CHAIN_ID, 1));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_react_wrongChainIgnored() public {
        vm.recordLogs();
        vm.prank(address(ReactiveConstants.SERVICE_ADDR));
        rc.react(_vmLog(uint256(keccak256(bytes(SIG))), 999, block.number + 500));
        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(rc.processed(TX_HASH));
    }

    function test_react_zeroSearcherIgnored() public {
        vm.recordLogs();
        ReactiveSimulator.deliverRawEvent(
            vm, IReactive(address(rc)), _sandwichLog(address(0), block.number + 500, TX_HASH)
        );
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_react_disabledIsNoop_andReEnable() public {
        rc.setEnabled(false);
        CallbackResult[] memory results =
            triggerAndReact(address(origin), _emitArgs(block.number + 500), ORIGIN_CHAIN_ID);
        assertEq(results.length, 0);
        assertEq(hook.flaggedUntil(searcher), 0);
        rc.setEnabled(true);
        results = triggerAndReact(address(origin), _emitArgs(block.number + 500), ORIGIN_CHAIN_ID);
        assertTrue(results[0].success);
        assertEq(hook.flaggedUntil(searcher), block.number + 500);
    }

    function test_processedPersistsAcrossDisable() public {
        LogRecord memory log = _sandwichLog(searcher, block.number + 500, TX_HASH);
        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
        rc.setEnabled(false);
        rc.setEnabled(true);
        vm.recordLogs();
        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // --- Ownership and enable ---

    function test_setEnabled_onlyOwner_andEvents() public {
        vm.prank(searcher);
        vm.expectRevert("Vadium: not owner");
        rc.setEnabled(false);
        vm.expectEmit(false, false, false, true, address(rc));
        emit VadiumReactive.EnabledSet(false);
        rc.setEnabled(false);
        rc.setEnabled(false);
        assertFalse(rc.enabled());
    }

    function test_transferOwnership_chainedAndZeroReverts() public {
        address b = makeAddr("ownerB");
        address c = makeAddr("ownerC");
        rc.transferOwnership(b);
        vm.prank(b);
        rc.transferOwnership(c);
        assertEq(rc.owner(), c);
        vm.expectRevert("Vadium: not owner");
        rc.setEnabled(false);
        vm.prank(c);
        vm.expectRevert("Vadium: zero owner");
        rc.transferOwnership(address(0));
    }
}
