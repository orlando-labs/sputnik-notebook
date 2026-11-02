import { readFile, writeFile, mkdir } from 'node:fs/promises'
import path from 'node:path'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { APP } from './common.mjs'
import { palette } from './parity_fixture.mjs'

const tools = await palette(), file = path.join(APP, 'frontend/src/board-editor.ts'), source = await readFile(file, 'utf8')
const section = source.slice(source.indexOf('export const boardTools = ['), source.indexOf('] as const', source.indexOf('export const boardTools = [')))
const web = new Set([...section.matchAll(/kind: '([^']+)'/g)].map(match => match[1]))
const absent = tools.filter(tool => !web.has(tool.kind)).map(tool => tool.id).sort()
assert.deepEqual(absent, [], 'The audit matrix changed; review new/removed parity gaps.')
const limitations = {
  result: 'Captured Inspect/Pretty, literal Find and table controls; search covers bounded snapshots, not the worker heap.',
  log: 'Bounded stdout/stderr with search, stream filter, copy and export; private worker source paths are not exposed.',
  periodic_work: 'Server schedule. Desktop pause-while-hidden is intentionally preserved without controlling server lifetime.',
  run_history: 'Shared server retention/pins; scalar restore is atomic per scope, not a whole local notebook heap.',
  experiment_compare: 'Exact scalar/metric deltas and CSV; same retained-snapshot limits as Run History.',
  audio_input: 'Browser microphone permission and recorder formats depend on browser support; no Safari/mobile OS acceptance.',
  file_input: 'Managed upload and relative project members; arbitrary desktop/server file paths are not browser authority.',
  config_editor: 'Uses an Input with JSON/YAML/TOML control settings, rather than a separate palette button.',
  image_annotator: 'Uses Image/Carousel annotation settings, rather than a separate palette button.',
  status: 'Sheet/cell/action/service/runtime state and source navigation, with server quota status.',
  artifacts: 'Captured path/name/caption records resolve immutable saved bundle members only; external and newly generated non-bundled files are unavailable.',
  task_monitor: 'Up to 512 task records, parent tree, state/errors, duration and usage; only trusted cell/line references, never private worker paths.',
}
const entries = tools.map(tool => ({ ...tool, web: web.has(tool.kind) ? tool.id === tool.kind ? 'runtime-present' : 'existing-kind-preset' : 'preserved-unavailable', limitations: limitations[tool.id] || 'Runtime renderer present; this inventory does not assert equality of every inspector option.' }))
const hashes = {}
for (const relative of ['../../tools/notebook-macos/NotebookBoard.swift','frontend/src/board-editor.ts','frontend/src/NotebookBoardCard.vue']) hashes[relative] = createHash('sha256').update(await readFile(path.resolve(APP, relative))).digest('hex')
const report = { date:'2026-10-31', swift_palette_tools:tools.length, persisted_kinds:new Set(tools.map(tool=>tool.kind)).size, web_palette_kinds:web.size, unavailable_tools:absent, scope:'Source inventory plus separate native bridge/browser transfer acceptance; not SwiftUI visual equivalence', entries, source_sha256:hashes }
const output = path.join(APP, 'build/parity-inventory.json'); await mkdir(path.dirname(output), { recursive:true }); await writeFile(output, JSON.stringify(report,null,2)+'\n')
console.log(`PASS parity inventory: ${tools.length} Swift tools / ${report.persisted_kinds} persisted kinds; ${absent.length} explicit unavailable kinds; ${web.size} web palette kinds`)
