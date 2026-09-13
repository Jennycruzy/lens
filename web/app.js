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
  'event ObservationRecorded(bytes32 indexed feedId, uint64 indexed chainKey, address indexed target, uint256 probeHeight, bool callSucceeded, address prober, bytes returnData)',
];
const PROBE_ABI = [
  'event Probed(address indexed target, bytes32 indexed callHash, address indexed caller, bool success, bool truncated, uint256 blockNumber, uint256 blockTimestamp, bytes returnData)',
];
const CHAIN_INFO_ABI = [
  'function get_supported_chains() view returns ((uint64 chainKey,uint64 chainId,bytes chainName,uint8 chainEncoding)[])',
];
const registry = new Contract(C.registry, REGISTRY_ABI, creditcoin);
const probeInterface = new ethers.Interface(PROBE_ABI);
const chainInfo = new Contract('0x0000000000000000000000000000000000000fd3', CHAIN_INFO_ABI, creditcoin);

const coder = AbiCoder.defaultAbiCoder();
const short = (h, n = 10) => (h ? `${h.slice(0, n)}…${h.slice(-4)}` : '—');
const num = (n) => Number(n).toLocaleString();
const el = (t, cls, html) => {
  const e = document.createElement(t);
  if (cls) e.className = cls;
  if (html !== undefined) e.innerHTML = html;
  return e;
};
const $ = (id) => document.getElementById(id);
const link = (href, text, cls = 'mono') => `<a class="${cls}" href="${href}" target="_blank" rel="noopener">${text}</a>`;
const when = (ts) => new Date(Number(ts) * 1000).toISOString().replace('T', ' ').slice(0, 19) + ' UTC';
const minutes = (blocks) => {
  const m = (blocks * 12) / 60;
  return m >= 120 ? `~${(m / 60).toFixed(1)} h` : `~${Math.round(m)} min`;
};

/** Chain keys are environment-local, so they are resolved from the precompile, never assumed. */
let chainKeyByChainId = null;
async function chainKeys() {
  if (chainKeyByChainId) return chainKeyByChainId;
  const chains = await chainInfo.get_supported_chains();
  chainKeyByChainId = Object.fromEntries(chains.map((c) => [Number(c.chainId), Number(c.chainKey)]));
  return chainKeyByChainId;
}

/** The page's headline feeds, in the order the generator ranks them. */
const featuredFeeds = () => C.feeds.filter((f) => f.featured).sort((a, b) => a.featured - b.featured);

const feedId = (chainKey, target, calldata) =>
  keccak256(coder.encode(['uint64', 'address', 'bytes32'], [chainKey, target, keccak256(calldata)]));

/** The registry's view of a feed, plus the freshness arithmetic every reader uses. */
async function readFeed(feed) {
  const keys = await chainKeys();
  const chainKey = keys[feed.chainId];
  if (chainKey === undefined) return { chainKey, state: 'not-attested' };
  const id = feedId(chainKey, feed.target, feed.calldata);
  if (!(await registry.hasObservation(id))) return { chainKey, id, state: 'missing' };
  const [o, frontier] = await Promise.all([registry.observationOf(id), registry.frontierOf(chainKey)]);
  const regressed = o.probeHeight > frontier;
  const age = regressed ? Infinity : Number(frontier - o.probeHeight);
  let state = 'ok';
  if (!o.callSucceeded) state = 'failed';
  else if (regressed) state = 'regressed';
  else if (o.truncated) state = 'truncated';
  return { chainKey, id, state, o, frontier: Number(frontier), age };
}

/**
 * The comparison, run in the visitor's browser: call the same contract with the same
 * calldata on the source chain at the height that was proven, and hold it against what
 * Creditcoin holds. Three outcomes, kept apart: equal, diverged, and could-not-check.
 * A public RPC declining to serve an old block says nothing about whether the values
 * agree, so it is never shown as a divergence.
 */
async function compare(feed, observation) {
  const src = C.sources[feed.chainId];
  const request = { to: feed.target, data: feed.calldata, blockTag: Number(observation.probeHeight) };
  // The main endpoint first, then the public endpoints that serve historical state.
  // Only when every one declines is the comparison inconclusive.
  const attempts = [[src.rpc, sourceProviders[feed.chainId]], ...(src.archiveRpcs ?? []).map((rpc) => [rpc, null])];
  let lastMessage = '';
  let sawArchiveRefusal = false;
  for (const [rpc, existing] of attempts) {
    const provider = existing ?? new JsonRpcProvider(rpc, undefined, { staticNetwork: true });
    try {
      const onSource = await provider.call(request);
      const via = new URL(rpc).host;
      return { outcome: onSource === observation.returnData ? 'equal' : 'diverged', onSource, via };
    } catch (e) {
      // ethers puts the RPC's own words in the response body, not the short message, and
      // publicnode answers a historical call with a 403 and "archive requests require a
      // personal token". All of that is "could not check here", never "diverged".
      const msg = [e.shortMessage, e.message, e.info?.responseBody, e.info?.error?.message].filter(Boolean).join(' ');
      if (/archive|personal token|missing revert data|state.*not available|missing trie node|header not found|403/i.test(msg)) sawArchiveRefusal = true;
      lastMessage = e.shortMessage ?? e.message ?? '';
    }
  }
  return { outcome: sawArchiveRefusal ? 'archive' : 'error', message: lastMessage };
}

function describeState(r) {
  switch (r.state) {
    case 'not-attested': return '<span class="warn">NOT ATTESTED HERE</span>';
    case 'missing': return '<span class="muted">NOT YET PROVEN</span>';
    case 'failed': return '<span class="bad">SOURCE CALL FAILED</span>';
    case 'regressed': return '<span class="bad">FRONTIER REGRESSED · REFUSED</span>';
    case 'truncated': return '<span class="warn">TRUNCATED · REFUSED</span>';
    default: return '';
  }
}

// ---------------------------------------------------------------------------
// Network status in the nav.

async function loadStatus() {
  const pill = $('net-status');
  try {
    const n = await creditcoin.getBlockNumber();
    pill.className = 'pill ok';
    pill.innerHTML = `<span class="dot live"></span> CC3 testnet live · block ${num(n)}`;
  } catch {
    pill.className = 'pill bad';
    pill.innerHTML = '<span class="dot"></span> CC3 testnet unreachable';
  }
}

// ---------------------------------------------------------------------------
// The hero: one value, mainnet, live.

async function loadHeroFlow() {
  const feed = C.feeds.find((f) => f.name === 'mainnet.steth.rate') ?? C.feeds.find((f) => f.featured) ?? C.feeds[0];
  $('hf-call').textContent = feed.signature.split(' ')[0].replace(/\(.*$/, '') + (feed.name.includes('steth') ? '(1e18)' : '()');
  const src = C.sources[feed.chainId];
  try {
    const r = await readFeed(feed);
    if (r.state !== 'ok') {
      $('hf-src').innerHTML = describeState(r);
      return;
    }
    const value = feed.decode(r.o.returnData);
    $('hf-src').textContent = `${src.label} · block ${num(r.o.probeHeight)}`;
    $('hf-e1').classList.add('lit');
    $('hf-probe').textContent = `source block ${num(r.o.probeHeight)}`;
    $('hf-e2').classList.add('lit');
    $('hf-att').textContent = `attested to ${num(r.frontier)}`;
    $('hf-e3').classList.add('lit');
    $('hf-cc').textContent = value;
    $('hf-age').textContent = `${r.age} source blocks old · ${minutes(r.age)}`;
    const v = $('hf-verdict');
    const c = await compare(feed, r.o);
    if (c.outcome === 'equal') {
      v.textContent = `✓ VERIFIED · BYTE EQUAL, RECHECKED HERE VIA ${c.via.toUpperCase()}`;
    } else if (c.outcome === 'archive') {
      v.textContent = '✓ BYTE EQUAL AT PROOF TIME · ARCHIVE RPC NEEDED TO RECHECK HERE';
      v.classList.add('warn');
    } else if (c.outcome === 'diverged') {
      v.textContent = '✗ DIVERGED';
      v.className = 'verdict shown bad';
    } else {
      v.textContent = 'RECHECK UNAVAILABLE';
      v.classList.add('warn');
    }
    v.classList.add('shown');
  } catch (e) {
    $('hf-src').innerHTML = `<span class="bad">${(e.shortMessage ?? e.message ?? '').slice(0, 80)}</span>`;
  }
}

// ---------------------------------------------------------------------------
// The proof visualizer: one feed, four stages, every link real.

const traced = { feed: null };

function buildChooser() {
  const box = $('proof-chooser');
  const order = [...featuredFeeds(), ...C.feeds.filter((f) => !f.featured && f.name.includes('uniswap'))];
  for (const feed of order) {
    const b = el('button', 'chip', `${feed.title} <span class="muted">· ${C.sources[feed.chainId].label.split(' ')[1]}</span>`);
    b.type = 'button';
    b.setAttribute('aria-pressed', 'false');
    b.onclick = () => trace(feed);
    b.dataset.feed = feed.name;
    box.appendChild(b);
  }
}

async function trace(feed) {
  traced.feed = feed;
  for (const b of document.querySelectorAll('#proof-chooser .chip')) b.setAttribute('aria-pressed', String(b.dataset.feed === feed.name));
  for (const i of [1, 2, 3, 4]) $(`st-${i}`).classList.remove('lit');
  const src = C.sources[feed.chainId];
  const badge = $('oc-badge');
  badge.className = 'badge';
  badge.innerHTML = 'CHECKING…<small>comparing in your browser</small>';
  $('oc-source').textContent = '—';
  $('oc-cc').textContent = '—';

  $('s1-title').textContent = feed.title;
  $('s1-chain').textContent = src.label;
  $('s1-value').textContent = 'reading…';
  $('s1-contract').innerHTML = link(`${src.explorer}/address/${feed.target}`, short(feed.target));
  $('s1-fn').textContent = feed.signature.replace(/ view returns.*$/, '').replace(/ returns.*$/, '');
  $('s1-block').textContent = '—';
  $('s1-time').textContent = '—';
  $('s2-chain').textContent = src.label;
  $('s2-status').textContent = '—';
  $('s2-probe').innerHTML = link(`${src.explorer}/address/${src.probe}`, short(src.probe));
  $('s2-tx').textContent = 'looking up…';
  $('s2-prober').textContent = '—';
  $('s3-chain').textContent = `${src.label} → Creditcoin`;
  $('s3-status').textContent = '—';
  $('s3-frontier').textContent = '—';
  $('s3-height').textContent = '—';
  $('s3-tx').textContent = 'looking up…';
  $('s4-value').textContent = '—';
  $('s4-registry').innerHTML = link(`${C.explorer}/address/${C.registry}`, short(C.registry));
  $('s4-feed').textContent = '—';
  $('s4-age').textContent = '—';

  let r;
  try {
    r = await readFeed(feed);
  } catch (e) {
    $('s1-value').innerHTML = `<span class="bad">${(e.shortMessage ?? e.message ?? '').slice(0, 80)}</span>`;
    return;
  }
  if (traced.feed !== feed) return;
  $('s4-feed').textContent = r.id ? short(r.id, 14) : '—';
  if (r.state !== 'ok') {
    $('s1-value').innerHTML = describeState(r);
    $('s4-value').innerHTML = describeState(r);
    badge.className = 'badge warn';
    badge.innerHTML = `${r.state === 'missing' ? 'NOT YET PROVEN' : 'REFUSED'}<small>nothing to compare</small>`;
    return;
  }
  const { o } = r;
  const value = feed.decode(o.returnData);

  // 01 — the source read
  $('s1-value').textContent = value;
  $('s1-block').textContent = num(o.probeHeight);
  $('s1-time').textContent = when(o.sourceTimestamp);
  $('st-1').classList.add('lit');

  // 02 — the probe transaction that carried it
  $('s2-status').textContent = 'Probed event emitted';
  $('s2-prober').innerHTML = link(`${src.explorer}/address/${o.prober}`, short(o.prober)) + ' <span class="muted">liveness only</span>';
  $('st-2').classList.add('lit');
  findProbeTx(feed, o).then((tx) => {
    if (traced.feed !== feed) return;
    $('s2-tx').innerHTML = tx
      ? link(`${src.explorer}/tx/${tx}`, short(tx, 12))
      : link(`${src.explorer}/address/${src.probe}#events`, 'see the probe’s events on the explorer', '');
  });

  // 03 — attestation
  $('s3-frontier').textContent = num(r.frontier);
  $('s3-height').textContent = num(o.probeHeight);
  $('s3-status').textContent = 'Proof accepted';
  $('st-3').classList.add('lit');
  findProofTx(r.id).then((tx) => {
    if (traced.feed !== feed) return;
    $('s3-tx').innerHTML = tx
      ? link(`${C.explorer}/tx/${tx}`, short(tx, 12))
      : link(`${C.explorer}/address/${C.registry}?tab=logs`, 'see the registry’s logs on Blockscout', '');
  });

  // 04 — Creditcoin holds it
  $('s4-value').textContent = value;
  $('s4-age').textContent = `${r.age} source blocks · ${minutes(r.age)}`;
  $('st-4').classList.add('lit');
  $('oc-cc').textContent = o.returnData;

  const c = await compare(feed, o);
  if (traced.feed !== feed) return;
  if (c.outcome === 'equal') {
    $('oc-source').textContent = c.onSource;
    badge.className = 'badge ok';
    badge.innerHTML = `✓ BYTE IDENTICAL<small>rechecked from the source chain in this browser, at the proven block, via ${c.via}</small>`;
  } else if (c.outcome === 'diverged') {
    $('oc-source').textContent = c.onSource;
    badge.className = 'badge bad';
    badge.innerHTML = '✗ DIVERGED<small>the source chain disagrees with Creditcoin at this block</small>';
  } else if (c.outcome === 'archive') {
    $('oc-source').innerHTML = '<span class="warn">archive state unavailable on this public RPC</span>';
    badge.className = 'badge warn';
    badge.innerHTML = '✓ BYTE EQUAL AT PROOF TIME<small>compared when proven and recorded in the evidence ledger. No reachable public endpoint would serve the historical block just now; that is not a divergence.</small>';
  } else {
    $('oc-source').innerHTML = `<span class="muted">${c.message.slice(0, 100)}</span>`;
    badge.className = 'badge warn';
    badge.innerHTML = 'RECHECK UNAVAILABLE<small>the source RPC did not answer</small>';
  }
}

/** The source transaction whose log carries this observation: the Probed event at the proven block, for this call. */
async function findProbeTx(feed, o) {
  try {
    const topic = probeInterface.getEvent('Probed').topicHash;
    const logs = await sourceProviders[feed.chainId].getLogs({
      address: C.sources[feed.chainId].probe,
      fromBlock: Number(o.probeHeight),
      toBlock: Number(o.probeHeight),
      topics: [topic, ethers.zeroPadValue(feed.target, 32), keccak256(feed.calldata)],
    });
    return logs[0]?.transactionHash ?? null;
  } catch {
    return null;
  }
}

/**
 * The Creditcoin transaction that recorded this observation. The public RPC answers a
 * 5,000-block log query in under a second and refuses a 40,000-block one, so this walks
 * back in small windows, newest first, and stops at the first hit.
 */
async function findProofTx(id) {
  try {
    const head = await creditcoin.getBlockNumber();
    const topic = registry.interface.getEvent('ObservationRecorded').topicHash;
    const span = 5000;
    for (let to = head; to > head - 8 * span && to > 0; to -= span) {
      const logs = await creditcoin.getLogs({ address: C.registry, fromBlock: Math.max(0, to - span + 1), toBlock: to, topics: [topic, id] });
      if (logs.length) return logs[logs.length - 1].transactionHash;
    }
    return null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Feeds: four cards first, the full table on request.

function verifyButton(feed, o, cell) {
  const btn = el('button', 'btn small', 'Verify');
  btn.type = 'button';
  btn.onclick = async () => {
    btn.disabled = true;
    btn.textContent = 'checking…';
    const c = await compare(feed, o);
    if (c.outcome === 'equal') {
      cell.innerHTML = `<span class="pill ok">byte equal</span><div class="muted small" style="margin-top:6px">rechecked here via ${c.via}</div>`;
    } else if (c.outcome === 'diverged') {
      cell.innerHTML = `<span class="pill bad">diverged</span><div class="hex mono small" style="margin-top:6px">source ${short(c.onSource, 20)}</div>`;
    } else if (c.outcome === 'archive') {
      cell.innerHTML = '<span class="pill warn">archive RPC required</span>' +
        `<div class="muted small" style="margin-top:6px">this public RPC will not serve block ${num(o.probeHeight)}. Equal at proof time; not a divergence.</div>`;
    } else {
      cell.innerHTML = `<span class="pill warn">recheck unavailable</span><div class="muted small" style="margin-top:6px">${c.message.slice(0, 100)}</div>`;
      btn.disabled = false;
      btn.textContent = 'Retry';
      cell.appendChild(btn);
    }
  };
  return btn;
}

async function loadFeaturedFeeds() {
  const grid = $('featured');
  grid.innerHTML = '';
  for (const feed of featuredFeeds()) {
    const src = C.sources[feed.chainId];
    const card = el('article', 'card feed-card');
    card.innerHTML =
      `<div class="chain">${src.label}</div><h3>${feed.title}</h3>` +
      `<div class="value">reading…</div>` +
      `<dl><dt>Source block</dt><dd class="b">—</dd><dt>Age</dt><dd class="a">—</dd><dt>Proof</dt><dd class="p">—</dd></dl>` +
      `<div class="actions"></div>`;
    grid.appendChild(card);
    const value = card.querySelector('.value');
    const actions = card.querySelector('.actions');
    try {
      const r = await readFeed(feed);
      if (r.state !== 'ok') {
        value.innerHTML = describeState(r);
        continue;
      }
      value.textContent = feed.decode(r.o.returnData);
      card.querySelector('.b').textContent = num(r.o.probeHeight);
      card.querySelector('.a').textContent = `${r.age} blocks · ${minutes(r.age)}`;
      card.querySelector('.p').innerHTML = '<span class="ok">VERIFIED</span>';
      const view = el('button', 'btn small', 'View proof');
      view.type = 'button';
      view.onclick = () => { trace(feed); document.getElementById('proof').scrollIntoView({ behavior: 'smooth' }); };
      actions.appendChild(view);
      actions.insertAdjacentHTML('beforeend',
        `<a class="btn small" href="${src.explorer}/address/${feed.target}" target="_blank" rel="noopener">Source</a>` +
        `<a class="btn small" href="${C.explorer}/address/${C.registry}" target="_blank" rel="noopener">Creditcoin</a>`);
    } catch (e) {
      value.innerHTML = `<span class="bad">${(e.shortMessage ?? e.message ?? '').slice(0, 80)}</span>`;
    }
  }
}

async function loadFeedTable() {
  const tbody = document.querySelector('#feeds-table tbody');
  tbody.innerHTML = '';
  for (const feed of C.feeds) {
    const src = C.sources[feed.chainId];
    const row = el('tr');
    row.appendChild(el('td', '', `<div>${feed.title}</div><div class="sub">${feed.note}</div><div class="sub mono">${feed.name}</div>`));
    const sourceCell = el('td', '', `${src.label}<div class="sub mono">${feed.signature.replace(/ view returns.*$/, '')}</div>` +
      link(`${src.explorer}/address/${feed.target}`, short(feed.target)));
    const valueCell = el('td', 'muted', 'reading…');
    const ageCell = el('td', 'muted', '—');
    const checkCell = el('td');
    row.append(sourceCell, valueCell, ageCell, checkCell);
    tbody.appendChild(row);
    try {
      const r = await readFeed(feed);
      if (r.state === 'not-attested') { sourceCell.innerHTML += '<div class="warn small">not attested here</div>'; valueCell.textContent = '—'; continue; }
      sourceCell.innerHTML += `<div class="sub mono">key ${r.chainKey} here</div>`;
      if (r.state !== 'ok') { valueCell.innerHTML = describeState(r); continue; }
      valueCell.className = '';
      valueCell.innerHTML = `<div>${feed.decode(r.o.returnData)}</div><div class="hex mono small">${short(r.o.returnData, 20)}</div><div class="sub mono">block ${num(r.o.probeHeight)}</div>`;
      ageCell.className = r.age > 600 ? 'warn' : '';
      ageCell.innerHTML = `${r.age} blocks<div class="sub">${minutes(r.age)}</div>`;
      checkCell.appendChild(verifyButton(feed, r.o, checkCell));
    } catch (e) {
      valueCell.innerHTML = `<span class="bad">${(e.shortMessage ?? e.message ?? '').slice(0, 80)}</span>`;
    }
  }
}

// ---------------------------------------------------------------------------
// Consumers. A refusal is the design working, so the card says why.

const REFUSALS = [
  'error FeedStale(bytes32 feedId, uint256 age, uint256 maxAge)',
  'error StalePrice(uint256 age, uint256 maxAge)',
  'error FeedUnavailable(bytes32 feedId)',
  'error SourceCallReverted(bytes32 feedId)',
  'error AnswerTruncated(bytes32 feedId)',
  'error FeedReadFailed(bytes32 feedId)',
  'error FeedTruncated(bytes32 feedId)',
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
        const [, age, maxAge] = parsed.args.length === 3 ? parsed.args : [null, ...parsed.args];
        return `STALE · ${age} source blocks old, bound is ${maxAge}`;
      }
      if (parsed?.name === 'FeedUnavailable') return 'NOT YET PROVEN';
      if (parsed?.name === 'SourceCallReverted' || parsed?.name === 'FeedReadFailed') return 'SOURCE CALL FAILED';
      if (parsed?.name === 'AnswerTruncated' || parsed?.name === 'FeedTruncated') return 'TRUNCATED';
      if (parsed?.name === 'CannotDetermineSolvency') return 'REFUSED · an input is unavailable';
      if (parsed?.name === 'BreakerTripped') return 'REFUSED · the breaker is tripped';
      if (parsed) return `REFUSED · ${parsed.name}`;
    } catch { /* fall through to the message */ }
  }
  const msg = e?.shortMessage ?? e?.message ?? '';
  const named = msg.match(/(FeedStale|StalePrice|FeedUnavailable|SourceCallReverted|AnswerTruncated|CannotDetermineSolvency|BreakerTripped)\(([^)]*)\)/);
  if (named) {
    if (named[1] === 'FeedStale' || named[1] === 'StalePrice') {
      const [age, maxAge] = named[2].split(',').map((p) => p.trim()).slice(-2);
      return `STALE · ${age} source blocks old, bound is ${maxAge}`;
    }
    return `REFUSED · ${named[1]}`;
  }
  return 'REFUSED';
}

const CONSUMERS = [
  {
    title: 'Reserve / backing monitor',
    tag: 'Cross-chain solvency checkpoint',
    path: '<b>Sepolia</b> WETH held by Aave, aWETH issued<br>↓ Lens<br><b>Creditcoin</b> ReserveMonitor',
    address: () => C.reserveMonitor,
    abi: ['function ratio() view returns (uint256,uint256)', 'function isSolvent() view returns (bool)'],
    read: async (c) => {
      const [value, age] = await c.ratio();
      const solvent = await c.isSolvent();
      return { v: `${(Number(value) / 1e18).toFixed(6)}×`, n: `${solvent ? 'backing covers what was issued' : 'SHORTFALL'} · ${age} source blocks old` };
    },
  },
  {
    title: 'AggregatorV3-compatible feed',
    tag: 'Familiar interface, verified source',
    path: '<b>Sepolia</b> Chainlink ETH/USD latestAnswer()<br>↓ Lens<br><b>Creditcoin</b> LensAggregatorV3 → LensMarket',
    address: () => C.market,
    abi: ['function price() view returns (uint256)', 'function PRICE_UNIT() view returns (uint256)'],
    read: async (c) => {
      const p = await c.price();
      const unit = await c.PRICE_UNIT();
      return { v: `$${(Number(p) / Number(unit)).toFixed(2)}`, n: 'read through latestRoundData(); reverts when stale' };
    },
    note: 'For time-averaged or slow-moving state only. Not intended for block-sensitive liquidation pricing. The value keeps Chainlink’s own trust assumptions; Lens removes the cross-chain reporter.',
  },
  {
    title: 'Historical voting weight',
    tag: 'Governance from checkpointed history',
    path: '<b>Sepolia</b> getPastVotes(holder, block)<br>↓ Lens<br><b>Creditcoin</b> VotePort',
    address: () => C.votePort,
    abi: ['function proposalCount() view returns (uint256)', 'function outcome(uint256) view returns (bool,uint256,uint256)'],
    read: async (c) => {
      const n = await c.proposalCount();
      if (n === 0n) return { v: '0 proposals', n: 'no proposals yet' };
      const [, forVotes, against] = await c.outcome(n - 1n);
      return { v: `${(Number(forVotes) / 1e18).toLocaleString()} for`, n: `${(Number(against) / 1e18).toLocaleString()} against · weight proven from the source chain, never supplied by the voter` };
    },
  },
];

async function loadConsumers() {
  const grid = $('consumers-grid');
  grid.innerHTML = '';
  for (const spec of CONSUMERS) {
    const card = el('article', 'card consumer');
    card.innerHTML =
      `<div class="k">${spec.tag}</div><h3 style="margin-top:6px">${spec.title}</h3>` +
      `<div class="path">${spec.path}</div>` +
      `<div class="live"><div class="k">Live result</div><div class="v">…</div><div class="n"></div></div>` +
      (spec.note ? `<div class="note">${spec.note}</div>` : '') +
      `<div class="actions" style="margin-top:12px">${link(`${C.explorer}/address/${spec.address()}`, short(spec.address()))}</div>`;
    grid.appendChild(card);
    const v = card.querySelector('.live .v');
    const n = card.querySelector('.live .n');
    try {
      const { v: value, n: note } = await spec.read(new Contract(spec.address(), spec.abi, creditcoin));
      v.textContent = value;
      n.textContent = note;
    } catch (e) {
      v.innerHTML = '<span class="pill warn">refused</span>';
      n.textContent = explainRefusal(e);
    }
  }

  const more = $('more-primitives');
  for (const [name, addr] of [['CircuitBreaker', C.breaker], ['FeedEscrow', C.escrow], ['SnapshotProver', C.snapshotProver], ['LensAggregatorV3', C.aggregator]]) {
    more.insertAdjacentHTML('beforeend', `<a class="pill" href="${C.explorer}/address/${addr}" target="_blank" rel="noopener">${name}</a>`);
  }
}

// ---------------------------------------------------------------------------
// Attestation lag, read from the chains rather than quoted from a document.

async function loadLatency() {
  const grid = $('latency');
  grid.innerHTML = '';
  const keys = await chainKeys();
  for (const [chainId, src] of Object.entries(C.sources)) {
    const chainKey = keys[chainId];
    const card = el('div', 'card');
    card.innerHTML = `<div class="k">${src.label} · attestation lag</div><div class="v">…</div><div class="n"></div>`;
    grid.appendChild(card);
    const v = card.querySelector('.v');
    const n = card.querySelector('.n');
    if (chainKey === undefined) { v.textContent = '—'; n.textContent = 'not attested by this environment'; continue; }
    try {
      const [frontier, head] = await Promise.all([registry.frontierOf(chainKey), sourceProviders[chainId].getBlockNumber()]);
      const lag = Math.max(0, head - Number(frontier));
      v.textContent = `${lag} blocks`;
      n.textContent = `~${((lag * 12) / 60).toFixed(1)} min behind · attested to ${num(frontier)}, head ${num(head)}`;
    } catch (e) {
      v.textContent = '—';
      n.textContent = (e.shortMessage ?? e.message ?? '').slice(0, 70);
    }
  }
}

// ---------------------------------------------------------------------------
// Feed builder. Any view function on an attested chain is a feed; this works out which.

const EXAMPLES = [
  { label: 'WETH totalSupply()', chainId: 11155111, target: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14', sig: 'totalSupply() returns (uint256)', args: '' },
  { label: 'stETH exchange rate', chainId: 1, target: '0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84', sig: 'getPooledEthByShares(uint256) returns (uint256)', args: '1000000000000000000' },
  { label: 'Aave pool admin role', chainId: 11155111, target: '0x7F2bE3b178deeFF716CD6Ff03Ef79A1dFf360ddD', sig: 'isPoolAdmin(address) returns (bool)', args: '0xfA0e305E0f46AB04f00ae6b5f4560d61a2183E00' },
];

async function loadBuilder() {
  const select = $('b-chain');
  const keys = await chainKeys();
  select.innerHTML = '';
  for (const [chainId, src] of Object.entries(C.sources)) {
    const o = el('option', '', `${src.label}${keys[chainId] === undefined ? ' — not attested' : ''}`);
    o.value = chainId;
    if (keys[chainId] === undefined) o.disabled = true;
    select.appendChild(o);
  }
  const ex = $('b-examples');
  for (const e of EXAMPLES) {
    const b = el('button', 'chip', e.label);
    b.type = 'button';
    b.onclick = () => {
      select.value = String(e.chainId);
      $('b-target').value = e.target;
      $('b-sig').value = e.sig;
      $('b-args').value = e.args;
      $('b-go').click();
    };
    ex.appendChild(b);
  }

  $('b-go').onclick = async () => {
    const out = $('b-out');
    const chainId = select.value;
    const target = $('b-target').value.trim();
    const sig = $('b-sig').value.trim();
    const rawArgs = $('b-args').value.trim();
    out.className = 'secondary small';
    out.textContent = 'working…';
    try {
      if (!ethers.isAddress(target)) throw new Error('That is not an address.');
      const fn = sig.startsWith('function') ? sig : `function ${sig}`;
      const iface = new ethers.Interface([fn]);
      const fnName = fn.match(/function\s+(\w+)/)[1];
      const args = rawArgs ? rawArgs.split(',').map((a) => a.trim()) : [];
      const calldata = iface.encodeFunctionData(fnName, args);
      const chainKey = keys[chainId];

      // Read it now, and decode it. The call succeeding is not enough: a contract with a
      // fallback returns empty for an unknown selector rather than reverting, so only
      // decoding tells you the target really answers this function.
      let sample;
      try {
        const raw = await sourceProviders[chainId].call({ to: target, data: calldata });
        sample = String(iface.decodeFunctionResult(fnName, raw)[0]);
      } catch {
        out.className = 'bad small';
        out.innerHTML = `That contract does not answer <code>${fnName}</code> on ${C.sources[chainId].label}.` +
          '<div class="muted" style="margin-top:6px">A feed for a call the target rejects would never hold a value.</div>';
        return;
      }
      const id = feedId(chainKey, target, calldata);
      const exists = await registry.hasObservation(id);
      out.className = '';
      out.innerHTML =
        `<div class="k">Current source value</div><div class="sample">${sample}</div>` +
        `<dl><dt>calldata</dt><dd>${calldata}</dd><dt>feed id</dt><dd>${id}</dd>` +
        `<dt>status</dt><dd>${exists ? '<span class="ok">ALREADY PROVEN</span> — this feed is live' : '<span class="warn">NOT YET PROVEN</span> — a prober has to probe it once'}</dd></dl>` +
        `<div class="k" style="margin-top:14px">Make this feed live</div>` +
        `<pre id="b-cmd">git clone https://github.com/Jennycruzy/lens && cd lens && npm install
# add the feed to prober/lib/config.mjs, then:
node prober/probe.mjs &lt;feed-name&gt;              # read it on ${C.sources[chainId].label}, emit it
node prober/prove.mjs &lt;tx-hash&gt; ${chainId}   # prove it to Creditcoin, compare the bytes</pre>` +
        `<div class="copyrow"><button class="btn small" data-copy="b-cmd" type="button">Copy</button></div>`;
      wireCopyButtons(out);
    } catch (e) {
      out.className = 'bad small';
      out.textContent = e.shortMessage ?? e.message;
    }
  };
}

// ---------------------------------------------------------------------------
// Integration snippets and tabs.

function loadSnippets() {
  const steth = C.feeds.find((f) => f.name === 'mainnet.steth.rate');

  $('snippet-native').textContent =
`import {LensConsumer} from "lens/contracts/src/LensConsumer.sol";
import {LensRegistry} from "lens/contracts/src/LensRegistry.sol";

contract YourContract is LensConsumer {
    uint64 private immutable SOURCE_KEY;

    // Resolve sourceKey from Creditcoin's ChainInfo for the environment you deploy to.
    // Chain keys are environment-local: never copy one from another environment.
    constructor(LensRegistry lens, uint64 sourceKey) LensConsumer(lens) {
        SOURCE_KEY = sourceKey;
    }

    function _defaultChainKey() internal view override returns (uint64) {
        return SOURCE_KEY;
    }

    function stethRate(bytes32 feedId) external view returns (uint256) {
        // 2400 source blocks, about eight hours: a staking rate moves basis points a day.
        // Below ~50 can never be satisfied — the frontier trails the head by 30 to 40.
        return _latestUint(feedId, 2400);
    }
}`;

  $('snippet-chainlink').textContent =
`// Already written against AggregatorV3Interface? Point it at the adapter.
AggregatorV3Interface feed = AggregatorV3Interface(
    ${C.aggregator}
);
(, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
require(block.timestamp - updatedAt <= maxAge, "stale");

// updatedAt is the SOURCE chain's clock, so this measures the real age
// of the number rather than when the proof happened to land here.
// A stale feed reverts inside latestRoundData() before you get this far.`;

  $('snippet-js').textContent =
`import { Lens } from '@jennycruzy/lens-sdk';

const lens = new Lens('${C.creditcoinRpc}', '${C.registry}');

// The stETH exchange rate, read on Ethereum mainnet and proven to Creditcoin.
const rate = await lens.readValue(
  ${steth?.chainId ?? 1},                                   // native chain id, never a chain key
  '${steth?.target ?? ''}',
  'getPooledEthByShares(uint256) returns (uint256)',
  ['1000000000000000000'],
  2400,                                // largest acceptable age, in source blocks
);

// Or take the explicit refusal instead of a throw:
const r = await lens.read(1, target, callData, 2400);
if (!r.ok) console.log(r.refusal);     // missing | call-reverted | truncated | stale`;

  for (const tab of document.querySelectorAll('.tab')) {
    tab.onclick = () => {
      for (const t of document.querySelectorAll('.tab')) t.setAttribute('aria-selected', String(t === tab));
      for (const p of document.querySelectorAll('.panel')) p.hidden = p.id !== `panel-${tab.dataset.tab}`;
    };
  }
  wireCopyButtons(document);
}

function wireCopyButtons(root) {
  for (const btn of root.querySelectorAll('[data-copy]')) {
    btn.onclick = async () => {
      try {
        await navigator.clipboard.writeText($(btn.dataset.copy).textContent);
        const was = btn.textContent;
        btn.textContent = 'Copied';
        setTimeout(() => (btn.textContent = was), 1200);
      } catch {
        btn.textContent = 'Select and copy';
      }
    };
  }
}

// ---------------------------------------------------------------------------
// Evidence: the places to look without us in the middle.

function loadEvidence() {
  const gh = 'https://github.com/Jennycruzy/lens/blob/main';
  const items = [
    ['Registry on CC3', C.registry, `${C.explorer}/address/${C.registry}`],
    ['StateProbe on Ethereum mainnet', C.sources[1]?.probe, `${C.sources[1]?.explorer}/address/${C.sources[1]?.probe}`],
    ['StateProbe on Sepolia', C.sources[11155111]?.probe, `${C.sources[11155111]?.explorer}/address/${C.sources[11155111]?.probe}`],
    ['A mainnet proof transaction', '0xf34bfdb6…8b2d0 · three observations, one source tx', `${C.explorer}/tx/0xf34bfdb6b4536f54c3d87a56d3d63d00d92094596072bef7315fd8144ae8b2d0`],
    ['Evidence ledger', 'every address and transaction behind a claim', `${gh}/docs/EVIDENCE.md`],
    ['Security model', 'six checks, and the attack each one stops', `${gh}/docs/SECURITY.md`],
    ['Latency measurements', 'lag and gas, with the receipts', `${gh}/docs/LATENCY.md`],
    ['Limits', 'what Lens cannot do, volunteered', 'https://github.com/Jennycruzy/lens#limits'],
    ['GitHub', 'contracts, prober, SDK, tests', 'https://github.com/Jennycruzy/lens'],
  ];
  const grid = $('evidence-grid');
  for (const [k, v, href] of items) {
    if (!href || href.includes('undefined')) continue;
    grid.insertAdjacentHTML('beforeend', `<a class="card" href="${href}" target="_blank" rel="noopener"><div class="k">${k}</div><div class="mono">${v}</div></a>`);
  }
}

loadStatus();
loadHeroFlow();
buildChooser();
trace(featuredFeeds()[0] ?? C.feeds[0]);
loadFeaturedFeeds();
loadFeedTable();
loadConsumers();
loadLatency();
loadBuilder();
loadSnippets();
loadEvidence();
setInterval(() => { loadStatus(); loadFeaturedFeeds(); loadFeedTable(); loadLatency(); }, 60000);
