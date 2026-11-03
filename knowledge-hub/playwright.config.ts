import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  outputDir: 'out/test-results',
  fullyParallel: true,
  workers: Number(process.env.KH_WORKERS ?? 2),
  retries: 1,
  timeout: 60_000, // whole test incl. GIF encode; the recorded window has its own 3-10s budget
  forbidOnly: !!process.env.CI,
  reporter: [['list'], ['json', { outputFile: 'out/results.json' }]],
  use: {
    baseURL: process.env.APP_BASE_URL ?? 'http://localhost:3000',
    locale: 'en-US',
    timezoneId: 'America/New_York',
    colorScheme: 'light',
    video: 'off',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'setup', testMatch: /fixtures\/auth\.setup\.ts$/ },
    {
      name: 'kh',
      testMatch: /scenarios\/.*\.kh\.spec\.ts$/,
      dependencies: ['setup'],
      use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1 },
    },
  ],
  // The app under test is started outside Playwright and reached via APP_BASE_URL.
});
