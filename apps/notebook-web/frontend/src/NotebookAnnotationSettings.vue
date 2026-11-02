<script setup lang="ts">
import { computed } from 'vue'
import { documentJSON, parseDocumentJSON } from './document-json'
import type { CellComponent } from './inputs'
import { annotationClassesError, type AnnotationClass } from './image-annotations'
const props=defineProps<{component:CellComponent}>()
const classes=computed(()=> (props.component.annotation_classes ?? ((props.component.kind==='audio_annotator'?props.component.audio_annotations:props.component.annotations) as {classes?:AnnotationClass[]})?.classes ?? []) as AnnotationClass[])
function edit(){return props.component.annotation_classes ||= parseDocumentJSON(documentJSON(classes.value))}
function attribute(index:number){(edit() as AnnotationClass[])[index]!.attributes.push({id:crypto.randomUUID(),title:'Attribute',type:'text',options:[]})}
function add(){(edit() as AnnotationClass[]).push({id:crypto.randomUUID(),title:'Class',attributes:[]})}
</script>
<template>
  <details class="annotation-settings"><summary>Classes &amp; attributes</summary>
    <p class="source-note">Definitions are saved in the notebook designer. Runtime regions can only use these classes.</p>
    <div v-for="(item,index) in classes" :key="item.id" class="annotation-class-setting"><label>Class title<input :value="item.title" :aria-label="`Class ${index+1} title`" maxlength="128" @input="(edit() as AnnotationClass[])[index]!.title=($event.target as HTMLInputElement).value"></label><button type="button" @click="(edit() as AnnotationClass[]).splice(index,1)">Remove class</button>
      <div v-for="(attribute,at) in item.attributes" :key="attribute.id" class="annotation-attribute-setting"><label>Attribute title<input :value="attribute.title" :aria-label="`Class ${index+1} attribute ${at+1} title`" maxlength="128" @input="(edit() as AnnotationClass[])[index]!.attributes[at]!.title=($event.target as HTMLInputElement).value"></label><label>Type<select :value="attribute.type" :aria-label="`Class ${index+1} attribute ${at+1} type`" @change="(edit() as AnnotationClass[])[index]!.attributes[at]!.type=($event.target as HTMLSelectElement).value as typeof attribute.type; (edit() as AnnotationClass[])[index]!.attributes[at]!.options=($event.target as HTMLSelectElement).value==='choice'?['Option']:[]"><option value="text">Text</option><option value="number">Number</option><option value="boolean">Boolean</option><option value="choice">Choice</option></select></label><label v-if="attribute.type==='choice'">Choices (one per line)<textarea :value="attribute.options.join('\n')" :aria-label="`Class ${index+1} attribute ${at+1} choices`" @input="(edit() as AnnotationClass[])[index]!.attributes[at]!.options=($event.target as HTMLTextAreaElement).value.split('\n')" /></label><button type="button" @click="(edit() as AnnotationClass[])[index]!.attributes.splice(at,1)">Remove attribute</button></div>
      <button type="button" :disabled="item.attributes.length>=16" @click="attribute(index)">Add attribute</button>
    </div><button type="button" :disabled="classes.length>=32" @click="add">Add class</button><p v-if="annotationClassesError(classes)" class="source-error">{{ annotationClassesError(classes) }}</p>
  </details>
</template>
