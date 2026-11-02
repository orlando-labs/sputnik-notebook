<script setup lang="ts">
import type { BoardComponent, NotebookBoard } from './boards'
import { referenceID } from './boards'
import type { NotebookDocument } from './notebook'
import { newId } from './notebook'
import { allBoardComponents } from './board-execution'
import type { ActionArgument } from './inputs'
const props = defineProps<{ component: BoardComponent; board: NotebookBoard; document: NotebookDocument }>()
function argumentMode(arg: ActionArgument, value: string) { if (value === 'input') { arg.input = props.document.inputs?.[0]?.id || ''; delete arg.value_json } else { delete arg.input; arg.value_json = '0' } }
function number(key: string, event: Event) { const value = (event.target as HTMLInputElement).value; if (value === '') delete props.component[key]; else props.component[key] = Number(value) }
function moveArg(index: number) { const args = props.component.p1!.arguments!; [args[index - 1], args[index]] = [args[index]!, args[index - 1]!] }
</script>
<template>
  <template v-if="component.kind === 'action' || component.kind === 'periodic_work'">
    <label>Notebook module<select v-model="component.module_id" aria-label="Notebook module"><option value="">Choose module…</option><option v-if="component.module_id && !document.modules?.some(module => module.id === component.module_id)" :value="component.module_id">{{ component.module_id }} · unavailable</option><option v-for="module in document.modules || []" :key="module.id" :value="module.id">{{ module.id }}</option></select></label>
    <label>Exported function<input v-model="component.function" aria-label="Exported function" maxlength="128"></label>
    <template v-if="component.kind === 'action'">
      <p class="source-note">Arguments freeze accepted project parameters and scalar constants when Run is pressed. Positional arguments precede named arguments.</p>
      <article v-for="(arg, index) in component.p1?.arguments || []" :key="arg.id" class="board-panel-settings">
        <label>Argument {{ index + 1 }} name<input v-model="arg.name" :aria-label="`Argument ${index + 1} name`" placeholder="Empty = positional" maxlength="128"></label>
        <label>Value<select :value="arg.input != null ? 'input' : 'constant'" :aria-label="`Argument ${index + 1} source`" @change="argumentMode(arg, ($event.target as HTMLSelectElement).value)"><option value="constant">Scalar JSON</option><option value="input">Project parameter</option></select></label>
        <label v-if="arg.input != null">Parameter<select v-model="arg.input" :aria-label="`Argument ${index + 1} parameter`"><option v-for="input in document.inputs || []" :key="input.id" :value="input.id">{{ input.title }}</option></select></label><label v-else>Scalar JSON<input v-model="arg.value_json" :aria-label="`Argument ${index + 1} JSON`" spellcheck="false"></label>
        <div class="board-inspector-actions"><button type="button" :disabled="index === 0" :aria-label="`Move argument ${index + 1} up`" @click="moveArg(index)">Up</button><button type="button" :aria-label="`Remove argument ${index + 1}`" @click="component.p1!.arguments!.splice(index, 1)">Remove</button></div>
      </article>
      <button type="button" :disabled="(component.p1?.arguments?.length || 0) >= 64" @click="((component.p1 ||= {}).arguments ||= []).push({ id: newId('arg'), value_json: '0' })">Add argument</button>
    </template>
    <template v-else>
      <label>Period (seconds)<input type="number" :value="component.period_seconds ?? 60" aria-label="Service period" min="0.01" max="31536000" step="any" @input="number('period_seconds', $event)"></label>
      <label>Schedule<select :value="component.timing || 'fixed_delay'" aria-label="Service schedule" @change="component.timing = ($event.target as HTMLSelectElement).value"><option value="fixed_delay">After completion</option><option value="fixed_rate">Start to start · skip overlaps</option></select></label>
      <label>History<select :value="component.retention || 'tail'" aria-label="Service retention" @change="component.retention = ($event.target as HTMLSelectElement).value"><option value="none">None</option><option value="tail">Last N runs</option><option value="all">All runs</option></select></label>
      <label v-if="!component.retention || component.retention === 'tail'">N<input type="number" :value="component.tail_limit ?? 100" aria-label="Service tail limit" min="1" max="1000000" step="1" @input="number('tail_limit', $event)"></label>
      <label v-for="setting in [{ key: 'store_values', title: 'Store returned values', fallback: true }, { key: 'store_errors', title: 'Store errors', fallback: true }, { key: 'run_immediately', title: 'First run immediately', fallback: true }, { key: 'stop_on_error', title: 'Stop on error', fallback: false }]" :key="setting.key" class="auto-import-option"><input type="checkbox" :checked="component[setting.key] ?? setting.fallback" :aria-label="setting.title" @change="component[setting.key] = ($event.target as HTMLInputElement).checked">{{ setting.title }}</label>
      <p class="source-note">Start explicitly on the board. The server owns scheduling and continues while this board or browser is closed. Changed service or module settings pause future calls.</p>
    </template>
  </template>
  <template v-else>
    <label>Execution target<select :value="component.p1?.target_kind || (component.kind === 'status' && component.cell != null ? 'cell' : 'sheet')" aria-label="Execution target" @change="(component.p1 ||= {}).target_kind = ($event.target as HTMLSelectElement).value"><option value="sheet">Controller sheet</option><option value="cell">Cell</option><option value="action">Action</option><option value="service">Service</option><option v-if="component.kind === 'status'" value="runtime">Runtime</option></select></label>
    <label v-if="(component.p1?.target_kind || (component.kind === 'status' && component.cell != null ? 'cell' : 'sheet')) === 'cell'">Source cell<select :value="referenceID(component.cell)" aria-label="Execution source cell" @change="component.cell = ($event.target as HTMLSelectElement).value"><option value="">Choose…</option><option v-for="cell in document.sheets.find(sheet => sheet.id === board.sheet)?.cells.filter(cell => cell.kind === 'code') || []" :key="cell.id" :value="cell.id">Cell {{ cell.id }}</option></select></label>
    <label v-if="['action', 'service'].includes(component.p1?.target_kind || '')">Target<select :value="component.p1?.target_component || ''" aria-label="Target component" @change="(component.p1 ||= {}).target_component = ($event.target as HTMLSelectElement).value"><option value="">Choose…</option><option v-for="item in allBoardComponents(board).filter(item => item.kind === (component.p1?.target_kind === 'service' ? 'periodic_work' : 'action'))" :key="item.id" :value="item.id">{{ item.title }}</option></select></label>
  </template>
</template>
