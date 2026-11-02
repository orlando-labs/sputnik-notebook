import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import path from 'node:path'
import {webcrypto} from 'node:crypto'
globalThis.crypto ||= webcrypto
const root=await mkdtemp(path.join(tmpdir(),'sputnik-selection-'))
try {
 for(const name of ['shared-selection','date-input','parameter-presets','inputs','document-json']){
  const text=await readFile(new URL(`../frontend/src/${name}.ts`,import.meta.url),'utf8')
  await writeFile(path.join(root,name+'.mjs'),ts.transpileModule(text,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText.replace(/from '(\.\/[^']+)'/g,"from '$1.mjs'"))
 }
 const {parseSourceTable,publicTable,selectionError,selectedRow,assetID,assetMatches}=await import('file://'+path.join(root,'shared-selection.mjs'))
 const {validDate,validTimestamp,validZone,localTime,timeCandidates,dateSettingsError}=await import('file://'+path.join(root,'date-input.mjs'))
 const {presetError,presetListError,capturePreset}=await import('file://'+path.join(root,'parameter-presets.mjs'))
 const {documentJSON}=await import('file://'+path.join(root,'document-json.mjs'))
 const table=parseSourceTable('{"columns":[{"id":"0","title":"id","type":"integer"},{"id":"1","title":"name","type":"text"}],"rows":[{"id":"0","values":[9223372036854775807,"A"]},{"id":"1","values":[9223372036854775806,"B"]}],"total_rows":2,"truncated":false}')
 assert.equal(selectionError(table,'id'),'');assert.equal(publicTable(table).rows[0].values[0].text,'9223372036854775807');assert.ok(documentJSON(selectedRow(table,'a'.repeat(64),'id','1')).includes('"key":9223372036854775806'))
 assert.ok(selectionError({...table,rows:[table.rows[0],table.rows[0]]},'id'));assert.ok(selectionError({...table,rows:[{id:'0',values:[null,'A']}]},'id'));assert.ok(selectionError({...table,columns:[table.columns[0],{...table.columns[1],title:'id'}]},'id'));assert.ok(selectionError(table,'missing'));assert.throws(()=>selectedRow(table,'a'.repeat(64),'id','missing'))
 const identity=await assetID(btoa('encoded'));assert.equal(identity.length,64);assert.equal(await assetMatches(btoa('encoded'),{row:{asset_id:identity}}),true);assert.equal(await assetMatches(btoa('different'),{row:{asset_id:identity}}),false)
 assert.equal(validDate('2024-02-29'),true);assert.equal(validDate('2026-02-29'),false);assert.equal(validDate('0001-01-01'),true);assert.equal(validDate('0000-01-01'),false);assert.equal(validTimestamp('2026-10-29T12:34:56Z'),true);assert.equal(validTimestamp('2026-02-30T00:00:00Z'),false);assert.equal(validZone('Unknown/Zone'),false)
 assert.equal(localTime('2026-10-29T10:00:00Z','Europe/Moscow'),'2026-10-29T13:00:00');assert.deepEqual(timeCandidates('2026-10-29T13:00:00','Europe/Moscow'),['2026-10-29T10:00:00Z']);assert.deepEqual(timeCandidates('2026-11-01T01:30','America/New_York'),['2026-11-01T05:30:00Z','2026-11-01T06:30:00Z']);assert.throws(()=>timeCandidates('2026-03-08T02:30','America/New_York'),/does not exist/);assert.deepEqual(timeCandidates('2026-10-29T13:00','Asia/Kathmandu'),['2026-10-29T07:15:00Z']);assert.deepEqual(timeCandidates('2026-10-29T00:00','UTC'),['2026-10-29T00:00:00Z']);assert.ok(dateSettingsError({date_mode:'date',date_time_zone:'UTC'},'2026-02-30'))
 const defs=[{id:'exact',title:'Exact',type:'integer',default_json:'9223372036854775806'},{id:'flag',title:'Flag',type:'boolean',default:false},{id:'text',title:'Text',type:'string',default:'saved'}]
 const preset=capturePreset('Current',defs,{exact:'9223372036854775807',text:'"runtime"'},[]);assert.equal(preset.values.exact,'9223372036854775807');assert.equal(preset.values.flag,'false');assert.equal(presetError(preset,defs),'');assert.equal(presetError({...preset,values:{text:'123'}},defs).includes('Incorrect'),true);assert.ok(presetError(preset,defs,['exact']));assert.ok(presetError({...preset,values:{exact:'9223372036854775808'}},defs));assert.ok(presetListError([preset,preset],defs));assert.ok(presetListError(Array(129).fill(preset),defs));assert.equal(capturePreset('Scoped',defs,{},['exact']).values.exact,'9223372036854775806');assert.ok(presetError({...preset,values:{text:'"bad"'}},defs,[],[{kind:'date_input',input:'text',date_mode:'date'}]));assert.ok(presetError({...preset,title:' '},defs))
 console.log('PASS exact selection scalar/row identity, duplicate/null/ambiguous keys, media SHA-256 bindings; strict calendar/UTC, IANA quarter-hour offsets and DST gaps/folds; preset scope/types/Int64/default separation/limits')
}finally{await rm(root,{recursive:true,force:true})}
