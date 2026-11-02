<script setup lang="ts">
import { computed } from 'vue'
import NotebookPlot from './NotebookPlot.vue'
import { download, type RichCell, type LiveChart } from './rich'
import { chartCSV, chartFigure, duration, progressNumber } from './telemetry'
const props = defineProps<{ rich: RichCell; active: boolean; identity: string }>()
const current = computed(() => props.active && !props.rich.telemetry_stale)
const charts = computed(() => props.rich.charts.map(chart => ({ chart, figure: chartFigure(chart) })))
const complete = (item: RichCell['progress'][number]) => item.done && (item.total === 0 || item.current >= item.total)
const saveChart = (chart: LiveChart) => download(new Blob([chartCSV(chart)], { type: 'text/csv;charset=utf-8' }), 'chart.csv')
</script>
<template>
  <div v-if="rich.progress.length || rich.stopwatches.length || rich.charts.length || rich.elapsed_ms !== null" class="runtime-telemetry" :class="{ 'telemetry-stale': rich.telemetry_stale }" data-testid="runtime-telemetry">
    <p v-if="rich.telemetry_stale" class="rich-stale-note">Previous measurements · stale</p>
    <p v-if="rich.elapsed_ms !== null" class="cell-duration"><span>Cell execution time</span><output aria-label="Cell execution time">{{ duration(rich.elapsed_ms) }}</output><span v-if="current && rich.timing_running">Running</span></p>
    <section v-for="item in rich.progress" :key="item.id" class="runtime-progress" :class="{ complete: complete(item) }" :aria-label="item.description || item.id" data-testid="runtime-progress" :data-channel="item.id">
      <div class="runtime-heading"><h3>{{ item.description || 'Progress' }}</h3><span>{{ complete(item) ? 'Finished' : item.done || !current ? 'Stopped' : 'Running' }}</span></div>
      <progress v-if="item.total > 0" :value="Math.min(item.current, item.total)" :max="item.total" :aria-label="item.description || item.id" />
      <progress v-else-if="current && !item.done" :aria-label="item.description || item.id" />
      <div class="runtime-counts"><span>{{ progressNumber(item.current) }}<template v-if="item.total > 0"> / {{ progressNumber(item.total) }} · {{ progressNumber(Math.min(item.current, item.total) / item.total * 100) }}%</template></span><span v-if="item.elapsed_ms !== '0'">{{ duration(item.elapsed_ms) }}</span></div>
    </section>
    <section v-for="timer in rich.stopwatches" :key="timer.id" class="runtime-stopwatch" :aria-label="timer.id" data-testid="runtime-stopwatch" :data-channel="timer.id">
      <div class="runtime-heading"><h3>{{ timer.id }}</h3><span>{{ timer.done ? 'Finished' : current ? 'Running' : 'Stopped' }}</span></div><output :aria-label="`Stopwatch ${timer.id}`">{{ duration(timer.elapsed_ms) }}</output>
    </section>
    <section v-for="{ chart, figure } in charts" :key="`${identity}:${chart.id}`" class="runtime-chart" :aria-label="`Live chart ${chart.id}`" data-testid="runtime-chart" :data-channel="chart.id">
      <NotebookPlot v-if="figure" :figure="figure" live />
      <p v-else class="rich-unavailable">{{ chart.id }} · Waiting for samples</p>
      <div class="figure-footer"><span>{{ chart.points.length }} retained / {{ chart.total_points }} total samples<template v-if="chart.points.length > 2048"> · chart sampled; CSV includes all retained points</template></span><button :disabled="!chart.points.length" @click="saveChart(chart)">Export samples CSV…</button></div>
    </section>
  </div>
</template>
