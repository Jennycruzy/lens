// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IChainInfo
 * @notice The ChainInfo precompile at `0xfd3`, which reports which source chains
 *         Creditcoin attests and how far each one has been attested.
 *
 * @dev Written from the ABI shipped in `@gluwa/usc-sdk` rather than transcribed from
 *      documentation, and confirmed against CC3 testnet at runtime — see
 *      `docs/VERIFIED.md`. Two details are easy to get wrong:
 *
 *      `chainName` is ABI type `bytes`, not `string`, even though the SDK's TypeScript
 *      interface declares it a string.
 *
 *      `chainKey` is an identifier local to one Attestcoin environment. The same
 *      integer means different chains on different environments: Ethereum mainnet is
 *      key 3 on CC3 testnet and key 1 on CC3 mainnet, while key 1 on testnet is
 *      Sepolia. `chainId` is the native chain id and is the only field here that means
 *      the same thing everywhere.
 */
interface IChainInfo {
    struct ChainInfo {
        uint64 chainKey;
        uint64 chainId;
        bytes chainName;
        uint8 chainEncoding;
    }

    /// @dev `get_chain_by_key` wraps the struct with a presence flag, while
    ///      `get_supported_chains` returns the bare struct. The two are easy to
    ///      conflate and the ABI decoder gives nothing useful when they are: a
    ///      constructor that reads the wrong shape reverts with no data at all.
    struct ChainInfoResult {
        ChainInfo info;
        bool exists;
    }

    struct HeightHash {
        uint64 height;
        bytes32 hash;
        bool isAttestation;
        bool exists;
    }

    struct HeightResult {
        uint64 height;
        bool exists;
    }

    function get_supported_chains() external view returns (ChainInfo[] memory chains);

    function get_chain_by_key(uint64 chainKey) external view returns (ChainInfoResult memory);

    /// @notice Highest block of `chainKey` that Creditcoin has attested.
    /// @dev When `exists` is false nothing has been attested for the chain and the
    ///      other fields carry no meaning.
    function get_latest_attestation_height_and_hash(uint64 chainKey) external view returns (HeightHash memory);

    function get_latest_checkpoint_height_and_hash(uint64 chainKey) external view returns (HeightHash memory);

    /// @notice Lowest block of `chainKey` that can be proven at all.
    function get_attestation_genesis_height(uint64 chainKey) external view returns (uint64);

    function is_height_attested(uint64 chainKey, uint64 height) external view returns (bool);
}

library ChainInfoLib {
    address internal constant PRECOMPILE = 0x0000000000000000000000000000000000000fD3;

    function chainInfo() internal pure returns (IChainInfo) {
        return IChainInfo(PRECOMPILE);
    }
}
