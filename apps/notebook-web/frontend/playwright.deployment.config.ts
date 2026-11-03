import { defineConfig } from '@playwright/test'

const baseURL = process.env.NOTEBOOK_WEB_DEPLOY_ORIGIN
if (!baseURL || new URL(baseURL).protocol !== 'https:') throw new Error('Set NOTEBOOK_WEB_DEPLOY_ORIGIN to the selected HTTPS deployment.')
process.env.ORBIT_E2E_MODE = 'deployment'
process.env.ORBIT_E2E_NATIVE = '1'
export default defineConfig({
  testDir: './test',
  testMatch: ['public.spec.ts', 'deployment-mode.spec.ts'],
  outputDir: 'test-results/deployment',
  workers: 1,
  fullyParallel: false,
  timeout: 30_000,
  use: {
    baseURL, headless: true, trace: 'retain-on-failure',
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } : undefined,
  },
})
