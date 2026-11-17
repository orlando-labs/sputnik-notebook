// Offline registry for browser integration tests. Never used by backend/main.s.
import http from 'node:http'
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { createHash } from 'node:crypto'
export async function packageFixture(compiler) {
  const root = await mkdtemp(path.join(tmpdir(), 'notebook-web-registry-'))
  await writeFile(path.join(root, 'main.s'), 'package test.web_probe\nexport answer\ndef answer(): 42\n')
  const installOptions = [{ name: 'fixture-directory', type: 'path', env: 'WEB_FIXTURE_DIRECTORY', description: 'Directory for the package fixture.' }]
  await mkdir(path.join(root, 'notebook'))
  await writeFile(path.join(root, 'notebook/components.json'), JSON.stringify({ version: 1, components: [
    { id: 'probe_service', kind: 'service', title: 'Probe Service', detail: 'Test service', module: 'test.web_probe', entry: 'answer', properties: [{ id: 'port', kind: 'integer', title: 'Probe port', initial: '0', minimum: 0, maximum: 65535 }] },
    { id: 'probe_board', kind: 'board', title: 'Probe Board', detail: 'Test board', board: 'notebook/board.json' },
  ] }))
  await writeFile(path.join(root, 'notebook/board.json'), JSON.stringify({ format: 'sputnik-notebook', version: 2, title: 'Probe Board',
    sheets: [{ id: 'probe', title: 'Private controller', cells: [] }],
    boards: [{ id: 'probe', title: 'Probe Board', sheet: 'probe', columns: 1, rows: [{ id: 'intro' }], components: [
      { id: 'text', title: 'Probe text', kind: 'rich_text', row: 'intro', span: 12, text_mode: 'markdown', text_content: { source: 'Packaged board content' } },
    ] }],
  }))
  await writeFile(path.join(root, 'sputnik.build.yaml'), JSON.stringify({ schema: 'sputnik.build.v1', name: 'test/web-probe', version: '1.0.0', requires: { sputnik: '>=1.0.0 <2.0.0' }, files: ['main.s', 'notebook/components.json', 'notebook/board.json'], module_names: { 'main.s': 'test.web_probe' }, install_options: installOptions, notebook_packages: ['test/web-companion'] }))
  const archive = path.join(root, 'package.sputnikpkg')
  await promisify(execFile)(compiler, ['pkg', 'build', root, '--out', archive])
  const bytes = await readFile(archive), digest = 'sha256:' + createHash('sha256').update(bytes).digest('hex')
  const base = '/api/v1/namespaces/test/packages/web-probe'
  let origin
  const server = http.createServer((request, response) => {
    const route = request.url
    const artifact = { package_ref: 'test/web-probe', version: '1.0.0', variant: 'source', target: { os: 'any', arch: 'any', compute_backend: 'none' }, compatibility: { sputnik_requirement: '>=1.0.0 <2.0.0' }, native_mode: 'none', bundle: 'none', quarantined: false, install_options: installOptions, size: bytes.length, sha256: digest, url: origin + base + '/versions/1.0.0/artifacts/source/download' }
    const release = { package_ref: 'test/web-probe', version: '1.0.0', yanked: false, artifacts: [artifact] }
    if (route === base + '/versions/1.0.0/artifacts/source/download') { response.writeHead(200, { 'Content-Type': 'application/octet-stream', 'x-sputnik-sha256': digest, 'Content-Length': bytes.length }); response.end(bytes); return }
    let data
    if (route === base + '/index') data = { package_ref: 'test/web-probe', revision: 1, versions: [release], next_cursor: null }
    else if (route === base) data = { package_ref: 'test/web-probe' }
    else if (route === base + '/versions/1.0.0') data = release
    else if (route === base + '/versions/1.0.0/artifacts/source') data = artifact
    response.writeHead(data ? 200 : 404, { 'Content-Type': 'application/json' }); response.end(JSON.stringify(data || { error: { code: 'NOT_FOUND' } }))
  })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  origin = `http://127.0.0.1:${server.address().port}`
  return { origin, async close() { await new Promise(resolve => server.close(resolve)); await rm(root, { recursive: true, force: true }) } }
}
