import { spawn } from 'node:child_process'
import { mkdir, readFile, writeFile, stat, readdir } from 'node:fs/promises'
import { randomBytes } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

export const APP = fileURLToPath(new URL('../', import.meta.url))
export const ORBIT = path.resolve(APP, '../../../orbit')
export const COMPILER = process.env.SPUTNIK || path.resolve(ORBIT, '../sputnik-lang/build/sputnik')
const grants = ['net.listen', 'net.connect', 'random.secure', 'time.now', 'fs.read', 'fs.write', 'fs.metadata', 'ffi']
export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

export function backend(manifest, args = [], env = process.env, stdio = 'inherit', detached = process.platform !== 'win32') {
  return spawn(COMPILER, ['run', manifest, ...grants.flatMap(grant => ['--grant', grant]), '--', ...args], {
    cwd: APP, env, stdio, detached,
  })
}

export function vite(env = process.env, stdio = 'inherit', detached = process.platform !== 'win32') {
  return spawn(process.execPath, [path.join(APP, 'frontend/node_modules/vite/bin/vite.js')], {
    cwd: path.join(APP, 'frontend'), env, stdio, detached,
  })
}

export async function stop(child, group = process.platform !== 'win32') {
  if (!child || child.exitCode !== null || child.signalCode !== null) return
  const signal = value => {
    try { group ? process.kill(-child.pid, value) : child.kill(value) }
    catch (error) { if (error.code !== 'ESRCH') throw error }
  }
  signal('SIGTERM')
  for (let attempt = 0; attempt < 50 && child.exitCode === null && child.signalCode === null; attempt++) await sleep(100)
  if (child.exitCode === null && child.signalCode === null) signal('SIGKILL')
}

export async function secrets() {
  const file = path.join(APP, 'build/dev-secrets.json')
  await mkdir(path.dirname(file), { recursive: true })
  try {
    await writeFile(file, JSON.stringify(Object.fromEntries(['ORBIT_SESSION_SECRET', 'ORBIT_CSRF_SECRET'].map(key => [key, randomBytes(32).toString('hex')]))), { flag: 'wx', mode: 0o600 })
  } catch (error) { if (error.code !== 'EEXIST') throw error }
  return JSON.parse(await readFile(file, 'utf8'))
}

export async function sourceStamp(cache = path.join(APP, 'build/dev-vm-cache')) {
  const views = (await readdir(path.join(APP, 'backend'), { recursive: true })).filter(name => /\.(s|sv)$/.test(name))
  let inputs = []
  try { inputs = JSON.parse(await readFile(path.join(cache, 'inputs.json'), 'utf8')).inputs || [] }
  catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error }
  const files = [...new Set([COMPILER, path.join(APP, 'sputnik.build.json'), path.join(APP, 'sputnik.lock'),
    ...views.map(name => path.join(APP, 'backend', name)),
    ...(await readdir(path.join(APP, 'db/migrations'))).map(name => path.join(APP, 'db/migrations', name)), ...inputs])]
  return Promise.all(files.map(async file => {
    try { const info = await stat(file); return `${file}:${info.mtimeMs}:${info.size}` }
    catch (error) { if (error.code === 'ENOENT') return `${file}:missing`; throw error }
  })).then(values => values.join('|'))
}
