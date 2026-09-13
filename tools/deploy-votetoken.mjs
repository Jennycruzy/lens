/**
 * Deploys the Sepolia governance token and self-delegates, so the
 * holder immediately has checkpointed voting weight for VotePort to read.
 *
 *   node tools/deploy-votetoken.mjs [--broadcast]
 */
import { readFileSync } from 'node:fs';
import { ContractFactory, Contract, parseUnits } from 'ethers';
import { proberWallet, sourceProvider } from '../prober/lib/config.mjs';

/** Reads a compiled artifact, and says what to do when the project has not been built. */
function readArtifact(url) {
  try {
    return JSON.parse(readFileSync(url));
  } catch {
    console.error('\n  no compiled artifact. Run: forge build\n');
    process.exit(2);
  }
}


const broadcast = process.argv.includes('--broadcast');
const wallet = proberWallet(11155111);
const art = readArtifact(new URL('../out/LensVoteToken.sol/LensVoteToken.json', import.meta.url));

console.log(`\n  holder ${wallet.address}`);
if (!broadcast) {
  console.log('\nnothing sent. re-run with --broadcast to deploy.\n');
  process.exit(0);
}

const factory = new ContractFactory(art.abi, art.bytecode.object, wallet);
const token = await factory.deploy(wallet.address, parseUnits('1000000', 18));
await token.waitForDeployment();
const address = await token.getAddress();
console.log(`  token  ${address}`);

// An ERC20Votes balance writes no checkpoints until it is delegated, so weight would
// read as zero however many tokens were held. Delegating is what creates the history.
const tx = await token.delegate(wallet.address);
const receipt = await tx.wait();
console.log(`  delegated in block ${receipt.blockNumber}`);

const provider = sourceProvider(11155111);
const t = new Contract(address, art.abi, provider);
console.log(`\n  balanceOf         ${await t.balanceOf(wallet.address)}`);
console.log(`  delegates to      ${await t.delegates(wallet.address)}`);
console.log(`  getVotes          ${await t.getVotes(wallet.address)}`);

// A checkpoint is only readable once its block is genuinely past: asking about the
// current block reverts with ERC5805FutureLookup rather than returning anything.
let head = await provider.getBlockNumber();
while (head <= receipt.blockNumber) {
  await new Promise((r) => setTimeout(r, 4000));
  head = await provider.getBlockNumber();
}
console.log(`  getPastVotes(${receipt.blockNumber})  ${await t.getPastVotes(wallet.address, receipt.blockNumber)}`);
console.log(`\n  add to .env:  LENS_VOTE_TOKEN=${address}\n`);
