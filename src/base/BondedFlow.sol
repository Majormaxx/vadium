// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { ImmutableState } from "v4-periphery/src/base/ImmutableState.sol";

import { IBondedFlow } from "../interfaces/IBondedFlow.sol";
import { BondManager } from "../libraries/BondManager.sol";
import { BondParamsLib } from "../libraries/BondParamsLib.sol";
import { FeeDiscount } from "../libraries/FeeDiscount.sol";
import { InsurancePolicy } from "../libraries/InsurancePolicy.sol";
import { SandwichDetector } from "../libraries/SandwichDetector.sol";

/// @title BondedFlow
/// @notice Composable base for hooks that want a bonded, slashable identity for
///         professional flow: bonds, strikes, bans, flags, evidence, per-pool insurance
///         reserves, victim refunds, and the roles that operate them.
///
/// @dev    The base implements no `IHooks` function. A host hook:
///           1. calls `_bfBeforeInitialize(key)` from its `beforeInitialize`;
///           2. calls `_isExempt(poolId, sender)` wherever it grants the privilege;
///           3. calls `_bfRecordSwap(poolId, sender, zeroForOne, victimKey, shortfall)`
///              from its `afterSwap`;
///           4. routes its `_unlockCallback` to `_bfUnlockCallback` for reserve payouts.
///
///         Storage is split by scope. Hook-wide: bonds, strikes, bans, flags, refunds,
///         parameters, roles. Per pool: registration, configuration, the insurance
///         reserve, and the same-block ordering state the detector reads.
///
///         The bond token is one ERC-20 per hook instance and every registered pool
///         must contain it, because reserve payouts are a one-sided donate of that
///         token. Fee-on-transfer tokens are rejected at bond time.
///
/// @custom:security  `bond`, `withdrawBond`, `claimRefund`, `drainFlagged`, and
///                   `claimCoverage` are reentrancy-guarded. `withdrawBond` is never
///                   pausable, so a pause can never trap a searcher's capital.
abstract contract BondedFlow is
    IBondedFlow,
    ImmutableState,
    Ownable2Step,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using BondManager for BondManager.Bond;
    using InsurancePolicy for InsurancePolicy.InsuranceState;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Unlock payload discriminator for a reserve payout.
    uint8 internal constant UNLOCK_KIND_PAYOUT = 1;

    /// @notice A sender's most recent swap on a pool. One slot.
    struct SwapRecord {
        uint48 blockNumber;
        bool zeroForOne;
    }

    /// @notice Everything the base tracks for one pool.
    struct PoolState {
        bool registered;
        bool bondIsCurrency0;
        address operator;
        PoolKey key;
        PoolConfig cfg;
        InsurancePolicy.InsuranceState reserve;
        // Same-block ordering state, reset lazily on a block boundary.
        uint48 lastRecordedBlock;
        address lastSwapper;
        address lastVictimKey;
        uint96 lastVictimShortfall;
        mapping(address => SwapRecord) lastSwap;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @inheritdoc IBondedFlow
    IERC20 public immutable override bondToken;

    BondParams internal _params;

    /// @inheritdoc IBondedFlow
    mapping(address => BondManager.Bond) public override bonds;
    /// @inheritdoc IBondedFlow
    mapping(address => uint256) public override flaggedUntil;
    /// @inheritdoc IBondedFlow
    mapping(address => bytes32) public override flagEvidence;
    /// @inheritdoc IBondedFlow
    mapping(address => uint256) public override claimableRefund;
    /// @inheritdoc IBondedFlow
    mapping(address => uint256) public override refundCreditedAt;

    mapping(PoolId => PoolState) internal _pools;

    /// @inheritdoc IBondedFlow
    address public override watchtower;
    /// @inheritdoc IBondedFlow
    address public override keeper;

    /// @inheritdoc IBondedFlow
    uint256 public override totalBonded;
    /// @inheritdoc IBondedFlow
    uint256 public override totalReserve;
    /// @inheritdoc IBondedFlow
    uint256 public override totalClaimable;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyWatchtower() {
        if (msg.sender != watchtower || watchtower == address(0)) revert Unauthorized();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper || keeper == address(0)) revert Unauthorized();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param bondToken_ ERC-20 the bonds, reserves, and refunds are denominated in.
    /// @param owner_     Initial owner (two-step transferable).
    /// @param params     Initial bond economics; must satisfy `BondParamsLib.isValid`.
    constructor(IERC20 bondToken_, address owner_, BondParams memory params) Ownable(owner_) {
        if (address(bondToken_) == address(0)) revert ZeroAddress();
        bondToken = bondToken_;
        _setBondParams(params);
    }

    // ---------------------------------------------------------------------
    // Pool registry and configuration
    // ---------------------------------------------------------------------

    /// @inheritdoc IBondedFlow
    function registerPool(PoolKey calldata key, PoolConfig calldata cfg, address operator)
        external
        override
        onlyOwner
    {
        if (address(key.hooks) != address(this)) revert InvalidPoolKey();
        PoolId id = key.toId();
        PoolState storage p = _pools[id];
        if (p.registered) revert PoolAlreadyRegistered();

        bool bond0 = Currency.unwrap(key.currency0) == address(bondToken);
        bool bond1 = Currency.unwrap(key.currency1) == address(bondToken);
        if (!bond0 && !bond1) revert PoolMissingBondToken();
        _validateConfig(key.fee, cfg);

        p.registered = true;
        p.bondIsCurrency0 = bond0;
        p.operator = operator;
        p.key = key;
        p.cfg = cfg;
        emit PoolRegistered(id, operator, cfg);
    }

    /// @inheritdoc IBondedFlow
    function setPoolConfig(PoolId poolId, PoolConfig calldata cfg) external override {
        PoolState storage p = _pools[poolId];
        if (!p.registered) revert PoolNotRegistered();
        if (msg.sender != owner() && msg.sender != p.operator) revert Unauthorized();
        _validateConfig(p.key.fee, cfg);
        p.cfg = cfg;
        emit PoolConfigSet(poolId, cfg);
    }

    /// @inheritdoc IBondedFlow
    function setPoolOperator(PoolId poolId, address operator) external override onlyOwner {
        PoolState storage p = _pools[poolId];
        if (!p.registered) revert PoolNotRegistered();
        p.operator = operator;
        emit PoolOperatorSet(poolId, operator);
    }

    /// @inheritdoc IBondedFlow
    function setBondParams(BondParams calldata params) external override onlyOwner {
        _setBondParams(params);
    }

    /// @inheritdoc IBondedFlow
    function setWatchtower(address watchtower_) external override onlyOwner {
        watchtower = watchtower_;
        emit WatchtowerSet(watchtower_);
    }

    /// @inheritdoc IBondedFlow
    function setKeeper(address keeper_) external override onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @inheritdoc IBondedFlow
    function pause() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc IBondedFlow
    function unpause() external override onlyOwner {
        _unpause();
    }

    /// @dev Discount and base fee only make sense on a dynamic-fee pool: v4 ignores a
    ///      `beforeSwap` fee override on static-fee pools.
    function _validateConfig(uint24 poolFee, PoolConfig memory cfg) internal pure {
        if (poolFee.isDynamicFee()) {
            if (!cfg.baseFee.isValid()) revert InvalidConfig();
            if (
                cfg.feeDiscountBps > 0
                    && uint256(cfg.feeDiscountBps) * FeeDiscount.BPS_TO_FEE_UNITS >= cfg.baseFee
            ) revert InvalidConfig();
        } else if (cfg.baseFee != 0 || cfg.feeDiscountBps != 0) {
            revert InvalidConfig();
        }
    }

    function _setBondParams(BondParams memory params) internal {
        if (!BondParamsLib.isValid(params)) revert InvalidParams();
        _params = params;
        emit BondParamsSet(params);
    }

    // ---------------------------------------------------------------------
    // Host integration points
    // ---------------------------------------------------------------------

    /// @notice Reverts unless the pool was pre-registered by the owner.
    function _bfBeforeInitialize(PoolKey calldata key) internal view {
        if (!_pools[key.toId()].registered) revert PoolNotRegistered();
    }

    /// @notice Whether `sender` currently holds the privilege on `poolId`.
    function _isExempt(PoolId poolId, address sender) internal view virtual returns (bool) {
        if (paused()) return false;
        BondManager.Bond storage b = bonds[sender];
        if (b.amount == 0) return false;
        if (b.bannedUntil > block.number) return false;
        if (flaggedUntil[sender] > block.number) return false;
        PoolState storage p = _pools[poolId];
        if (p.cfg.exemptFirstSwapOnly && p.lastSwap[sender].blockNumber == uint48(block.number)) {
            return false;
        }
        return true;
    }

    /// @notice Record a swap and, if it completes a sandwich, penalize the sender.
    ///
    /// @param poolId              The pool.
    /// @param sender              The swapper as the PoolManager reports it (the router).
    /// @param zeroForOne          Swap direction.
    /// @param victimKey           Address to credit if this swap turns out to be the
    ///                            victim of the next swap's sandwich.
    /// @param victimShortfallBond How much worse than block start this swap executed,
    ///                            in bond-token units. 0 when it did not suffer.
    /// @return slashed            Bond confiscated from `sender`, if any.
    function _bfRecordSwap(
        PoolId poolId,
        address sender,
        bool zeroForOne,
        address victimKey,
        uint256 victimShortfallBond
    ) internal virtual returns (uint256 slashed) {
        PoolState storage p = _pools[poolId];
        SwapRecord storage rec = p.lastSwap[sender];

        if (rec.blockNumber == uint48(block.number)) {
            slashed = _detectAndPenalize(poolId, p, sender, rec.zeroForOne, zeroForOne);
        }

        rec.blockNumber = uint48(block.number);
        rec.zeroForOne = zeroForOne;
        p.lastRecordedBlock = uint48(block.number);
        p.lastSwapper = sender;
        p.lastVictimKey = victimKey;
        p.lastVictimShortfall =
            victimShortfallBond > type(uint96).max ? type(uint96).max : uint96(victimShortfallBond);
    }

    /// @dev The sender already swapped this block. Decide whether this swap completes a
    ///      sandwich around the immediately preceding swap, and penalize if so.
    function _detectAndPenalize(
        PoolId poolId,
        PoolState storage p,
        address sender,
        bool priorDirection,
        bool currentDirection
    ) internal returns (uint256 slashed) {
        (bool hit, uint256 shortfall) = _matches(p, sender, priorDirection, currentDirection);
        if (!hit) return 0;
        return _applyPenalty(poolId, p, sender, shortfall);
    }

    /// @dev Detector inputs from the pool's same-block ordering state.
    function _matches(
        PoolState storage p,
        address sender,
        bool priorDirection,
        bool currentDirection
    ) private view returns (bool hit, uint256 shortfall) {
        bool samePriorBlock = p.lastRecordedBlock == uint48(block.number);
        bool interveningDifferent = samePriorBlock && p.lastSwapper != sender;
        shortfall = samePriorBlock ? p.lastVictimShortfall : 0;
        bool victimSuffered = !p.cfg.requireVictimLoss || shortfall > 0;
        hit = SandwichDetector.detect(
            true, priorDirection, currentDirection, interveningDifferent, victimSuffered
        );
    }

    /// @dev Slash, refund the victim, credit the reserve, emit.
    function _applyPenalty(PoolId poolId, PoolState storage p, address sender, uint256 shortfall)
        private
        returns (uint256 taken)
    {
        bool isRepeat;
        bool bonded;
        (taken, isRepeat, bonded) = _slash(sender);
        if (!bonded) return 0;

        uint256 refunded = _refundVictim(poolId, p.lastVictimKey, shortfall, taken, sender);
        _creditReserve(p, taken - refunded);
        _emitSandwiched(poolId, sender, taken, isRepeat, refunded);
        _onSlashed(poolId, sender, taken, isRepeat);
    }

    function _creditReserve(PoolState storage p, uint256 amount) private {
        p.reserve.credit(amount);
        totalReserve += amount;
    }

    function _emitSandwiched(
        PoolId poolId,
        address sender,
        uint256 taken,
        bool isRepeat,
        uint256 refunded
    ) private {
        emit Sandwiched(
            poolId, sender, taken, isRepeat, bonds[sender].amount, flaggedUntil[sender], refunded
        );
    }

    /// @notice Apply the two-tier penalty to `sender`'s bond.
    /// @return slashed   Amount confiscated.
    /// @return isRepeat  Whether this was a repeat strike (full slash plus ban).
    /// @return bonded    Whether `sender` had a live bond (no penalty otherwise).
    function _slash(address sender)
        internal
        virtual
        returns (uint256 slashed, bool isRepeat, bool bonded)
    {
        BondManager.Bond storage b = bonds[sender];
        if (b.amount == 0) return (0, false, false);
        bonded = true;

        isRepeat = b.isRepeat(_params.firstOffenseLockExtensionBlocks, block.number);
        slashed = b.computeSlash(isRepeat, _params.firstSlashBps);

        b.strikeCount += 1;
        b.lastStrikeBlock = uint48(block.number);

        uint256 window;
        if (isRepeat) {
            window = _params.repeatOffenseBanBlocks;
            b.bannedUntil = uint48(block.number + window);
        } else {
            // Twice the escalation window, so a keeper can still drain after the
            // residual bond matures and the searcher exits.
            window = 2 * _params.firstOffenseLockExtensionBlocks;
        }
        _extendFlag(sender, block.number + window);

        if (slashed > 0) {
            b.amount -= uint128(slashed);
            totalBonded -= slashed;
        }
    }

    /// @notice Credit the victim with the smaller of its measured loss and the refund
    ///         ceiling. The credit is claimable by the attributed address.
    function _refundVictim(
        PoolId poolId,
        address victim,
        uint256 shortfall,
        uint256 slashed,
        address searcher
    ) internal virtual returns (uint256 refund) {
        if (victim == address(0) || shortfall == 0) return 0;
        uint256 cap = (slashed * _params.victimRefundBps) / 10_000;
        refund = shortfall < cap ? shortfall : cap;
        if (refund == 0) return 0;

        claimableRefund[victim] += refund;
        totalClaimable += refund;
        refundCreditedAt[victim] = block.number;
        emit VictimRefundCredited(poolId, victim, searcher, refund);
    }

    /// @notice Hook point for hosts that want to react to a slash.
    function _onSlashed(PoolId, address, uint256, bool) internal virtual { }

    /// @notice Extend a flag; never shortens an active one.
    function _extendFlag(address searcher, uint256 until) internal returns (bool extended) {
        if (until > flaggedUntil[searcher]) {
            flaggedUntil[searcher] = until;
            return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------
    // Bond lifecycle
    // ---------------------------------------------------------------------

    /// @inheritdoc IBondedFlow
    function bond(uint256 amount) external override whenNotPaused nonReentrant {
        BondManager.Bond storage b = bonds[msg.sender];
        if (b.amount > 0) revert BondAlreadyActive();
        if (b.bannedUntil > block.number) revert Banned(b.bannedUntil);
        if (amount < _params.minBond) revert BondTooSmall(amount, _params.minBond);
        if (amount > type(uint128).max) revert BondTooLarge();

        // Strikes and the last-strike block are deliberately left untouched: a
        // withdraw-and-rebond cycle does not launder a record.
        b.amount = uint128(amount);
        b.depositBlock = uint48(block.number);
        totalBonded += amount;

        uint256 before = bondToken.balanceOf(address(this));
        bondToken.safeTransferFrom(msg.sender, address(this), amount);
        if (bondToken.balanceOf(address(this)) - before != amount) revert TransferAmountMismatch();

        emit Bonded(msg.sender, amount, block.number);
    }

    /// @inheritdoc IBondedFlow
    function withdrawBond() external override nonReentrant {
        BondManager.Bond storage b = bonds[msg.sender];
        if (b.amount == 0) revert NoBond();
        if (b.bannedUntil > block.number) revert Banned(b.bannedUntil);

        uint256 maturity = b.maturityBlock(
            _params.minBondDurationBlocks, _params.firstOffenseLockExtensionBlocks
        );
        if (block.number < maturity) revert BondNotMatured(block.number, maturity);

        uint256 amount = b.amount;
        b.amount = 0;
        totalBonded -= amount;
        bondToken.safeTransfer(msg.sender, amount);
        emit BondWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc IBondedFlow
    function claimRefund() external override whenNotPaused nonReentrant returns (uint256 amount) {
        amount = claimableRefund[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimableRefund[msg.sender] = 0;
        totalClaimable -= amount;
        bondToken.safeTransfer(msg.sender, amount);
        emit RefundClaimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Watchtower, keeper, owner
    // ---------------------------------------------------------------------

    /// @inheritdoc IBondedFlow
    function flagFromWatchtower(
        PoolId poolId,
        address searcher,
        uint256 amount,
        uint256 banUntil,
        bytes32 evidenceHash
    ) external override onlyWatchtower {
        PoolState storage p = _pools[poolId];
        if (!p.registered) revert PoolNotRegistered();
        if (searcher == address(0)) revert ZeroAddress();
        if (evidenceHash == bytes32(0)) revert MissingEvidence();
        if (banUntil <= block.number) revert FlagExpired();

        _extendFlag(searcher, banUntil);
        flagEvidence[searcher] = evidenceHash;

        uint256 slashed;
        BondManager.Bond storage b = bonds[searcher];
        if (b.amount > 0 && amount > 0) {
            slashed = amount > b.amount ? b.amount : amount;
            // Same two-tier rules as the on-pool detector.
            bool isRepeat = b.isRepeat(_params.firstOffenseLockExtensionBlocks, block.number);
            b.strikeCount += 1;
            b.lastStrikeBlock = uint48(block.number);
            if (isRepeat) b.bannedUntil = uint48(block.number + _params.repeatOffenseBanBlocks);
            b.amount -= uint128(slashed);
            totalBonded -= slashed;
            p.reserve.credit(slashed);
            totalReserve += slashed;
        }

        emit Flagged(searcher, poolId, slashed, evidenceHash, flaggedUntil[searcher]);
    }

    /// @inheritdoc IBondedFlow
    function drainFlagged(PoolId poolId, address[] calldata searchers, uint256 maxAmount)
        external
        override
        onlyKeeper
        whenNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        if (searchers.length == 0) revert NotFlagged();
        for (uint256 i = 0; i < searchers.length; i++) {
            if (flaggedUntil[searchers[i]] <= block.number) revert NotFlagged();
        }
        if (maxAmount == 0) revert ZeroAmount();
        PoolState storage p = _pools[poolId];
        if (!p.registered) revert PoolNotRegistered();
        uint256 release = maxAmount < p.reserve.reserve ? maxAmount : p.reserve.reserve;
        return _payout(poolId, p, release);
    }

    /// @inheritdoc IBondedFlow
    function claimCoverage(PoolId poolId, uint256 amount)
        external
        override
        onlyOwner
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        PoolState storage p = _pools[poolId];
        if (!p.registered) revert PoolNotRegistered();
        return _payout(poolId, p, amount);
    }

    /// @inheritdoc IBondedFlow
    function sweepUnclaimed(address key, PoolId to)
        external
        override
        onlyOwner
        returns (uint256 amount)
    {
        amount = claimableRefund[key];
        if (amount == 0) revert NothingToClaim();
        if (block.number <= refundCreditedAt[key] + _params.refundClaimWindowBlocks) {
            revert RefundWindowOpen();
        }
        PoolState storage p = _pools[to];
        if (!p.registered) revert PoolNotRegistered();

        claimableRefund[key] = 0;
        totalClaimable -= amount;
        p.reserve.credit(amount);
        totalReserve += amount;
        emit UnclaimedSwept(key, to, amount);
    }

    /// @inheritdoc IBondedFlow
    function sweepToken(IERC20 token, address to, uint256 amount) external override onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == bondToken) {
            uint256 free = freeBalance();
            if (amount > free) revert SweepExceedsFree(amount, free);
        }
        token.safeTransfer(to, amount);
        emit TokenSwept(address(token), to, amount);
    }

    // ---------------------------------------------------------------------
    // Reserve payout plumbing
    // ---------------------------------------------------------------------

    function _payout(PoolId poolId, PoolState storage p, uint256 amount)
        internal
        returns (uint256)
    {
        uint256 taken = p.reserve.take(amount);
        totalReserve -= taken;
        poolManager.unlock(abi.encode(UNLOCK_KIND_PAYOUT, abi.encode(PoolId.unwrap(poolId), taken)));
        emit CoverageClaimed(poolId, taken, p.reserve.reserve);
        return taken;
    }

    /// @notice Executes a reserve payout inside the PoolManager unlock. The host routes
    ///         its `_unlockCallback` here for `UNLOCK_KIND_PAYOUT`.
    function _bfUnlockCallback(bytes memory payload) internal virtual returns (bytes memory) {
        (bytes32 idRaw, uint256 amount) = abi.decode(payload, (bytes32, uint256));
        PoolState storage p = _pools[PoolId.wrap(idRaw)];
        if (p.bondIsCurrency0) _donate(p.key, amount, 0);
        else _donate(p.key, 0, amount);
        return abi.encode(amount);
    }

    /// @notice Donate bond-token reserve to the pool's in-range LPs and settle it from
    ///         the hook's own balance. Virtual so a test harness can stub the pool.
    function _donate(PoolKey memory key, uint256 amount0, uint256 amount1) internal virtual {
        poolManager.donate(key, amount0, amount1, "");
        poolManager.sync(Currency.wrap(address(bondToken)));
        bondToken.safeTransfer(address(poolManager), amount0 + amount1);
        poolManager.settle();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IBondedFlow
    function bondParams() external view override returns (BondParams memory) {
        return _params;
    }

    /// @inheritdoc IBondedFlow
    function isBonded(address searcher) external view override returns (bool) {
        BondManager.Bond storage b = bonds[searcher];
        return b.amount > 0 && b.bannedUntil <= block.number;
    }

    /// @inheritdoc IBondedFlow
    function isBanned(address searcher) external view override returns (bool) {
        return bonds[searcher].bannedUntil > block.number;
    }

    /// @inheritdoc IBondedFlow
    function isExempt(PoolId poolId, address searcher) external view override returns (bool) {
        return _isExempt(poolId, searcher);
    }

    /// @inheritdoc IBondedFlow
    function bondedBalance(address searcher) external view override returns (uint256) {
        return bonds[searcher].amount;
    }

    /// @inheritdoc IBondedFlow
    function freeBalance() public view override returns (uint256) {
        uint256 bal = bondToken.balanceOf(address(this));
        uint256 owed = totalBonded + totalReserve + totalClaimable;
        return bal > owed ? bal - owed : 0;
    }

    /// @inheritdoc IBondedFlow
    function isPoolRegistered(PoolId poolId) external view override returns (bool) {
        return _pools[poolId].registered;
    }

    /// @inheritdoc IBondedFlow
    function poolOperator(PoolId poolId) external view override returns (address) {
        return _pools[poolId].operator;
    }

    /// @inheritdoc IBondedFlow
    function poolConfig(PoolId poolId) external view override returns (PoolConfig memory) {
        return _pools[poolId].cfg;
    }

    /// @inheritdoc IBondedFlow
    function poolKeyOf(PoolId poolId) public view override returns (PoolKey memory) {
        PoolState storage p = _pools[poolId];
        if (!p.registered) revert PoolNotRegistered();
        return p.key;
    }

    /// @inheritdoc IBondedFlow
    function unbondedFee(PoolId poolId) external view override returns (uint24) {
        return _unbondedFee(_pools[poolId]);
    }

    /// @inheritdoc IBondedFlow
    function insuranceReserve(PoolId poolId) external view override returns (uint256) {
        return _pools[poolId].reserve.remaining();
    }

    /// @inheritdoc IBondedFlow
    function remainingCoverage(PoolId poolId) external view override returns (uint256) {
        return _pools[poolId].reserve.remaining();
    }

    /// @inheritdoc IBondedFlow
    function slashedPledged(PoolId poolId) external view override returns (uint256) {
        return _pools[poolId].reserve.slashedPledged;
    }

    /// @inheritdoc IBondedFlow
    function totalWithdrawn(PoolId poolId) external view override returns (uint256) {
        return _pools[poolId].reserve.withdrawn;
    }

    /// @inheritdoc IBondedFlow
    function lastSwapOf(PoolId poolId, address sender)
        external
        view
        override
        returns (uint48 blockNumber, bool zeroForOne)
    {
        SwapRecord storage r = _pools[poolId].lastSwap[sender];
        return (r.blockNumber, r.zeroForOne);
    }

    /// @inheritdoc IBondedFlow
    function poolBlockState(PoolId poolId)
        external
        view
        override
        returns (
            uint48 lastRecordedBlock,
            address lastSwapper,
            address lastVictimKey,
            uint96 lastVictimShortfall
        )
    {
        PoolState storage p = _pools[poolId];
        return (p.lastRecordedBlock, p.lastSwapper, p.lastVictimKey, p.lastVictimShortfall);
    }

    /// @dev Fee an unbonded swapper pays: the configured base fee on a dynamic pool,
    ///      the pool's static fee otherwise.
    function _unbondedFee(PoolState storage p) internal view returns (uint24) {
        return p.key.fee.isDynamicFee() ? p.cfg.baseFee : p.key.fee;
    }
}
