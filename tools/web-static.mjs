/**
 * Checks the web page without a network: every local file it references exists, the
 * generated config evaluates, every decoder runs on a plausible input, and no source
 * file carries a private endpoint or a key.
 *
 *   node tools/web-static.mjs
 */
import { readFileSync, existsSync } from 'node:fs';

const web = new URL('../web/', import.meta.url);
const html = readFileSync(new URL('index.html', web), 'utf8');
let failures = 0;
const say = (ok, line) => {
  if (!ok) failures++;
  console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${line}`);
};

for (const ref of [...html.matchAll(/(?:src|href)="\.\/([^"]+)"/g)].map((m) => m[1])) {
  say(existsSync(new URL(ref, web)), `${ref} exists`);
}

const window = {};
new Function('window', readFileSync(new URL('config.js', web), 'utf8'))(window);
const C = window.LENS;
say(Array.isArray(C.feeds) && C.feeds.length > 0, `config.js evaluates with ${C.feeds?.length ?? 0} feeds`);

const word = (n) => '0x' + n.toString(16).padStart(64, '0');
for (const feed of C.feeds) {
  const sample = /\[\]/.test(feed.signature)
    ? '0x' + [0x40, 0xa0, 2, 1, 2, 2, 3, 4].map((n) => n.toString(16).padStart(64, '0')).join('')
    : word(1_000_000_000_000_000_000n);
  try {
    const out = feed.decode(sample);
    say(typeof out === 'string' && out.length > 0, `${feed.name} decodes: ${out}`);
  } catch (e) {
    say(false, `${feed.name} decoder threw: ${e.message}`);
  }
}

for (const file of ['index.html', 'app.js', 'config.js', 'styles.css']) {
  const text = readFileSync(new URL(file, web), 'utf8');
  // Transaction hashes and feed ids are 32-byte hex too, so keys are not searched for
  // by shape; keyed RPC endpoints have recognisable hosts.
  say(!/alchemy\.com\/v2\/|infura\.io\/v3\/|quiknode\.pro\/|apikey=|api_key=/i.test(text), `${file} carries no keyed endpoint`);
}
say(Object.values(C.sources).every((s) => /^https:\/\/[^/]+(\/[a-z-]*)?$/.test(s.rpc)), 'source RPCs are public, unkeyed endpoints');

console.log(failures ? `\n${failures} check(s) failed` : '\nthe page is well-formed');
process.exit(failures ? 1 : 0);
