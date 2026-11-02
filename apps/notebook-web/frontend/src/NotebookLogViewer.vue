<script setup lang="ts">
import { computed, ref } from 'vue'
import type { CellPresentation } from './execution'
import { logEntries } from './runtime-observation'
import { download } from './rich'
const props = defineProps<{ presentation: CellPresentation }>()
const query = ref(''), stream = ref('all'), notice = ref('')
const matches = (text: string) => !query.value || text.toLocaleLowerCase().includes(query.value.toLocaleLowerCase())
const entries = computed(() => logEntries(props.presentation.output).filter(entry => (stream.value === 'all' || entry.stream === stream.value) && matches(entry.text)))
const diagnostic = computed(() => props.presentation.error && matches(props.presentation.error) ? props.presentation.error : '')
const exported = computed(() => entries.value.map(entry => `[${entry.stream}] ${entry.text}`).join('') + (diagnostic.value ? '\n[diagnostic] ' + diagnostic.value : ''))
async function copy() { try { await navigator.clipboard.writeText(exported.value); notice.value = 'Filtered output copied' } catch { notice.value = 'Clipboard unavailable. Use Save output.' } }
function save() { download(new Blob([exported.value], { type: 'text/plain;charset=utf-8' }), 'output.log') }
</script>
<template>
  <div class="log-viewer">
    <div class="observation-controls"><label>Find in output<input v-model="query" type="search" maxlength="256" aria-label="Find in output"></label><label>Stream<select v-model="stream" aria-label="Log stream"><option value="all">All</option><option value="stdout">stdout</option><option value="stderr">stderr</option><option value="truncation">Omitted output</option></select></label></div>
    <div class="observation-controls"><button @click="copy">Copy filtered output</button><button @click="save">Save output…</button><span role="status">{{ notice }}</span></div>
    <div class="observation-output" aria-label="Cell output"><article v-for="entry in entries.slice(0,4096)" :key="entry.id"><small>{{ entry.id + 1 }} · {{ entry.stream }}</small><pre :class="{ 'stderr-output': entry.stream === 'stderr' }">{{ entry.text }}</pre></article><pre v-if="diagnostic" class="cell-output-error">{{ diagnostic }}</pre><p v-if="!entries.length && !diagnostic" class="rich-unavailable">No matching output</p></div>
    <p class="source-note">{{ presentation.active ? 'Live output' : presentation.stale ? 'Previous output · stale' : 'Committed output' }} · {{ entries.length }} events<span v-if="entries.length > 4096"> · display limited to 4,096; export includes all captured matches</span></p>
  </div>
</template>
