import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import vm from 'node:vm'
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import path from 'node:path'
import {webcrypto} from 'node:crypto'
const root=await mkdtemp(path.join(tmpdir(),'sputnik-capture-'))
try {
 for(const name of ['audio','audio-recording','image-annotations','document-json']){
  const src=await readFile(new URL(`../frontend/src/${name}.ts`,import.meta.url),'utf8')
  const code=ts.transpileModule(src,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText.replace(/from '(\.\/[^']+)'/g,"from '$1.mjs'")
  await writeFile(path.join(root,name+'.mjs'),code)
 }
 const {RecordingPCM}=await import('file://'+path.join(root,'audio-recording.mjs'))
 const {wavPCM}=await import('file://'+path.join(root,'audio.mjs'))
 const {parseDocumentJSON}=await import('file://'+path.join(root,'document-json.mjs'))
 const {drawnShape,annotationError,annotationClassesError}=await import('file://'+path.join(root,'image-annotations.mjs'))
 globalThis.crypto ||= webcrypto
 const recorder=new RecordingPCM(48000);recorder.append(new Float32Array([-2,-.5,0,.5,2,0]),2,3)
 const wav=wavPCM(recorder.wav());assert.equal(wav.frames,3);assert.equal(wav.channels,2);assert.equal(wav.rate,48000);assert.equal(new DataView(wav.bytes.buffer,wav.bytes.byteOffset).getInt16(0,true),-32768);assert.equal(recorder.clipped,true)
 assert.throws(()=>recorder.append(new Float32Array([NaN,0]),2,1),/invalid samples/);assert.throws(()=>recorder.append(new Float32Array(3),2,2),/Invalid/);assert.throws(()=>recorder.append(new Float32Array(1),1,1),/Invalid/);assert.throws(()=>new RecordingPCM(1));assert.throws(()=>new RecordingPCM(48000).wav(),/No microphone/)
 let Processor;const messages=[]
 class Base{constructor(){this.port={postMessage:m=>messages.push(m),onmessage:null}}}
 vm.runInNewContext(await readFile(new URL('../frontend/src/audio-recorder-worklet.js',import.meta.url),'utf8'),{AudioWorkletProcessor:Base,sampleRate:48000,registerProcessor:(_name,c)=>Processor=c,Float32Array,Math,Number})
 const worklet=new Processor(), input=new Float32Array(128).fill(.25)
 for(let i=0;i<12000&&!worklet.done;i++)worklet.process([[input]])
 assert.equal(worklet.frames,1440000);assert.equal(messages.at(-1).kind,'done');assert.equal(messages.filter(m=>m.kind==='pcm').reduce((n,m)=>n+m.frames,0),1440000)
 const recorded=new RecordingPCM(48000);for(const m of messages.filter(m=>m.kind==='pcm'))recorded.append(m.data,m.channels,m.frames);assert.equal(wavPCM(recorded.wav()).frames,1440000);assert.throws(()=>recorded.append(new Float32Array(1),1,1),/exceeds/)
 messages.length=0;const short=new Processor();short.process([[input,input]]);short.port.onmessage({data:'stop'});assert.equal(messages[0].frames,128);assert.equal(messages[0].channels,2);assert.equal(messages.at(-1).kind,'done')
 assert.deepEqual({...drawnShape('rect',{x:8.2,y:9.4},{x:2.2,y:1.2},10,10),id:''},{id:'',kind:'rect',label:'',x:2,y:1,width:6,height:8,classes:[],attributes:{}})
 assert.equal(drawnShape('rect',{x:1,y:1},{x:1.1,y:1.1},10,10),null)
 const defs=[{id:'object',title:'Object',attributes:[{id:'count',title:'Count',type:'number',options:[]}]}]
 assert.equal(annotationClassesError(defs),'');assert.ok(annotationClassesError([...defs,...defs]));assert.ok(annotationClassesError([{id:'x',title:'X',attributes:[{id:'c',title:'C',type:'choice',options:[]}]}]))
 const annotations={version:1,asset:'a'.repeat(64),channel:'image',width:10,height:20,classes:defs,shapes:[{id:'region',kind:'rect',label:'',x:1,y:2,width:3,height:4,classes:['object'],attributes:{object:{count:parseDocumentJSON('9223372036854775807')}}}]}
 assert.equal(annotationError(annotations),'');assert.ok(annotationError({...annotations,shapes:[{...annotations.shapes[0],x:.5}]}));assert.ok(annotationError({...annotations,shapes:[{...annotations.shapes[0],width:11}]}));assert.ok(annotationError({...annotations,shapes:[{...annotations.shapes[0],classes:['unknown']}]}));assert.ok(annotationError({...annotations,shapes:[{...annotations.shapes[0],attributes:{object:{count:Infinity}}}]}))
 console.log('PASS bounded PCM16/WAV, clipping, invalid samples, worklet stop/30-second cap, exact source-pixel geometry, schema/attributes/Int64 and annotation bounds')
}finally{await rm(root,{recursive:true,force:true})}
