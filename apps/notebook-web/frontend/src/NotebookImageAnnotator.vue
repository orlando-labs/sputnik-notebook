<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue'
import type { BoardComponent } from './boards'
import type { MediaRuntime } from './media-inputs'
import { annotationError, annotationNumber, drawnShape, imageIdentity, type AnnotationImage, type AnnotationClass, type ImageAnnotations, type ImageShape } from './image-annotations'
import { documentJSON, parseDocumentJSON } from './document-json'
import { download } from './rich'
const props=defineProps<{component:BoardComponent;boardId:string;runtime:MediaRuntime;image:AnnotationImage|null;disabled:boolean}>()
const emit=defineEmits<{dirty:[value:boolean]}>()
const dialog=ref<HTMLDialogElement>(),draft=ref<ImageAnnotations|null>(null),snapshot=ref<AnnotationImage|null>(null),selected=ref(''),mode=ref<'select'|'point'|'rect'>('rect'),zoom=ref(1),error=ref(''),opening=ref(false),saving=ref(false),open=ref(false)
const clone=<T,>(value:T)=>parseDocumentJSON(documentJSON(value)) as T
const shape=computed(()=>draft.value?.shapes.find(s=>s.id===selected.value)), invalid=computed(()=>draft.value?annotationError(draft.value):'No source image.')
const stale=computed(()=>open.value&&(props.runtime.revision!==frozenRevision || props.runtime.version!==frozenVersion || !props.runtime.readable || props.component.image_id!==frozenChannel || !props.component.image_annotator || props.image?.data!==snapshot.value?.data))
const history=ref<string[]>([]),redo=ref<string[]>([]),attributeErrors=ref<Record<string,string>>({})
let frozenRevision='',frozenVersion='',frozenChannel:unknown,baseline='',generation=0,disposed=false,pointer:{x:number;y:number;id:number}|null=null
const dirty=computed(()=>open.value && !!draft.value && (documentJSON(draft.value)!==baseline || Object.keys(attributeErrors.value).length>0))
watch(dirty,v=>emit('dirty',v),{flush:'sync'})
function checkpoint(){if(!draft.value)return;history.value.push(documentJSON(draft.value));while(history.value.length>30||history.value.reduce((s,t)=>s+t.length*2,0)>8*1024*1024)history.value.shift();redo.value=[]}
function undo(){if(!history.value.length||!draft.value)return;redo.value.push(documentJSON(draft.value));draft.value=parseDocumentJSON(history.value.pop()!) as ImageAnnotations;attributeErrors.value={}}
function redoEdit(){if(!redo.value.length||!draft.value)return;history.value.push(documentJSON(draft.value));draft.value=parseDocumentJSON(redo.value.pop()!) as ImageAnnotations;attributeErrors.value={}}
async function show(){
  if(!props.image||opening.value||props.disabled)return
  const own=++generation, image=clone(props.image),component=clone(props.component)
  frozenRevision=props.runtime.revision;frozenVersion=props.runtime.version;frozenChannel=props.component.image_id
  opening.value=true;error.value=''
  try{
    const identity=await imageIdentity(image)
    if(disposed||own!==generation||frozenRevision!==props.runtime.revision||!props.runtime.readable)return
    const saved=component.annotations as ImageAnnotations|undefined, classes=(component.annotation_classes ?? saved?.classes ?? []) as AnnotationClass[]
    const value:ImageAnnotations={...(saved?.asset===identity.asset?saved:{}),version:1,...identity,channel:component.image_id||component.id,shapes:saved?.asset===identity.asset?clone(saved.shapes):[],classes:clone(classes)}
    // Changed definitions keep source geometry but remove unavailable assignments.
    for(const region of value.shapes){region.classes=(region.classes||[]).filter(id=>classes.some(c=>c.id===id));const attributes:Record<string,Record<string,unknown>>=Object.create(null);for(const id of region.classes){const c=classes.find(c=>c.id===id)!;const values:Record<string,unknown>=Object.create(null);for(const a of c.attributes){const v=region.attributes?.[id]?.[a.id];if(v!==undefined&&(a.type==='text'&&typeof v==='string'||a.type==='number'&&annotationNumber(v)||a.type==='boolean'&&typeof v==='boolean'||a.type==='choice'&&a.options.includes(String(v))))values[a.id]=v}attributes[id]=values}region.attributes=attributes}
    snapshot.value=image;draft.value=value;baseline=documentJSON(value);selected.value=value.shapes[0]?.id||'';history.value=[];redo.value=[];attributeErrors.value={};zoom.value=1;open.value=true
    await nextTick();dialog.value?.showModal()
  }catch(cause){error.value=(cause as Error).message}finally{opening.value=false}
}
function close(){if(saving.value)return;generation++;dialog.value?.close();open.value=false;draft.value=null;snapshot.value=null;history.value=[];redo.value=[];attributeErrors.value={};pointer=null}
function point(event:PointerEvent){const box=(event.currentTarget as SVGElement).getBoundingClientRect();return{x:(event.clientX-box.left)/box.width*draft.value!.width,y:(event.clientY-box.top)/box.height*draft.value!.height}}
function down(event:PointerEvent){if(!draft.value||stale.value||mode.value==='select'||saving.value||event.button!==0)return;event.preventDefault();const value=point(event);pointer={...value,id:event.pointerId};(event.currentTarget as SVGElement).setPointerCapture(event.pointerId)}
function up(event:PointerEvent){if(!pointer||pointer.id!==event.pointerId||!draft.value)return;const value=drawnShape(mode.value==='point'?'point':'rect',pointer,point(event),draft.value.width,draft.value.height);pointer=null;if(value&&draft.value.shapes.length<500){checkpoint();draft.value.shapes.push(value);selected.value=value.id}}
function add(kind:'point'|'rect'){if(!draft.value||draft.value.shapes.length>=500)return;checkpoint();const value:ImageShape={id:crypto.randomUUID(),kind,label:'',x:0,y:0,classes:[],attributes:{},...(kind==='rect'?{width:1,height:1}:{})};draft.value.shapes.push(value);selected.value=value.id}
function remove(){if(!shape.value||!draft.value)return;checkpoint();draft.value.shapes=draft.value.shapes.filter(s=>s.id!==selected.value);selected.value=draft.value.shapes[0]?.id||'';attributeErrors.value={}}
function change(key:string,value:unknown){if(!shape.value)return;checkpoint();shape.value[key]=value}
function assign(id:string,checked:boolean){if(!shape.value)return;checkpoint();shape.value.classes=checked?[...(shape.value.classes||[]),id]:(shape.value.classes||[]).filter(c=>c!==id);if(!checked&&shape.value.attributes)delete shape.value.attributes[id]}
function attribute(classId:string,id:string,type:string,event:Event){
  if(!shape.value)return
  const input=event.target as HTMLInputElement,key=shape.value.id+':'+classId+':'+id;let value:unknown=input.value
  if(type==='boolean')value=input.checked
  else if(type==='number') {try{value=parseDocumentJSON(input.value);if(!annotationNumber(value))throw new Error()}catch{attributeErrors.value[key]='Enter a finite number or Int64.';return}}
  delete attributeErrors.value[key];checkpoint();const attributes=clone(shape.value.attributes||{}),values=clone(attributes[classId]||{});Object.defineProperty(values,id,{value,writable:true,enumerable:true,configurable:true});Object.defineProperty(attributes,classId,{value:values,writable:true,enumerable:true,configurable:true});shape.value.attributes=attributes
}
function exportJSON(){if(draft.value)download(new Blob([documentJSON(draft.value)],{type:'application/json'}),'image-annotations.json')}
async function apply(){
  if(!draft.value||invalid.value||stale.value||saving.value||!props.runtime.canApply||props.disabled||Object.keys(attributeErrors.value).length)return
  saving.value=true;error.value=''
  const json=documentJSON(draft.value), bytes=new TextEncoder().encode(json);let binary='';for(let i=0;i<bytes.length;i+=16384)binary+=String.fromCharCode(...bytes.subarray(i,i+16384))
  try{if(await props.runtime.apply({board_id:props.boardId,component_id:props.component.id,operation:'annotations',extension:'json',name:'image-annotations.json',data:btoa(binary)},{revision:frozenRevision,version:frozenVersion})){saving.value=false;close()}else error.value='Annotations were not confirmed. Keep this draft or export it; check media command status.'}catch(cause){error.value=(cause as Error).message}finally{saving.value=false}
}
watch(()=>props.runtime.readable,v=>{if(!v){saving.value=false;close()}})
onBeforeUnmount(()=>{disposed=true;generation++;emit('dirty',false)})
</script>
<template>
  <div class="image-annotator-launch"><button :disabled="disabled || !image || opening" @click="show">{{ opening ? 'Opening image…' : 'Annotate image…' }}</button><p v-if="error && !open" class="source-error" role="status">{{ error }}</p></div>
  <dialog ref="dialog" class="notebook-dialog image-annotation-dialog" aria-label="Image annotations" @cancel.prevent="close">
    <template v-if="draft && snapshot"><header><h2>Image annotations</h2><button :disabled="saving" aria-label="Close image annotations" @click="close">Discard &amp; close</button></header><p>{{ snapshot.name }} · {{ draft.width }} × {{ draft.height }} source pixels</p><p v-if="stale" class="source-error" role="status">The source or accepted inputs changed. This draft keeps its original image. Export or discard it, then reopen before Apply.</p>
      <div class="annotation-toolbar"><label>Tool<select v-model="mode" aria-label="Annotation tool"><option value="select">Select</option><option value="point">Point</option><option value="rect">Rectangle</option></select></label><button :disabled="saving || stale || draft.shapes.length>=500" @click="add('point')">Add point</button><button :disabled="saving || stale || draft.shapes.length>=500" @click="add('rect')">Add rectangle</button><button :disabled="!history.length || saving" @click="undo">Undo</button><button :disabled="!redo.length || saving" @click="redoEdit">Redo</button><button :disabled="zoom<=.25" @click="zoom=Math.max(.25,zoom/2)">Zoom out</button><button :disabled="zoom>=16" @click="zoom=Math.min(16,zoom*2)">Zoom in</button><button @click="zoom=1">Fit</button></div>
      <div class="annotation-layout"><div class="annotation-scroll"><svg :viewBox="`0 0 ${draft.width} ${draft.height}`" :style="{width:zoom*100+'%'}" role="img" aria-label="Annotation canvas" @pointerdown="down" @pointerup="up" @pointercancel="pointer=null"><image :href="'data:image/'+(snapshot.extension==='png'?'png':'jpeg')+';base64,'+snapshot.data" :width="draft.width" :height="draft.height" /><g v-for="region in draft.shapes" :key="region.id" :class="{selected:region.id===selected}" @pointerdown.stop="selected=region.id"><rect v-if="region.kind==='rect'" :x="region.x" :y="region.y" :width="region.width" :height="region.height" vector-effect="non-scaling-stroke" /><circle v-else :cx="region.x+.5" :cy="region.y+.5" :r="Math.max(.3,Math.min(draft.width,draft.height)/100)" vector-effect="non-scaling-stroke" /></g></svg></div>
        <fieldset class="annotation-inspector" :disabled="saving || stale"><legend>Regions · {{ draft.shapes.length }} / 500</legend><label>Selected region<select v-model="selected" aria-label="Selected region"><option value="">Choose…</option><option v-for="(region,index) in draft.shapes" :key="region.id" :value="region.id">{{ index+1 }} · {{ region.label || region.kind }}</option></select></label>
          <template v-if="shape"><label>Label<input :value="shape.label" aria-label="Region label" maxlength="128" @input="change('label',($event.target as HTMLInputElement).value)"></label><div class="annotation-coordinates"><label v-for="key in shape.kind==='rect'?['x','y','width','height']:['x','y']" :key="key">{{ key }}<input type="number" step="1" :value="shape[key]" :aria-label="'Region '+key" @input="change(key,($event.target as HTMLInputElement).value===''?null:Number(($event.target as HTMLInputElement).value))"></label></div>
            <div v-for="definition in draft.classes || []" :key="definition.id" class="annotation-region-class"><label><input type="checkbox" :checked="shape.classes?.includes(definition.id)" :aria-label="'Assign '+definition.title" @change="assign(definition.id,($event.target as HTMLInputElement).checked)">{{ definition.title }}</label><template v-if="shape.classes?.includes(definition.id)"><label v-for="a in definition.attributes" :key="a.id">{{ a.title }}<input v-if="a.type==='boolean'" type="checkbox" :aria-label="a.title" :checked="shape.attributes?.[definition.id]?.[a.id]===true" @change="attribute(definition.id,a.id,a.type,$event)"><select v-else-if="a.type==='choice'" :aria-label="a.title" :value="shape.attributes?.[definition.id]?.[a.id] ?? ''" @change="attribute(definition.id,a.id,a.type,$event)"><option value="" disabled>Choose…</option><option v-for="option in a.options" :key="option" :value="option">{{ option }}</option></select><input v-else :aria-label="a.title" :inputmode="a.type==='number'?'decimal':undefined" :value="a.type==='number'&&shape.attributes?.[definition.id]?.[a.id]!==undefined?documentJSON(shape.attributes[definition.id]![a.id]):shape.attributes?.[definition.id]?.[a.id]??''" @input="attribute(definition.id,a.id,a.type,$event)"></label></template></div><button @click="remove">Delete region</button>
          </template><p v-else class="source-note">Draw on the image or add a region, then edit exact source-pixel coordinates.</p>
        </fieldset></div>
      <p v-if="invalid" class="source-error" role="status">{{ invalid }}</p><p v-for="(message,key) in attributeErrors" :key="key" class="source-error">{{ message }}</p><p v-if="error" class="source-error" role="status">{{ error }}</p><footer class="dialog-actions"><button @click="exportJSON">Export JSON…</button><button :disabled="saving" @click="close">Discard</button><button class="primary" :disabled="saving || stale || !!invalid || Object.keys(attributeErrors).length>0 || disabled || !runtime.canApply" @click="apply">{{ saving?'Applying…':'Apply annotations' }}</button></footer>
    </template>
  </dialog>
</template>
