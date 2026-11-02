import { test, expect } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { parseDocumentJSON } from '../src/document-json'
// Test-only fixture authoring through the same native bridge as the Swift app.
// @ts-expect-error Node test tooling is an ESM module without declaration files.
import { createParityBook } from '../../tools/parity_fixture.mjs'

test('native palette → web edit/export → native reopen preserves every authored kind and bundled byte', async ({ page }) => {
  const root = await mkdtemp('/private/tmp/notebook-parity-')
  try {
    const original = path.join(root, 'Original.sputnikbook'), { tools, document, probe } = await createParityBook(original)
    const archive = execFileSync('python3', ['-c', 'import sys,zipfile,io,pathlib\np=pathlib.Path(sys.argv[1]); b=io.BytesIO()\nwith zipfile.ZipFile(b,"w",zipfile.ZIP_DEFLATED) as z:\n for f in sorted(p.rglob("*")):\n  if f.is_file(): z.write(f,"Original.sputnikbook/"+str(f.relative_to(p)))\nsys.stdout.buffer.write(b.getvalue())', original])
    await page.goto('/'); await page.getByRole('button', { name: 'Continue with GitHub' }).click(); await page.getByRole('button', { name: 'Sign in as Alice' }).click(); await expect(page.getByTestId('account-name')).toHaveText('Alice')
    await page.getByRole('button', { name: 'Import Notebook…', exact: true }).click(); await page.getByLabel('Notebook ZIP', { exact: true }).setInputFiles({ name: 'Original.sputnikbook.zip', mimeType: 'application/zip', buffer: archive }); await page.getByRole('button', { name: 'Import as new notebook', exact: true }).click()
    await expect(page.getByLabel('Code cell 1', { exact: true })).toHaveValue('value = 43\nvalue\n')
    const id = page.url().split('/').at(-1)!, api = (suffix: string) => `/api/projects/${id}${suffix}`
    await page.getByRole('navigation', { name: 'Boards', exact: true }).getByRole('button', { name: 'Palette', exact: true }).click()
    await expect(page.locator('[data-board-component="status"]')).toContainText('Ready')
    await expect(page.locator('[data-board-component="artifacts"]')).toContainText('Return records with path')
    await expect(page.locator('[data-board-component="task_monitor"]')).toContainText('No task telemetry loaded')
    expect((await (await page.request.get(api('/execution'))).json()).runs).toEqual([])
    expect((await (await page.request.get(api('/environments'))).json()).environments).toEqual([])
    for (const scheme of ['light', 'dark'] as const) for (const width of [1280, 375]) { await page.emulateMedia({ colorScheme: scheme }); await page.setViewportSize({ width, height: 1000 }); await page.evaluate(() => scrollTo(0, 0)); expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true); await page.screenshot({ path: `../build/parity-${scheme}-${width}-${process.env.ORBIT_E2E_MODE || 'production'}-${process.env.ORBIT_E2E_NATIVE === '1' ? 'native' : 'vm'}.png` }) }
    await page.getByRole('navigation', { name: 'Sheets', exact: true }).getByRole('button', { name: /^Main/ }).click(); await page.getByLabel('Code cell 1', { exact: true }).fill('value = 44\nvalue\n'); await page.getByRole('button', { name: 'Save notebook', exact: true }).click(); await expect(page.getByTestId('notebook-save-status')).toHaveText('All changes saved')
    const saved = (await (await page.request.get(api('/notebook'))).json()).notebook
    expect(saved.document).toContain('9223372036854775806'); expect(saved.document).toContain('9007199254740993')
    const waiting = page.waitForEvent('download'); await page.getByRole('button', { name: 'Export saved…', exact: true }).click(); const file = (await (await waiting).path())!
    const reopened = path.join(root, 'reopened'); execFileSync('python3', ['-c', 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])', file, reopened])
    const folder = (await readdir(reopened)).find(name => name.endsWith('.sputnikbook'))!; const book = path.join(reopened, folder)
    expect(await readFile(path.join(book, '.hidden/bytes.bin'))).toEqual(await readFile(path.join(original, '.hidden/bytes.bin')))
    expect(await readFile(path.join(book, 'modules/jobs.s'))).toEqual(await readFile(path.join(original, 'modules/jobs.s')))
    const after = parseDocumentJSON(await readFile(path.join(book, 'project.json'), 'utf8')) as any
    const expectedWeb = parseDocumentJSON(document) as any; expectedWeb.sheets[0].cells[0].source = 'value = 44\nvalue\n'
    expect(after).toEqual(expectedWeb)
    expect(after.boards[0].components.map((item: any) => item.id)).toEqual(tools.map((item: any) => item.id))
    const nativeOutput = path.join(root, 'final-native-export.json'); execFileSync(probe, [book, 'value = 45\nvalue\n', nativeOutput])
    const final = parseDocumentJSON(JSON.parse(await readFile(nativeOutput, 'utf8')).document) as any
    const expectedNative = parseDocumentJSON(document) as any; expectedNative.sheets[0].cells[0].source = 'value = 45\nvalue\n'
    expect(final).toEqual(expectedNative); expect(await readFile(path.join(book, 'project.json'), 'utf8')).toContain('9223372036854775806')
    expect((await (await page.request.get(api('/execution'))).json()).runs).toEqual([])
    await writeFile('../build/parity-transfer-summary.json', JSON.stringify({ tools: tools.length, component_ids: tools.map((item: any) => item.id), known_unavailable: [], native_bridge_roundtrip: true, swift_ui_automated: false, execution_inert: true, bundled_bytes_preserved: true }, null, 2))
  } finally { await rm(root, { recursive: true, force: true }) }
})
