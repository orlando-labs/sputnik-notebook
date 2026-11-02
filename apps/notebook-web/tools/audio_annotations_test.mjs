import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import path from 'node:path'
import {webcrypto} from 'node:crypto'
globalThis.crypto ||= webcrypto
const root=await mkdtemp(path.join(tmpdir(),'sputnik-audio-labels-'))
try {
 for(const name of ['audio-annotations','audio-analysis','plasma','image-annotations','document-json']){
  const src=await readFile(new URL(`../frontend/src/${name}.ts`,import.meta.url),'utf8')
  await writeFile(path.join(root,name+'.mjs'),ts.transpileModule(src,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText.replace(/from '(\.\/[^']+)'/g,"from '$1.mjs'"))
 }
 const {spectrum,analyzeAudio}=await import('file://'+path.join(root,'audio-analysis.mjs'))
 const {audioAnnotationError,drawnSegment,audioSettingsError}=await import('file://'+path.join(root,'audio-annotations.mjs'))
 const {parseDocumentJSON}=await import('file://'+path.join(root,'document-json.mjs'))
 const {plasma}=await import('file://'+path.join(root,'plasma.mjs'))
 const tone=Float32Array.from({length:8000},(_,i)=>Math.sin(2*Math.PI*1000*i/8000))
 for(const size of [256,512,1024,2048,4096]){
  const db=spectrum([tone],4000,0,size),peak=[...db].indexOf(Math.max(...db));assert.equal(peak,size/8);assert.ok(Math.abs(db[peak])<.001)
  const half=spectrum([Float32Array.from(tone,x=>x*.5)],4000,0,size);assert.ok(Math.abs(half[peak]+6.0206)<.001)
  const dc=spectrum([new Float32Array(8000).fill(1)],4000,0,size);assert.ok(Math.abs(dc[0])<.001)
  const ny=spectrum([Float32Array.from({length:8000},(_,i)=>i%2?-1:1)],4000,0,size);assert.ok(Math.abs(ny[size/2])<.001)
 }
 assert.equal(plasma.length,768);assert.deepEqual([...plasma.slice(0,3)],[13,8,135]);assert.deepEqual([...plasma.slice(-3)],[240,249,33])
 const request={samples:[tone],rate:8000,channel:0,viewport:{start:0,end:8000,low:0,high:4000},fft:1024,range:90,spectral:true,columns:5000}
 const result=analyzeAudio(request);assert.equal(result.columns,1400);assert.equal(result.rows,512);assert.equal(result.rgba.length,1400*512*4)
 const impulse=new Float32Array(1000);impulse[123]=1;impulse[124]=-1
 const peaks=analyzeAudio({...request,samples:[impulse],viewport:{start:0,end:1000,low:0,high:4000},columns:10,spectral:false}).waveform;assert.equal(Math.max(...peaks),1);assert.equal(Math.min(...peaks),-1)
 const silent=analyzeAudio({...request,samples:[tone,Float32Array.from(tone,x=>-x)],channel:-1,columns:2});assert.ok([...silent.waveform].every(x=>x===0))
 assert.throws(()=>analyzeAudio({...request,viewport:{...request.viewport,end:9000}}));assert.throws(()=>analyzeAudio({...request,fft:128}));assert.throws(()=>analyzeAudio({...request,channel:1}));assert.throws(()=>analyzeAudio({...request,columns:Infinity}))
 const component={id:'labels',kind:'audio_annotator',title:'Labels',audio_transcript_required:true,audio_segment_transcript_required:true}
 const segment=drawnSegment({frame:4000,hz:2000},{frame:1,hz:300},8000,8000,true)
 assert.deepEqual({...segment,id:''},{id:'',title:'',start_frame:1,end_frame:4000,low_hz:300,high_hz:2000,classes:[],attributes:{},transcript:''})
 assert.equal(drawnSegment({frame:1,hz:100},{frame:1.1,hz:200},8000,8000,false),null)
 const value={version:1,asset:'a'.repeat(64),source:'input',channel:'clip',cell:0,sample_rate:8000,channels:1,frames:8000,transcript:'Track',classes:[{id:'speech',title:'Speech',attributes:[{id:'n',title:'N',type:'number',options:[]}]}],segments:[{...segment,transcript:'Phrase',classes:['speech'],attributes:{speech:{n:parseDocumentJSON('9223372036854775807')}}}]}
 assert.equal(audioAnnotationError(value,component),'');assert.ok(audioAnnotationError({...value,transcript:' '},component));assert.ok(audioAnnotationError(value,{...component,audio_transcript_allowed:false}));assert.ok(audioAnnotationError({...value,segments:[{...value.segments[0],transcript:''}]},component))
 for(const edit of [{start_frame:.5},{end_frame:8001},{low_hz:4001},{high_hz:Infinity},{classes:['unknown']},{attributes:{speech:{n:Infinity}}}])assert.ok(audioAnnotationError({...value,segments:[{...value.segments[0],...edit}]},component))
 assert.ok(audioSettingsError({...component,audio_source:'cell'}));assert.ok(audioSettingsError({...component,audio_transcript_allowed:false}));assert.equal(audioSettingsError({...component,audio_source:'cell',cell:'1'}),'')
 console.log('PASS FFT 256–4096 tone/DC/Nyquist and -6 dBFS normalization; plasma LUT; bounded STFT and peak waveform; stereo mix; reverse frame/Hz selection; transcript/schema/Int64/geometry limits')
}finally{await rm(root,{recursive:true,force:true})}
