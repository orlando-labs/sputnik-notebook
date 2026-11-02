<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { CellComponent } from './inputs'
import type { RichCell } from './rich'
import { download } from './rich'
import { numberSetting } from './displays'
import { chartsFigure, chartCSV } from './telemetry'
import NotebookPlot from './NotebookPlot.vue'
const props = defineProps<{ component: CellComponent; rich: RichCell }>()
const hidden = ref<string[]>([])
const series = computed(() => (props.component.p1?.series?.length ? props.component.p1.series : [{ id: props.component.chart_id || props.component.id, title: props.component.title, stroke: props.component.stroke || '#86505f' }]).map(settings => ({ ...settings, chart: props.rich.charts.find(chart => chart.id === settings.id) || { id: settings.id, points: [], total_points: '0' } })))
watch(() => series.value.map(item => item.id).join('\0'), () => { hidden.value = hidden.value.filter(id => series.value.some(item => item.id === id)) })
const figure = computed(() => chartsFigure(series.value.filter(item => !hidden.value.includes(item.id)), { title: props.component.title, x_label: props.component.x_label, y_label: props.component.y_label, x_min: numberSetting(props.component.x_min), x_max: numberSetting(props.component.x_max), y_min: numberSetting(props.component.y_min), y_max: numberSetting(props.component.y_max) }))
function toggle(id: string) { hidden.value = hidden.value.includes(id) ? hidden.value.filter(value => value !== id) : [...hidden.value, id] }
function save() {
  const csv = series.value.length === 1 ? chartCSV(series.value[0]!.chart) : 'Series,X,Y\r\n' + series.value.map(item => item.chart.points.map(([x, y]) => `"${item.title.replaceAll('"', '""')}",${x},${y}\r\n`).join('')).join('')
  download(new Blob([csv], { type: 'text/csv;charset=utf-8' }), 'chart.csv')
}
</script>
<template>
  <div class="authored-chart" data-testid="authored-chart">
    <div v-if="series.length > 1" class="chart-series-legend"><button v-for="item in series" :key="item.id" class="plain" :aria-label="`Toggle series ${item.title}`" :aria-pressed="!hidden.includes(item.id)" :style="{ '--series-color': item.stroke }" @click="toggle(item.id)"><span aria-hidden="true">{{ hidden.includes(item.id) ? '○' : '●' }}</span>{{ item.title }}</button></div>
    <NotebookPlot v-if="figure" :figure="figure" live />
    <div v-else class="component-waiting"><h3>{{ component.title }}</h3><p>{{ hidden.length === series.length && hidden.length ? 'All series hidden' : 'Waiting for chart samples' }}</p></div>
    <div class="figure-footer"><span v-for="item in series" :key="item.id">{{ item.title }}: {{ item.chart.points.length }} retained / {{ item.chart.total_points }} total samples</span><button :disabled="!series.some(item => item.chart.points.length)" @click="save">Export samples CSV…</button></div>
    <p v-if="component.caption" class="image-caption">{{ component.caption }}</p>
  </div>
</template>
