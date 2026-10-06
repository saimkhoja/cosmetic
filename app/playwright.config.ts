import { defineConfig } from '@playwright/test';

// End-to-end tests run the production build against a Supabase project:
// the local stack (supabase/local/start.sh) by default, or your own via SIM_E2E_URL.
export default defineConfig({
  testDir: 'e2e',
  timeout: 180_000,
  expect: { timeout: 15_000 },
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: process.env.SIM_E2E_URL ?? 'http://localhost:4173',
    launchOptions: process.env.PW_CHROMIUM ? { executablePath: process.env.PW_CHROMIUM } : {},
    viewport: { width: 1366, height: 900 },
    trace: 'retain-on-failure',
  },
});
