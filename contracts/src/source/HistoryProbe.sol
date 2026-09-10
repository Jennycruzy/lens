// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title HistoryProbe
 * @notice Reads a contract's own record of its past, and proves that.
 *
 * @dev A plain probe reads current state. This reads history — without a storage proof,
 *      and without any protocol change — by exploiting something already true of a large
 *      class of contracts: **many of them expose their own history through ordinary view
 *      functions.**
 *
 *      `ERC20Votes.getPastVotes(account, block)` answers what an account's voting weight
 *      was at a past block. Compound-style checkpoints do the same for balances.
 *      Uniswap's `observe(secondsAgo[])` answers what the cumulative tick was at points
 *      in the past. Any checkpointed accumulator has this shape.
 *
 *      For those targets, "what was the balance at block N" is not a storage question at
 *      all. It is a function call, made now, whose answer is about then. A probe of that
 *      call is an ordinary probe, provable by the ordinary path, and the answer is
 *      historical state verified with no storage proof anywhere in the system.
 *
 *      That turns the airdrop-snapshot problem — prove what someone held at a past block
 *      — into an ordinary Lens feed. It is the most useful idea in this repository after
 *      the core one.
 *
 *      **What it does not cover.** A contract that keeps no checkpoints cannot answer
 *      questions about its own past, and no amount of probing changes that. A plain
 *      ERC-20 without `ERC20Votes` can only ever report its balance now. The technique
 *      covers the checkpointed class exactly, and that boundary is stated rather than
 *      blurred, because a reader who discovers the limit themselves will assume it was
 *      being hidden.
 *
 *      The separate event is the whole point of a separate contract. A historical read
 *      carries a claim an ordinary read does not — that the answer is about a stated
 *      past height — and a consumer must be able to bind to that height rather than
 *      infer it from calldata it would have to parse.
 */
contract HistoryProbe {
    /**
     * @param target       Contract that was asked about its own past.
     * @param callHash     keccak256 of the calldata.
     * @param aboutHeight  The source-chain height the answer describes, as declared by
     *                     the caller and carried through to the consumer.
     * @param blockNumber  The height the read was performed at.
     * @param blockTimestamp The time the read was performed at.
     */
    event ProbedHistory(
        address indexed target,
        bytes32 indexed callHash,
        address indexed caller,
        uint256 aboutHeight,
        bool success,
        bool truncated,
        uint256 blockNumber,
        uint256 blockTimestamp,
        bytes returnData
    );

    uint256 public constant MAX_RETURN_BYTES = 8192;
    uint256 public constant MAX_PROBE_GAS = 2_000_000;
    uint256 public constant MAX_BATCH = 64;

    error EmptyBatch();
    error LengthMismatch();
    error BatchTooLarge(uint256 length, uint256 maximum);
    error NotYetHistory(uint256 aboutHeight, uint256 currentHeight);

    /**
     * @notice Ask `target` about height `aboutHeight` and emit the answer.
     * @dev `aboutHeight` is not extracted from the calldata. Doing so would require
     *      knowing every target's argument layout, and guessing wrong would bind a value
     *      to the wrong height. The caller declares it, and a consumer treats it as a
     *      claim to be checked against the calldata it constructed, which it already
     *      knows because the feed identifier commits to it.
     *
     *      A height at or above the current one is rejected outright. It is not history,
     *      and a target answering such a question is answering about the present while
     *      appearing to answer about the past.
     */
    function probeHistory(address target, uint256 aboutHeight, bytes calldata data) external {
        _probeHistory(target, aboutHeight, data);
    }

    function probeHistoryMany(address[] calldata targets, uint256[] calldata aboutHeights, bytes[] calldata datas)
        external
    {
        uint256 n = targets.length;
        if (n == 0) revert EmptyBatch();
        if (n != datas.length || n != aboutHeights.length) revert LengthMismatch();
        if (n > MAX_BATCH) revert BatchTooLarge(n, MAX_BATCH);
        for (uint256 i = 0; i < n; ++i) {
            _probeHistory(targets[i], aboutHeights[i], datas[i]);
        }
    }

    function _probeHistory(address target, uint256 aboutHeight, bytes calldata data) private {
        if (aboutHeight >= block.number) revert NotYetHistory(aboutHeight, block.number);

        (bool success, bool truncated, bytes memory ret) = _boundedStaticCall(target, data);
        emit ProbedHistory(
            target,
            keccak256(data),
            msg.sender,
            aboutHeight,
            success,
            truncated,
            block.number,
            block.timestamp,
            ret
        );
    }

    /// @dev Identical in behaviour to the ordinary probe: static only, returndata capped,
    ///      forwarded gas capped so one hostile target cannot starve a batch.
    function _boundedStaticCall(address target, bytes calldata data)
        private
        view
        returns (bool success, bool truncated, bytes memory ret)
    {
        uint256 cap = MAX_RETURN_BYTES;
        uint256 gasCap = MAX_PROBE_GAS;
        assembly ("memory-safe") {
            let input := mload(0x40)
            calldatacopy(input, data.offset, data.length)

            let forwarded := div(mul(gas(), 63), 64)
            if gt(forwarded, gasCap) { forwarded := gasCap }

            success := staticcall(forwarded, target, input, data.length, 0, 0)

            let size := returndatasize()
            let copied := size
            if gt(copied, cap) {
                copied := cap
                truncated := 1
            }

            ret := add(input, data.length)
            mstore(ret, copied)
            returndatacopy(add(ret, 0x20), 0, copied)
            mstore(0x40, add(add(ret, 0x20), and(add(copied, 0x1f), not(0x1f))))
        }
    }
}
