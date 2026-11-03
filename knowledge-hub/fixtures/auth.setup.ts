import fs from 'node:fs';
import path from 'node:path';
import { test as setup, expect } from '@playwright/test';
import { authFile, PERSONA_LOGINS, personaIds } from '../personas/personas';

// Official Playwright pattern: authenticate once per persona in a setup project, reuse storageState.
// Adjust selectors/endpoint to the app's local-profile login. Never point this at a shared environment.
for (const id of personaIds()) {
  setup(`authenticate ${id}`, async ({ page }) => {
    const login = PERSONA_LOGINS[id];
    if (!login) throw new Error(`No seeded login for persona ${id}`);
    await page.goto('/login');
    await page.getByLabel('Username').fill(login.username);
    await page.getByLabel('Password').fill(process.env.KH_SEED_PASSWORD ?? '');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page.getByTestId('app-shell')).toBeVisible();
    fs.mkdirSync(path.dirname(authFile(id)), { recursive: true });
    await page.context().storageState({ path: authFile(id) });
  });
}
