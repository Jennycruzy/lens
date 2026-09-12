// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StateProbe} from "./StateProbe.sol";

/**
 * @title HistoryProbe
 * @notice Named entry points for checkpointed and historical reads.
 *
 * @dev A historical read is not a different proof primitive. The target contract's
 *      own checkpoint function supplies history, and StateProbe supplies the event
 *      that the registry proves. This variant makes that intent explicit while using
 *      the same bounded, staticcall-only execution and event ABI.
 *
 *      It is intentionally unowned and non-upgradeable. Register the address of
 *      whichever probe variant is used for a source chain in LensRegistry; a log from
 *      an unregistered sibling is rejected by emitter binding.
 */
contract HistoryProbe is StateProbe {
    /// @notice Probe calldata that asks a target for checkpointed historical state.
    function probeHistorical(address target, bytes calldata data) external {
        _probe(target, data);
    }

    /// @notice Batch checkpointed historical reads under one source transaction.
    function probeManyHistorical(address[] calldata targets, bytes[] calldata datas) external {
        uint256 n = targets.length;
        if (n == 0) revert EmptyBatch();
        if (n != datas.length) revert LengthMismatch(n, datas.length);
        if (n > MAX_BATCH) revert BatchTooLarge(n, MAX_BATCH);
        for (uint256 i = 0; i < n; ++i) {
            _probe(targets[i], datas[i]);
        }
    }
}
