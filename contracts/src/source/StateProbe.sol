// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title StateProbe
 * @notice Turns contract state into a transaction, so that it can be proven.
 *
 * @dev Attestcoin proves what a transaction did. It cannot prove what a contract is:
 *      there are no storage proofs, only transaction and event inclusion. A probe
 *      closes that gap without touching the protocol. It performs the read on the
 *      source chain, where the EVM is the authority on the answer, and emits the
 *      result. The emission lands in a block, the block is attested, and the log is
 *      proven to Creditcoin through the path that already exists.
 *
 *      The caller is trusted for liveness and never for correctness. Nothing here
 *      accepts a result from its caller: the returndata is produced by the EVM
 *      executing the target, and a forged log fails at the precompile because it was
 *      never in an attested block. A prober who withholds causes a consumer to refuse,
 *      which is the failure mode this design chooses.
 *
 *      Unowned, unpausable, non-upgradeable, and holding no state. There is no admin
 *      key because there is no operation an admin could perform. That is a security
 *      property, not an omission.
 */
contract StateProbe {
    /**
     * @notice A read that was performed on this chain.
     * @param target     Contract that was read.
     * @param callHash   keccak256 of the calldata, indexed so a consumer can bind a log
     *                   to exactly one query without scanning the data.
     * @param caller     Who paid for the read. Carried for accounting only; a consumer
     *                   that treats this as authority has misunderstood the design.
     * @param success    False when the target reverted. A reverted read is reported,
     *                   never silently dropped, so a consumer can tell "the read failed"
     *                   apart from "no probe exists".
     * @param truncated  True when the target returned more than {MAX_RETURN_BYTES}.
     *                   The data below is then a prefix and must not be decoded.
     * @param blockNumber Source-chain height the read was performed at.
     * @param blockTimestamp Source-chain time the read was performed at.
     * @param returnData Bytes the target returned, or the revert data when !success.
     *
     * @dev The timestamp is emitted because nothing downstream can recover it. It is not
     *      carried in the proven transaction encoding, and Creditcoin's own clock reads
     *      minutes later than the read — the attestation lag sits between them. A
     *      consumer told the later time would believe the value fresher than it is,
     *      which is the one error this whole design exists to prevent. Chainlink-shaped
     *      consumers compare `updatedAt` against `block.timestamp` and liquidate on the
     *      difference, so the honest source time has to travel with the value.
     */
    event Probed(
        address indexed target,
        bytes32 indexed callHash,
        address indexed caller,
        bool success,
        bool truncated,
        uint256 blockNumber,
        uint256 blockTimestamp,
        bytes returnData
    );

    /// @notice Upper bound on emitted returndata.
    /// @dev The target is arbitrary and may return megabytes to exhaust gas or to
    ///      produce a log too large to prove. Copying is capped rather than trusted.
    ///      A truncated result is emitted and flagged so the failure is visible on
    ///      Creditcoin rather than appearing as a missing update.
    uint256 public constant MAX_RETURN_BYTES = 8192;

    error EmptyBatch();
    error LengthMismatch(uint256 targets, uint256 datas);
    error BatchTooLarge(uint256 length, uint256 maximum);

    /// @dev Bounded so one transaction cannot produce a receipt too large to prove.
    uint256 public constant MAX_BATCH = 64;

    /// @notice Gas forwarded to any single read.
    /// @dev A target that reverts consumes everything forwarded to it, so an
    ///      unbounded forward would let one hostile address in a batch burn the whole
    ///      transaction and take every other feed's update down with it. Capping the
    ///      forward confines the damage to that one query. The ceiling is far above
    ///      what a real read costs: a Uniswap V3 `observe` over many periods is an
    ///      order of magnitude below it.
    uint256 public constant MAX_PROBE_GAS = 2_000_000;

    /**
     * @notice Read `target` with `data` and emit the result.
     * @dev Static call only: a probe can never mutate source-chain state, whatever
     *      the target is. Reverts are captured rather than propagated, because the
     *      fact that a read reverted is itself a result worth proving.
     */
    function probe(address target, bytes calldata data) external {
        _probe(target, data);
    }

    /**
     * @notice Read many targets in one transaction.
     * @dev One source transaction feeds many feeds, and the resulting logs sit in one
     *      block, so a single continuity proof covers all of them on the Creditcoin
     *      side. This is what makes proof cost per feed fall as feed count rises.
     */
    function probeMany(address[] calldata targets, bytes[] calldata datas) external {
        uint256 n = targets.length;
        if (n == 0) revert EmptyBatch();
        if (n != datas.length) revert LengthMismatch(n, datas.length);
        if (n > MAX_BATCH) revert BatchTooLarge(n, MAX_BATCH);
        for (uint256 i = 0; i < n; ++i) {
            _probe(targets[i], datas[i]);
        }
    }

    /// @dev Static analysis flags the emit-after-call ordering as a reentrancy risk.
    ///      It is not one here: the call is a `staticcall`, so the target cannot write
    ///      to any chain state, and this contract holds none for a reentrant call to
    ///      observe or corrupt. A target that calls back in can only cause more logs to
    ///      be emitted, which it could equally do by calling {probe} itself.
    function _probe(address target, bytes calldata data) private {
        (bool success, bool truncated, bytes memory ret) = _boundedStaticCall(target, data);
        emit Probed(target, keccak256(data), msg.sender, success, truncated, block.number, block.timestamp, ret);
    }

    /**
     * @dev Performs the read and copies back at most {MAX_RETURN_BYTES}.
     *
     *      Solidity's ordinary call would copy the whole of returndata into memory
     *      before this contract could inspect its size, which hands an arbitrary
     *      target control of this transaction's memory expansion cost. The call is
     *      written in assembly to copy nothing automatically and then to copy back
     *      only what fits.
     *
     *      A call to an address with no code succeeds at the EVM level and returns
     *      empty. That is reported as success with empty data rather than being
     *      rewritten as a failure: it is what the chain did, and the consumer
     *      standard is where such a result is refused.
     */
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

            // Forward at most `gasCap`, and never more than the EVM would allow
            // anyway, so a reverting target cannot consume the caller's whole budget.
            let forwarded := div(mul(gas(), 63), 64)
            if gt(forwarded, gasCap) { forwarded := gasCap }

            success := staticcall(forwarded, target, input, data.length, 0, 0)

            let size := returndatasize()
            let copied := size
            if gt(copied, cap) {
                copied := cap
                truncated := 1
            }

            // Lay the result out as a `bytes` immediately after the input scratch
            // space and move the free memory pointer past it.
            ret := add(input, data.length)
            mstore(ret, copied)
            returndatacopy(add(ret, 0x20), 0, copied)
            mstore(0x40, add(add(ret, 0x20), and(add(copied, 0x1f), not(0x1f))))
        }
    }
}
