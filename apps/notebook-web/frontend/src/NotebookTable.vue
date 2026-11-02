<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { compareValues, download, tableCSV, tableMarkdown, type TableSnapshot } from './rich'

const props = defineProps<{ table: TableSnapshot; caption?: string; selectedId?: string }>()
const emit = defineEmits<{ select: [id: string] }>()
const query = ref('')
const column = ref<number | null>(null)
const ascending = ref(true)
const page = ref(0)
const selected = ref('')
watch(() => props.selectedId, value => { if (value !== undefined) selected.value = value }, { immediate: true })
function choose(id: string) { selected.value = id; emit('select', id) }
const copyStatus = ref('')
const pageSize = 100
const rows = computed(() => {
  const q = query.value.toLocaleLowerCase()
  const filtered = props.table.rows.filter(row => !q || row.values.some(value => value.text.toLocaleLowerCase().includes(q)))
  if (column.value === null) return filtered
  const index = column.value
  return filtered.map((row, index) => ({ row, index })).sort((a, b) => {
    const order = compareValues(a.row.values[index]!, b.row.values[index]!)
    return (ascending.value ? order : -order) || a.index - b.index
  }).map(value => value.row)
})
const pages = computed(() => Math.max(1, Math.ceil(rows.value.length / pageSize)))
const visible = computed(() => rows.value.slice(page.value * pageSize, (page.value + 1) * pageSize))
watch([query, column, ascending], () => { page.value = 0; copyStatus.value = '' })
watch(() => props.table, () => { selected.value = ''; page.value = Math.min(page.value, pages.value - 1) })
function sort(index: number) { if (column.value === index) ascending.value = !ascending.value; else { column.value = index; ascending.value = true } }
function save(markdown: boolean) {
  download(new Blob([markdown ? tableMarkdown(props.table, rows.value) : tableCSV(props.table, rows.value)], { type: markdown ? 'text/markdown;charset=utf-8' : 'text/csv;charset=utf-8' }), markdown ? 'table.md' : 'table.csv')
}
async function copyRow() {
  const row = rows.value.find(row => row.id === selected.value)
  if (!row) return
  try { await navigator.clipboard.writeText(row.values.map(value => value.text).join('\t')); copyStatus.value = 'Row copied' }
  catch { copyStatus.value = 'Clipboard unavailable. Use a table download.' }
}
</script>

<template>
  <section class="rich-table" aria-label="Table result" data-testid="rich-table">
    <h3 v-if="caption" class="figure-caption">{{ caption }}</h3>
    <div class="table-actions">
      <input v-model="query" type="search" aria-label="Filter rows" placeholder="Filter rows…">
      <details class="result-menu"><summary aria-label="Table actions">Actions</summary><div>
        <button @click="save(false)">Save CSV…</button><button @click="save(true)">Save Markdown…</button>
        <button :disabled="!selected" @click="copyRow">Copy selected row</button>
        <button :disabled="column === null" @click="column = null">Reset sorting</button>
      </div></details>
    </div>
    <div class="table-scroll" tabindex="0" aria-label="Scrollable table">
      <table>
        <thead><tr><th v-for="(item, index) in table.columns" :key="item.id" :aria-sort="column === index ? ascending ? 'ascending' : 'descending' : 'none'">
          <button class="plain" :aria-label="`Sort by ${item.title}`" @click="sort(index)"><span>{{ item.title }}<span v-if="column === index"> {{ ascending ? '↑' : '↓' }}</span></span><small>{{ item.type }}</small></button>
        </th></tr></thead>
        <tbody><tr v-for="row in visible" :key="row.id" :class="{ 'table-row-selected': selected === row.id }" tabindex="0" :aria-selected="selected === row.id" @click="choose(row.id)" @keydown.enter.prevent="choose(row.id)" @keydown.space.prevent="choose(row.id)">
          <td v-for="(value, index) in row.values" :key="index" :title="value.text">{{ value.text }}</td>
        </tr><tr v-if="!rows.length"><td :colspan="table.columns.length" class="table-empty">{{ query ? 'No matching rows' : 'This table is empty' }}</td></tr></tbody>
      </table>
    </div>
    <div class="figure-footer"><span>{{ rows.length }} shown · {{ table.total_rows }} rows</span><span v-if="table.truncated">Snapshot limited · downloads contain retained rows</span>
      <span v-if="pages > 1" class="table-pagination"><button aria-label="Previous rows" :disabled="page === 0" @click="page--">‹</button><span>{{ page + 1 }} / {{ pages }}</span><button aria-label="Next rows" :disabled="page + 1 >= pages" @click="page++">›</button></span>
      <span v-if="copyStatus" role="status">{{ copyStatus }}</span>
    </div>
  </section>
</template>
