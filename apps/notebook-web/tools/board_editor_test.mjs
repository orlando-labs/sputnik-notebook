import assert from 'node:assert/strict'
import ts from '../frontend/node_modules/typescript/lib/typescript.js'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { webcrypto } from 'node:crypto'
globalThis.crypto ||= webcrypto
const root = await mkdtemp(path.join(tmpdir(), 'sputnik-board-editor-'))
try {
  for (const name of ['document-json', 'notebook', 'boards', 'inputs', 'displays', 'board-execution', 'rich-text', 'image-annotations', 'audio-annotations', 'date-input', 'parameter-presets', 'board-editor']) {
    let code = ts.transpileModule(await readFile(new URL(`../frontend/src/${name}.ts`, import.meta.url), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText
    code = code.replace(/from '(\.\/[^']+)'/g, (_, name) => `from '${name}.mjs'`)
    await writeFile(path.join(root, `${name}.mjs`), code)
  }
  const { newBoard, designBoard, addComponent, addRow, gridAt, freeColumns, moveComponent, duplicateComponent, boardError, boardCounts, BoardHistory, cloneBoard } = await import('file://' + path.join(root, 'board-editor.mjs'))
  const { parseDocumentJSON, documentJSON } = await import('file://' + path.join(root, 'document-json.mjs'))
  const { commandSettingsError } = await import('file://' + path.join(root, 'board-execution.mjs'))
  const document = { format: 'sputnik-notebook', version: 4, title: 'Test', active_sheet: 'main', sheets: [{ id: 'main', title: 'Main', cells: [{ id: '1', kind: 'code', source: '42\n' }] }], inputs: [{ id: 'gain', title: 'Gain', type: 'integer', default: 2 }], boards: [] }
  const board = newBoard(document)
  assert.equal(boardError(board, document), '')
  const row = board.rows[0].id
  const first = addComponent(board, [], row, 'metric', 6, document), second = addComponent(board, [], row, 'table', 6, document)
  assert.equal(freeColumns(gridAt(board, []), row), 0)
  const third = addComponent(board, [], row, 'image', 6, document)
  assert.equal(board.rows.length, 2)
  const secondRow = board.rows[1].id, before = documentJSON(board)
  assert.throws(() => moveComponent(board, [], third, row), /Not enough columns/)
  assert.equal(documentJSON(board), before, 'rejected moves preserve every field')
  board.components.find(item => item.id === first).span = 3
  board.components.find(item => item.id === second).span = 3
  moveComponent(board, [], third, row)
  assert.equal(board.components.at(-1).id, third); assert.equal(board.components.at(-1).row, row)
  const copyId = duplicateComponent(board, [], third)
  assert.equal(board.components.find(item => item.id === copyId).row, board.rows.at(-1).id)
  assert.equal(boardError(board, document), '')
  const groupId = addComponent(board, [], secondRow, 'group', 6, document)
  const group = board.components.find(item => item.id === groupId), panel = group.panels[0]
  panel.future_panel = { exact: parseDocumentJSON('9223372036854775807') }; panel.rows[0].future_row = 'kept'
  const nestedId = addComponent(board, [{ component: groupId, panel: panel.id }], panel.rows[0].id, 'metric', 6, document)
  panel.components[0].p1 = { target_component: nestedId, future: ['retained'] }
  const duplicate = duplicateComponent(board, [], groupId), cloned = board.components.find(item => item.id === duplicate)
  assert.notEqual(cloned.panels[0].id, panel.id); assert.notEqual(cloned.panels[0].rows[0].id, panel.rows[0].id)
  const child = cloned.panels[0].components[0]
  assert.notEqual(child.id, nestedId); assert.equal(child.row, cloned.panels[0].rows[0].id); assert.equal(child.p1.target_component, child.id)
  assert.equal(cloned.panels[0].rows[0].future_row, 'kept'); assert(documentJSON(cloned).includes('9223372036854775807'))
  assert.equal(boardError(board, document), '')
  const legacy = parseDocumentJSON('{"id":"legacy","title":"Legacy","sheet":"main","columns":2,"future":9223372036854775807,"components":[{"id":"metric","kind":"metric","title":"Value","cell":"1"},{"id":"service","kind":"periodic_work","title":"Saved service","module_id":"jobs","function":"tick","future":{"keep":true}}]}')
  const original = documentJSON(legacy), normalized = designBoard(legacy)
  assert.equal(documentJSON(legacy), original); assert.equal(normalized.components.length, 2)
  assert.equal(normalized.components[1].row, undefined); assert(documentJSON(normalized).includes('9223372036854775807'))
  const invalid = cloneBoard(board); invalid.rows[0].height = 0; assert.match(boardError(invalid, document), /height/)
  invalid.rows[0].height = 100; invalid.components[0].span = 0; assert.match(boardError(invalid, document), /12 columns/)
  const nested = cloneBoard(board); nested.components.find(item => item.id === groupId).panels[0].components[0].panels = []
  assert.match(boardError(nested, document), /panels/)
  const inputBoard = newBoard(document); addComponent(inputBoard, [], inputBoard.rows[0].id, 'input', 6, document)
  assert.equal(boardError(inputBoard, document), ''); inputBoard.components[0].input = 'missing'; assert.match(boardError(inputBoard, document), /project parameter/)
  const limited = newBoard(document); limited.rows = Array.from({ length: 256 }, (_, i) => ({ id: `row_${i}` })); assert.throws(() => addRow(limited, []), /256 rows/)
  assert.deepEqual(boardCounts(limited), { rows: 256, components: 0, panels: 0 })
  const history = new BoardHistory()
  history.remember('first', 'title', 1); history.remember('second', 'title', 100)
  assert.deepEqual(history.undo, ['first'], 'text editing coalesces')
  history.remember('third', '', 101)
  assert.equal(history.restore('fourth', true), 'third'); assert.equal(history.restore('third', true), 'first'); assert.equal(history.restore('first', false), 'third')
  history.remember('branch'); assert.deepEqual(history.redo, [])
  const budget = new BoardHistory(1000)
  for (let i = 0; i < 1000; i++) budget.remember('😀'.repeat(50) + i)
  assert(budget.undo.length <= 4, 'history respects UTF-8 byte budget')
  const commands = { ...document, modules: [{ id: 'jobs', path: 'modules/jobs.s' }] }, services = newBoard(commands)
  addComponent(services, [], services.rows[0].id, 'metric', 12, commands)
  const job = addComponent(services, [], services.rows[0].id, 'periodic_work', 12, commands)
  duplicateComponent(services, [], job)
  assert.equal(services.rows.length, 1, 'nonvisual services never consume grid columns')
  assert.equal(services.components.filter(item => item.kind === 'periodic_work').length, 2)
  assert.equal(boardError(services, commands), '')
  const action = { id: 'action', kind: 'action', title: 'Call', module_id: 'jobs', function: 'compute', p1: { arguments: [{ id: 'arg', value_json: '9223372036854775807' }] } }
  assert.equal(commandSettingsError(action, commands), '', 'Int64 constants stay opaque scalars')
  action.p1.arguments[0].value_json = '9223372036854775808'; assert.match(commandSettingsError(action, commands), /scalar/)
  action.p1.arguments[0].value_json = '{"not":"scalar"}'; assert.match(commandSettingsError(action, commands), /scalar/)
  action.p1.arguments = [{ id: 'named', name: 'value', value_json: 'true' }, { id: 'positional', value_json: 'null' }]
  assert.match(commandSettingsError(action, commands), /positional/)
  services.components.find(item => item.id === job).period_seconds = 0; assert.match(boardError(services, commands), /Period/)
  console.log('PASS board command settings: exact scalar arguments, argument ordering, nonvisual service copies and schedule limits')
  console.log('PASS board creation, atomic row moves, nested duplication/remapping, exact metadata, native limits and bounded undo/redo')
} finally { await rm(root, { recursive: true, force: true }) }
