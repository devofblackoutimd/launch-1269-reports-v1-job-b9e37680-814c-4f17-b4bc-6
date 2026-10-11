import {encodeCall,word,decodeWords} from './eth.mjs';
export function bytesCall(signature,stream,hex) {
  if(!/^0x(?:[0-9a-fA-F]{2})*$/.test(hex)) throw Error('Expected hex bytes');
  const length=(hex.length-2)/2;
  return encodeCall(signature).slice(0,10)+word(stream)+word(64)+word(length)+hex.slice(2).padEnd(Math.ceil(length/32)*64,'0');
}
export function storedAnswer(log) {
  if(log.removed) return null;
  const words=decodeWords(log.data); const offset=Number(words[1]);
  if(offset!==64) throw Error('Invalid AnswerStored ABI');
  const length=Number(words[2]);
  if(length!==288&&length!==608) throw Error('Unexpected oracle answer length');
  const answer='0x'+log.data.slice(2+offset*2+64,2+offset*2+64+length*2);
  if(answer.length!==2+length*2) throw Error('Truncated oracle answer');
  return {stream:Number(BigInt(log.topics[1])),id:log.topics[2],answer};
}
