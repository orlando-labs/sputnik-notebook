import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath } from 'node:url'

const origin = process.env.ORBIT_ORIGIN || 'http://127.0.0.1:3000'
const viteOrigin = process.env.VITE_ORIGIN || 'http://127.0.0.1:5173'
const dev = new URL(viteOrigin)

export default defineConfig({
  plugins: [vue()],
  base: '/',
  server: {
    host: dev.hostname,
    port: Number(dev.port || 5173),
    strictPort: true,
    origin: viteOrigin,
    cors: { origin },
    hmr: { host: dev.hostname, port: Number(dev.port || 5173) },
  },
  build: {
    manifest: true,
    assetsInlineLimit: 0,
    rolldownOptions: { input: fileURLToPath(new URL('./src/main.ts', import.meta.url)) },
  },
})
