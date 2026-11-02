import { documentJSON } from './document-json'
export interface AnnotationAttribute { id: string; title: string; type: 'text'|'number'|'boolean'|'choice'; options: string[] }
export interface AnnotationClass { id: string; title: string; attributes: AnnotationAttribute[] }
export interface ImageShape { id:string; kind:'point'|'rect'; label:string; x:number; y:number; width?:number; height?:number; classes?:string[]; attributes?:Record<string,Record<string,unknown>>; [key:string]:unknown }
export interface ImageAnnotations { version:1; asset:string; channel:string; width:number; height:number; classes?:AnnotationClass[]; shapes:ImageShape[]; [key:string]:unknown }
export interface AnnotationImage { data:string; extension:string; name:string }
const bytes=(s:string)=>new TextEncoder().encode(s).length
const text=(s:unknown,limit:number,required=false):s is string=>typeof s==='string'&&!s.includes('\0')&&bytes(s)<=limit&&(!required||!!s.trim())
export function annotationNumber(value:unknown) {
  try { const token=documentJSON(value); if(/^-?\d+$/.test(token))return BigInt(token)>=-9223372036854775808n&&BigInt(token)<=9223372036854775807n;return /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(token)&&Number.isFinite(Number(token)) }catch{return false}
}
export function annotationClassesError(classes: AnnotationClass[]) {
  if(!Array.isArray(classes)||classes.length>32)return 'Use up to 32 annotation classes.'
  const ids=new Set<string>()
  for(const c of classes){
    if(!text(c.id,64,true)||ids.has(c.id)||!text(c.title,128,true)||!Array.isArray(c.attributes)||c.attributes.length>16)return 'Classes need unique IDs, titles and at most 16 attributes.'
    ids.add(c.id);const keys=new Set<string>()
    for(const a of c.attributes){
      if(!text(a.id,64,true)||keys.has(a.id)||!text(a.title,128,true)||!['text','number','boolean','choice'].includes(a.type)||!Array.isArray(a.options)||a.options.length>64||new Set(a.options).size!==a.options.length||a.options.some(o=>!text(o,128,true))||(a.type==='choice')!==(a.options.length>0))return 'Attributes need unique IDs, titles, valid types and unique choice options.'
      keys.add(a.id)
    }
  }
  return ''
}
export function annotationError(value: ImageAnnotations) {
  if(value.version!==1||!/^[a-f0-9]{64}$/.test(value.asset)||!text(value.channel,256,true)||![value.width,value.height].every(n=>Number.isInteger(n)&&n>0&&n<=8192)||value.width*value.height>16000000)return 'Invalid image identity or dimensions.'
  const classes=value.classes||[], invalid=annotationClassesError(classes);if(invalid)return invalid
  if(value.shapes.length>500)return 'An image permits up to 500 regions.'
  const ids=new Set<string>()
  for(const shape of value.shapes){
    if(!text(shape.id,64,true)||ids.has(shape.id)||!text(shape.label,128)||!['point','rect'].includes(shape.kind))return 'Regions need unique IDs and labels up to 128 UTF-8 bytes.'
    ids.add(shape.id)
    if(![shape.x,shape.y].every(Number.isInteger)||shape.x<0||shape.y<0||shape.x>=value.width||shape.y>=value.height)return 'Coordinates must be whole source pixels inside the image.'
    if(shape.kind==='rect'&&(![shape.width,shape.height].every(n=>Number.isInteger(n)&&n!>0)||shape.x+shape.width!>value.width||shape.y+shape.height!>value.height))return 'Rectangles need positive whole sizes inside the source image.'
    const assigned=shape.classes||[]
    if(new Set(assigned).size!==assigned.length||assigned.some(id=>!classes.some(c=>c.id===id)))return 'Choose only configured classes.'
    for(const [id,values] of Object.entries(shape.attributes||{})){
      const c=classes.find(c=>c.id===id);if(!c||!assigned.includes(id)||!values||typeof values!=='object')return 'Attributes require an assigned class.'
      for(const [key,entry] of Object.entries(values)){
        const a=c.attributes.find(a=>a.id===key);if(!a)return 'Unknown class attribute.'
        if(a.type==='text'&&!text(entry,2048)||a.type==='choice'&&!a.options.includes(String(entry))||a.type==='boolean'&&typeof entry!=='boolean'||a.type==='number'&&!annotationNumber(entry))return `Invalid ${a.title} value.`
      }
    }
  }
  return bytes(documentJSON(value))>256*1024?'Annotations exceed 256 KiB.':''
}
export function drawnShape(kind:'point'|'rect',from:{x:number;y:number},to:{x:number;y:number},width:number,height:number):ImageShape|null {
  if(![from.x,from.y,to.x,to.y,width,height].every(Number.isFinite))return null
  const clamp=(n:number,max:number)=>Math.max(0,Math.min(max,n))
  if(kind==='point')return {id:crypto.randomUUID(),kind,label:'',x:clamp(Math.floor(from.x),width-1),y:clamp(Math.floor(from.y),height-1),classes:[],attributes:{}}
  const x1=clamp(Math.round(from.x),width),y1=clamp(Math.round(from.y),height),x2=clamp(Math.round(to.x),width),y2=clamp(Math.round(to.y),height)
  return x1===x2||y1===y2?null:{id:crypto.randomUUID(),kind,label:'',x:Math.min(x1,x2),y:Math.min(y1,y2),width:Math.abs(x2-x1),height:Math.abs(y2-y1),classes:[],attributes:{}}
}
export async function imageIdentity(image:AnnotationImage) {
  const raw=Uint8Array.from(atob(image.data),c=>c.charCodeAt(0)),blob=new Blob([raw],{type:image.extension==='png'?'image/png':'image/jpeg'})
  const bitmap=await createImageBitmap(blob)
  try {
    if(bitmap.width>8192||bitmap.height>8192||bitmap.width*bitmap.height>16000000)throw new Error('Image exceeds annotation dimensions.')
    const digest=await crypto.subtle.digest('SHA-256',raw)
    return {asset:Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join(''),width:bitmap.width,height:bitmap.height}
  }finally{bitmap.close()}
}
