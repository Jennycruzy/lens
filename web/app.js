/**
 * Reads Lens directly from the chains, in the visitor's browser.
 *
 * There is no server and no cache. Every number on the page is fetched from
 * Creditcoin's public RPC or the source chain's, so a visitor is checking the claim
 * rather than reading our summary of it.
 */
const C = window.LENS;
const { JsonRpcProvider, Contract, AbiCoder, keccak256 } = ethers;

const creditcoin = new JsonRpcProvider(C.creditcoinRpc, undefined, { staticNetwork: true });
const sourceProviders = Object.fromEntries(
  Object.entries(C.sources).map(([id, s]) => [id, new JsonRpcProvider(s.rpc, undefined, { staticNetwork: true })]),
);

const REGISTRY_ABI = [
  'function observationOf(bytes32) view returns ((bytes returnData,uint256 probeHeight,uint64 sourceTimestamp,uint64 recordedAt,bool callSucceeded,bool truncated,address prober))',
  'function hasObservation(bytes32) view returns (bool)',
  'function frontierOf(uint64) view returns (uint64)',
  'function feedIdFromCallHash(uint64,address,bytes32) view returns (bytes32)',
  'function chainKeys() view returns (uint64[])',
  'function sourceOf(uint64) view returns ((uint64 chainId,address probe,bool registered))',
];
const CHAIN_INFO_ABI = [
  'function get_supported_chains() view returns ((uint64 chainKey,uint64 chainId,bytes chainName,uint8 chainEncoding)[])',
];
const registry = new Contract(C.registry, REGISTRY_ABI, creditcoin);
const chainInfo = new Contract('0x0000000000000000000000000000000000000fd3', CHAIN_INFO_ABI, creditcoin);

const coder = AbiCoder.defaultAbiCoder();
const short = (h, n = 10) => `${h.slice(0, n)}…${h.slice(-4)}`;
const el = (t, cls, html) => {
  const e = document.createElement(t);
  if (cls) e.className = cls;
  if (html !== undefined) e.innerHTML = html;
  return e;
};

/** Chain keys are environment-local, so they are resolved from the precompile, never assumed. */
let chainKeyByChainId = null;
async function chainKeys() {
  if (chainKeyByChainId) return chainKeyByChainId;
  const chains = await chainInfo.get_supported_chains();
  chainKeyByChainId = Object.fromEntries(chains.map((c) => [Number(c.chainId), Number(c.chainKey)]));
  return chainKeyByChainId;
}

const feedId = (chainKey, target, calldata) =>
  keccak256(coder.encode(['uint64', 'address', 'bytes32'], [chainKey, target, keccak256(calldata)]));

async function loadFeeds() {
  const keys = await chainKeys();
  const tbody = document.querySelector('#feeds tbody');
  tbody.innerHTML = '';

  for (const feed of C.feeds) {
    const chainKey = keys[feed.chainId];
    const src = C.sources[feed.chainId];
    const row = el('tr');
    const id = feedId(chainKey, feed.target, feed.calldata);

    row.appendChild(el('td', '', `<div>${feed.name}</div><div class="dim" style="font-size:12.5px">${feed.note}</div>`));

    if (chainKey === undefined) {
      row.appendChild(el('td', 'dim', `${src.label}<br><span class="warn">not attested here</span>`));
      row.appendChild(el('td', 'dim', '—'));
      row.appendChild(el('td', 'dim', '—'));
      row.appendChild(el('td', 'dim', '—'));
      tbody.appendChild(row);
      continue;
    }

    row.appendChild(el('td', '',
      `${src.label}<div class="dim mono">key ${chainKey} here</div>` +
      `<a class="mono" href="${src.explorer}/address/${feed.target}" target="_blank" rel="noopener">${short(feed.target)}</a>`));

    const valueCell = el('td', 'dim', 'reading…');
    const ageCell = el('td', 'dim', '—');
    const checkCell = el('td');
    row.append(valueCell, ageCell, checkCell);
    tbody.appendChild(row);

    try {
      if (!(await registry.hasObservation(id))) {
        valueCell.className = 'dim';
        valueCell.textContent = 'never proven';
        continue;
      }
      const o = await registry.observationOf(id);
      const frontier = await registry.frontierOf(chainKey);
      const age = frontier > o.probeHeight ? Number(frontier - o.probeHeight) : 0;

      if (!o.callSucceeded) {
        valueCell.innerHTML = '<span class="bad">the source read failed</span>';
      } else if (o.truncated) {
        valueCell.innerHTML = '<span class="warn">truncated, not decodable</span>';
      } else {
        valueCell.innerHTML =
          `<div>${feed.decode(o.returnData)}</div>` +
          `<div class="hex mono">${short(o.returnData, 20)}</div>` +
          `<div class="dim mono">${src.label.split(' ')[1] ?? ''} block ${o.probeHeight}</div>`;
      }

      ageCell.className = age > 600 ? 'warn' : '';
      ageCell.innerHTML = `${age} blocks<div class="dim" style="font-size:12px">~${Math.round((age * 12) / 60)} min</div>`;

      const btn = el('button', '', 'verify');
      btn.onclick = () => verify(btn, checkCell, feed, chainKey, o);
      checkCell.appendChild(btn);
    } catch (e) {
      valueCell.innerHTML = `<span class="bad">${e.shortMessage ?? e.message}</span>`;
    }
  }
}

/**
 * The comparison, run in the visitor's browser: call the same contract with the same
 * calldata on the source chain at the height that was proven, and hold it against what
 * Creditcoin holds.
 */
async function verify(btn, cell, feed, chainKey, observation) {
  btn.disabled = true;
  btn.textContent = 'checking…';
  try {
    const provider = sourceProviders[feed.chainId];
    const onSource = await provider.call({
      to: feed.target,
      data: feed.calldata,
      blockTag: Number(observation.probeHeight),
    });
    const agrees = onSource === observation.returnData;
    cell.innerHTML =
      `<span class="pill ${agrees ? 'ok' : 'bad'}">${agrees ? 'byte-equal' : 'DIVERGED'}</span>` +
      `<div class="hex mono" style="margin-top:6px">source ${short(onSource, 20)}</div>` +
      `<div class="hex mono">lens&nbsp;&nbsp; ${short(observation.returnData, 20)}</div>`;
  } catch (e) {
    cell.innerHTML = `<span class="bad">${e.shortMessage ?? e.message}</span>`;
  }
}

/**
 * The errors a consumer can refuse with, so the page can say why rather than showing a
 * bare failure. A refusal is the design working, and it is worth reading: a feed past
 * its age bound, a read that failed at the source, a breaker that has tripped. Showing
 * only "refused" throws away the most interesting thing on the page.
 */
const REFUSALS = [
  'error FeedStale(bytes32 feedId, uint256 age, uint256 maxAge)',
  'error StalePrice(uint256 age, uint256 maxAge)',
  'error FeedUnavailable(bytes32 feedId)',
  'error SourceCallReverted(bytes32 feedId)',
  'error AnswerTruncated(bytes32 feedId)',
  'error CannotDetermineSolvency()',
  'error BreakerTripped(uint8 reason, uint64 since)',
  'error InvalidPrice(int256 answer)',
  'error NoProvenWeight(address voter, bytes32 feedId)',
];
const refusalInterface = new ethers.Interface(REFUSALS);

function explainRefusal(e) {
  const data = e?.data ?? e?.info?.error?.data ?? e?.error?.data;
  if (data && data !== '0x') {
    try {
      const parsed = refusalInterface.parseError(data);
      if (parsed?.name === 'FeedStale' || parsed?.name === 'StalePrice') {
        const [, age, maxAge] = parsed.args;
        return `refused: ${age} blocks old, bound is ${maxAge}`;
      }
      if (parsed?.name === 'FeedUnavailable') return 'refused: never proven';
      if (parsed?.name === 'SourceCallReverted') return 'refused: the source read failed';
      if (parsed?.name === 'AnswerTruncated') return 'refused: the answer was truncated';
      if (parsed?.name === 'CannotDetermineSolvency') return 'refused: an input is unavailable';
      if (parsed?.name === 'BreakerTripped') return 'refused: the breaker is tripped';
      if (parsed) return `refused: ${parsed.name}`;
    } catch { /* fall through to the message */ }
  }
  const msg = e?.shortMessage ?? e?.message ?? '';
  const named = msg.match(/(FeedStale|StalePrice|FeedUnavailable|SourceCallReverted|AnswerTruncated|CannotDetermineSolvency|BreakerTripped)\(([^)]*)\)/);
  if (named) {
    if (named[1] === 'FeedStale' || named[1] === 'StalePrice') {
      const parts = named[2].split(',').map((p) => p.trim());
      const [age, maxAge] = parts.slice(-2);
      return `refused: ${age} blocks old, bound is ${maxAge}`;
    }
    return `refused: ${named[1]}`;
  }
  return 'refused';
}

const CONSUMERS = [
  {
    label: 'Reserve backing',
    address: () => C.reserveMonitor,
    abi: ['function ratio() view returns (uint256,uint256)', 'function isSolvent() view returns (bool)'],
    read: async (c) => {
      const [value] = await c.ratio();
      const solvent = await c.isSolvent();
      return { v: (Number(value) / 1e18).toFixed(6), n: solvent ? 'covers what was issued' : 'SHORTFALL' };
    },
  },
  {
    label: 'Lending market price',
    address: () => C.market,
    abi: ['function price() view returns (uint256)', 'function PRICE_UNIT() view returns (uint256)'],
    read: async (c) => {
      const p = await c.price();
      const unit = await c.PRICE_UNIT();
      return { v: `$${(Number(p) / Number(unit)).toFixed(2)}`, n: 'read through the Chainlink interface' };
    },
  },
  {
    label: 'Circuit breaker',
    address: () => C.breaker,
    abi: ['function status() view returns (bool,uint8)'],
    read: async (c) => {
      const [tripped, reason] = await c.status();
      const why = ['', 'deviation', 'frontier regression', 'age'][Number(reason)] || '';
      return { v: tripped ? 'tripped' : 'closed', n: tripped ? why : 'no owner, no pause key' };
    },
  },
  {
    label: 'Governance',
    address: () => C.votePort,
    abi: [
      'function proposalCount() view returns (uint256)',
      'function outcome(uint256) view returns (bool,uint256,uint256)',
    ],
    read: async (c) => {
      const n = await c.proposalCount();
      if (n === 0n) return { v: '0', n: 'no proposals yet' };
      const [, forVotes] = await c.outcome(0n);
      return { v: `${(Number(forVotes) / 1e18).toLocaleString()}`, n: 'weight proven from the source chain' };
    },
  },
  {
    label: 'Snapshot claims',
    address: () => C.snapshotProver,
    abi: ['function campaignCount() view returns (uint256)'],
    read: async (c) => ({ v: String(await c.campaignCount()), n: 'eligibility proven, never published' }),
  },
];

async function loadConsumers() {
  const grid = document.getElementById('consumers');
  grid.innerHTML = '';
  for (const spec of CONSUMERS) {
    const card = el('div', 'card');
    card.appendChild(el('div', 'k', spec.label));
    const v = el('div', 'v', '…');
    const n = el('div', 'n', '');
    card.append(v, n);
    grid.appendChild(card);
    try {
      const { v: value, n: note } = await spec.read(new Contract(spec.address(), spec.abi, creditcoin));
      v.textContent = value;
      n.textContent = note;
    } catch (e) {
      // A refusal is the design working. Say what it refused for.
      const why = explainRefusal(e);
      v.innerHTML = '<span class="pill warn">fails closed</span>';
      n.textContent = why;
    }
  }
}

function loadAddresses() {
  const rows = [
    ['LensRegistry', C.registry],
    ['LensAggregatorV3', C.aggregator],
    ['ReserveMonitor', C.reserveMonitor],
    ['LensMarket', C.market],
    ['VotePort', C.votePort],
    ['SnapshotProver', C.snapshotProver],
    ['CircuitBreaker', C.breaker],
  ];
  const tbody = document.querySelector('#addresses tbody');
  tbody.innerHTML = '';
  for (const [name, addr] of rows) {
    const tr = el('tr');
    tr.appendChild(el('td', '', name));
    tr.appendChild(el('td', 'mono',
      `<a href="${C.explorer}/address/${addr}" target="_blank" rel="noopener">${addr}</a>`));
    tbody.appendChild(tr);
  }
}

loadAddresses();
loadFeeds();
loadConsumers();
setInterval(() => { loadFeeds(); loadConsumers(); }, 60000);
