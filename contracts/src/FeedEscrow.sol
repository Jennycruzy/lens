// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LensRegistry} from "./LensRegistry.sol";
import {INativeQueryVerifier} from "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";

/**
 * @title FeedEscrow
 * @notice Pays whoever lands the next valid proof for a feed.
 *
 * @dev Economics appear in exactly one place in Lens, and only for the one thing that
 *      needs them.
 *
 *      A prober is trusted for liveness and never for correctness. A forged probe fails
 *      at the precompile no matter who submits it or what they were paid, so no amount
 *      of money buys a wrong answer. What money does buy is somebody bothering to
 *      submit at all.
 *
 *      That makes withholding the only attack worth pricing. To starve a feed, every
 *      prober must withhold together; one who defects takes the fee, and the feed
 *      updates. A single honest participant defeats the whole attack, which is why
 *      there is no auction, no reputation, no staking and no slashing here. Those
 *      mechanisms exist to punish lying, and lying is already impossible.
 *
 *      The reward is claimed by proving, not by asking. {submitAndClaim} performs the
 *      registry submission and pays out in the same transaction, so a prober cannot be
 *      front-run out of a fee it earned, and nobody can claim for work they did not do.
 */
contract FeedEscrow {
    LensRegistry public immutable LENS;

    struct Funding {
        uint256 balance;
        uint256 rewardPerUpdate;
        /// @dev Source-chain blocks that must pass before another reward is payable, so
        ///      a prober cannot drain a feed by submitting continuously.
        uint64 minBlocksBetweenRewards;
        uint64 lastRewardedHeight;
        address funder;
        uint64 refundableAfter;
    }

    mapping(bytes32 feedId => Funding) private _funding;

    /// @notice How long a funder must wait before withdrawing, from the last top-up.
    /// @dev A funder who could withdraw instantly could cancel a reward the moment a
    ///      prober's transaction entered the mempool, which is the same as never having
    ///      offered it.
    uint64 public constant REFUND_TIMELOCK = 3 days;

    event Funded(bytes32 indexed feedId, address indexed funder, uint256 amount, uint256 rewardPerUpdate);
    event Rewarded(bytes32 indexed feedId, address indexed prober, uint256 amount, uint256 height);
    event Refunded(bytes32 indexed feedId, address indexed funder, uint256 amount);

    error NothingSent();
    error RewardRequired();
    error NotTheFunder(address caller, address funder);
    error StillTimelocked(uint64 until);
    error NothingToRefund();
    error TransferFailed(address to, uint256 amount);
    error NoObservationRecorded();

    /**
     * @notice Fund a feed, or top it up.
     * @dev The first funder sets the terms. Later top-ups from anyone add to the balance
     *      without changing them, so a stranger cannot reduce a reward that probers are
     *      already relying on.
     */
    function fund(bytes32 feedId, uint256 rewardPerUpdate, uint64 minBlocksBetweenRewards) external payable {
        if (msg.value == 0) revert NothingSent();
        Funding storage f = _funding[feedId];

        if (f.funder == address(0)) {
            if (rewardPerUpdate == 0) revert RewardRequired();
            f.funder = msg.sender;
            f.rewardPerUpdate = rewardPerUpdate;
            f.minBlocksBetweenRewards = minBlocksBetweenRewards;
        }

        f.balance += msg.value;
        f.refundableAfter = uint64(block.timestamp) + REFUND_TIMELOCK;
        emit Funded(feedId, msg.sender, msg.value, f.rewardPerUpdate);
    }

    function fundingOf(bytes32 feedId) external view returns (Funding memory) {
        return _funding[feedId];
    }

    /// @notice What a proof landing right now would pay.
    function payableNow(bytes32 feedId, uint64 atHeight) public view returns (uint256) {
        Funding storage f = _funding[feedId];
        if (f.balance == 0 || f.rewardPerUpdate == 0) return 0;
        if (
            f.lastRewardedHeight != 0
                && uint256(atHeight) < uint256(f.lastRewardedHeight) + uint256(f.minBlocksBetweenRewards)
        ) return 0;
        return f.rewardPerUpdate > f.balance ? f.balance : f.rewardPerUpdate;
    }

    /**
     * @notice Record an observation and take the fee for it in the same transaction.
     * @dev The escrow never takes a caller's word for anything. It calls the registry
     *      itself, and the registry applies every one of its checks, so a payment can
     *      only follow a proof that was actually accepted.
     */
    function submitAndClaim(
        uint64 chainKey,
        uint64 blockHeight,
        bytes calldata encodedTransaction,
        INativeQueryVerifier.MerkleProof calldata merkleProof,
        INativeQueryVerifier.ContinuityProof calldata continuityProof,
        bytes32 feedId
    ) external returns (uint256 recorded, uint256 paid) {
        recorded = LENS.submitProofForFeed(
            chainKey, blockHeight, encodedTransaction, merkleProof, continuityProof, feedId
        );
        if (recorded == 0) revert NoObservationRecorded();

        paid = payableNow(feedId, blockHeight);
        if (paid > 0) {
            Funding storage f = _funding[feedId];
            f.balance -= paid;
            f.lastRewardedHeight = blockHeight;
            emit Rewarded(feedId, msg.sender, paid, blockHeight);
            _send(msg.sender, paid);
        }
    }

    /// @notice Return an unspent balance to whoever funded it, after the timelock.
    function refund(bytes32 feedId) external {
        Funding storage f = _funding[feedId];
        if (msg.sender != f.funder) revert NotTheFunder(msg.sender, f.funder);
        if (block.timestamp < f.refundableAfter) revert StillTimelocked(f.refundableAfter);

        uint256 amount = f.balance;
        if (amount == 0) revert NothingToRefund();
        f.balance = 0;
        emit Refunded(feedId, msg.sender, amount);
        _send(msg.sender, amount);
    }

    constructor(LensRegistry registry) {
        LENS = registry;
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed(to, amount);
    }
}
