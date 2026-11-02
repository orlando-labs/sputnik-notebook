import fs from 'node:fs'
import crypto from 'node:crypto'

// Source inventory, not an assertion of end-to-end behavioral coverage.
const nativePath = 'packages/notebook-core/native/notebook.cpp'
const source = fs.readFileSync(nativePath, 'utf8')
const start = source.indexOf('void command_impl(')
const section = source.slice(start, source.indexOf('extern "C"', start))
const actions = [...new Set([...section.matchAll(/action == "([a-z_]+)"/g)].map(m => m[1]))].sort()
const groups = [
  ['authored-and-synchronized', 'Local inert editing; full revision published by Remote.synchronize.',
    'add_cell add_text auto_import delete_cell delete_input move_down move_up new_input new_module new_sheet rename_sheet retain_cell_results rich_source save save_all save_board save_cell_ui select set_cell_id source watch'],
  ['remote-command', 'Explicit desktop transport to Core; see audit for target/acknowledgement limits.',
    'action_run periodic_run restart_worker run run_all set_cell_inputs set_input set_inputs'],
  ['policy-and-revision', 'Authored policy plus separate desktop policy RPC.', 'resource_policy'],
  ['local-media-then-sync', 'Writes desktop bundle, then uploads full revision; no media.accept route in desktop transport.', 'audio_edit image_edit'],
  ['broken-local-only', 'Local success without server invocation restart or selected-image update.', 'image_select periodic_dispose'],
  ['disabled-in-remote-ui', 'Remote desktop disables scalar restore and shared selection/annotation editing.', 'component_data_edit restore_inputs'],
  ['unsupported', 'Directory dependency bundles rejected on remote Run; Apply requires explicit restart instead.', 'add_dependency remove_dependency apply'],
  ['server-owned-automatic', 'Desktop local operation blocked; corresponding work is owned by the Core agent.', 'periodic_tick watch_run'],
  ['alternate-remote-api', 'Worker settings use NotebookModel.configureWorker / Remote.configureWorker.', 'worker_environment worker_grants'],
  ['internal-client-policy', 'Internal host consent flag; no matching desktop remote command.', 'trust_native'],
]
const classified = new Map()
for (const [status, note, keys] of groups) for (const key of keys.split(' ')) {
  if (classified.has(key)) throw new Error(`duplicate ${key}`)
  classified.set(key, {status, note})
}
if (actions.some(a => !classified.has(a)) || [...classified.keys()].some(a => !actions.includes(a))) throw new Error('Action inventory drift')
const boardPath = 'tools/notebook-macos/NotebookBoard.swift'
const board = fs.readFileSync(boardPath, 'utf8')
const palette = [...board.matchAll(/Self\(id: "([a-z_]+)", title: "([^"]+)"/g)].map(m => ({id: m[1], title: m[2], kind: m[1] === 'config_editor' ? 'input' : m[1] === 'image_annotator' ? 'image' : m[1]}))
if (palette.length !== 35) throw new Error(`Palette drift: ${palette.length}`)
const paths = [nativePath, boardPath,
  'tools/notebook-macos/NotebookModel.swift', 'tools/notebook-macos/NotebookRemote.swift',
  'tools/notebook-macos/NotebookExecutionControlsView.swift', 'tools/notebook-macos/NotebookBoardView.swift',
  'tools/notebook-macos/NotebookSelection.swift', 'tools/notebook-macos/NotebookRangeDateView.swift',
  'tools/notebook-macos/NotebookRunHistory.swift', 'tools/notebook-macos/NotebookRunHistoryView.swift',
  'tools/notebook-macos/NotebookAudioAnnotatorView.swift', 'tools/notebook-remote/server.s',
  'tools/notebook-remote/client.s', 'packages/notebook-core/src/notebook/core.s',
  'packages/notebook-core/src/notebook/core/services.s', '../sputnik-lang/tools/isputnik/tabs.cpp']
const digest = path => crypto.createHash('sha256').update(fs.readFileSync(path)).digest('hex')
const report = {
  date: '2026-11-01', scope: 'macOS desktop with Remote Core; web comparison is separate',
  evidence: 'Static source inventory; runtime observations are in observations.json and probe.log',
  action_count: actions.length, palette_tool_count: palette.length, persisted_kind_count: new Set(palette.map(p => p.kind)).size,
  actions: actions.map(action => {
    const index = source.indexOf(`action == "${action}"`, start)
    return {action, ...classified.get(action), path: nativePath, line: source.slice(0, index).split('\n').length}
  }), palette,
  sha256: Object.fromEntries(paths.map(path => [path, digest(path)])),
}
fs.writeFileSync('docs/evidence/2026-11-01/remote-action-audit/inventory.json', JSON.stringify(report, null, 2) + '\n')
console.log(`${report.action_count} actions, ${report.palette_tool_count} tools, ${report.persisted_kind_count} kinds; all actions classified`)
