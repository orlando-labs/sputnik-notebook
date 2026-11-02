<script setup lang="ts">
import { computed } from 'vue'
import type { BoardComponent, BoardContext } from './boards'
import { referenceID } from './boards'
import { terminal, runLabel } from './execution'
const props = defineProps<{ component: BoardComponent; context: BoardContext }>()
const runtime = computed(() => props.context.runtime)
const kind = computed(() => props.component.kind === 'execution_controls' ? props.component.p1?.target_kind || 'sheet' : props.component.kind === 'periodic_work' ? 'service' : 'action')
const target = computed(() => ['action', 'service'].includes(kind.value) ? props.component.kind === 'execution_controls' ? runtime.value?.components.find(item => item.id === props.component.p1?.target_component && item.kind === (kind.value === 'action' ? 'action' : 'periodic_work')) : props.component : undefined)
const service = computed(() => runtime.value?.services.find(item => item.board_id === runtime.value?.boardId && item.component_id === target.value?.id))
const run = computed(() => target.value ? [...(runtime.value?.runs || [])].reverse().find(run => run.board_id === runtime.value?.boardId && run.component_id === target.value?.id) : ['sheet', 'cell'].includes(kind.value) ? runtime.value?.sheetRun : undefined)
const active = computed(() => !!run.value && !terminal(run.value.state))
const available = computed(() => kind.value === 'sheet' ? !!props.context.sheet?.cells.some(cell => cell.kind === 'code') : kind.value === 'cell' ? !!props.context.sheet?.cells.some(cell => cell.kind === 'code' && cell.id === referenceID(props.component.cell)) : !!target.value)
const canStart = computed(() => runtime.value?.canStart && available.value && !active.value && (!['sheet', 'cell'].includes(kind.value) || !runtime.value.sheetNeedsRestart))
function start() { if (!canStart.value || !runtime.value) return; if (kind.value === 'action') runtime.value.invoke(target.value!.id); else if (kind.value === 'service') runtime.value.configure(target.value!.id, 'once'); else if (kind.value === 'cell') props.context.onRun(referenceID(props.component.cell)); else runtime.value.runSheet() }
</script>
<template>
  <div class="board-command" :aria-label="component.title + ' controls'">
    <h3 v-if="component.kind !== 'action'" class="board-card-title">{{ component.title }}</h3>
    <p class="source-note" role="status">{{ !runtime ? 'Preview · runtime controls disabled' : !available ? 'Execution target unavailable' : active ? runLabel(run!.state) : service?.status || (run ? runLabel(run.state) : 'Ready') }}</p>
    <p v-if="kind === 'service' && target" class="source-note">{{ target.module_id }}.{{ target.function }}() · Every {{ target.period_seconds ?? 60 }} s · {{ target.timing === 'fixed_rate' ? 'start to start, skip overlaps' : 'after completion' }}</p>
    <div class="board-inspector-actions">
      <button :class="{ primary: component.kind === 'action' }" :disabled="!canStart" @click="start">{{ component.kind === 'action' ? component.title : kind === 'service' ? 'Run Once' : 'Run' }}</button>
      <template v-if="kind === 'service'"><button :disabled="!runtime?.canStart || !target || active || service?.enabled" @click="runtime?.configure(target!.id, 'start')">Start</button><button :disabled="!runtime?.canControl || !service || !service.enabled" @click="runtime?.configure(target!.id, 'pause')">Pause</button></template>
      <button :disabled="!runtime?.canControl || !active" @click="runtime?.stop(run!)">Stop</button>
      <button :disabled="!runtime?.canControl || !active" @click="runtime?.stop(run!, true)">Force Stop…</button>
      <button :disabled="!runtime?.canControl || active || (kind === 'service' && service?.enabled) || (!['sheet', 'cell'].includes(kind) && !run)" @click="runtime?.restart(['sheet', 'cell'].includes(kind) ? undefined : run)">Restart…</button>
      <button v-if="run && !['sheet', 'cell'].includes(kind)" :disabled="!runtime?.connected" @click="runtime?.inspect(run)">View output</button>
    </div>
    <template v-if="kind === 'service'"><p class="source-note">Server schedule continues when this board or browser is closed.</p><p v-if="service" class="service-counters">{{ service.runs }} runs · {{ service.failures }} errors · {{ service.skipped }} skipped</p><div v-if="service" class="board-inspector-actions"><button :disabled="!runtime?.connected" @click="runtime?.history(target!.id)">History · {{ service.history_count }}</button><button :disabled="!runtime?.canControl || service.history_count === '0'" @click="runtime?.configure(target!.id, 'clear')">Clear history</button></div></template>
  </div>
</template>
