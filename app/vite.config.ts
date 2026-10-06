import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

// The app shell is cached by a service worker so the till opens and sells without internet.
export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['icon.svg'],
      manifest: {
        name: 'SIM – Smart Invoice Management',
        short_name: 'SIM',
        description: 'Cosmetics store and till: stock, deliveries, invoices and reports.',
        theme_color: '#06328F',
        background_color: '#F2F5FB',
        display: 'standalone',
        start_url: '/',
        icons: [{ src: 'icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any maskable' }],
      },
      workbox: {
        navigateFallback: '/index.html',
        globPatterns: ['**/*.{js,css,html,svg,woff2}'],
        runtimeCaching: [{
          urlPattern: /^https:\/\/fonts\.(googleapis|gstatic)\.com\/.*/,
          handler: 'StaleWhileRevalidate',
          options: { cacheName: 'fonts' },
        }],
      },
    }),
  ],
  server: { port: 5173 },
  test: { environment: 'node', include: ['src/**/*.test.ts'] },
} as never);
