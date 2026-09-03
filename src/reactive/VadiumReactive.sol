// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AbstractReactive } from "reactive-lib/abstract-base/AbstractReactive.sol";
import { IReactive } from "reactive-lib/interfaces/IReactive.sol";
import { ISubscriptionService } from "reactive-lib/interfaces/ISubscriptionService.sol";

/// @title VadiumReactive
/// @notice Reactive sidecar for VadiumHook, deployed on Reactive Network (Lasna
///         Testnet, chain 5318007).
///
/// @dev    Bridges the hook's on-pool sandwich detection into a keeper-actionable
///         watchtower flag:
///           1. The hook's `_slash` catches a sandwich, confiscates a portion of the
///              bond into the LP insurance reserve, and emits `Sandwiched`.
///           2. This contract is subscribed to `Sandwiched` on the hook (Unichain
///              Sepolia, origin chain 1301).
///           3. On receipt it emits a `Callback` back to the hook calling
///              `onWatchtowerFlag`. Reactive Network overwrites the first payload
///              argument with this contract's ReactVM ID, which the hook uses to
///              verify the flag came from the approved watchtower.
///           4. The hook persists `flaggedUntil[searcher]`, making the searcher
///              eligible for the reserve payout via `drainFlagged`.
///
///         The hook's on-pool detector intentionally leaves `flaggedUntil` unset, so
///         this sidecar closes the only gap between "bond slashed" and "reserve
///         payable to LPs" entirely on-chain, with no off-chain bot or keeper loop.
///
///         Contract owner (the ReactVM owner) can pause the notification filter or
///         switch which subscription/service it uses, but the core reaction is
///         permissionless and runs automatically.
///
/// @custom:design  This contract is deployed once on Lasna Testnet. Because a foundry
///                 CREATE2 broadcast sets `msg.sender` to the factory in the
///                 constructor, the owner is passed explicitly rather than from
///                 `msg.sender`.
contract VadiumReactive is AbstractReactive {
    /// @notice Origin chain where the hook lives (Unichain Sepolia).
    uint256 public immutable originChainId;

    /// @notice The contract on the origin chain whose `Sandwiched` events this sidecar
    ///         watches. In production this is the VadiumHook itself.
    address public immutable originContract;

    /// @notice The contract that receives the cross-chain watchtower flag callback. In
    ///         production this is the same VadiumHook instance as `originContract`.
    address public immutable callbackTarget;

    /// @notice Gas budget granted to the cross-chain callback.
    uint64 public immutable callbackGasLimit;

    /// @notice The event signature this contract reacts to:
    ///         `Sandwiched(address indexed searcher, uint256 slashed, bool isRepeat,
    ///         uint256 remaining, uint256 bannedUntil)`.
    uint256 public immutable sandwichedTopic;

    /// @notice The ReactVM owner — the only account that can adjust parameters here.
    address public owner;

    /// @notice Whether the reaction is currently enabled. When false, incoming
    ///         `Sandwiched` events are ignored. Owner-controlled.
    bool public enabled;

    /// @notice Tokens of origin transactions this contract has already processed.
    ///         Prevents a duplicated `Callback` for one origin event across the
    ///         network's delivery/retry lifecycle.
    mapping(uint256 => bool) public processed;

    /// @notice Emitted whenever the sidecar reacts to a sandwich and queues a
    ///         cross-chain watchtower flag.
    event WatchtowerFlagQueued(
        uint256 indexed originChainId,
        address indexed searcher,
        uint256 bannedUntil,
        uint256 originBlock
    );

    /// @notice Emitted when the reaction is enabled or disabled by the owner.
    event EnabledSet(bool enabled);

    /// @param _originChainId     Chain where the hook is deployed (1301).
    /// @param _originContract     The contract whose `Sandwiched` events are watched
    ///                            (the VadiumHook in production).
    /// @param _callbackTarget     The contract that receives the watchtower flag
    ///                            callback (the VadiumHook in production).
    /// @param _callbackGasLimit   Gas budget for the cross-chain callback.
    /// @param _owner              The ReactVM owner (the deployer EOA).
    constructor(
        uint256 _originChainId,
        address _originContract,
        address _callbackTarget,
        uint64 _callbackGasLimit,
        address _owner
    ) payable AbstractReactive() {
        if (_originContract == address(0)) revert("Vadium: zero origin");
        if (_callbackTarget == address(0)) revert("Vadium: zero callback target");
        if (_owner == address(0)) revert("Vadium: zero owner");

        originChainId = _originChainId;
        originContract = _originContract;
        callbackTarget = _callbackTarget;
        callbackGasLimit = _callbackGasLimit;
        sandwichedTopic = uint256(keccak256("Sandwiched(address,uint256,bool,uint256,uint256)"));
        owner = _owner;
        enabled = true;

        ISubscriptionService(payable(address(SERVICE_ADDR)))
            .subscribe(
                _originChainId,
                _originContract,
                sandwichedTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
    }

    /// @notice Called by ReactVM whenever a subscribed event fires on the origin chain.
    /// @param log  The intercepted log record.
    function react(IReactive.LogRecord calldata log) external vmOnly {
        if (!enabled) return;
        // Only react to the exact event we subscribed to.
        if (log.topic_0 != sandwichedTopic) return;
        if (log._contract != originContract) return;
        // Dedup on the origin transaction hash so one sandwich never double-flags.
        if (processed[log.tx_hash]) return;
        processed[log.tx_hash] = true;

        // topic_1 = indexed `searcher` address (left-padded to 32 bytes).
        address searcher = address(uint160(log.topic_1));
        if (searcher == address(0)) return;

        // Non-indexed data: (uint256 slashed, bool isRepeat, uint256 remaining,
        // uint256 bannedUntil).
        (uint256 slashed,,, uint256 bannedUntil) =
            abi.decode(log.data, (uint256, bool, uint256, uint256));

        // The first argument is address(0) as a placeholder: Reactive Network
        // overwrites it with this contract's ReactVM ID, which the hook checks
        // against its bound watchtower.
        bytes memory payload = abi.encodeWithSignature(
            "onWatchtowerFlag(address,address,uint256)", address(0), searcher, bannedUntil
        );

        emit Callback(originChainId, callbackTarget, callbackGasLimit, payload);
        emit WatchtowerFlagQueued(originChainId, searcher, bannedUntil, log.block_number);
    }

    /// @notice Enable or disable the reaction. Owner-only.
    function setEnabled(bool _enabled) external {
        if (msg.sender != owner) revert("Vadium: not owner");
        enabled = _enabled;
        emit EnabledSet(_enabled);
    }

    /// @notice Transfer ownership. Owner-only.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert("Vadium: not owner");
        if (newOwner == address(0)) revert("Vadium: zero owner");
        owner = newOwner;
    }
}
