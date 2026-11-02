import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import path from 'node:path'
import { tmpdir } from 'node:os'
const root = await mkdtemp(path.join(tmpdir(),'notebook-observation-'))
try {
  const source = await readFile(new URL('../frontend/src/runtime-observation.ts', import.meta.url),'utf8')
  await writeFile(path.join(root,'observation.mjs'),ts.transpileModule(source,{ compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022} }).outputText)
  const { literalMatches, taskDepth, artifactRows, logEntries, targetStatus } = await import('file://'+path.join(root,'observation.mjs'))
  assert.deepEqual(literalMatches('😀 Aa aa [.*] İi','aa').ranges,[{start:3,end:5},{start:6,end:8}])
  assert.deepEqual(literalMatches('x[.*]x','[.*]').ranges,[{start:1,end:5}])
  assert.equal(literalMatches('Aa aa','aa',true).ranges.length,1)
  assert.equal(literalMatches('a'.repeat(65536),'a').ranges.length,4096)
  assert.equal(literalMatches('a'.repeat(65536),'a').limited,true)
  assert.equal(literalMatches('x','').ranges.length,0)
  assert.equal(taskDepth({id:'9007199254740993',parent:'9007199254740992'},[{id:'9007199254740992',parent:'0'}]),1)
  assert.equal(taskDepth({id:'a',parent:'b'},[{id:'b',parent:'a'},{id:'a',parent:'b'}]),1)
  const value=text=>({kind:'text',text}), table={columns:[{title:'path'},{title:'name'},{title:'caption'}],rows:['resources/good.txt','../secret','/etc/passwd','a\\b','C:x','project.json','a\0b','a//b'].map((text,i)=>({id:String(i),values:[value(text),value('<script>literal</script>'),value('caption')]}))}
  assert.deepEqual(artifactRows(table).map(item=>item.safe),[true,false,false,false,false,false,false,false])
  assert.equal(artifactRows({...table,rows:Array(200).fill(table.rows[0])}).length,128)
  assert.equal(artifactRows({...table,columns:[{title:'other'}]}).length,0)
  const grouped=logEntries([{stream:'stdout',text:'😀'.repeat(16000)},{stream:'stdout',text:'tail'},{stream:'stderr',text:'problem'},{stream:'stdout',text:'end'}])
  assert.equal(grouped.length,3); assert(grouped[0].text.endsWith('tail')); assert.equal(grouped[2].id,3)
  assert.equal(logEntries([{stream:'stdout',text:'é'.repeat(32768)},{stream:'stdout',text:'é'}]).length,2)
  const component={kind:'status',p1:{target_kind:'runtime'}}, context={observation:{connected:true,needsRestart:false,resources:{remaining_ms:'0'}}}
  assert.equal(targetStatus(component,context).title,'Computation quota exhausted')
  context.observation.connected=false; assert.equal(targetStatus(component,context).title,'Disconnected')
  context.observation.connected=true;context.observation.needsRestart=true;assert.equal(targetStatus(component,context).title,'Computation quota exhausted')
  context.observation.resources.remaining_ms='1000';assert.equal(targetStatus(component,context).title,'Restart required')
  assert.equal(targetStatus({kind:'status',p1:{target_kind:'cell'},cell:'missing'},{...context,sheet:{cells:[]}}).title,'Unavailable')
  console.log('PASS literal Unicode search/caps, exact task hierarchy/cycles, artifact authority, bounded log grouping and quota/disconnect status')
} finally { await rm(root,{recursive:true,force:true}) }
