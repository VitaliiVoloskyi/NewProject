import path from 'node:path'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), tailwindcss()],
  // The Cognito ids (COGNITO_*) come from the repo's .env locally and from the environment in
  // Docker and deploy builds. Only VITE_* and COGNITO_* variables reach the bundle.
  envDir: '..',
  envPrefix: ['VITE_', 'COGNITO_'],
  resolve: {
    alias: {
      '@': path.resolve(import.meta.dirname, './src'),
    },
  },
  server: {
    proxy: {
      '/api': process.env.VITE_API_PROXY ?? 'http://localhost:8000',
    },
  },
})
