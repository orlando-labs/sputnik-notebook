import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import path from 'node:path'
import { APP } from './common.mjs'

export async function palette() {
  const swift = await readFile(path.resolve(APP, '../../tools/notebook-macos/NotebookBoard.swift'), 'utf8')
  const source = swift.slice(swift.indexOf('static let all = ['), swift.indexOf('static func tool('))
  return [...source.matchAll(/Self\(id: "([^"]+)", title: "([^"]+)"/g)].map(([, id, title]) => ({ id, title, kind: id === 'config_editor' ? 'input' : id === 'image_annotator' ? 'image' : id }))
}

export async function createParityBook(directory) {
  await mkdir(path.join(directory, 'modules'), { recursive: true })
  await mkdir(path.join(directory, '.hidden'), { recursive: true })
  const tools = await palette(), cell = '9007199254740993'
  const components = tools.map((tool, index) => {
    const c = { id: tool.id, kind: tool.kind, title: tool.title, row: 'row_' + index, span: 12, future_component: { exact: '__exact__', note: 'keep' } }
    if (['run','text','metric','log','artifacts','result','table','progress','plot','audio'].includes(c.kind)) c.cell = cell
    if (c.kind === 'input') { c.input = tool.id === 'config_editor' ? 'config' : 'gain'; c.control = { style: tool.id === 'config_editor' ? 'json' : 'stepper', ...(tool.id === 'config_editor' ? { config_format: 'json' } : { step: 1 }) } }
    if (c.kind === 'range_input') c.input = 'range'
    if (c.kind === 'file_input') { c.input = 'file'; c.p1 = { extensions: 'csv' } }
    if (c.kind === 'date_input') { c.input = 'date'; c.date_mode = 'date'; c.date_time_zone = 'UTC' }
    if (c.kind === 'parameter_form') c.fields = [{ input: 'gain' }, { input: 'flag' }]
    if (c.kind === 'parameter_presets') c.p1 = { preset_inputs: ['gain'], presets: [{ id: 'baseline', title: 'Baseline', values: { gain: '9223372036854775806' } }] }
    if (['audio_input','audio_annotator','audio'].includes(c.kind)) c.audio_id = c.kind === 'audio_annotator' ? 'annotated_clip' : 'clip'
    if (c.kind === 'audio_annotator') { c.audio_source = 'file'; c.annotation_id = 'segments'; c.annotation_classes = [] }
    if (['image','image_carousel'].includes(c.kind)) { c.image_id = c.id; c.image_allow_load = true; c.image_allow_save = true; c.image_allow_read = true }
    if (tool.id === 'image_annotator') { c.image_annotator = true; c.annotation_id = 'labels'; c.annotation_classes = [] }
    if (c.kind === 'rich_text') { c.text_content = { source: 'Imported **palette** {{value}}' }; c.text_mode = 'markdown' }
    if (c.kind === 'live_chart') c.chart_id = 'loss'
    if (['action','periodic_work'].includes(c.kind)) { c.module_id = 'jobs'; c.function = 'ready' }
    if (c.kind === 'periodic_work') { delete c.row; c.period_seconds = 60; c.timing = 'fixed_delay'; c.retention = 'tail'; c.tail_limit = 100; c.run_immediately = false }
    if (['tabs','split','group'].includes(c.kind)) c.panels = Array.from({ length: c.kind === 'group' ? 1 : 2 }, (_, n) => ({ id: 'panel_' + n, title: 'Panel ' + n, rows: [{ id: 'inner' }], components: [{ id: c.id + '_child_' + n, kind: 'rich_text', title: 'Nested text', row: 'inner', span: 12, text_content: { source: 'Preserved nested content' } }] }))
    return c
  })
  const document = { format: 'sputnik-notebook', version: 4, title: 'Native palette transfer', active_sheet: 'main',
    sheets: [{ id: 'main', title: 'Main', cells: [{ id: cell, kind: 'code', mode: 'manual', source: 'value = 42\nvalue\n' }, { id: '2', kind: 'text', source: 'Portable prose {{value}}' }] }],
    modules: [{ id: 'jobs', path: 'modules/jobs.s' }], auto_imports: [], dependencies: [],
    inputs: [{ id: 'gain', title: 'Exact gain', type: 'integer', default: '__exact__' }, { id: 'flag', title: 'Flag', type: 'boolean', default: false }, { id: 'config', title: 'Config', type: 'string', default: '{"answer":42}' }, { id: 'file', title: 'Dataset', type: 'string', default: '' }, { id: 'date', title: 'Date', type: 'string', default: '2026-10-31' }, { id: 'range', title: 'Range', type: 'range', default: { start: 0, finish: 10, inclusive_end: false, step: 2 } }],
    boards: [{ id: 'palette', title: 'Palette', sheet: 'main', columns: 1, rows: tools.map((_, i) => ({ id: 'row_' + i })), components, future_board: ['preserved'] }],
    resource_policy: { total_run_seconds: 60, run_seconds: 60, project_bytes: 67108864, max_run_bytes: 4194304 }, future_document: { exact: '__exact__', list: ['extension'] } }
  await writeFile(path.join(directory, 'project.json'), JSON.stringify(document).replaceAll('"__exact__"', '9223372036854775806'))
  await writeFile(path.join(directory, 'modules/jobs.s'), 'package jobs\nexport ready\ndef ready(): 42\n')
  await writeFile(path.join(directory, '.hidden/bytes.bin'), Buffer.from([0, 255, 128, 1, 13, 10]))
  const probe = path.resolve(APP, '../../build/notebook_web_transfer_probe')
  await promisify(execFile)(probe, [directory, 'value = 43\nvalue\n', path.join(directory, '../native-export.json')])
  return { tools, document: await readFile(path.join(directory, 'project.json'), 'utf8'), probe }
}
