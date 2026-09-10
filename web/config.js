// Everything the page needs to read Lens without a server.
// Addresses are the live CC3 testnet deployment; see docs/EVIDENCE.md.
window.LENS = {
  creditcoinRpc: 'https://rpc.cc3-testnet.creditcoin.network',
  explorer: 'https://creditcoin-testnet.blockscout.com',
  registry: '0x81b6DcbcE28EC0634DC905cfDc5eA84005915852',
  aggregator: '0x43E5d502Fa15bE5ef70799B629718fb4CF490fF5',
  reserveMonitor: '0xD51bEE1d6b2f013d907D3e13e570b2b6586e0c72',
  market: '0xEE527a62C239E4664e887c0e248eAc741E0EF9EF',
  votePort: '0x4AD27A0b32c0D2aA0ebf96D7F1F74810093be115',
  snapshotProver: '0xaef8215c3048687Cf3d0346cB9FcB1BE67c12647',
  breaker: '0xf219a37884B5314dD5057d0C4051aa0349907066',

  // Source chains, keyed by native chain id. Chain keys are resolved at runtime from
  // the precompile, never hardcoded, for the reason given in docs/VERIFIED.md.
  sources: {
    11155111: {
      label: 'Ethereum Sepolia',
      rpc: 'https://ethereum-sepolia-rpc.publicnode.com',
      explorer: 'https://sepolia.etherscan.io',
    },
    1: {
      label: 'Ethereum mainnet',
      rpc: 'https://ethereum-rpc.publicnode.com',
      explorer: 'https://etherscan.io',
    },
  },

  feeds: [
    {
      name: 'Chainlink ETH/USD',
      note: 'a Chainlink feed carried onto a chain Chainlink does not serve',
      chainId: 11155111,
      target: '0x694AA1769357215DE4FAC081bf1f309aDC325306',
      calldata: '0x50d25bcd',
      decode: (hex) => `$${(Number(BigInt(hex)) / 1e8).toFixed(2)} per ETH`,
    },
    {
      name: 'Aave WETH backing',
      note: 'WETH actually held against the aWETH issued',
      chainId: 11155111,
      target: '0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c',
      calldata: '0x70a082310000000000000000000000005b071b590a59395fe4025a0ccc1fcc931aac1830',
      decode: (hex) => `${(Number(BigInt(hex)) / 1e18).toLocaleString(undefined, { maximumFractionDigits: 3 })} WETH`,
    },
    {
      name: 'aWETH issued',
      note: 'the other leg of the solvency ratio',
      chainId: 11155111,
      target: '0x5b071b590a59395fE4025A0Ccc1FcC931AAc1830',
      calldata: '0x18160ddd',
      decode: (hex) => `${(Number(BigInt(hex)) / 1e18).toLocaleString(undefined, { maximumFractionDigits: 3 })} aWETH`,
    },
    {
      name: 'WETH total supply',
      note: 'an ordinary ERC-20 read',
      chainId: 11155111,
      target: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14',
      calldata: '0x18160ddd',
      decode: (hex) => `${(Number(BigInt(hex)) / 1e18).toLocaleString(undefined, { maximumFractionDigits: 3 })} WETH`,
    },
    {
      name: 'Governance weight at a past block',
      note: 'historical state, with no storage proof anywhere',
      chainId: 11155111,
      target: '0x99E1749Fd45Bb14CF59139b04Cc387981f3ef66e',
      calldata:
        '0x3a46b1a8000000000000000000000000cf7a68bf1585c36f0cc0077ce16888f6388fc3590000000000000000000000000000000000000000000000000000000000b22c6e',
      decode: (hex) => `${(Number(BigInt(hex)) / 1e18).toLocaleString()} LVOTE`,
    },
  ],
};
