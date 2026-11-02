<script setup lang="ts">
import type { ServiceHistory } from './board-execution'
defineProps<{ value: ServiceHistory | null; error: string }>()
defineEmits<{ close: []; older: [cursor: string]; newest: [] }>()
</script>
<template>
  <section class="invocation-result" aria-label="Service history" data-testid="service-history">
    <header><h3>Service history<span v-if="value"> · {{ value.service.component_id }} · {{ value.service.history_count }} stored</span></h3><button @click="$emit('close')">Close history</button></header>
    <p v-if="error" role="alert" class="parameter-error">{{ error }}</p><p v-else-if="!value" role="status">Loading service history…</p>
    <template v-else><p v-if="!value.history.length" class="source-note">No retained runs in this page.</p><ol class="service-history-list"><li v-for="entry in value.history" :key="entry.id"><p class="source-note">#{{ entry.id }} · {{ entry.ok ? 'Success' : 'Error' }} · {{ new Date(entry.started * 1000).toLocaleString() }} · {{ entry.duration.toFixed(3) }} s</p><pre :class="{ 'parameter-error': !entry.ok }">{{ entry.value ?? entry.error ?? '' }}</pre><p v-if="entry.truncated" class="source-note">History preview truncated at 4096 characters.</p></li></ol><div class="board-inspector-actions"><button @click="$emit('newest')">Latest history</button><button :disabled="!value.before" @click="$emit('older', value.before!)">Older history</button></div></template>
  </section>
</template>
