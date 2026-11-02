import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile, rm, readdir } from 'node:fs/promises'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../', import.meta.url))
const compiler = process.env.SPUTNIK || path.resolve(root, '../sputnik-lang/build/sputnik')
const worker = process.env.NOTEBOOK_WORKER || path.join(root, 'build/sputnik-notebook-worker')
const env = { ...process.env, SPUTNIK_NATIVE_RT_CACHE: path.resolve(root, '../sputnik-lang/build/interop-runtime-cache'), SPUTNIK_VM_CACHE: path.join(root, 'build/core-api-vm-cache') }
const temporary = await mkdtemp(path.join(tmpdir(), 'notebook-core-api-'))
const grants = ['ffi', 'time.now', 'fs.read', 'fs.write', 'fs.metadata', 'random.secure', 'process.spawn']
function run(program, args) {
  const result = spawnSync(program, args, { cwd: root, env, encoding: 'utf8', timeout: 600_000, maxBuffer: 10 * 1024 * 1024 })
  assert.equal(result.status, 0, result.error?.message || result.stdout + result.stderr)
  return result.stdout
}
try {
  // The package must remain usable without Swift, AppKit, HTTP and CLI modules.
  const sourceRoot = path.join(root, 'packages/notebook-core/src')
  for (const relative of await readdir(sourceRoot, { recursive: true })) {
    if (!relative.endsWith('.s')) continue
    const source = await readFile(path.join(sourceRoot, relative), 'utf8')
    assert.doesNotMatch(source, /(?:from|import)\s+(?:notebook\.remote|orbit|net\.http)\b/)
    assert.doesNotMatch(source, /ArgParser\(|Bearer /)
    if (!relative.endsWith("client.s")) assert.doesNotMatch(source, /agent\.sock/)
  }
  for (const relative of await readdir(path.join(root, 'packages/notebook-core/native'))) {
    if (!relative.endsWith('.cpp')) continue
    const source = await readFile(path.join(root, 'packages/notebook-core/native', relative), 'utf8')
    assert.doesNotMatch(source, /#include[^\n]*(?:notebook-macos|AppKit|SwiftUI)/)
  }
  const options = grants.flatMap(name => ['--grant', name])
  const input = 'tests/notebook_core_api.build.json'
  assert.match(run(compiler, ['run', input, ...options, '--', '--root', path.join(temporary, 'vm'), '--worker', worker]), /PASS notebook-core direct API/)
  if (process.argv.includes('--native')) {
    const text = run(compiler, ['build', input, '--target', 'native', '--require-full-native', ...options, '--out-dir', 'build/core-api-native'])
    await writeFile(path.join(root, 'build/core-api-native-build.json'), text)
    const report = JSON.parse(text)
    assert(report.native_graph_full_coverage && report.native_graph_vm_independent && !report.native_graph_runtime_bridge)
    assert.equal(report.native_graph_fallback_code_count, 0)
    assert.match(run(path.join(root, 'build/core-api-native/test.notebook_core_api'), ['--root', path.join(temporary, 'native'), '--worker', worker]), /PASS notebook-core direct API/)
  }
  console.log('PASS notebook-core package boundary and direct API' + (process.argv.includes('--native') ? ' (VM/full-native)' : ' (VM)'))
} finally { await rm(temporary, { recursive: true, force: true }) }
