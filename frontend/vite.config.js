import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

export default defineConfig({
  plugins: [vue()],
  base: '/static/frontend/',
  build: {
    manifest: true,
    outDir: path.resolve(__dirname, '../static/frontend'),
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    strictPort: true,
    origin: 'http://localhost:5173',
    proxy: {
      '/api': 'http://127.0.0.1:8000',
      '/admin': 'http://127.0.0.1:8000',
      '/media': 'http://127.0.0.1:8000',
    },
  },
})
