// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { SafeCallback } from "v4-periphery/src/base/SafeCallback.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";

import { BondManager } from "./libraries/BondManager.sol";
import { FeeDiscount } from "./libraries/FeeDiscount.sol";
import { InsurancePolicy } from "./libraries/InsurancePolicy.sol";
import { SandwichDetector } from "./libraries/SandwichDetector.sol";
import { IVadiumHook } from "./interfaces/IVadiumHook.sol";

/// @title VadiumHook
/// @notice Uniswap v4 hook that lets searchers post a bond in exchange for a swap-fee
///         discount, and slashes that bond when the searcher's own on-chain behavior
///         matches a sandwich pattern within the same block. Slashed funds flow into an
///         LP insurance reserve that an authorized keeper drains to in-range LPs via a
///         single `unlock()`.
///
/// @dev    The central design insight: the bond is what makes detection possible. A
///         searcher only benefits from bonding if they keep using the same bonded
///         address across trades (that is how the fee discount attaches), but reusing
///         the same address across the two legs of a sandwich is exactly what makes the
///         sandwich detectable by this hook. Bonding funds the penalty and creates the
///         identity consistency the detector depends on.
///
///         The hook governs a single pool (locked at construction). The bond is
///         denominated in the pool's token1, which is also the token that gets slashed
///         and held in the insurance reserve — no oracle, no swap, no normalization
///         needed.
///
///         Detection is the buildable subset of a sandwich: same-address, same-block,
///         direction-reversal with an intervening swap from a different address. It is
///         scoped, not a full sandwich detector — see the README's Adversarial Analysis
///         for the disclosed limitations.
///
/// @custom:security  Slashing happens only inside the `afterSwap` callback, which v4
///                   reentrancy-locks. Bond token transfers use SafeERC20. Callback
///                   entrypoints are gated by `onlyPoolManager`. The contract is NOT
///                   audited; use at your own risk.
contract VadiumHook is IHooks, SafeCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using InsurancePolicy for InsurancePolicy.InsuranceState;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice A searcher's bond, tracked via the BondManager.Bond struct.
    using BondManager for BondManager.Bond;

    /// @notice A single swap record per searcher, scoped to one block.
    /// @dev    Position-in-block is a monotonic per-block counter, so a later swap
    ///         always has a strictly larger `positionInBlock` than an earlier one.
    struct SwapRecord {
        uint256 blockNumber;
        bool zeroForOne;
        uint256 positionInBlock;
    }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Swap-fee discount granted to bonded, non-banned searchers, in basis
    ///         points (10 = 0.10% off the pool fee).
    uint24 public constant DEFAULT_FEE_DISCOUNT_BPS = 10;

    /// @notice Minimum bond amount in token1 (6-decimal USDC = 100 USDC). An owner-set
    ///         constant for the hackathon scope; a production version would let LPs vote.
    uint256 public constant DEFAULT_MIN_BOND = 100e6;

    /// @notice Minimum bond duration in blocks before withdrawal is eligible. Kept
    ///         short for the testnet demo; production targets ~1 day L1 (≈7200 blocks).
    uint256 public constant DEFAULT_MIN_BOND_DURATION_BLOCKS = 100;

    /// @notice Portion of the bond confiscated on a first offense, in basis points.
    uint256 public constant FIRST_SLASH_BPS = 5000; // 50%

    /// @notice Lock extension (in blocks) applied after a first offense. A repeat
    ///         violation within this extended window escalates to a full slash.
    uint256 public constant FIRST_OFFENSE_LOCK_EXTENSION_BLOCKS = 7_200; // ~1 day L1

    /// @notice Ban period (in blocks) after a repeat offense during which the address
    ///         cannot re-bond. ~30 days L1.
    uint256 public constant REPEAT_OFFENSE_BAN_BLOCKS = 216_000;

    /// @notice Zero-address sentinel — never a legitimate swapper. Used for "no prior
    ///         swap this block" bookkeeping.
    address private constant ZERO = address(0);

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @notice The pool's static LP fee. The bonded discount reduces this fee via the
    ///         `beforeSwap` fee override; unbonded swappers pay it in full.
    uint24 public immutable fee;

    /// @notice The pool's tick spacing.
    int24 public immutable tickSpacing;

    /// @notice The pool's two tokens.
    Currency public immutable currency0;
    Currency public immutable currency1;

    /// @notice The pool's token1 — the bond denomination and the target for slashes.
    IERC20 public immutable bondToken;

    // -------------------------------------------------------------------------
    // Mutable state
    // -------------------------------------------------------------------------

    /// @notice Per-searcher bond and strike state.
    mapping(address searcher => BondManager.Bond) public bonds;

    /// @notice Per-searcher last swap record, used by the sandwich detector.
    mapping(address searcher => SwapRecord) public lastSwap;

    /// @notice Block currently being tracked for swap-order bookkeeping.
    uint256 public lastRecordedBlock;

    /// @notice Monotonic position-in-block counter. Resets when the block changes.
    uint256 public blockSwapCounter;

    /// @notice Address that performed the most recent swap this block, and its
    ///         position. The immediately-preceding swapper.
    address public lastSwapper;
    uint256 public lastSwapperPosition;

    /// @notice Whether any swap has been recorded in the current block.
    bool public hasPriorSwap;

    /// @notice Owner of the hook. Set once at construction to the deployer; controls the
    ///         role assignments and the owner-gated `claimCoverage` payout.
    address public owner;

    /// @notice The reactive watchtower. Set once by the owner; the only address allowed
    ///         to call `flagFromWatchtower`.
    address public watchtower;

    /// @notice The keeper. Set once by the owner; the only address allowed to call
    ///         `drainFlagged` to push the reserve out to LPs.
    address public keeper;

    /// @notice The pooled LP insurance reserve.
    InsurancePolicy.InsuranceState internal insurance;

    /// @notice End-of-flag block for an address flagged by the watchtower. An address
    ///         flagged via watchtower (without an on-chain bond) becomes eligible for
    ///         the reserve payout only once it is drained through this map's presence
    ///         during `drainFlagged`.
    mapping(address searcher => uint256 flaggedUntil) public flaggedUntil;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Reverts when a searcher bonds with zero or below the minimum.
    error BondTooSmall(uint256 amount, uint256 minimum);

    /// @notice Reverts when withdrawing a bond still inside its minimum lock duration.
    error BondNotMatured(uint256 currentBlock, uint256 maturityBlock);

    /// @notice Reverts when a banned address tries to withdraw or re-bond.
    error Banned(uint256 bannedUntil);

    /// @notice Reverts when the caller has no live bond.
    error NoBond();

    /// @notice Reverts when re-bonding while a bond is already active.
    error BondAlreadyActive();

    /// @notice Reverts when an unauthorized caller uses a role-gated entrypoint.
    error Unauthorized();

    /// @notice Reverts when the watchtower or keeper role is set more than once.
    error AlreadySet();

    /// @notice Reverts when a payout or drain references an address that was not
    ///         flagged, or lists no flagged addresses.
    error NotFlagged();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a searcher posts a bond.
    event Bonded(address indexed searcher, uint256 amount, uint256 depositBlock);

    /// @notice Emitted when a searcher withdraws their bond.
    event BondWithdrawn(address indexed searcher, uint256 amount);

    /// @notice Emitted when a sandwich pattern is detected and the bond is slashed.
    event Sandwiched(
        address indexed searcher,
        uint256 slashed,
        bool isRepeat,
        uint256 remaining,
        uint256 bannedUntil
    );

    /// @notice Emitted when the watchtower role is assigned (once).
    event WatchtowerSet(address indexed watchtower);

    /// @notice Emitted when the keeper role is assigned (once).
    event KeeperSet(address indexed keeper);

    /// @notice Emitted when the watchtower flags an address (and optionally slashes a
    ///         live bond into the reserve).
    event Flagged(address indexed searcher, uint256 slashed, uint256 flaggedUntil);

    /// @notice Emitted when reserve capital is pushed out to in-range LPs.
    event CoverageClaimed(uint256 amount, uint256 remainingReserve);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param _poolManager  The Uniswap v4 PoolManager.
    /// @param _currency0    The pool's lower token (sorted numerically).
    /// @param _currency1    The pool's higher token — the bond denomination.
    /// @param _fee          The pool's static LP fee (e.g. 3000 = 0.30%). The bonded
    ///                      discount is applied as a `beforeSwap` fee override, which
    ///                      v4 honors on static-fee pools as well.
    /// @param _tickSpacing  The pool's tick spacing.
    constructor(
        IPoolManager _poolManager,
        Currency _currency0,
        Currency _currency1,
        uint24 _fee,
        int24 _tickSpacing,
        address _owner
    ) SafeCallback(_poolManager) {
        // A static fee is required and must be within v4's ceiling. An exact
        // DYNAMIC_FEE_FLAG (0x800000) value exceeds MAX_LP_FEE, so it is excluded.
        if (!_fee.isValid()) revert("Vadium: pool fee out of range");
        if (_owner == ZERO) revert("Vadium: zero owner");

        fee = _fee;
        tickSpacing = _tickSpacing;
        currency0 = _currency0;
        currency1 = _currency1;
        bondToken = IERC20(Currency.unwrap(_currency1));

        // The bond is ERC-20 token1, so the zero address (native token) is invalid.
        if (address(bondToken) == ZERO) revert("Vadium: bond token cannot be zero address");

        // A foundry CREATE2 broadcast deploys through its factory, so `msg.sender`
        // is the factory, not the deployer. The owner is therefore passed explicitly
        // (the broadcast sender) rather than read from msg.sender. Watchtower and
        // keeper are assigned later, once, by the owner.
        owner = _owner;
    }

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyWatchtower() {
        if (msg.sender != watchtower) revert Unauthorized();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert Unauthorized();
        _;
    }

    /// @notice Bootstrap the owner when it is unset. Runs once, permissionless only
    ///         because it can never fire on a normal deployment.
    ///
    /// @dev    The constructor sets `owner` on a regular deployment, so this reverts
    ///         (`AlreadySet`) everywhere the constructor has run. It exists for the
    ///         hook-at-permission-address pattern, where an implementation is deployed
    ///         and its bytecode is etch-copied onto the permission-derived address
    ///         without running the constructor (the local test harness does exactly
    ///         this). In that case the owner slot is still zero and `initializeOwner`
    ///         seeds it once.
    ///
    ///         To close the open-grab window, seeding is refused once the hook has
    ///         begun operating (any role assigned, any slash into the reserve). A real
    ///         deployment must therefore seed the owner in the same transaction that
    ///         places the hook; leave that hop unseeded at your own risk.
    function initializeOwner(address _owner) external {
        if (_owner == ZERO) revert("Vadium: zero owner");
        if (owner != ZERO) revert AlreadySet();
        if (watchtower != ZERO || keeper != ZERO) revert AlreadySet();
        if (insurance.slashedPledged != 0 || insurance.withdrawn != 0) revert AlreadySet();
        owner = _owner;
    }

    /// @notice Assign the watchtower, once. Owner-only. The watchtower is an off-chain
    ///         reactive contract that flags addresses for the insurance payout.
    function setWatchtower(address _watchtower) external onlyOwner {
        if (_watchtower == ZERO) revert("Vadium: zero watchtower");
        if (watchtower != ZERO) revert AlreadySet();
        watchtower = _watchtower;
        emit WatchtowerSet(_watchtower);
    }

    /// @notice Assign the keeper, once. Owner-only. The keeper can drain the insurance
    ///         reserve out to LPs for flagged addresses.
    function setKeeper(address _keeper) external onlyOwner {
        if (_keeper == ZERO) revert("Vadium: zero keeper");
        if (keeper != ZERO) revert AlreadySet();
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    /// @notice Flag an address via the watchtower. Watchtower-only.
    ///
    /// @dev    Marks `searcher` as flagged until `banUntil`. If the address holds a live
    ///         bond, up to `amount` of it is slashed into the reserve immediately (an
    ///         on-chain bond lets the hook confiscate capital now, not in a later drain).
    ///         An unbonded address is flagged but left for the keeper's later `drainFlagged`.
    ///
    /// @param searcher  Address to flag.
    /// @param amount    Token1 to slash from a live bond (0 leaves the bond untouched and
    ///                  only records the flag).
    /// @param banUntil  Block before which the flag is considered active.
    function flagFromWatchtower(address searcher, uint256 amount, uint256 banUntil)
        external
        onlyWatchtower
    {
        if (searcher == ZERO) revert("Vadium: zero searcher");
        if (banUntil <= block.number) revert("Vadium: flag already expired");
        if (flaggedUntil[searcher] != 0 && flaggedUntil[searcher] >= block.number) {
            revert("Vadium: re-flag before expiry");
        }
        flaggedUntil[searcher] = banUntil;

        BondManager.Bond storage b = bonds[searcher];
        uint256 slashed = 0;
        if (b.amount > 0) {
            uint256 toSlash = amount > b.amount ? b.amount : amount;
            if (toSlash > 0) {
                b.amount -= toSlash;
                slashed = toSlash;
                insurance.credit(toSlash);

                // A watchtower slash plays by the same two-tier rules as the on-pool
                // detector: a repeat while still inside the extended lock escalates to
                // a full ban, otherwise it records a strike and extends the lock. This
                // closes the gap where repeated watchtower flags could bleed a live
                // bond to zero with no lock and no ban.
                bool isRepeat = b.strikeCount > 0
                    && b.isWithinExtendedLock(FIRST_OFFENSE_LOCK_EXTENSION_BLOCKS, block.number);
                if (isRepeat) {
                    b.bannedUntil = block.number + REPEAT_OFFENSE_BAN_BLOCKS;
                } else {
                    b.depositBlock = block.number;
                    b.strikeCount++;
                }
            }
        }

        emit Flagged(searcher, slashed, banUntil);
    }

    /// @notice Push the full insurance reserve out to the pool's LPs. Keeper-only.
    ///
    /// @dev    Requires every listed address to hold an active watchtower flag. The
    ///         payout happens through a real PoolManager `unlock`, so the settlement
    ///         (donate + sync + settle) runs in one atomic callback. This is the path a
    ///         Reactive watchtower would trigger on-chain.
    ///
    /// @param searchers  Flagged addresses that justify the payout.
    /// @return amount    The token1 pushed out of the reserve.
    function drainFlagged(address[] calldata searchers)
        external
        onlyKeeper
        returns (uint256 amount)
    {
        if (searchers.length == 0) revert NotFlagged();
        for (uint256 i = 0; i < searchers.length; i++) {
            // Only an active (unexpired) flag justifies a payout.
            if (flaggedUntil[searchers[i]] <= block.number) revert NotFlagged();
        }
        return _payout(insurance.reserve);
    }

    /// @notice Push a specific amount of reserve capital out to the pool's LPs.
    ///         Owner-only.
    ///
    /// @param amount  Token1 to release from the reserve.
    /// @return The amount released.
    function claimCoverage(uint256 amount) external onlyOwner returns (uint256) {
        return _payout(amount);
    }

    /// @notice Release `amount` from the reserve to in-range LPs via a real unlock.
    ///
    /// @dev    `_unlockCallback` runs the donation (donate + sync + settle) against the
    ///         PoolManager. The hook must hold the token1 it is donating; that capital
    ///         is what accumulated in the reserve from bond slashes.
    function _payout(uint256 amount) internal returns (uint256) {
        uint256 taken = insurance.take(amount);
        poolManager.unlock(abi.encode(taken));
        emit CoverageClaimed(taken, insurance.reserve);
        return taken;
    }

    /// @notice Executes the reserve payout inside the PoolManager's `unlock` callback.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        _donate(amount);
        return abi.encode(amount);
    }

    // -------------------------------------------------------------------------
    // Permission flags
    // -------------------------------------------------------------------------

    /// @notice Permission flags for the hooks this contract implements.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------
    // IHooks — token callbacks (unused by Vadium; pure selectors)
    // -------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // -------------------------------------------------------------------------
    // IHooks — beforeSwap (bonded free discount)
    // -------------------------------------------------------------------------

    /// @notice Applies the bonded fee discount in `beforeSwap`.
    ///
    /// @dev    Only bonded, non-banned swappers receive the reduced fee. The returned
    ///         `uint24` carries the OVERRIDE_FEE_FLAG so the PoolManager honors it.
    ///
    /// @return selector       The `IHooks.beforeSwap` selector.
    /// @return delta          `BeforeSwapDeltaLibrary.ZERO_DELTA` — Vadium never moves
    ///                        capital itself in `beforeSwap`.
    /// @return feeOverride    The discounted fee if the sender is bonded and not
    ///                        banned; otherwise 0 (no override).
    function beforeSwap(
        address sender,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        // A v4 hook cannot reorder transactions within a block; ordering is decided by
        // the builder before the hook ever runs. So "priority" is not execution-order
        // priority; it is a dynamic free discount. Bonded, non-banned swappers pay the
        // pool fee minus the discount; everyone else pays the standard fee.
        uint24 overrideFee = 0;

        BondManager.Bond storage b = bonds[sender];
        if (b.amount > 0 && b.bannedUntil <= block.number && flaggedUntil[sender] <= block.number) {
            // Discount is applied to the pool's static fee.
            uint24 discounted = FeeDiscount.discountedFee(fee, DEFAULT_FEE_DISCOUNT_BPS);
            // The override is only honored if the override flag is set.
            overrideFee = discounted | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overrideFee);
    }

    // -------------------------------------------------------------------------
    // IHooks — afterSwap (sandwich detection + slashing)
    // -------------------------------------------------------------------------

    /// @notice Runs sandwich detection and slashes on `afterSwap`.
    ///
    /// @param sender      The swapper. This is the address Vadium attributes a
    ///                    sandwich pattern to — the bonded identity.
    /// @param params      The swap parameters; the direction (`zeroForOne`) drives the
    ///                    detector.
    function afterSwap(
        address sender,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _recordSwap(sender, params.zeroForOne);
        return (IHooks.afterSwap.selector, 0);
    }

    // -------------------------------------------------------------------------
    // Bond lifecycle
    // -------------------------------------------------------------------------

    /// @notice Post a bond of `amount` token1. Grants the free discount.
    ///
    /// @dev    Bonding is permissionless. Requires `amount >= DEFAULT_MIN_BOND`.
    ///         Reverts if a bond is already active (withdraw first) or the address
    ///         is banned. The bond is not withdrawable until the minimum duration
    ///         has elapsed, so it is a standing commitment rather than a per-tx toggle.
    ///
    /// @param amount  Amount of token1 to bond, in the token's native decimals.
    function bond(uint256 amount) external {
        BondManager.Bond storage b = bonds[msg.sender];

        if (b.amount > 0) revert BondAlreadyActive();
        if (b.bannedUntil > block.number) revert Banned(b.bannedUntil);
        if (amount < DEFAULT_MIN_BOND) revert BondTooSmall(amount, DEFAULT_MIN_BOND);

        b.amount = amount;
        b.depositBlock = block.number;
        b.strikeCount = 0;

        bondToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Bonded(msg.sender, amount, block.number);
    }

    /// @notice Withdraw the full remaining bond back to the caller.
    ///
    /// @dev    Reverts if the minimum duration has not elapsed or the address is
    ///         banned. Only the remaining (post-slash) amount is returned.
    function withdrawBond() external {
        BondManager.Bond storage b = bonds[msg.sender];

        if (b.amount == 0) revert NoBond();
        if (b.bannedUntil > block.number) revert Banned(b.bannedUntil);

        // A first offense stretches the minimum-duration lock to the extended window
        // (default 7,200 blocks), so a struck searcher cannot instantly re-discharge
        // the residual bond and walk away from the scheme.
        uint256 maturity = b.depositBlock
            + (b.strikeCount > 0
                    ? FIRST_OFFENSE_LOCK_EXTENSION_BLOCKS
                    : DEFAULT_MIN_BOND_DURATION_BLOCKS);
        if (block.number < maturity) revert BondNotMatured(block.number, maturity);

        uint256 amount = b.amount;
        b.amount = 0;

        bondToken.safeTransfer(msg.sender, amount);

        emit BondWithdrawn(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Whether `searcher` has a live bond and is currently eligible for the fee
    ///         discount.
    /// @param searcher  Address to check.
    /// @return true if bonded and not banned.
    function isBonded(address searcher) external view returns (bool) {
        BondManager.Bond storage b = bonds[searcher];
        return b.amount > 0 && b.bannedUntil <= block.number;
    }

    /// @notice Remaining bond balance of `searcher` (after any slashes).
    /// @param searcher  Address to check.
    /// @return Remaining bonded token1 amount.
    function bondedBalance(address searcher) external view returns (uint256) {
        return bonds[searcher].amount;
    }

    /// @notice Whether `searcher` is currently banned from re-bonding.
    /// @param searcher  Address to check.
    /// @return true if banned until `bannedUntil`, false otherwise.
    function isBanned(address searcher) external view returns (bool) {
        return bonds[searcher].bannedUntil > block.number;
    }

    /// @notice Token1 currently held in the LP insurance reserve.
    function insuranceReserve() external view returns (uint256) {
        return insurance.remaining();
    }

    /// @notice Cumulative token1 slashed and credited into the insurance reserve.
    function slashedPledged() external view returns (uint256) {
        return insurance.slashedPledged;
    }

    /// @notice Cumulative token1 paid out of the reserve to LPs.
    function totalWithdrawn() external view returns (uint256) {
        return insurance.withdrawn;
    }

    /// @notice Live coverage still available to pay out. Identical to `insuranceReserve`.
    function remainingCoverage() external view returns (uint256) {
        return insurance.remaining();
    }

    // -------------------------------------------------------------------------
    // Internal — swap bookkeeping, slashing, donation
    // -------------------------------------------------------------------------

    /// @notice Record a swap and, if it completes a sandwich pattern, slash and donate.
    ///
    /// @dev    The hook observes every swap against its pool in block order. On a
    ///         block boundary it resets the ordering counters. Every swap updates the
    ///         sender's record and the block's last-swapper, so the next swap has a
    ///         correct baseline regardless of whether this one was flagged.
    ///
    /// @param sender      The swapper (the bonded identity to attribute the pattern to).
    /// @param zeroForOne  Direction of the swap.
    function _recordSwap(address sender, bool zeroForOne) internal {
        // Reset the block-scoped ordering state on a new block.
        if (block.number != lastRecordedBlock) {
            blockSwapCounter = 0;
            lastSwapper = ZERO;
            lastSwapperPosition = 0;
            hasPriorSwap = false;
            lastRecordedBlock = block.number;
        }

        blockSwapCounter++;
        uint256 position = blockSwapCounter;

        SwapRecord storage prior = lastSwap[sender];
        bool hadPriorSameBlock = prior.blockNumber == block.number;

        // An intervening swap from a different address is detected via the immediately
        // preceding swapper: if it differs from the current sender, a different address
        // swapped strictly after the sender's prior leg (positions are sequential and
        // strictly increasing within a block).
        if (hadPriorSameBlock) {
            bool interveningDifferent = hasPriorSwap && lastSwapper != sender;
            bool isSandwich = SandwichDetector.detect(
                hadPriorSameBlock, prior.zeroForOne, zeroForOne, interveningDifferent
            );

            if (isSandwich) {
                _slash(sender);
            }
        }

        // Record this swap as the sender's latest and as the block's last swapper.
        prior.blockNumber = block.number;
        prior.zeroForOne = zeroForOne;
        prior.positionInBlock = position;
        hasPriorSwap = true;
        lastSwapper = sender;
        lastSwapperPosition = position;
    }

    /// @notice Confiscate bond capital for a detected sandwich and donate it to LPs.
    ///
    /// @dev    Two-tier slash: the first offense takes only a portion and extends the
    ///         lock; a repeat within the extended window takes the full remaining bond
    ///         and bans the address. This is calibrated against false positives — a
    ///         same-block direction reversal is a strong signal but not proof beyond
    ///         doubt, so a full slash on a first violation is disproportionate.
    ///
    /// @param sender  The bonded address flagged for a sandwich.
    function _slash(address sender) internal {
        BondManager.Bond storage b = bonds[sender];
        if (b.amount == 0) return; // nothing bonded, nothing to slash

        bool isRepeat = b.strikeCount > 0
            && b.isWithinExtendedLock(FIRST_OFFENSE_LOCK_EXTENSION_BLOCKS, block.number);

        uint256 slashed = b.computeSlash(isRepeat, FIRST_SLASH_BPS);
        if (slashed == 0) {
            // A zero-amount slash is still recorded as a first strike to preserve the
            // escalation guarantee, but there is no capital to donate.
            if (!isRepeat) {
                b.strikeCount++;
                b.depositBlock = block.number;
            }
            return;
        }

        b.amount -= slashed;

        uint256 bannedUntil = 0;
        if (isRepeat) {
            bannedUntil = block.number + REPEAT_OFFENSE_BAN_BLOCKS;
            b.bannedUntil = bannedUntil;
        } else {
            // First offense: extend the minimum-duration lock by the extension window
            // and increment the strike counter.
            b.depositBlock = block.number;
            b.strikeCount++;
        }

        // The slashed capital is parked in the LP insurance reserve, not donated
        // instantly. A keeper later drains it to LPs in one atomic unlock.
        insurance.credit(slashed);

        emit Sandwiched(sender, slashed, isRepeat, b.amount, bannedUntil);
    }

    /// @notice Donate `amount1` of token1 to the pool's in-range LPs.
    ///
    /// @dev    The hook holds the bond token1. `donate()` routes one-sided token1 to
    ///         in-range LPs with no swap or oracle. This runs inside the `unlock`
    ///         callback during a reserve payout: donate (which debits a token1 delta
    ///         against the hook), then settle the owed token1 by syncing and
    ///         transferring the donation to the PoolManager.
    ///
    /// @param amount1  Amount of token1 to donate.
    function _donate(uint256 amount1) internal virtual {
        poolManager.donate(_poolKey(), 0, amount1, abi.encode(address(this)));

        // Settle the donation: the hook now owes the pool `amount1` of token1. Sync
        // the currency, transfer the capital, then settle to clear the delta.
        poolManager.sync(currency1);
        bondToken.safeTransfer(address(poolManager), amount1);
        poolManager.settle();
    }

    /// @notice Reconstruct the full `PoolKey` from the immutables.
    function _poolKey() internal view returns (PoolKey memory k) {
        k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
    }
}
