#!/usr/bin/env node
// Offline packing for the launcher's fourteen-word SwarmDesk constructor. No RPC or signing.
import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';

function uint(value,bits,name,min=0n) {
  if(typeof value==='number'&&!Number.isSafeInteger(value))throw Error(`Use a decimal string for ${name}`);
  let n;try{n=BigInt(value);}catch{throw Error(`Invalid ${name}`);}
  if(n<min||n>=(1n<<BigInt(bits)))throw Error(`Out of range ${name}`);
  return n;
}
function address(value,name) {
  if(!/^0x[0-9a-fA-F]{40}$/.test(value)||BigInt(value)===0n)throw Error(`Invalid ${name}`);
  return value;
}
function hash(value,name) {
  if(!/^0x[0-9a-fA-F]{64}$/.test(value)||BigInt(value)===0n)throw Error(`Invalid ${name}`);
  return value;
}
export function swarmConstructorArgs(o,b) {
  const chain=uint(o.questionChain,64,'questionChain',1n),from=uint(o.fromBlock,64,'fromBlock'),to=uint(o.toBlock,64,'toBlock');
  if(to<from)throw Error('Reversed context window');
  const rl=uint(b.registryLaunch??0,64,'registryLaunch'),ri=uint(b.registryIndex??0,3,'registryIndex');
  const pl=uint(b.paramsLaunch??0,64,'paramsLaunch'),pi=uint(b.paramsIndex??0,3,'paramsIndex');
  if(rl!==0n||ri!==0n||pl!==0n||pi!==0n)throw Error('v3.8: launch coordinates are proven at bind time, not in the constructor');
  const bps=uint(b.heartbeatBps,16,'heartbeatBps');
  if(bps<200n||bps>5000n||BigInt(b.heartbeatCap)!==10n**18n)throw Error('Invalid heartbeat configuration');
  if(o.intake.toLowerCase()===o.delivery.toLowerCase())throw Error('Duplicate callback endpoints');
  if(o.questions[0].toLowerCase()===o.questions[1].toLowerCase())throw Error('Duplicate question commitments');
  const context=chain|(from<<64n)|(to<<128n),binding=rl|(ri<<64n)|(pl<<72n)|(pi<<136n)|(bps<<144n);
  return [address(o.intake,'intake'),address(o.delivery,'delivery'),address(o.signer,'signer'),address(o.asset,'asset'),
    hash(o.action,'action'),uint(o.maxPrice,256,'maxPrice',1n).toString(),context.toString(),
    hash(o.questions[0],'eventQuestion'),hash(o.questions[1],'regulatorQuestion'),hash(o.bodies[0],'eventBody'),hash(o.bodies[1],'regulatorBody'),
    address(b.factory,'factory'),binding.toString(),hash(b.gameConfigHash,'gameConfigHash')];
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  if(process.argv.length!==4)throw Error('Usage: node tools/swarm_constructor_args.mjs oracle-config.json approved-binding.json');
  const [o,b]=process.argv.slice(2).map(p=>JSON.parse(readFileSync(p,'utf8')));
  console.log(JSON.stringify({constructorArgs:swarmConstructorArgs(o,b)},null,2));
}
