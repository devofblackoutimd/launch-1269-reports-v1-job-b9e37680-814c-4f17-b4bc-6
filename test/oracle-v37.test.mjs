import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {oracleQuestionHash} from '../tools/oracle_question_hash.mjs';
import {bytesCall,storedAnswer} from '../keeper/lib/oracle.mjs';
import {swarmConstructorArgs} from '../tools/swarm_constructor_args.mjs';
import {keccak256,utf8,word,decodeWords} from '../keeper/lib/eth.mjs';
const vectors=JSON.parse(readFileSync('test/fixtures/oracle-hash-vectors.json','utf8')).vectors;
for(const v of vectors)assert.equal(oracleQuestionHash(v.body),v.questionHash);
const config=JSON.parse(readFileSync('docs/oracle-v37/oracle-config.json','utf8'));
// Local encoder fixtures only: never a production launch configuration.
const binding={factory:'0x1234567890123456789012345678901234567890',registryLaunch:'0',registryIndex:0,paramsLaunch:'0',paramsIndex:0,heartbeatBps:200,heartbeatCap:'1000000000000000000',gameConfigHash:keccak256(utf8('fixture'))};
const constructorArgs=swarmConstructorArgs(config,binding);
assert.equal(constructorArgs.length,14);assert.equal(constructorArgs.map(word).join('').length,14*64);
const context=BigInt(constructorArgs[6]),bind=BigInt(constructorArgs[12]),mask=(1n<<64n)-1n;
assert.equal(context&mask,1n);assert.equal((context>>64n)&mask,26122900n);assert.equal(context>>128n,26122901n);
assert.equal(bind&mask,812n);assert.equal((bind>>64n)&255n,1n);assert.equal((bind>>72n)&mask,812n);assert.equal((bind>>136n)&255n,0n);assert.equal(bind>>144n,200n);
assert.throws(()=>swarmConstructorArgs(config,{...binding,registryIndex:8}));
assert.throws(()=>swarmConstructorArgs(config,{...binding,heartbeatCap:'2'}));
assert.throws(()=>swarmConstructorArgs({...config,questionChain:1n<<64n},binding));
for(const [i,name]of ['event','regulator'].entries()) {
 const text=readFileSync(`docs/oracle-v37/${name}.json`,'utf8');const body=JSON.parse(text);
 assert.equal(oracleQuestionHash(body),config.questions[i]);assert.equal(keccak256(utf8(text)),config.bodies[i]);
 assert.equal(body.head,i===0?7:17);assert.ok(Buffer.byteLength(text)<16384);
 for(const [key,value]of Object.entries(body.definitions)){assert.ok(key.length<=64);assert.ok(value.length<=512);}
 assert.notEqual(oracleQuestionHash({...body,head:1}),config.questions[i]);
 assert.notEqual(oracleQuestionHash({...body,definitions:{...body.definitions,policy:'attacker'}}),config.questions[i]);
 assert.equal(oracleQuestionHash({...body,deliver:{chainId:4663,target:'routing excluded'}}),config.questions[i]);
 const answer='0x'+word(32)+word(body.head)+Array.from({length:body.head},(_,j)=>word(j)).join('');
 const encoded=bytesCall('execute(uint8,bytes)',i,answer);
 const args=decodeWords('0x'+encoded.slice(10));assert.equal(args[0],BigInt(i));assert.equal(args[1],64n);assert.equal(args[2],BigInt((answer.length-2)/2));
 const log={topics:['unused','0x'+word(i),'0x'+word(9)],data:'0x'+word(12)+word(64)+word((answer.length-2)/2)+answer.slice(2)};
 assert.deepEqual(storedAnswer(log),{stream:i,id:'0x'+word(9),answer});
 assert.equal(storedAnswer({...log,removed:true}),null);
}
assert.throws(()=>bytesCall('execute(uint8,bytes)',0,'0xzz'));
assert.throws(()=>oracleQuestionHash({...vectors[0].body,window:{hours:6}}));
console.log(`${vectors.length} independent protocol hash vectors; commitments, flat constructor packing, field limits, dynamic keeper ABI and log recovery passed.`);
