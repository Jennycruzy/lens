// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LensRegistry} from "../LensRegistry.sol";

/**
 * @title SnapshotProver
 * @notice Distributes rewards on eligibility the recipient proves, not eligibility
 *         somebody publishes.
 *
 * @dev Creditcoin currently runs reward and airdrop snapshots through trusted off-chain
 *      scripts. Someone queries an archive node, produces a list, and everyone downstream
 *      takes the list on faith. Even a Merkle root only moves the trust: the root is
 *      still asserted by whoever computed it, and nothing on chain can contradict it.
 *
 *      This replaces that. A claimant's holding at the snapshot block is read from the
 *      token's own checkpoints on the source chain and proven by the precompile. There
 *      is no list, no root, and nobody who could have written a different one. The
 *      organiser funds a campaign and states the rule; they cannot choose who satisfies
 *      it.
 *
 *      Removing a trusted snapshot from the chain whose thesis is that oracles are
 *      unnecessary is the point of building this one.
 *
 *      **The selector is per campaign** because the accessor differs by token family:
 *      `getPastVotes(address,uint256)` for ERC20Votes, `getPriorVotes(address,uint256)`
 *      for Compound-style. Fixing one would silently exclude the other.
 */
contract SnapshotProver {
    LensRegistry public immutable LENS;
    uint64 public immutable CHAIN_KEY;

    struct Campaign {
        address token; // source-chain token holding the checkpoints
        bytes4 selector; // its historical-balance accessor
        uint256 snapshotBlock;
        uint256 minimumHolding; // below this, not eligible
        uint256 rewardPerToken; // 1e18 scale, paid per unit held
        uint256 maxPerClaim; // ceiling so one whale cannot drain the pool
        uint256 funded;
        uint256 paidOut;
        uint64 closesAt;
        address organiser;
        bool exists;
    }

    Campaign[] private _campaigns;
    mapping(uint256 => mapping(address => bool)) public claimed;

    uint256 public immutable MAX_AGE_BLOCKS;
    uint256 private constant WAD = 1e18;
    bytes4 public constant GET_PAST_VOTES = 0x3a46b1a8;
    bytes4 public constant GET_PRIOR_VOTES = 0x782d6fe1;

    event CampaignOpened(uint256 indexed id, address token, uint256 snapshotBlock, uint256 funded);
    event Claimed(uint256 indexed id, address indexed claimant, uint256 holding, uint256 paid);
    event Reclaimed(uint256 indexed id, address indexed organiser, uint256 amount);

    error RegistryRequired();
    error TokenRequired();
    error NothingFunded();
    error SnapshotMustBeInThePast(uint256 snapshotBlock, uint256 frontier);
    error NoSuchCampaign(uint256 id);
    error CampaignClosed(uint64 closesAt);
    error CampaignStillOpen(uint64 closesAt);
    error AlreadyClaimed(uint256 id, address claimant);
    error NoProvenHolding(address claimant, bytes32 feedId);
    error ProofFailed();
    error ProofStale(uint256 age, uint256 maxAge);
    error FrontierRegression(uint256 frontier, uint256 probeHeight);
    error BelowMinimum(uint256 holding, uint256 minimum);
    error PoolExhausted();
    error NotTheOrganiser(address caller, address organiser);
    error TransferFailed();
    error SelectorRequired();
    error UnsupportedSelector(bytes4 selector);
    error RewardCalculationOverflow();

    constructor(LensRegistry registry, uint64 chainKey, uint256 maxAgeBlocks) {
        if (address(registry) == address(0)) revert RegistryRequired();
        LENS = registry;
        CHAIN_KEY = chainKey;
        MAX_AGE_BLOCKS = maxAgeBlocks;
    }

    /// @notice The feed a claimant needs proven. Public so a prober knows what to probe.
    function holdingFeedId(uint256 id, address account) public view returns (bytes32) {
        Campaign memory c = _requireCampaign(id);
        return LENS.feedIdFromCallHash(
            CHAIN_KEY, c.token, keccak256(abi.encodeWithSelector(c.selector, account, c.snapshotBlock))
        );
    }

    /// @notice The exact calldata a prober must use.
    function holdingCallData(uint256 id, address account) external view returns (bytes memory) {
        Campaign memory c = _requireCampaign(id);
        return abi.encodeWithSelector(c.selector, account, c.snapshotBlock);
    }

    function open(
        address token,
        bytes4 selector,
        uint256 snapshotBlock,
        uint256 minimumHolding,
        uint256 rewardPerToken,
        uint256 maxPerClaim,
        uint64 openFor
    ) external payable returns (uint256 id) {
        if (token == address(0)) revert TokenRequired();
        if (selector == bytes4(0)) revert SelectorRequired();
        if (selector != GET_PAST_VOTES && selector != GET_PRIOR_VOTES) revert UnsupportedSelector(selector);
        if (msg.value == 0) revert NothingFunded();

        uint256 frontier = LENS.frontierOf(CHAIN_KEY);
        if (snapshotBlock == 0 || snapshotBlock > frontier) {
            revert SnapshotMustBeInThePast(snapshotBlock, frontier);
        }

        id = _campaigns.length;
        _campaigns.push(
            Campaign({
                token: token,
                selector: selector,
                snapshotBlock: snapshotBlock,
                minimumHolding: minimumHolding,
                rewardPerToken: rewardPerToken,
                maxPerClaim: maxPerClaim,
                funded: msg.value,
                paidOut: 0,
                closesAt: uint64(block.timestamp) + openFor,
                organiser: msg.sender,
                exists: true
            })
        );
        emit CampaignOpened(id, token, snapshotBlock, msg.value);
    }

    /**
     * @notice Claim on proven holdings.
     * @dev The claimant claims for themselves and supplies no evidence. Everything is
     *      read from the registry, so there is no input to forge and no list to be on.
     */
    function claim(uint256 id) external returns (uint256 holding, uint256 paid) {
        Campaign storage c = _requireCampaignStorage(id);
        if (block.timestamp > c.closesAt) revert CampaignClosed(c.closesAt);
        if (claimed[id][msg.sender]) revert AlreadyClaimed(id, msg.sender);

        holding = provenHolding(id, msg.sender);
        if (holding < c.minimumHolding) revert BelowMinimum(holding, c.minimumHolding);

        uint256 remaining = c.funded - c.paidOut;
        if (remaining == 0) revert PoolExhausted();
        paid = _calculatePayout(holding, c.rewardPerToken, c.maxPerClaim, remaining);

        claimed[id][msg.sender] = true;
        c.paidOut += paid;

        emit Claimed(id, msg.sender, holding, paid);
        (bool ok,) = payable(msg.sender).call{value: paid}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice What the source chain says an account held at the snapshot block.
    function provenHolding(uint256 id, address account) public view returns (uint256) {
        bytes32 feedId = holdingFeedId(id, account);
        if (!LENS.hasObservation(feedId)) revert NoProvenHolding(account, feedId);

        LensRegistry.Observation memory o = LENS.observationOf(feedId);
        if (!o.callSucceeded || o.truncated || o.returnData.length != 32) revert ProofFailed();

        uint256 frontier = LENS.frontierOf(CHAIN_KEY);
        if (o.probeHeight > frontier) revert FrontierRegression(frontier, o.probeHeight);
        uint256 age = frontier - o.probeHeight;
        if (age > MAX_AGE_BLOCKS) revert ProofStale(age, MAX_AGE_BLOCKS);

        return abi.decode(o.returnData, (uint256));
    }

    /// @notice Whether an account could claim right now, without reverting.
    function eligibility(uint256 id, address account)
        external
        view
        returns (bool eligible, uint256 holding, uint256 wouldPay, string memory reason)
    {
        Campaign memory c = _requireCampaign(id);
        if (claimed[id][account]) return (false, 0, 0, "already claimed");
        if (block.timestamp > c.closesAt) return (false, 0, 0, "campaign closed");

        bytes32 feedId = holdingFeedId(id, account);
        if (!LENS.hasObservation(feedId)) return (false, 0, 0, "holding not yet proven");

        LensRegistry.Observation memory o = LENS.observationOf(feedId);
        if (!o.callSucceeded || o.truncated || o.returnData.length != 32) {
            return (false, 0, 0, "the source read failed");
        }

        uint256 frontier = LENS.frontierOf(CHAIN_KEY);
        if (o.probeHeight > frontier) return (false, 0, 0, "attestation frontier regressed");
        if (frontier - o.probeHeight > MAX_AGE_BLOCKS) return (false, 0, 0, "proof is stale");

        holding = abi.decode(o.returnData, (uint256));
        if (holding < c.minimumHolding) return (false, holding, 0, "below the minimum");

        uint256 remaining = c.funded - c.paidOut;
        wouldPay = _calculatePayout(holding, c.rewardPerToken, c.maxPerClaim, remaining);

        return (true, holding, wouldPay, "");
    }

    /// @dev Refuse an overflowing reward calculation rather than wrapping and overpaying.
    function _calculatePayout(uint256 holding, uint256 rewardPerToken, uint256 maxPerClaim, uint256 remaining)
        private
        pure
        returns (uint256 paid)
    {
        if (holding != 0 && rewardPerToken > type(uint256).max / holding) revert RewardCalculationOverflow();
        paid = (holding * rewardPerToken) / WAD;
        if (maxPerClaim != 0 && paid > maxPerClaim) paid = maxPerClaim;
        if (paid > remaining) paid = remaining;
    }

    /// @notice Return whatever nobody claimed, once the campaign has closed.
    function reclaim(uint256 id) external {
        Campaign storage c = _requireCampaignStorage(id);
        if (msg.sender != c.organiser) revert NotTheOrganiser(msg.sender, c.organiser);
        if (block.timestamp <= c.closesAt) revert CampaignStillOpen(c.closesAt);

        uint256 amount = c.funded - c.paidOut;
        if (amount == 0) revert PoolExhausted();
        c.paidOut = c.funded;

        emit Reclaimed(id, msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function campaignCount() external view returns (uint256) {
        return _campaigns.length;
    }

    function campaignOf(uint256 id) external view returns (Campaign memory) {
        return _requireCampaign(id);
    }

    function _requireCampaign(uint256 id) private view returns (Campaign memory) {
        if (id >= _campaigns.length) revert NoSuchCampaign(id);
        return _campaigns[id];
    }

    function _requireCampaignStorage(uint256 id) private view returns (Campaign storage) {
        if (id >= _campaigns.length) revert NoSuchCampaign(id);
        return _campaigns[id];
    }
}
