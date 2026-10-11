#!/usr/bin/env node
// BLACKOUT v3.7 keeper. Node 22+, no dependencies. Reads RPC_URL and KEEPER_KEY only from an env
// file outside the repository (default /etc/blackout/keeper.env, override with --env PATH).
//
//   node keeper.mjs status            read-only overview of what is due
//   node keeper.mjs once [--dry-run]  one pass over every duty
//   node keeper.mjs run  [--dry-run]  loop forever (systemd unit); --interval SECONDS (default 2)
//
// Every duty is simulated with eth_call first and only sent when the simulation succeeds, so a
// disabled phase (locks, billboards, pot...) or a not-yet-due action never costs gas.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';
import {bytesCall,storedAnswer} from './lib/oracle.mjs';
import { encodeCall, decodeWords, wordToAddress, keccak256, utf8, signTransaction, privateToAddress, bigToHex, word }
  from './lib/eth.mjs';

const args = process.argv.slice(2);
const command = args.find((a) => !a.startsWith('--')) || 'status';
const flag = (name, fallback) => {
  const i = args.indexOf(name);
  return i === -1 ? fallback : args[i + 1];
};
const dryRun = args.includes('--dry-run') || command === 'status';
const envPath = flag('--env', '/etc/blackout/keeper.env');
const interval = Number(flag('--interval', '2')) * 1000;

function loadEnv(path) {
  const out = {};
  if (!existsSync(path)) throw new Error(`env file not found: ${path} (see keeper/README.md)`);
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z_]+)\s*=\s*"?([^"#]*)"?\s*(#.*)?$/);
    if (m) out[m[1]] = m[2].trim();
  }
  return out;
}
const env = loadEnv(envPath);
const RPC = env.RPC_URL;
const REGISTRY = env.REGISTRY;
const KEY = env.KEEPER_KEY;
const STATE = env.STATE_FILE || '/var/lib/blackout/keeper-state.json';
const CHAIN = env.CHAIN_ID ? Number(env.CHAIN_ID) : null;
if (!RPC || !REGISTRY) throw new Error('RPC_URL and REGISTRY are required in the env file');
if (!dryRun && !/^0x[0-9a-fA-F]{64}$/.test(KEY || '')) throw new Error('KEEPER_KEY (0x + 64 hex) is required unless --dry-run');
const keeper = KEY && /^0x[0-9a-fA-F]{64}$/.test(KEY) ? privateToAddress(KEY) : null;

let rpcId = 1;
async function rpc(method, params = []) {
  const res = await fetch(RPC, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: rpcId++, method, params }),
  });
  const body = await res.json();
  if (body.error) throw Object.assign(new Error(body.error.message || 'rpc error'), { rpc: body.error });
  return body.result;
}
const call = (to, sig, a = []) => rpc('eth_call', [{ to, data: encodeCall(sig, a), from: keeper || undefined }, 'latest']);
const uint = async (to, sig, a = []) => decodeWords(await call(to, sig, a))[0] ?? 0n;
const addr = async (to, sig, a = []) => wordToAddress(await uint(to, sig, a));
const topic = (sig) => keccak256(utf8(sig));

// ---------------------------------------------------------------- state
function loadState() {
  try { return JSON.parse(readFileSync(STATE, 'utf8')); } catch { return { nextBlock: 0, pending: {} }; }
}
function saveState(state) {
  if (dryRun) return;
  mkdirSync(dirname(STATE), { recursive: true });
  writeFileSync(STATE, JSON.stringify(state));
}

// ------------------------------------------------------------- contracts
const ROLES = { pool: 0, rewards: 1, farm: 2, items: 3, packs: 4, starter: 5, fees: 6, grid: 7, season: 8, engine: 9,
  economy: 10, enhancement: 11, civic: 12, billboards: 13 };
async function modules() {
  const out = { registry: REGISTRY };
  for (const [name, role] of Object.entries(ROLES)) {
    try { out[name] = await addr(REGISTRY, 'module(uint256)', [role]); } catch { out[name] = null; }
    if (out[name] && (await rpc('eth_getCode', [out[name], 'latest'])) === '0x') out[name] = null;
  }
  if (Object.values(ROLES).some((_, i) => !out[Object.keys(ROLES)[i]])) {
    throw new Error(`registry ${REGISTRY} has unregistered or codeless modules; register all fourteen roles first`);
  }
  out.market = await addr(REGISTRY, 'market()');
  out.params = await addr(REGISTRY, 'params()');
  out.desk = await addr(out.params, 'swarmWallet()');
  return out;
}

// --------------------------------------------------------------- sending
const log = (...m) => console.log(new Date().toISOString(), ...m);
async function attempt(label, to, sig, a = [], rawData) {
  if (!to) return { label, ok: false, reason: 'module not registered' };
  const data = rawData || encodeCall(sig, a);
  try {
    await rpc('eth_call', [{ from: keeper || undefined, to, data }, 'latest']);
  } catch (e) {
    return { label, ok: false, reason: e.rpc?.data || e.message };
  }
  if (dryRun) { log(`[dry-run] would send ${label}`); return { label, ok: true, dry: true }; }
  const [nonce, gasHex, block] = await Promise.all([
    rpc('eth_getTransactionCount', [keeper, 'pending']),
    rpc('eth_estimateGas', [{ from: keeper, to, data }]),
    rpc('eth_getBlockByNumber', ['latest', false]),
  ]);
  const base = BigInt(block.baseFeePerGas || '0x0');
  const tip = BigInt(env.PRIORITY_FEE_WEI || '1000000');
  const tx = { chainId: CHAIN ?? Number(BigInt(await rpc('eth_chainId'))), nonce, maxPriorityFeePerGas: tip,
    maxFeePerGas: base * 2n + tip, gas: BigInt(gasHex) * 12n / 10n, to, data, value: 0n };
  const raw = signTransaction(tx, KEY);
  const hash = await rpc('eth_sendRawTransaction', [raw]);
  log(`sent ${label} ${hash}`);
  for (let i = 0; i < 60; i++) {
    const receipt = await rpc('eth_getTransactionReceipt', [hash]);
    if (receipt) {
      const ok = BigInt(receipt.status) === 1n;
      log(`${ok ? 'confirmed' : 'REVERTED'} ${label} in block ${Number(BigInt(receipt.blockNumber))}`);
      return { label, ok, hash };
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  return { label, ok: false, reason: 'no receipt after 60s', hash };
}

// ----------------------------------------------------------------- duties
async function scanCommits(m, state) {
  const head = Number(BigInt(await rpc('eth_blockNumber')));
  const start = Math.max(0, state.nextBlock - 16); // re-read a little after restarts
  const sources = [
    ['pack', m.packs, topic('PackCommitted(uint256,address,uint256,uint256,bool)')],
    ['starter', m.starter, topic('StarterCommitted(uint256,address,uint256)')],
    ['enhance', m.enhancement, topic('EnhancementCommitted(uint256,address,uint256,uint256,uint256,uint256)')],
    ['season', m.season, topic('SeasonPrepared(uint256,uint256)')],
    ['oracle', m.desk, topic('AnswerStored(uint8,bytes32,uint256,bytes)')],
  ];
  for (let low = start; low <= head; low += 2000) {
    const high = Math.min(head, low + 1999);
    for (const [kind, address, t] of sources) {
      if (!address) continue;
      const logs = await rpc('eth_getLogs', [{ address, fromBlock: bigToHex(BigInt(low)), toBlock: bigToHex(BigInt(high)), topics: [t] }]);
      for (const entry of logs) {
        if (entry.removed) continue;
        if (kind === 'oracle') {
          const result=storedAnswer(entry);state.oracleAnswers ??= {};state.oracleAnswers[result.stream]=result;continue;
        }
        state.pending[`${kind}:${BigInt(entry.topics[1])}`] = [kind, BigInt(entry.topics[1]).toString()];
      }
    }
  }
  state.nextBlock = head + 1;
}

async function entropyDuties(m, state, results) {
  for (const [key, [kind, idStr]] of Object.entries(state.pending)) {
    const id = BigInt(idStr);
    let done = false;
    if (kind === 'pack') {
      const c = decodeWords(await call(m.packs, 'commits(uint256)', [id]));
      // Commit layout: player, target, count, opened, mythic, guaranteed, seed, fixedSeed, expired
      done = c.length && c[7] === 1n && c[3] >= c[2];
      if (!done && c[7] === 0n) {
        const r = await attempt(`pack capture #${id}`, m.packs, 'captureEntropy(uint256)', [id]);
        results.push(r);
        if (!r.ok) results.push(await attempt(`pack re-arm #${id}`, m.packs, 'rearm(uint256)', [id]));
      }
    } else if (kind === 'starter') {
      const captured = await uint(m.starter, 'entropyCaptured(uint256)', [id]);
      done = captured === 1n;
      if (!done) {
        const r = await attempt(`starter capture #${id}`, m.starter, 'captureEntropy(uint256)', [id]);
        results.push(r);
        if (!r.ok) results.push(await attempt(`starter re-arm #${id}`, m.starter, 'rearm(uint256)', [id]));
      }
    } else if (kind === 'enhance') {
      const a = decodeWords(await call(m.enhancement, 'attempts(uint256)', [id]));
      done = a.length && a[6] === 1n; // resolved
      if (!done) {
        if (a[5] === 0n) results.push(await attempt(`enhancement capture #${id}`, m.enhancement, 'capture(uint256)', [id]));
        results.push(await attempt(`enhancement resolve #${id}`, m.enhancement, 'resolve(uint256)', [id]));
      }
    } else if (kind === 'season') {
      const r = await attempt(`season finalize week ${id}`, m.season, 'finalize(uint256)', [id]);
      results.push(r);
      if (!r.ok) results.push(await attempt(`season re-arm week ${id}`, m.season, 'rearm(uint256)', [id]));
      else if (!r.dry) done = true;
    }
    if (done) delete state.pending[key];
  }
}

async function epochDuties(m, results) {
  const [live, end, epoch] = await Promise.all([uint(m.rewards, 'live()'), uint(m.rewards, 'epochEnd()'), uint(m.rewards, 'epoch()')]);
  const now = BigInt(Math.floor(Date.now() / 1000));
  if (live === 1n && now >= end) results.push(await attempt(`advanceEpoch -> ${epoch + 1n}`, m.rewards, 'advanceEpoch()'));
  // Event resolution for the current epoch (no-op if the epoch advance already resolved it).
  const ev = decodeWords(await call(m.grid, 'eventAt(uint256)', [epoch]));
  if (ev.length && ev[4] === 0n) results.push(await attempt(`grid resolve epoch ${epoch}`, m.grid, 'resolve(uint256)', [epoch]));
  return { live, end, epoch };
}

async function seasonDuties(m, results) {
  let week = 0n;
  try { week = await uint(m.billboards || m.civic, 'week()'); } catch { return { week: null }; }
  for (let w = week > 2n ? week - 2n : 0n; w < week; w++) {
    results.push(await attempt(`season prepare week ${w}`, m.season, 'prepare(uint256,uint256)', [w, 64n]));
    results.push(await attempt(`season rollover week ${w}`, m.season, 'rollover(uint256)', [w]));
  }
  if (m.billboards) {
    for (let d = 0n; d < 8n; d++) results.push(await attempt(`billboard settle week ${week} district ${d}`, m.billboards, 'settleBillboard(uint256,uint256)', [week, d]));
  }
  return { week };
}

async function feeDuties(m, results) {
  const [amount, minimum] = decodeWords(await call(m.fees, 'sellBatchQuote()'));
  if (amount && amount > 0n) results.push(await attempt(`system sell ${amount} tokens`, m.fees, 'executeSells(uint256,uint256)', [amount, minimum]));
  const [rewardETH, potETH, batch, slippage] = await Promise.all([
    uint(m.fees, 'rewardETH()'), uint(m.fees, 'potETH()'),
    uint(m.params, 'get(uint8)', [22n]), uint(m.params, 'get(uint8)', [23n]),
  ]);
  const MIN = 50000000000000000n; // 0.05 ETH, FeeRouter.MIN_BUY_AMOUNT
  for (const [name, balance, fn, bps] of [['reward', rewardETH, 'executeBuys(uint256,uint256)', slippage], ['pot', potETH, 'executePotBuys(uint256,uint256)', 150n]]) {
    if (balance === 0n) continue;
    const eth = balance < batch ? balance : batch;
    if (eth < (balance < MIN ? balance : MIN)) continue;
    const quote = await uint(m.market, 'quote(uint256)', [eth]);
    if (quote === 0n) continue;
    results.push(await attempt(`${name} buy ${eth} wei`, m.fees, fn, [eth, quote * (10000n - bps) / 10000n]));
  }
  return { sellBatch: amount ?? 0n, rewardETH, potETH };
}

async function phaseDuties(m, results) {
  const flags = [];
  for (let f = 0n; f < 8n; f++) {
    const [enabled, notice] = await Promise.all([uint(m.civic, 'enabled(uint256)', [f]), uint(m.civic, 'noticeAt(uint256)', [f])]);
    flags.push({ feature: Number(f), enabled: enabled === 1n, noticeAt: Number(notice) });
    if (enabled === 0n && notice !== 0n) results.push(await attempt(`enable feature ${f}`, m.civic, 'enable(uint256)', [f]));
  }
  const announcedCap = await uint(m.enhancement, 'announcedCap()');
  if (announcedCap !== 0n) results.push(await attempt(`activate enhancement cap +${announcedCap}`, m.enhancement, 'activateCap()'));
  return flags;
}

async function oracleDuties(m,state,results) {
  const status=[];
  for(let stream=0;stream<2;stream++) {
    const a=decodeWords(await call(m.desk,'lastAnswer(uint8)',[stream]));
    const row={stream,hash:a[0],requestId:a[1],issuedAt:Number(a[2]),validUntil:Number(a[3]),slot:a[4],pending:a[5]===1n,receivedBlock:a[6]};
    status.push(row);
    let cached=state.oracleAnswers?.[stream];
    if(row.pending&&(!cached||BigInt(cached.id)!==row.requestId)) {
      const logs=await rpc('eth_getLogs',[{address:m.desk,fromBlock:bigToHex(row.receivedBlock),toBlock:bigToHex(row.receivedBlock),topics:[topic('AnswerStored(uint8,bytes32,uint256,bytes)'),'0x'+word(stream),'0x'+word(row.requestId)]}]);
      for(const entry of logs) {cached=storedAnswer(entry);if(cached){state.oracleAnswers??={};state.oracleAnswers[stream]=cached;}}
    }
    if(row.pending&&cached&&BigInt(cached.id)===row.requestId) {
      results.push(await attempt(`execute swarm ${stream===0?'event':'regulator'}`,m.desk,'execute(uint8,bytes)',[],bytesCall('execute(uint8,bytes)',stream,cached.answer)));
    }
  }
  return status;
}

async function pass(m, state) {
  const results = [];
  await scanCommits(m, state);
  const oracle = await oracleDuties(m, state, results);
  const epoch = await epochDuties(m, results);
  await entropyDuties(m, state, results);
  const season = await seasonDuties(m, results);
  const fees = await feeDuties(m, results);
  const flags = await phaseDuties(m, results);
  saveState(state);
  return { epoch, season, fees, flags, oracle, results };
}

const FEATURE_NAMES = ['district war', 'grid collapse', 'weekly lots', 'enhancement', 'locks/stake/lobby', 'billboards', 'season pot', 'reserved events'];
async function status() {
  const m = await modules();
  const state = loadState();
  const out = await pass(m, state);
  const now = Math.floor(Date.now() / 1000);
  console.log(`keeper ${keeper || '(no key, read-only)'} chain ${Number(BigInt(await rpc('eth_chainId')))}`);
  if (keeper) console.log(`balance ${Number(BigInt(await rpc('eth_getBalance', [keeper, 'latest']))) / 1e18} ETH`);
  console.log(`epoch ${out.epoch.epoch} live=${out.epoch.live === 1n} ends in ${Number(out.epoch.end) - now}s; week ${out.season.week}`);
  console.log(`fees: sell batch ${out.fees.sellBatch} tokens, reward ETH ${out.fees.rewardETH}, pot ETH ${out.fees.potETH}`);
  for (const f of out.flags) console.log(`feature ${f.feature} ${FEATURE_NAMES[f.feature]}: ${f.enabled ? 'ENABLED' : f.noticeAt ? `announced, opens ${new Date(f.noticeAt * 1000).toISOString()}` : 'disabled'}`);
  console.log(`SwarmDesk ${m.desk}`);
  for (const a of out.oracle) console.log(`oracle ${a.stream===0?'event':'regulator'}: last=${a.issuedAt?new Date(a.issuedAt*1000).toISOString():'none'} validUntil=${a.validUntil} pending=${a.pending} slot=${a.slot}`);
  const oc=decodeWords(await call(m.desk,'oracleConfig()'));
  console.log(`backup IMD balance ${await uint(wordToAddress(oc[3]),'balanceOf(address)',[m.desk])}; last failure ${await call(m.desk,'lastFailure()')}`);
  console.log(`pending entropy commits: ${Object.keys(state.pending).length}`);
  const due = out.results.filter((r) => r.ok);
  console.log(due.length ? `due now: ${due.map((r) => r.label).join(', ')}` : 'nothing due');
}

async function main() {
  if (command === 'status') return status();
  const m = await modules();
  if(command==='ask-backup') {
    const name=flag('--stream','event');if(!['event','regulator'].includes(name))throw Error('--stream event|regulator');
    const body=readFileSync(flag('--body',`docs/oracle-v37/${name}.json`));
    const result=await attempt(`paid backup ${name}`,m.desk,'askBackup(uint8,bytes)',[],bytesCall('askBackup(uint8,bytes)',name==='event'?0:1,'0x'+body.toString('hex')));
    console.log(result);return;
  }
  if(!['once','run'].includes(command))throw Error('Command: status, once, run, ask-backup');
  log(`keeper ${keeper || '(dry-run, unsigned)'} registry ${REGISTRY} rpc ${new URL(RPC).host}${dryRun ? ' DRY-RUN' : ''}`);
  const state = loadState();
  do {
    try {
      const out = await pass(m, state);
      const sent = out.results.filter((r) => r.ok && !r.dry).length;
      if (sent) log(`${sent} transaction(s) sent`);
    } catch (e) {
      log('pass failed:', e.message);
    }
    if (command === 'run') await new Promise((r) => setTimeout(r, interval));
  } while (command === 'run');
}
main().catch((e) => { console.error(e.message); process.exit(1); });
