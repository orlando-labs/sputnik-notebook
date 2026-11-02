import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
const root = await mkdtemp(path.join(tmpdir(), 'sputnik-web-audio-'))
try {
  const code = ts.transpileModule(await readFile(new URL('../frontend/src/audio.ts', import.meta.url), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText
  await writeFile(path.join(root, 'audio.mjs'), code)
  const { pcm, wavBytes, wavPCM, streamPCM, audioBytes, audioPeaks, controlActions, decodedPCM } = await import('file://' + path.join(root, 'audio.mjs'))
  const bytes = Uint8Array.from([0,128,255,127,0,0,0,64]), value = pcm(bytes, 's16le', 24000, 2), wav = wavBytes(value)
  assert.equal(value.frames, 2); assert.equal(wav.length, 52); assert.equal(Buffer.from(wav).subarray(0,4).toString(), 'RIFF')
  assert.deepEqual(wavPCM(wav), value); assert.deepEqual(audioPeaks(value), new Float32Array([1, .5])); assert.deepEqual(audioBytes(Buffer.from(wav).toString('base64')), wav)
  const float = new Uint8Array(8), view = new DataView(float.buffer); view.setFloat32(0, -.25, true); view.setFloat32(4, 2, true)
  assert.deepEqual(audioPeaks(pcm(float, 'f32le', 8000, 1)), new Float32Array([.25,1])); assert.equal(wavPCM(wavBytes(pcm(float, 'f32le', 8000, 1))).format, 'f32le')
  const stream = { id:'stream', caption:'PCM', kind:'stream', format:'s16le', data:Buffer.from(bytes).toString('base64'), rate:24000, channels:2, token:'18446744073709551615', revision:'9223372036854775807', frames:'2', finished:false, position:0, volume:.5, waveform:true, loop:false, autoplay:false }
  assert.equal(streamPCM(stream).frames, 2); assert.throws(() => streamPCM({ ...stream, frames:'3' }), /Incomplete/); assert.throws(() => streamPCM({ ...stream, token:'18446744073709551616' }), /identity/); assert.throws(() => streamPCM({ ...stream, rate:1 }), /PCM/)
  assert.throws(() => audioBytes('A===')); assert.throws(() => audioBytes('https://secret')); assert.throws(() => audioBytes('AA A')); assert.throws(() => pcm(new Uint8Array(3), 's16le',24000,1)); assert.throws(() => pcm(bytes, 's24le',24000,1)); assert.throws(() => pcm(bytes, 's16le',24000,3)); assert.throws(() => pcm(new Uint8Array(16*1024*1024+2),'s16le',8000,1))
  view.setFloat32(0, NaN, true); assert.throws(() => pcm(float,'f32le',8000,1), /finite/)
  const broken = wav.slice(); new DataView(broken.buffer).setUint32(4, 1000,true); assert.throws(() => wavPCM(broken), /Incomplete/); assert.equal(wavPCM(Uint8Array.from([1,2,3])),null)
  const state = {}, control = { cell:'1', channel:'tone', playback_revision:'9223372036854775807', seek_revision:'9223372036854775806', volume_revision:'9223372036854775808', playback:2, position:.2, volume:.3 }
  assert.deepEqual(controlActions([control],state).map(item => item.kind),['seek','playback','volume']); assert.deepEqual(controlActions([control],state),[]); assert.deepEqual(controlActions([{...control,volume_revision:'18446744073709551616'}],state),[])
  assert.equal(decodedPCM({ length:2, numberOfChannels:1, sampleRate:48000, getChannelData:()=>new Float32Array([.5, -.5]) }).frames,2)
  assert.throws(() => decodedPCM({ length:10000000, numberOfChannels:2 }), /limit/)
  console.log('PASS PCM/WAV byte identity, finite samples, peaks, uint64 stream/control ordering, replay, malformed input and decode/export bounds')
} finally { await rm(root,{ recursive:true,force:true }) }
