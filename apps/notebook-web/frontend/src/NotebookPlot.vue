<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { dataPoint, drawPlot, parseScene, plotFrame, tick, validViewport, type Point, type Viewport } from './plot'
import { download, type Figure } from './rich'
import NotebookImages from './NotebookImages.vue'

const props = defineProps<{ figure: Figure; live?: boolean }>()
const canvas = ref<HTMLCanvasElement | null>(null)
const container = ref<HTMLElement | null>(null)
const scene = computed(() => parseScene(props.figure.plot_scene || '', props.figure.width, props.figure.height))
const view = ref<Viewport>([0, 0, 1, 1])
const width = ref(640)
const height = ref(420)
const drag = ref<{ start: Point; end: Point; view: Viewport; pan: boolean; pointer: number } | null>(null)
const message = ref('')
let observer: ResizeObserver | undefined
let frame = 0
const changed = computed(() => !!scene.value && view.value.some((value, index) => value !== scene.value!.bounds[index]))
const viewportText = computed(() => `x ${tick(view.value[0], view.value[2] - view.value[0])}…${tick(view.value[2], view.value[2] - view.value[0])} · y ${tick(view.value[1], view.value[3] - view.value[1])}…${tick(view.value[3], view.value[3] - view.value[1])}`)
function reset() { if (scene.value) view.value = [...scene.value.bounds]; message.value = '' }
watch(scene, (value, previous) => {
  if (value && (!props.live || !previous || view.value.every((entry, i) => entry === previous.bounds[i]))) reset()
}, { immediate: true })
function paint() {
  const element = canvas.value, value = scene.value
  if (!element || !value) return
  const scale = Math.min(2, window.devicePixelRatio || 1, 8192 / width.value, 8192 / height.value, Math.sqrt(16_000_000 / (width.value * height.value)))
  element.width = Math.round(width.value * scale); element.height = Math.round(height.value * scale)
  const ctx = element.getContext('2d')
  if (!ctx) return
  ctx.scale(scale, scale)
  drawPlot(ctx, value, view.value, width.value, height.value)
  if (drag.value && !drag.value.pan) {
    const { start, end } = drag.value
    ctx.fillStyle = '#9a5c7030'; ctx.strokeStyle = '#9a5c70'; ctx.lineWidth = 1
    ctx.fillRect(start[0], start[1], end[0] - start[0], end[1] - start[1]); ctx.strokeRect(start[0], start[1], end[0] - start[0], end[1] - start[1])
  }
}
function redraw() { cancelAnimationFrame(frame); frame = requestAnimationFrame(paint) }
watch([scene, view, width, height, drag], redraw, { deep: true })
function zoom(factor: number, anchor?: Point) {
  const value = scene.value
  if (!value) return
  const center = anchor ? dataPoint(anchor, value, view.value, plotFrame(value, view.value, width.value, height.value)) : [(view.value[0] + view.value[2]) / 2, (view.value[1] + view.value[3]) / 2]
  const next = view.value.map((value, index) => center[index % 2]! + (value - center[index % 2]!) * factor)
  if (validViewport(next)) view.value = next
}
function pointer(event: PointerEvent): Point {
  const rect = canvas.value!.getBoundingClientRect()
  return [(event.clientX - rect.left) / rect.width * width.value, (event.clientY - rect.top) / rect.height * height.value]
}
function down(event: PointerEvent) {
  if (!scene.value || event.button !== 0 || drag.value) return
  const p = pointer(event), f = plotFrame(scene.value, view.value, width.value, height.value)
  if (p[0] < f.x || p[0] > f.x + f.width || p[1] < f.y || p[1] > f.y + f.height) return
  canvas.value!.focus(); canvas.value!.setPointerCapture(event.pointerId)
  drag.value = { start: p, end: p, view: [...view.value], pan: event.shiftKey, pointer: event.pointerId }
}
function move(event: PointerEvent) {
  if (!drag.value || drag.value.pointer !== event.pointerId || !scene.value) return
  const current = pointer(event), previous = drag.value
  drag.value = { ...previous, end: current }
  if (previous.pan) {
    const f = plotFrame(scene.value, previous.view, width.value, height.value)
    const a = dataPoint(previous.start, scene.value, previous.view, f), b = dataPoint(current, scene.value, previous.view, f)
    const next = previous.view.map((value, index) => value + a[index % 2]! - b[index % 2]!)
    if (validViewport(next)) view.value = next
  }
}
function up(event: PointerEvent) {
  const current = drag.value, value = scene.value
  if (!current || current.pointer !== event.pointerId || !value) return
  if (!current.pan) {
    const f = plotFrame(value, current.view, width.value, height.value)
    const limit = (p: Point): Point => [Math.max(f.x, Math.min(f.x + f.width, p[0])), Math.max(f.y, Math.min(f.y + f.height, p[1]))]
    const p = limit(current.start), q = limit(pointer(event))
    if (Math.abs(p[0] - q[0]) >= 4 && Math.abs(p[1] - q[1]) >= 4) {
      const a = dataPoint(p, value, current.view, f), b = dataPoint(q, value, current.view, f)
      const next = [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.max(a[0], b[0]), Math.max(a[1], b[1])]
      if (validViewport(next)) view.value = next
    }
  }
  drag.value = null
  if (canvas.value?.hasPointerCapture(event.pointerId)) canvas.value.releasePointerCapture(event.pointerId)
}
function key(event: KeyboardEvent) {
  if (['+', '=', '-', '0', 'Escape'].includes(event.key)) {
    event.preventDefault()
    if (event.key === '0') reset()
    else if (event.key === 'Escape') { if (drag.value?.pan) view.value = drag.value.view; drag.value = null }
    else zoom(event.key === '-' ? 2 : .5)
  }
}
function wheel(event: WheelEvent) {
  if (!event.ctrlKey && !event.metaKey) return
  event.preventDefault()
  const rect = canvas.value!.getBoundingClientRect()
  zoom(event.deltaY > 0 ? 1.15 : 1 / 1.15, [(event.clientX - rect.left) / rect.width * width.value, (event.clientY - rect.top) / rect.height * height.value])
}
function save() {
  const element = canvas.value
  if (!element) return
  paint()
  element.toBlob(blob => { if (blob) download(blob, 'plot.png'); else message.value = 'Plot export unavailable.' }, 'image/png')
}
onMounted(() => {
  observer = new ResizeObserver(entries => {
    const available = entries[0]?.contentRect.width || 640
    const w = Math.min(8192, Math.max(120, Math.floor(available)))
    width.value = w; height.value = Math.max(180, Math.min(520, Math.round(w * props.figure.height / props.figure.width)))
    redraw()
  })
  if (container.value) observer.observe(container.value)
  canvas.value?.addEventListener('wheel', wheel, { passive: false })
  redraw()
})
onUnmounted(() => { observer?.disconnect(); cancelAnimationFrame(frame); canvas.value?.removeEventListener('wheel', wheel) })
</script>

<template>
  <section v-if="scene" class="rich-plot" aria-label="Plot result" data-testid="rich-plot">
    <h3 v-if="figure.caption" class="figure-caption">{{ figure.caption }}</h3>
    <div ref="container" class="plot-container"><canvas ref="canvas" class="plot-canvas" tabindex="0" role="img" :aria-label="scene.title || figure.caption || 'Notebook plot'" :data-viewport="JSON.stringify(view)" @pointerdown="down" @pointermove="move" @pointerup="up" @pointercancel="drag = null" @lostpointercapture="drag = null" @keydown="key">{{ scene.title || figure.caption }}</canvas></div>
    <div class="figure-footer plot-actions"><button aria-label="Zoom in" @click="zoom(.5)">+</button><button aria-label="Zoom out" @click="zoom(2)">−</button><button :disabled="!changed" @click="reset">Reset view</button><button @click="save">Save PNG…</button><output aria-label="Plot viewport">{{ viewportText }}</output></div>
    <p class="plot-hint">Drag to zoom · Shift-drag to pan · Ctrl-scroll to zoom · 0 to reset</p>
    <p v-if="message" role="status" class="rich-unavailable">{{ message }}</p>
  </section>
  <div v-else><p class="rich-unavailable">Interactive plot unavailable{{ figure.data ? ' · showing image' : '' }}</p><NotebookImages v-if="figure.data" :series="{ id: figure.id, caption: figure.caption, images: [figure] }" /></div>
</template>
