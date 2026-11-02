import { spawn } from 'node:child_process'
import { mkdtemp, mkdir, cp, appendFile, rm } from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
import assert from 'node:assert/strict'
import { APP, COMPILER } from './common.mjs'

const native = process.argv.includes('--native')
function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: APP, stdio: ['ignore', 'pipe', 'pipe'] })
    let output = ''
    child.stdout.on('data', value => { output += value })
    child.stderr.on('data', value => { output += value })
    child.on('error', reject)
    child.on('close', code => resolve({ code, output }))
  })
}
const grants = ['ffi', 'fs.read', 'fs.write', 'fs.metadata', 'random.secure', 'time.now'].flatMap(value => ['--grant', value])
const root = await mkdtemp(path.join(os.tmpdir(), 'notebook-web-models-'))
try {
  const migrations = path.join(root, 'migrations')
  await cp(path.join(APP, 'db/migrations'), migrations, { recursive: true })
  const args = ['--database', path.join(root, 'catalog.sqlite'), '--migrations', migrations]
  let command = COMPILER, prefix = ['run', 'test/model_test.s', ...grants, '--']
  if (native) {
    await mkdir(path.join(APP, 'build/model-native'), { recursive: true })
    command = path.join(APP, 'build/model-native/models')
    const build = await run(COMPILER, ['build', 'test/model_test.s', '-o', command, '--target', 'native', '--require-full-native', ...grants])
    assert.equal(build.code, 0, build.output)
    console.log(build.output.trim())
    prefix = []
  }
  for (const extra of [[], ['--existing']]) {
    const result = await run(command, [...prefix, ...args, ...extra])
    assert.equal(result.code, 0, result.output)
    assert.match(result.output, /PASS notebook-web/)
    console.log(result.output.trim())
  }
  await appendFile(path.join(migrations, '001_accounts_projects.sql'), '\n-- altered after application\n')
  const modified = await run(command, [...prefix, ...args, '--existing'])
  assert.notEqual(modified.code, 0, 'modified applied migration must fail startup')
  assert.match(modified.output, /applied migration was modified/)
  console.log(`PASS ${native ? 'full-native' : 'VM'} migration integrity`)
} finally { await rm(root, { recursive: true, force: true }) }
