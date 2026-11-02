// Runs only in the Web Audio rendering thread. Captured PCM never reaches an
// output channel; the connected silent output keeps the graph processing.
class NotebookRecorder extends AudioWorkletProcessor {
  constructor() {
    super(); this.frames = 0; this.channels = 0; this.count = 0; this.done = false; this.peak = 0; this.sum = 0
    this.port.onmessage = event => { if (event.data === 'stop') this.finish() }
  }
  flush() {
    if (!this.count) return
    const data = this.buffer.slice(0, this.count * this.channels)
    this.port.postMessage({ kind: 'pcm', channels: this.channels, frames: this.count, data, peak: this.peak, rms: Math.sqrt(this.sum / data.length) }, [data.buffer])
    this.count = 0; this.peak = 0; this.sum = 0
  }
  finish(error = '') { if (this.done) return; this.flush(); this.done = true; this.port.postMessage({ kind: 'done', error }) }
  process(inputs) {
    if (this.done) return false
    const input = inputs[0]
    if (!input?.length || !input[0]?.length) return true
    if (input.length > 2 || this.channels && this.channels !== input.length) { this.finish('Microphone channel layout changed.'); return false }
    if (!this.channels) { this.channels = input.length; this.buffer = new Float32Array(4096 * this.channels) }
    // 30 seconds and less than 16 MiB decoded float PCM, matching Core input.
    const limit = Math.min(Math.floor(sampleRate * 30), Math.floor((16 * 1024 * 1024 - 64) / (4 * this.channels)))
    for (let i = 0; i < input[0].length && this.frames < limit; i++) {
      for (let c = 0; c < this.channels; c++) {
        const value = input[c][i]
        if (!Number.isFinite(value)) { this.finish('Microphone returned invalid PCM samples.'); return false }
        this.buffer[this.count * this.channels + c] = value; this.peak = Math.max(this.peak, Math.abs(value)); this.sum += value * value
      }
      this.count++; this.frames++
      if (this.count === 4096) this.flush()
    }
    if (this.frames >= limit) { this.finish(); return false }
    return true
  }
}
registerProcessor('sputnik-notebook-recorder', NotebookRecorder)
