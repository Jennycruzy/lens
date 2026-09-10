// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IChainInfo} from "../../src/interfaces/IChainInfo.sol";
import {INativeQueryVerifier} from "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";

/**
 * @dev Stands in for the ChainInfo precompile so the registry's behaviour can be driven
 *      through states the live network will not hold still for — a frontier that
 *      rewinds, a chain key that resolves to the wrong chain, a chain with nothing
 *      attested. The real precompile is exercised separately against CC3 testnet.
 */
contract ChainInfoStub is IChainInfo {
    mapping(uint64 => ChainInfo) private _chains;
    mapping(uint64 => HeightHash) private _latest;
    mapping(uint64 => uint64) private _genesis;
    uint64[] private _keys;

    function setChain(uint64 chainKey, uint64 chainId, string memory name) external {
        if (_chains[chainKey].chainId == 0) _keys.push(chainKey);
        _chains[chainKey] = ChainInfo(chainKey, chainId, bytes(name), 1);
    }

    function setFrontier(uint64 chainKey, uint64 height, bool exists) external {
        _latest[chainKey] = HeightHash(height, keccak256(abi.encode(chainKey, height)), true, exists);
    }

    function setGenesis(uint64 chainKey, uint64 height) external {
        _genesis[chainKey] = height;
    }

    function get_supported_chains() external view returns (ChainInfo[] memory out) {
        out = new ChainInfo[](_keys.length);
        for (uint256 i = 0; i < _keys.length; ++i) {
            out[i] = _chains[_keys[i]];
        }
    }

    function get_chain_by_key(uint64 chainKey) external view returns (ChainInfoResult memory) {
        return ChainInfoResult(_chains[chainKey], _chains[chainKey].chainId != 0);
    }

    function get_latest_attestation_height_and_hash(uint64 chainKey) external view returns (HeightHash memory) {
        return _latest[chainKey];
    }

    function get_latest_checkpoint_height_and_hash(uint64 chainKey) external view returns (HeightHash memory) {
        return _latest[chainKey];
    }

    function get_attestation_genesis_height(uint64 chainKey) external view returns (uint64) {
        return _genesis[chainKey];
    }

    function is_height_attested(uint64 chainKey, uint64 height) external view returns (bool) {
        return _latest[chainKey].exists && height <= _latest[chainKey].height;
    }
}

/**
 * @dev Stands in for the BlockProver precompile. It answers only whether a proof was
 *      accepted; it never produces the value. That separation is the point: the
 *      registry must reject a bad probe transaction even when the proof is perfectly
 *      valid, because a valid proof of a reverted read is still a proof.
 */
contract VerifierStub {
    bool public accept = true;
    uint64 public txIndex;

    function setAccept(bool a) external {
        accept = a;
    }

    function setTxIndex(uint64 i) external {
        txIndex = i;
    }

    function calculateTxIndex(INativeQueryVerifier.MerkleProof calldata) external view returns (uint64) {
        return txIndex;
    }

    function verifyAndEmit(
        uint64,
        uint64,
        bytes calldata,
        INativeQueryVerifier.MerkleProof calldata,
        INativeQueryVerifier.ContinuityProof calldata
    ) external view returns (bool) {
        return accept;
    }

    function verifyAndEmit(
        uint64,
        uint64[] calldata,
        bytes[] calldata,
        INativeQueryVerifier.MerkleProof[] calldata,
        INativeQueryVerifier.ContinuityProof calldata
    ) external view returns (bool) {
        return accept;
    }
}

/// @dev Builds transactions in the encoding the decoder actually consumes.
library TxFixture {
    /// @param status 1 for a successful transaction, 0 for a reverted one.
    function encode(uint8 txType, uint8 status, EvmV1Decoder.LogEntry[] memory logs)
        internal
        pure
        returns (bytes memory)
    {
        bytes[] memory chunks = new bytes[](3);
        chunks[0] =
            abi.encode(uint64(1), uint64(100000), address(0xBEEF), false, address(0xCAFE), uint256(0), bytes(""));
        chunks[1] = abi.encode(uint128(1 gwei), uint128(2 gwei), new bytes(0), uint8(0), bytes32(0), bytes32(0));

        EvmV1Decoder.LogEntryTuple[] memory tuples = new EvmV1Decoder.LogEntryTuple[](logs.length);
        for (uint256 i = 0; i < logs.length; ++i) {
            tuples[i] = EvmV1Decoder.LogEntryTuple(logs[i].address_, logs[i].topics, logs[i].data);
        }
        chunks[2] = abi.encode(status, uint64(50000), tuples, bytes(""));

        return abi.encode(txType, chunks);
    }

    /// @dev Ten separate parameters put every caller close to the stack limit, and one
    ///      extra local in a handler was enough to cross it. Grouping them costs nothing
    ///      and gives the arguments names at the call site.
    struct Probe {
        address emitter;
        bytes32 signature;
        address target;
        bytes32 callHash;
        address prober;
        bool success;
        bool truncated;
        uint256 height;
        uint256 timestamp;
        bytes returnData;
    }

    function probedLog(Probe memory p) internal pure returns (EvmV1Decoder.LogEntry memory) {
        return probedLog(
            p.emitter,
            p.signature,
            p.target,
            p.callHash,
            p.prober,
            p.success,
            p.truncated,
            p.height,
            p.timestamp,
            p.returnData
        );
    }

    function probedLog(
        address emitter,
        bytes32 signature,
        address target,
        bytes32 callHash,
        address prober,
        bool success,
        bool truncated,
        uint256 height,
        uint256 timestamp,
        bytes memory returnData
    ) internal pure returns (EvmV1Decoder.LogEntry memory) {
        bytes32[] memory topics = new bytes32[](4);
        topics[0] = signature;
        topics[1] = bytes32(uint256(uint160(target)));
        topics[2] = callHash;
        topics[3] = bytes32(uint256(uint160(prober)));
        return EvmV1Decoder.LogEntry(emitter, topics, abi.encode(success, truncated, height, timestamp, returnData));
    }
}
