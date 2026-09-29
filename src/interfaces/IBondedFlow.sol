// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";

/// @title IBondedFlow
/// @notice Bonded, slashable identity for professional flow on Uniswap v4 pools.
///
/// @dev    A searcher posts a bond in the hook's bond token. While the bond is live and
///         the address is neither banned nor flagged, the address is "exempt": the host
///         hook grants it a privilege (in Vadium, exemption from the block-start price
///         clamp, optionally a fee discount). If the address's own flow reads as a
///         sandwich, the bond is slashed: part refunds the victim, the rest funds the
///         pool's LP insurance reserve. Bonds, strikes, bans, and flags are hook-wide;
///         reserves and configuration are per pool.
interface IBondedFlow {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Hook-wide bond economics. All block counts are in the host chain's
    ///         blocks.
    /// @param minBond                        Smallest bond accepted.
    /// @param minBondDurationBlocks          Lock before an unstruck bond may withdraw.
    /// @param firstSlashBps                  Portion slashed on a first strike.
    /// @param firstOffenseLockExtensionBlocks Window after a strike inside which another
    ///                                       strike is a repeat; also the lock after a strike.
    /// @param repeatOffenseBanBlocks         Re-bonding ban after a repeat strike.
    /// @param victimRefundBps                Ceiling on the share of a slash refunded to
    ///                                       the victim (the rest goes to the reserve).
    /// @param refundClaimWindowBlocks        Blocks a victim has to claim before the owner
    ///                                       may sweep the credit into a reserve.
    struct BondParams {
        uint256 minBond;
        uint256 minBondDurationBlocks;
        uint256 firstSlashBps;
        uint256 firstOffenseLockExtensionBlocks;
        uint256 repeatOffenseBanBlocks;
        uint256 victimRefundBps;
        uint256 refundClaimWindowBlocks;
    }

    /// @notice Per-pool behavior.
    /// @param clampEnabled        Whether unbonded flow is clamped to the block-start price.
    /// @param exemptFirstSwapOnly Whether a bonded address is exempt only on its first swap
    ///                            in a block.
    /// @param requireVictimLoss   Whether a slash needs the intervening swap to have executed
    ///                            worse than block start.
    /// @param baseFee             Fee charged to unbonded swappers on a dynamic-fee pool.
    ///                            Must be 0 on a static-fee pool.
    /// @param feeDiscountBps      Discount for exempt swappers, dynamic-fee pools only.
    struct PoolConfig {
        bool clampEnabled;
        bool exemptFirstSwapOnly;
        bool requireVictimLoss;
        uint24 baseFee;
        uint24 feeDiscountBps;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event PoolRegistered(PoolId indexed poolId, address indexed operator, PoolConfig cfg);
    event PoolConfigSet(PoolId indexed poolId, PoolConfig cfg);
    event PoolOperatorSet(PoolId indexed poolId, address indexed operator);
    event CollectiveSlashSet(PoolId indexed poolId, bool enabled);
    event BondParamsSet(BondParams params);
    event WatchtowerSet(address indexed watchtower);
    event KeeperSet(address indexed keeper);

    event Bonded(address indexed searcher, uint256 amount, uint256 depositBlock);
    event BondWithdrawn(address indexed searcher, uint256 amount);

    /// @notice A bonded address completed a sandwich pattern and was penalized.
    event Sandwiched(
        PoolId indexed poolId,
        address indexed searcher,
        uint256 slashed,
        bool isRepeat,
        uint256 remaining,
        uint256 flaggedUntil,
        uint256 refunded
    );
    event VictimRefundCredited(
        PoolId indexed poolId, address indexed victim, address indexed searcher, uint256 amount
    );
    event RefundClaimed(address indexed victim, uint256 amount);

    /// @notice An address was flagged (watchtower, on-pool slash, or cross-chain relay).
    event Flagged(
        address indexed searcher,
        PoolId indexed poolId,
        uint256 slashed,
        bytes32 evidenceHash,
        uint256 flaggedUntil
    );
    event CoverageClaimed(PoolId indexed poolId, uint256 amount, uint256 remainingReserve);
    event UnclaimedSwept(address indexed key, PoolId indexed to, uint256 amount);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error Unauthorized();
    error PoolNotRegistered();
    error PoolAlreadyRegistered();
    error PoolMissingBondToken();
    error InvalidPoolKey();
    error InvalidConfig();
    error InvalidParams();
    error BondTooSmall(uint256 amount, uint256 minimum);
    error BondTooLarge();
    error BondAlreadyActive();
    error Banned(uint256 bannedUntil);
    error NoBond();
    error BondNotMatured(uint256 currentBlock, uint256 maturityBlock);
    error TransferAmountMismatch();
    error NothingToClaim();
    error RefundWindowOpen();
    error NotFlagged();
    error ZeroAmount();
    error MissingEvidence();
    error FlagExpired();
    error SweepExceedsFree(uint256 amount, uint256 free);
    error UnknownUnlockKind();

    // ---------------------------------------------------------------------
    // Bond lifecycle
    // ---------------------------------------------------------------------

    function bond(uint256 amount) external;
    function withdrawBond() external;
    function claimRefund() external returns (uint256 amount);

    // ---------------------------------------------------------------------
    // Pool registry and configuration
    // ---------------------------------------------------------------------

    function registerPool(PoolKey calldata key, PoolConfig calldata cfg, address operator) external;
    function setPoolConfig(PoolId poolId, PoolConfig calldata cfg) external;
    function setPoolOperator(PoolId poolId, address operator) external;

    /// @notice Opt a pool into collective slashing: a bonded address whose swap closes a
    ///         reversal opened by a different address around a swap that was hurt is
    ///         slashed as if it had opened the reversal itself. Closes the split-leg
    ///         (mule) evasion at the price of slashing a bonded address that happens to
    ///         trade against another address's earlier leg in the same block.
    function setCollectiveSlash(PoolId poolId, bool enabled) external;
    function setBondParams(BondParams calldata params) external;
    function setWatchtower(address watchtower_) external;
    function setKeeper(address keeper_) external;
    function pause() external;
    function unpause() external;

    // ---------------------------------------------------------------------
    // Penalties and payouts
    // ---------------------------------------------------------------------

    function flagFromWatchtower(
        PoolId poolId,
        address searcher,
        uint256 amount,
        uint256 banUntil,
        bytes32 evidenceHash
    ) external;
    function drainFlagged(PoolId poolId, address[] calldata searchers, uint256 maxAmount)
        external
        returns (uint256 amount);
    function claimCoverage(PoolId poolId, uint256 amount) external returns (uint256);
    function sweepUnclaimed(address key, PoolId to) external returns (uint256 amount);
    function sweepToken(IERC20 token, address to, uint256 amount) external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function bondToken() external view returns (IERC20);
    function bondParams() external view returns (BondParams memory);
    function bonds(address searcher)
        external
        view
        returns (
            uint128 amount,
            uint48 depositBlock,
            uint48 bannedUntil,
            uint32 strikeCount,
            uint48 lastStrikeBlock
        );
    function isBonded(address searcher) external view returns (bool);
    function isBanned(address searcher) external view returns (bool);
    function isExempt(PoolId poolId, address searcher) external view returns (bool);
    function bondedBalance(address searcher) external view returns (uint256);
    function flaggedUntil(address searcher) external view returns (uint256);
    function flagEvidence(address searcher) external view returns (bytes32);
    function claimableRefund(address victim) external view returns (uint256);
    function refundCreditedAt(address victim) external view returns (uint256);
    function watchtower() external view returns (address);
    function keeper() external view returns (address);
    function totalBonded() external view returns (uint256);
    function totalReserve() external view returns (uint256);
    function totalClaimable() external view returns (uint256);
    function freeBalance() external view returns (uint256);
    function isPoolRegistered(PoolId poolId) external view returns (bool);
    function poolOperator(PoolId poolId) external view returns (address);
    function poolConfig(PoolId poolId) external view returns (PoolConfig memory);
    function collectiveSlashEnabled(PoolId poolId) external view returns (bool);
    function poolKeyOf(PoolId poolId) external view returns (PoolKey memory);
    function unbondedFee(PoolId poolId) external view returns (uint24);
    function insuranceReserve(PoolId poolId) external view returns (uint256);
    function remainingCoverage(PoolId poolId) external view returns (uint256);
    function slashedPledged(PoolId poolId) external view returns (uint256);
    function totalWithdrawn(PoolId poolId) external view returns (uint256);
    function lastSwapOf(PoolId poolId, address sender)
        external
        view
        returns (uint48 blockNumber, bool zeroForOne);
    function poolBlockState(PoolId poolId)
        external
        view
        returns (
            uint48 lastRecordedBlock,
            address lastSwapper,
            address lastVictimKey,
            uint96 lastVictimShortfall
        );
}
