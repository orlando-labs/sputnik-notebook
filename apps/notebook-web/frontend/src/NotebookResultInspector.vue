<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import type { CellPresentation } from './execution'
import { literalMatches } from './runtime-observation'
import { download } from './rich'
import NotebookTable from './NotebookTable.vue'
const props = withDefaults(defineProps<{ presentation: CellPresentation; label?: string }>(), { label: 'Captured result' })
const mode = ref('inspect'), wrap = ref(true), finding = ref(false), query = ref(''), matchCase = ref(false), selected = ref(0), notice = ref(''), output = ref<HTMLElement | null>(null), searchInput = ref<HTMLInputElement | null>(null)
const text = computed(() => mode.value === 'pretty' ? props.presentation.result_format?.pretty || props.presentation.result : props.presentation.result)
const limited = computed(() => mode.value === 'pretty' ? props.presentation.result_format?.pretty_truncated : props.presentation.result_format?.truncated)
const matches = computed(() => literalMatches(text.value, finding.value ? query.value : '', matchCase.value))
const segments = computed(() => {
  const result: { text: string; match: number }[] = []; let start = 0
  for (const [index, range] of matches.value.ranges.entries()) { if (range.start > start) result.push({ text: text.value.slice(start, range.start), match: -1 }); result.push({ text: text.value.slice(range.start, range.end), match: index }); start = range.end }
  if (start < text.value.length) result.push({ text: text.value.slice(start), match: -1 })
  return result
})
watch([query, matchCase, text], () => { selected.value = 0; notice.value = '' })
watch(() => props.presentation.identity, () => { query.value = ''; notice.value = '' })
watch([mode, () => props.presentation.result_format, () => props.presentation.rich.table], () => { if (mode.value === 'pretty' && !props.presentation.result_format?.pretty || mode.value === 'table' && !props.presentation.rich.table) mode.value = 'inspect' })
async function step(delta: number) { const count = matches.value.ranges.length; if (!count) return; selected.value = (selected.value + delta + count) % count; await nextTick(); output.value?.querySelector('.selected-match')?.scrollIntoView({ block: 'nearest', inline: 'nearest' }) }
async function toggleFind() { if (mode.value === 'table') mode.value = 'inspect'; finding.value = !finding.value; if (finding.value) { await nextTick(); searchInput.value?.focus() } }
async function copy() { try { await navigator.clipboard.writeText(text.value); notice.value = 'Captured result copied' } catch { notice.value = 'Clipboard unavailable. Use Save result.' } }
function save() { download(new Blob([text.value], { type: 'text/plain;charset=utf-8' }), 'result.txt') }
</script>
<template>
  <div class="result-inspector">
    <div class="observation-controls"><label>Result format<select v-model="mode" aria-label="Result format"><option value="inspect">Inspect</option><option v-if="presentation.result_format?.pretty" value="pretty">Pretty</option><option v-if="presentation.rich.table" value="table">Table</option></select></label><label><input v-model="wrap" type="checkbox">Wrap lines</label><button :aria-expanded="finding" @click="toggleFind">{{ finding ? 'Close result search' : 'Find in result…' }}</button></div>
    <div v-if="finding && mode !== 'table'" class="observation-controls"><label>Find substring in result<input ref="searchInput" v-model="query" type="search" maxlength="256" aria-label="Find substring in result" @keydown.enter.prevent="step(1)"></label><label><input v-model="matchCase" type="checkbox">Match case</label><button :disabled="!matches.ranges.length" aria-label="Previous match" @click="step(-1)">↑</button><button :disabled="!matches.ranges.length" aria-label="Next match" @click="step(1)">↓</button><span role="status">{{ !query ? '' : matches.ranges.length ? `${Math.min(selected + 1,matches.ranges.length)} / ${matches.ranges.length}${matches.limited ? '+' : ''}` : 'No matches' }}</span></div>
    <NotebookTable v-if="mode === 'table' && presentation.rich.table" :table="presentation.rich.table" />
    <pre v-else ref="output" class="captured-result" :class="{ 'wrap-result': wrap }" :aria-label="label"><template v-for="(segment,index) in segments" :key="index"><mark v-if="segment.match >= 0" :class="{ 'selected-match': segment.match === selected }">{{ segment.text }}</mark><template v-else>{{ segment.text }}</template></template><template v-if="!text">Result unavailable</template></pre>
    <p v-if="limited || matches.limited" class="source-note">{{ limited ? 'Result limited · search covers captured text only.' : 'Search limited to the first 4,096 literal matches.' }}</p>
    <div class="observation-controls"><button @click="copy">Copy captured result</button><button @click="save">Save result…</button><span role="status">{{ notice }}</span></div>
  </div>
</template>
