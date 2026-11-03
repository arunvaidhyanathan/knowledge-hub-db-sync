import { expect, scenario } from '../../fixtures/kh-test';

scenario('projects.project.create', async ({ page, kh }) => {
  // Setup: not recorded.
  await page.goto('/projects');
  await expect(page.getByRole('heading', { name: 'Projects' })).toBeVisible();

  await kh.record(async () => {
    await kh.step('Open the New project form', async () => {
      await page.getByRole('button', { name: 'New project' }).click();
      await expect(page.getByRole('dialog', { name: 'New project' })).toBeVisible();
    });
    await kh.step('Enter the project name', async () => {
      await page.getByLabel('Project name').pressSequentially('Analytics Module', { delay: 40 });
    });
    await kh.step('Save the project', async () => {
      await page.getByRole('button', { name: 'Save' }).click();
      await expect(page.getByRole('row', { name: /Analytics Module/ })).toBeVisible();
    });
  });
});

scenario('projects.project.create.validation-error', async ({ page, kh }) => {
  await page.goto('/projects');
  await page.getByRole('button', { name: 'New project' }).click();

  await kh.record(async () => {
    await kh.step('Save without a name', async () => {
      await page.getByRole('button', { name: 'Save' }).click();
    });
    await kh.step('Read the required-field message', async () => {
      await expect(page.getByText('Project name is required')).toBeVisible();
    });
  });
});
