// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LensRegistry} from "../LensRegistry.sol";

/**
 * @title VotePort
 * @notice Vote on Creditcoin with weight proven from another chain.
 *
 * @dev A holder's governance weight lives on Ethereum. The vote happens on Creditcoin.
 *      Between those two facts every existing system puts something you have to trust —
 *      a bridge, a snapshot API, an off-chain tally, a multisig that publishes results.
 *
 *      Here there is nothing. The weight is `getPastVotes(account, snapshotBlock)` read
 *      on the source chain and proven by the precompile. No token is moved, wrapped or
 *      locked, and the holder keeps custody throughout.
 *
 *      **The contract derives the feed identifier itself.** It knows the account and the
 *      snapshot block, so it builds the exact calldata it wants answered and computes
 *      the identifier that commits to it. It never parses a claim out of somebody else's
 *      calldata, which means there is no argument a submitter could shape to make a
 *      weight from one block or one account look like another's.
 *
 *      **Weight is fixed at a snapshot block chosen when the proposal opens.** Reading
 *      current weight would let anyone buy tokens after seeing the tally, vote, and sell
 *      — the standard flash-governance attack. A past block cannot be bought into.
 */
contract VotePort {
    LensRegistry public immutable LENS;
    uint64 public immutable CHAIN_KEY;

    /// @notice The source-chain token whose checkpoints decide weight.
    address public immutable TOKEN;

    /**
     * @notice The token's historical-weight accessor.
     * @dev Set at construction rather than fixed, because the accessor differs by token
     *      family: `getPastVotes(address,uint256)` on OpenZeppelin's ERC20Votes,
     *      `getPriorVotes(address,uint256)` on Compound-style tokens such as UNI and
     *      COMP. Hardcoding either silently excludes every token in the other family —
     *      the call reverts, the weight reads as unprovable, and nothing says why.
     */
    bytes4 public immutable WEIGHT_SELECTOR;

    /// @notice `getPastVotes(address,uint256)`, for OpenZeppelin's ERC20Votes.
    bytes4 public constant GET_PAST_VOTES = 0x3a46b1a8;

    /// @notice `getPriorVotes(address,uint256)`, for Compound-style tokens.
    bytes4 public constant GET_PRIOR_VOTES = 0x782d6fe1;

    struct Proposal {
        string description;
        uint256 snapshotBlock;
        uint64 opensAt;
        uint64 closesAt;
        uint256 forVotes;
        uint256 againstVotes;
        bool exists;
    }

    Proposal[] private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => uint256)) public weightUsed;

    /// @notice Largest acceptable age of the proof, in source-chain blocks.
    uint256 public immutable MAX_AGE_BLOCKS;

    event ProposalOpened(uint256 indexed id, string description, uint256 snapshotBlock, uint64 closesAt);
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 weight);

    error RegistryRequired();
    error TokenRequired();
    error SnapshotMustBeInThePast(uint256 snapshotBlock, uint256 frontier);
    error VotingClosed(uint64 closesAt);
    error VotingNotOpen(uint64 opensAt);
    error AlreadyVoted(uint256 id, address voter);
    error NoProvenWeight(address voter, bytes32 feedId);
    error WeightIsZero(address voter);
    error ProofStale(uint256 age, uint256 maxAge);
    error ProofFailed();
    error NoSuchProposal(uint256 id);

    error SelectorRequired();

    constructor(LensRegistry registry, uint64 chainKey, address token, bytes4 weightSelector, uint256 maxAgeBlocks) {
        if (address(registry) == address(0)) revert RegistryRequired();
        if (token == address(0)) revert TokenRequired();
        if (weightSelector == bytes4(0)) revert SelectorRequired();
        LENS = registry;
        CHAIN_KEY = chainKey;
        TOKEN = token;
        WEIGHT_SELECTOR = weightSelector;
        MAX_AGE_BLOCKS = maxAgeBlocks;
    }

    /**
     * @notice The feed a voter needs proven before they can vote.
     * @dev Public so a prober knows exactly what to probe, and so a voter can check that
     *      what was proven is what will be counted. This is the whole binding: the
     *      identifier commits to the token, the account and the block together.
     */
    function weightFeedId(address account, uint256 snapshotBlock) public view returns (bytes32) {
        bytes memory callData = abi.encodeWithSelector(WEIGHT_SELECTOR, account, snapshotBlock);
        return LENS.feedIdFromCallHash(CHAIN_KEY, TOKEN, keccak256(callData));
    }

    /// @notice The calldata a prober must use, so there is no guesswork.
    function weightCallData(address account, uint256 snapshotBlock) external view returns (bytes memory) {
        return abi.encodeWithSelector(WEIGHT_SELECTOR, account, snapshotBlock);
    }

    /**
     * @notice Open a proposal against a snapshot block that has already been attested.
     * @dev Permissionless. Nobody needs permission to ask a question, and the weight
     *      that answers it cannot be manufactured.
     */
    function propose(string calldata description, uint256 snapshotBlock, uint64 votingPeriod)
        external
        returns (uint256 id)
    {
        uint256 frontier = LENS.frontierOf(CHAIN_KEY);
        // A snapshot must be provable when the proposal opens, or nobody could vote.
        if (snapshotBlock == 0 || snapshotBlock > frontier) {
            revert SnapshotMustBeInThePast(snapshotBlock, frontier);
        }

        id = _proposals.length;
        _proposals.push(
            Proposal({
                description: description,
                snapshotBlock: snapshotBlock,
                opensAt: uint64(block.timestamp),
                closesAt: uint64(block.timestamp) + votingPeriod,
                forVotes: 0,
                againstVotes: 0,
                exists: true
            })
        );
        emit ProposalOpened(id, description, snapshotBlock, uint64(block.timestamp) + votingPeriod);
    }

    /**
     * @notice Vote with weight proven from the source chain.
     * @dev The caller votes for themselves. The weight is not supplied, it is looked up
     *      from a feed the caller cannot influence.
     */
    function castVote(uint256 id, bool support) external returns (uint256 weight) {
        Proposal storage p = _requireProposal(id);
        if (block.timestamp < p.opensAt) revert VotingNotOpen(p.opensAt);
        if (block.timestamp > p.closesAt) revert VotingClosed(p.closesAt);
        if (hasVoted[id][msg.sender]) revert AlreadyVoted(id, msg.sender);

        weight = provenWeight(msg.sender, p.snapshotBlock);
        if (weight == 0) revert WeightIsZero(msg.sender);

        hasVoted[id][msg.sender] = true;
        weightUsed[id][msg.sender] = weight;
        if (support) p.forVotes += weight;
        else p.againstVotes += weight;

        emit VoteCast(id, msg.sender, support, weight);
    }

    /**
     * @notice An account's proven weight at a snapshot block, or a revert.
     * @dev Every refusal is distinct. A voter who was never probed, whose read failed,
     *      or whose proof has gone stale needs to know which, because only the first is
     *      fixed by asking a prober.
     */
    function provenWeight(address account, uint256 snapshotBlock) public view returns (uint256) {
        bytes32 id = weightFeedId(account, snapshotBlock);
        if (!LENS.hasObservation(id)) revert NoProvenWeight(account, id);

        LensRegistry.Observation memory o = LENS.observationOf(id);
        if (!o.callSucceeded || o.truncated) revert ProofFailed();
        if (o.returnData.length != 32) revert ProofFailed();

        uint256 frontier = LENS.frontierOf(CHAIN_KEY);
        uint256 age = frontier > o.probeHeight ? frontier - o.probeHeight : 0;
        if (age > MAX_AGE_BLOCKS) revert ProofStale(age, MAX_AGE_BLOCKS);

        return abi.decode(o.returnData, (uint256));
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    function proposalOf(uint256 id) external view returns (Proposal memory) {
        return _requireProposalView(id);
    }

    function outcome(uint256 id) external view returns (bool passed, uint256 forVotes, uint256 againstVotes) {
        Proposal memory p = _requireProposalView(id);
        return (p.forVotes > p.againstVotes, p.forVotes, p.againstVotes);
    }

    function _requireProposal(uint256 id) private view returns (Proposal storage p) {
        if (id >= _proposals.length) revert NoSuchProposal(id);
        p = _proposals[id];
    }

    function _requireProposalView(uint256 id) private view returns (Proposal memory) {
        if (id >= _proposals.length) revert NoSuchProposal(id);
        return _proposals[id];
    }
}
