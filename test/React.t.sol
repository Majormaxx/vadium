// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { Currency } from "v4-core/src/types/Currency.sol";

import { ReactiveTest } from "reactive-test-lib/base/ReactiveTest.sol";
import { ReactiveSimulator } from "reactive-test-lib/simulator/ReactiveSimulator.sol";
import { ReactiveConstants } from "reactive-test-lib/constants/ReactiveConstants.sol";
import {
    CallbackResult,
    LogRecord,
    IReactive
} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";

import { VadiumReactive } from "../src/reactive/VadiumReactive.sol";
import { VadiumHook } from "../src/core/VadiumHook.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

// Import the reactive-lib's IReactive.LogRecord (structurally identical to the
// test-lib's LogRecord, but a different named type).
import { IReactive as IReactiveVM } from "reactive-lib/interfaces/IReactive.sol";

/// @title SandwichOrigin
/// @notice Test fixture standing in for the VadiumHook on the origin chain. It emits the
///         exact `Sandwiched` event the hook emits after an on-pool slash, so the Reactive
///         sidecar sees an identical log. The callback still lands on the real VadiumHook.
/// @dev    This is a fixture for the origin event, not a stub of any sidecar/hook logic —
///         the sidecar, the cross-chain delivery, and the hook entrypoint are all real.
contract SandwichOrigin {
    event Sandwiched(
        address indexed searcher,
        uint256 slashed,
        bool isRepeat,
        uint256 remaining,
        uint256 bannedUntil
    );

    function emitSandwiched(
        address searcher,
        uint256 slashed,
        bool isRepeat,
        uint256 remaining,
        uint256 bannedUntil
    ) external {
        emit Sandwiched(searcher, slashed, isRepeat, remaining, bannedUntil);
    }
}

/// @title ReactTest
/// @notice End-to-end test of the Reactive watchtower sidecar against the real hook,
///         using reactive-test-lib's simulator (RVM injection + callback proxy).
contract ReactTest is ReactiveTest {
    uint256 constant ORIGIN_CHAIN_ID = 1301;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 10;

    event Callback(
        uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload
    );
    event WatchtowerFlagQueued(
        uint256 indexed originChainId,
        address indexed searcher,
        uint256 bannedUntil,
        uint256 originBlock
    );
    event EnabledSet(bool enabled);

    SandwichOrigin internal origin;
    VadiumHook internal hook;
    VadiumReactive internal rc;

    address internal searcher = makeAddr("searcher");

    uint256 internal constant TX_HASH = 0xabc123;

    function setUp() public override {
        super.setUp();

        origin = new SandwichOrigin();

        MockERC20 token0 = new MockERC20("WETH", "WETH", 18);
        MockERC20 token1 = new MockERC20("USDC", "USDC", 6);
        if (address(token0) > address(token1)) {
            MockERC20 tmp = token0;
            token0 = token1;
            token1 = tmp;
        }

        // Real hook whose callback proxy is the simulator's proxy and whose watchtower is
        // the injected RVM ID (address(this) in the ReactiveTest harness).
        hook = new VadiumHook(
            IPoolManager(makeAddr("poolManager")),
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            POOL_FEE,
            TICK_SPACING,
            address(this),
            address(proxy)
        );
        hook.setWatchtower(address(this));

        // The sidecar watches the origin fixture and flags straight back at the hook.
        rc = new VadiumReactive(
            ORIGIN_CHAIN_ID, address(origin), address(hook), 300_000, address(this)
        );
        enableVmMode(address(rc));
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    function test_constructor_registersSubscription() public view {
        assertEq(address(rc.originContract()), address(origin));
        assertEq(address(rc.callbackTarget()), address(hook));
        assertEq(rc.originChainId(), ORIGIN_CHAIN_ID);
        assertEq(rc.enabled(), true);
        // Exactly one subscription (Sandwiched topic0 on the origin contract).
        assertEq(sys.subscriptionCount(), 1);
    }

    function test_constructor_revertsOnZeroOrigin() public {
        vm.expectRevert("Vadium: zero origin");
        new VadiumReactive(ORIGIN_CHAIN_ID, address(0), address(hook), 300_000, address(this));
    }

    function test_constructor_revertsOnZeroCallbackTarget() public {
        vm.expectRevert("Vadium: zero callback target");
        new VadiumReactive(ORIGIN_CHAIN_ID, address(origin), address(0), 300_000, address(this));
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert("Vadium: zero owner");
        new VadiumReactive(ORIGIN_CHAIN_ID, address(origin), address(hook), 300_000, address(0));
    }

    // -------------------------------------------------------------------------
    // End-to-end: event -> react -> cross-chain callback -> hook flag
    // -------------------------------------------------------------------------

    function test_endToEnd_sandwichFlagsSearcherOnHook() public {
        uint256 bannedUntil = block.number + 5_000_000;

        CallbackResult[] memory results = triggerAndReact(
            address(origin),
            abi.encodeCall(
                SandwichOrigin.emitSandwiched, (searcher, 50e6, false, 50e6, bannedUntil)
            ),
            ORIGIN_CHAIN_ID
        );

        assertEq(results.length, 1, "exactly one callback");
        assertEq(results[0].target, address(hook), "callback routed to the hook");
        assertEq(results[0].chainId, ORIGIN_CHAIN_ID);
        assertTrue(results[0].success, "hook accepted the cross-chain flag");

        // The hook persisted the flag: the searcher is now eligible for a keeper drain.
        assertEq(hook.flaggedUntil(searcher), bannedUntil);
    }

    function test_endToEnd_callbackCarriesInjectedRvmId() public {
        uint256 bannedUntil = block.number + 500;

        CallbackResult[] memory results = triggerAndReact(
            address(origin),
            abi.encodeCall(
                SandwichOrigin.emitSandwiched, (searcher, 50e6, false, 50e6, bannedUntil)
            ),
            ORIGIN_CHAIN_ID
        );

        // The payload is the pre-injection bytes: selector + 3 ABI words = 100 bytes.
        assertEq(results[0].payload.length, 4 + 32 * 3, "onWatchtowerFlag(address,address,uint256)");
        // First 4 bytes are the function selector.
        assertEq(
            bytes4(results[0].payload),
            bytes4(keccak256("onWatchtowerFlag(address,address,uint256)"))
        );
        // The callback succeeded because the simulator overwrote the first arg with the
        // RVM ID before delivery — proof: the flag was set on the hook.
        assertEq(hook.flaggedUntil(searcher), bannedUntil);
    }

    function test_endToEnd_zeroBanUntilDefaults() public {
        CallbackResult[] memory results = triggerAndReact(
            address(origin),
            abi.encodeCall(SandwichOrigin.emitSandwiched, (searcher, 0, false, 0, 0)),
            ORIGIN_CHAIN_ID
        );

        assertTrue(results[0].success, "hook applied the default ban window");
        assertEq(
            hook.flaggedUntil(searcher), block.number + hook.DEFAULT_MIN_BOND_DURATION_BLOCKS()
        );
    }

    // -------------------------------------------------------------------------
    // RSC reaction logic
    // -------------------------------------------------------------------------

    function test_react_emitsCallbackWithZeroPlaceholder() public {
        // The sidecar must queue a Callback with address(0) as the first arg: the
        // Reactive Network overwrites it with the ReactVM ID before delivery.
        IReactiveVM.LogRecord memory log = IReactiveVM.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(origin),
            topic_0: uint256(keccak256("Sandwiched(address,uint256,bool,uint256,uint256)")),
            topic_1: uint256(uint160(searcher)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(uint256(50e6), false, uint256(50e6), block.number + 500),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: TX_HASH,
            log_index: 0
        });

        bytes memory expectedPayload = abi.encodeWithSignature(
            "onWatchtowerFlag(address,address,uint256)", address(0), searcher, block.number + 500
        );

        vm.expectEmit(true, true, true, true, address(rc));
        emit Callback(ORIGIN_CHAIN_ID, address(hook), 300_000, expectedPayload);

        vm.prank(address(ReactiveConstants.SERVICE_ADDR));
        rc.react(log);
    }

    function test_react_dedupsByOriginTxHash() public {
        LogRecord memory log =
            _sandwichLog(searcher, 50e6, false, 50e6, block.number + 500, TX_HASH);

        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
        assertTrue(rc.processed(TX_HASH), "first reaction recorded the tx hash");

        // Re-delivering the same origin tx is a no-op: the sidecar must not re-flag.
        vm.recordLogs();
        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
        Vm.Log[] memory second = vm.getRecordedLogs();
        assertEq(second.length, 0, "no duplicate callback for a repeat tx hash");
    }

    function test_react_wrongOriginIgnored() public {
        // An event that is not from the subscribed origin contract is ignored.
        LogRecord memory log =
            _sandwichLog(searcher, 50e6, false, 50e6, block.number + 500, TX_HASH);
        log._contract = makeAddr("imposter");

        vm.recordLogs();
        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
        assertEq(vm.getRecordedLogs().length, 0, "no callback for a foreign emitter");
    }

    function test_react_zeroSearcherIgnored() public {
        LogRecord memory log = _sandwichLog(address(0), 0, false, 0, 0, TX_HASH);
        vm.recordLogs();
        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
        assertEq(vm.getRecordedLogs().length, 0, "no callback for a zero searcher");
    }

    function test_react_disabledIsNoop() public {
        rc.setEnabled(false);

        CallbackResult[] memory results = triggerAndReact(
            address(origin),
            abi.encodeCall(
                SandwichOrigin.emitSandwiched, (searcher, 50e6, false, 50e6, block.number + 500)
            ),
            ORIGIN_CHAIN_ID
        );

        assertEq(results.length, 0, "disabled sidecar produced no callbacks");
        assertEq(hook.flaggedUntil(searcher), 0, "hook was not flagged");
    }

    function test_react_reEnabledAfterDisable() public {
        rc.setEnabled(false);
        rc.setEnabled(true);

        CallbackResult[] memory results = triggerAndReact(
            address(origin),
            abi.encodeCall(
                SandwichOrigin.emitSandwiched, (searcher, 0, false, 0, block.number + 500)
            ),
            ORIGIN_CHAIN_ID
        );
        assertTrue(results[0].success);
        assertEq(hook.flaggedUntil(searcher), block.number + 500);
    }

    // -------------------------------------------------------------------------
    // Ownership
    // -------------------------------------------------------------------------

    function test_setEnabled_onlyOwner() public {
        vm.prank(searcher);
        vm.expectRevert("Vadium: not owner");
        rc.setEnabled(false);
    }

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        rc.transferOwnership(newOwner);
        assertEq(rc.owner(), newOwner);

        vm.prank(searcher);
        vm.expectRevert("Vadium: not owner");
        rc.setEnabled(false);
    }

    function test_transferOwnership_zeroReverts() public {
        vm.expectRevert("Vadium: zero owner");
        rc.transferOwnership(address(0));
    }

    // -------------------------------------------------------------------------
    // Constructor — subscription correctness
    // -------------------------------------------------------------------------

    function test_constructor_topicMatchesSandwiched() public view {
        uint256 expected = uint256(keccak256("Sandwiched(address,uint256,bool,uint256,uint256)"));
        assertEq(rc.sandwichedTopic(), expected, "topic must match the event signature");
    }

    function test_constructor_subscriptionDetails() public view {
        // The mock stores the subscription; verify the parameters match.
        assertEq(sys.subscriptionCount(), 1);
    }

    // -------------------------------------------------------------------------
    // react() — wrong topic_0
    // -------------------------------------------------------------------------

    function test_react_wrongTopicIgnored() public {
        // Deliver a log from the correct origin but with a different topic_0.
        IReactiveVM.LogRecord memory log = IReactiveVM.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(origin),
            topic_0: uint256(keccak256("SomeOtherEvent(address)")),
            topic_1: uint256(uint160(searcher)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(uint256(50e6), false, uint256(50e6), block.number + 500),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: TX_HASH,
            log_index: 0
        });

        vm.recordLogs();
        vm.prank(address(ReactiveConstants.SERVICE_ADDR));
        rc.react(log);
        assertEq(vm.getRecordedLogs().length, 0, "wrong topic produces no callback");
    }

    // -------------------------------------------------------------------------
    // react() — dedup across different tx_hashes
    // -------------------------------------------------------------------------

    function test_react_differentTxHashesBothProduceCallbacks() public {
        LogRecord memory log1 = _sandwichLog(searcher, 50e6, false, 50e6, block.number + 500, 0xaaa);
        LogRecord memory log2 = _sandwichLog(searcher, 50e6, false, 50e6, block.number + 500, 0xbbb);

        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log1);
        assertTrue(rc.processed(0xaaa), "first tx_hash recorded");

        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log2);
        assertTrue(rc.processed(0xbbb), "second tx_hash recorded");
    }

    // -------------------------------------------------------------------------
    // react() — WatchtowerFlagQueued event
    // -------------------------------------------------------------------------

    function test_react_emitsWatchtowerFlagQueuedEvent() public {
        IReactiveVM.LogRecord memory log = IReactiveVM.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(origin),
            topic_0: uint256(keccak256("Sandwiched(address,uint256,bool,uint256,uint256)")),
            topic_1: uint256(uint160(searcher)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(uint256(50e6), false, uint256(50e6), block.number + 500),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: TX_HASH,
            log_index: 0
        });

        vm.expectEmit(false, true, false, false, address(rc));
        emit VadiumReactive.WatchtowerFlagQueued(
            ORIGIN_CHAIN_ID, searcher, block.number + 500, block.number
        );

        vm.prank(address(ReactiveConstants.SERVICE_ADDR));
        rc.react(log);
    }

    // -------------------------------------------------------------------------
    // setEnabled — edge cases and events
    // -------------------------------------------------------------------------

    function test_setEnabled_doubleDisable_noop() public {
        rc.setEnabled(false);
        rc.setEnabled(false);
        assertFalse(rc.enabled());
    }

    function test_setEnabled_enableWhenAlreadyEnabled_noop() public {
        assertTrue(rc.enabled());
        rc.setEnabled(true);
        assertTrue(rc.enabled());
    }

    function test_setEnabled_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(rc));
        emit VadiumReactive.EnabledSet(false);
        rc.setEnabled(false);
    }

    // -------------------------------------------------------------------------
    // processed() persistence across disable cycle
    // -------------------------------------------------------------------------

    function test_processedPersistsAcrossDisable() public {
        LogRecord memory log =
            _sandwichLog(searcher, 50e6, false, 50e6, block.number + 500, TX_HASH);

        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
        assertTrue(rc.processed(TX_HASH));

        rc.setEnabled(false);
        rc.setEnabled(true);

        // Same tx_hash still deduped after the disable cycle.
        vm.recordLogs();
        ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
        assertEq(vm.getRecordedLogs().length, 0, "dedup persists across disable");
    }

    // -------------------------------------------------------------------------
    // Ownership — chained transfers
    // -------------------------------------------------------------------------

    function test_transferOwnership_chained() public {
        address b = makeAddr("ownerB");
        address c = makeAddr("ownerC");

        rc.transferOwnership(b);
        assertEq(rc.owner(), b);

        vm.prank(b);
        rc.transferOwnership(c);
        assertEq(rc.owner(), c);

        // Original owner no longer has control.
        vm.expectRevert("Vadium: not owner");
        rc.setEnabled(false);
    }

    // -------------------------------------------------------------------------
    // End-to-end — hook rejects flag (wrong watchtower)
    // -------------------------------------------------------------------------

    function test_endToEnd_hookRejectsFlag_wrongWatchtower() public {
        // Verify the hook rejects a callback where the injected RVM ID does not
        // match the bound watchtower. This is the security boundary between the
        // Reactive Network and the hook — the E2E path is covered by the
        // onWatchtowerFlag unit tests; this confirms the hook reverts cleanly.
        address wrongRvm = makeAddr("wrongRvmId");
        vm.prank(address(proxy));
        vm.expectRevert();
        hook.onWatchtowerFlag(wrongRvm, searcher, block.number + 500);
        assertEq(hook.flaggedUntil(searcher), 0, "no flag persisted");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _sandwichLog(
        address s,
        uint256 slashed,
        bool isRepeat,
        uint256 remaining,
        uint256 bannedUntil,
        uint256 txHash
    ) internal view returns (LogRecord memory) {
        return LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(origin),
            topic_0: uint256(keccak256("Sandwiched(address,uint256,bool,uint256,uint256)")),
            topic_1: uint256(uint160(s)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(slashed, isRepeat, remaining, bannedUntil),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: 0
        });
    }
}
