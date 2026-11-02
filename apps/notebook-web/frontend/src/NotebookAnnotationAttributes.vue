<script setup lang="ts">
import type { AnnotationClass } from './image-annotations'
import { annotationNumber } from './image-annotations'
import { documentJSON, parseDocumentJSON } from './document-json'
const props = defineProps<{ definitions: AnnotationClass[]; assigned: string[]; attributes: Record<string, Record<string, unknown>> }>()
const emit = defineEmits<{ assign: [id: string, checked: boolean]; attribute: [classId: string, id: string, value: unknown]; invalid: [key: string, invalid: boolean] }>()
function edit(classId: string, id: string, type: string, event: Event) {
  const input = event.target as HTMLInputElement; let value: unknown = type === 'boolean' ? input.checked : input.value
  if (type === 'number') try { value = parseDocumentJSON(input.value); if (!annotationNumber(value)) throw new Error() } catch { emit('invalid', classId + ':' + id, true); return }
  emit('invalid', classId + ':' + id, false); emit('attribute', classId, id, value)
}
</script>
<template>
  <div v-for="c in definitions" :key="c.id" class="annotation-region-class">
    <label><input type="checkbox" :aria-label="'Assign ' + c.title" :checked="assigned.includes(c.id)" @change="emit('assign', c.id, ($event.target as HTMLInputElement).checked)">{{ c.title }}</label>
    <template v-if="assigned.includes(c.id)"><label v-for="a in c.attributes" :key="a.id">{{ a.title }}
      <input v-if="a.type === 'boolean'" type="checkbox" :aria-label="a.title" :checked="attributes[c.id]?.[a.id] === true" @change="edit(c.id, a.id, a.type, $event)">
      <select v-else-if="a.type === 'choice'" :aria-label="a.title" :value="attributes[c.id]?.[a.id] ?? ''" @change="edit(c.id, a.id, a.type, $event)"><option value="" disabled>Choose…</option><option v-for="option in a.options" :key="option" :value="option">{{ option }}</option></select>
      <input v-else :aria-label="a.title" :value="a.type === 'number' && attributes[c.id]?.[a.id] !== undefined ? documentJSON(attributes[c.id]![a.id]) : attributes[c.id]?.[a.id] ?? ''" @input="edit(c.id, a.id, a.type, $event)">
    </label></template>
  </div>
</template>
