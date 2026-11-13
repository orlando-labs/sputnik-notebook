import { expect, test } from '@playwright/test'

test('public-only deployment has no sign-in or private workspace authority', async ({ page }) => {
  test.skip(process.env.NOTEBOOK_WEB_TEST_PUBLIC_ONLY !== '1' && process.env.NOTEBOOK_WEB_DEPLOY_PUBLIC_ONLY !== '1', 'Explicit public-only server acceptance.')
  await page.goto('/')
  await expect(page.getByRole('button', { name: 'Continue with GitHub' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Open Getting started', exact: true })).toBeVisible()
  const response = await page.request.get('/api/session', { headers: { Accept: 'application/json' } })
  expect(response.status()).toBe(200)
  const snapshot = await response.json()
  expect(snapshot.sign_in_available).toBe(false)
  expect(snapshot.account).toBeNull()
  expect(snapshot.projects).toEqual([])
  const readiness = await page.request.get('/health/ready', { headers: { Accept: 'application/json' } })
  expect(readiness.status()).toBe(200)
  expect(await readiness.json()).toEqual({ ready: true })
  const csrf = (await page.context().cookies()).find(cookie => cookie.name === 'orbit-csrf')!.value
  const headers = { Origin: new URL(page.url()).origin, 'X-CSRF-Token': decodeURIComponent(csrf), Accept: 'application/json' }
  expect((await page.request.post('/auth/github', { headers })).status()).toBe(404)
  expect((await page.request.get('/auth/github/callback?code=unaccepted&state=unaccepted', { headers })).status()).toBe(404)
  expect((await page.request.get('/api/projects', { headers })).status()).toBe(401)
  expect((await page.request.post('/api/projects', { headers, data: { title: 'Private authority denied' } })).status()).toBe(401)
})
