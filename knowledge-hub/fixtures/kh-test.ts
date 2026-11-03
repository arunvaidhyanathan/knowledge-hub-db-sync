import fs from 'node:fs';
import { test as base, expect, type Page } from '@playwright/test';
import { encodeGif } from '../lib/gif-encoder';
import { RECORDER_DEFAULTS, ScenarioRecorder } from '../lib/recorder';
import { getScenario } from '../lib/registry';
import type { Scenario } from '../registry/schema';
import { authFile } from '../personas/personas';

/** Fixed "now" so dates, relative times and greetings never change between runs. */
export const KH_FIXED_NOW = new Date('2026-01-15T14:30:00-05:00');

export interface KhApi {
  /** Everything inside this callback is recorded. Navigation and setup go before it. */
  record(body: () => Promise<void>): Promise<void>;
  /** A visible, captioned step. Use 2 to 6 per scenario. */
  step<T>(title: string, body: () => Promise<T>): Promise<T>;
  /** Hide volatile regions (build numbers, live clocks) from the GIF. */
  mask(selectors: string[]): Promise<void>;
}

export interface KhMeta {
  scenarioId: string;
  gif: string;
  poster: string;
  bytes: number;
  width: number;
  fps: number;
  durationMs: number;
  signature: string;
  steps: { title: string; atMs: number }[];
  appVersion: string;
  gitSha: string;
  recordedAt: string;
}

async function applyDeterminism(page: Page): Promise<void> {
  await page.clock.setFixedTime(KH_FIXED_NOW);
  await page.addInitScript(() => {
    const seed = { v: 42 };
    Math.random = () => ((seed.v = (seed.v * 16807) % 2147483647) - 1) / 2147483646;
  });
}

export const test = base.extend<{ kh: KhApi }>({
  kh: async ({ page }, use, testInfo) => {
    const tag = testInfo.tags.find((t) => t.startsWith('@kh:'));
    if (!tag) throw new Error('kh fixture used outside scenario(); register the scenario first');
    const scenario = getScenario(tag.slice(4));
    await applyDeterminism(page);
    const recorder = new ScenarioRecorder(page, testInfo, { ...RECORDER_DEFAULTS, maxSeconds: scenario.maxSeconds });

    await use({
      record: (body) => recorder.record(body),
      step: (title, body) => recorder.step(title, body),
      mask: async (selectors) => {
        await page.addStyleTag({ content: `${selectors.join(', ')} { visibility: hidden !important; }` });
      },
    });

    const rec = recorder.result();
    if (!rec || testInfo.status !== testInfo.expectedStatus) return;
    const narrative = JSON.stringify({ t: scenario.title, d: scenario.description, s: rec.steps.map((s) => s.title) });
    const asset = await encodeGif(rec, testInfo.outputPath('kh'), narrative);
    const meta: KhMeta = {
      scenarioId: scenario.id,
      gif: asset.gifPath,
      poster: asset.posterPath,
      bytes: asset.bytes,
      width: asset.width,
      fps: asset.fps,
      durationMs: asset.durationMs,
      signature: asset.signature,
      steps: rec.steps,
      appVersion: process.env.APP_VERSION ?? 'local',
      gitSha: process.env.GIT_SHA ?? 'local',
      recordedAt: new Date().toISOString(),
    };
    fs.writeFileSync(testInfo.outputPath('kh', 'kh-meta.json'), JSON.stringify(meta, null, 2));
    await testInfo.attach('kh-gif', { path: asset.gifPath, contentType: 'image/gif' });
  },
});

export { expect };

type ScenarioBody = (args: { page: Page; kh: KhApi; scenario: Scenario }) => Promise<void>;

/**
 * Declares a Knowledge Hub scenario. Title, persona and tags come from the registry,
 * so the registry stays the single place where scenarios are managed.
 */
export function scenario(id: string, body: ScenarioBody): void {
  const s = getScenario(id);
  test.describe(() => {
    test.use({ storageState: authFile(s.persona) });
    test(
      s.title,
      { tag: [`@kh:${s.id}`, `@module:${s.module}`, `@cap:${s.capability}`, `@persona:${s.persona}`] },
      async ({ page, kh }) => {
        await body({ page, kh, scenario: s });
      },
    );
  });
}
