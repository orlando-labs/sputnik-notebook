import { defineConfig } from '@playwright/test'

const mode = process.env.ORBIT_E2E_MODE || 'production'
const native = process.env.ORBIT_E2E_NATIVE === '1'
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
if (!['development', 'production'].includes(mode)) throw new Error('Invalid ORBIT_E2E_MODE')

process.env.NOTEBOOK_WEB_PACKAGE_FIXTURE = '1'

const port = (native ? 4427 : 4417) + (mode === 'development' ? 1 : 0)
const baseURL = `http://127.0.0.1:${port}`
process.env.NOTEBOOK_WEB_TEST_CORE_ROOT ||= `${process.platform === 'darwin' ? '/private/tmp' : '/tmp'}/sputnik-web-e2e-${port}-${process.pid}`

export default defineConfig({
  testDir: './test',
  outputDir: `test-results/${mode}-${native ? 'native' : 'vm'}`,
  workers: 1,
  fullyParallel: false,
  timeout: 30_000,
  use: { baseURL, headless: true, trace: 'retain-on-failure', launchOptions: executablePath ? { executablePath } : undefined },
  webServer: {
    command: `${process.platform === 'win32' ? '' : 'exec '}node ../tools/smoke_server.mjs --mode ${mode} --port ${port}${native ? ' --native-backend' : ''}`,
    url: baseURL,
    timeout: 60_000,
    ...(process.platform !== 'win32' ? { gracefulShutdown: { signal: 'SIGTERM' as const, timeout: 10_000 } } : {}),
    reuseExistingServer: false,
  },
})
