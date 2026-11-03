import fs from 'node:fs';
import path from 'node:path';
import type { KhMeta } from '../fixtures/kh-test';
import type { Registry } from '../registry/schema';
import { createClient, getJson, putFile, putJson, storeConfigFromEnv } from './s3-publisher';

export interface ManifestEntry {
  id: string;
  module: string;
  moduleName: string;
  feature: string;
  capability: string;
  persona: string;
  audience: string[];
  title: string;
  description: string;
  alt: string;
  steps: { title: string; atMs: number }[];
  gifUrl: string;
  posterUrl: string;
  bytes: number;
  width: number;
  durationMs: number;
  signature: string;
  appVersion: string;
  gitSha: string;
  updatedAt: string;
  status: 'active' | 'deprecated';
  order: number;
  history: { signature: string; gifUrl: string; updatedAt: string }[];
}

export interface Manifest {
  schemaVersion: 1;
  generatedAt: string;
  entries: Record<string, ManifestEntry>;
}

export function collectMetas(resultsDir: string): KhMeta[] {
  const found: KhMeta[] = [];
  const walk = (dir: string) => {
    if (!fs.existsSync(dir)) return;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name === 'kh-meta.json') found.push(JSON.parse(fs.readFileSync(p, 'utf8')));
    }
  };
  walk(resultsDir);
  // If a scenario passed on retry, keep the latest recording.
  const byId = new Map<string, KhMeta>();
  for (const m of found.sort((a, b) => a.recordedAt.localeCompare(b.recordedAt))) byId.set(m.scenarioId, m);
  return [...byId.values()];
}

export async function publish(registry: Registry, resultsDir: string, opts: { force: boolean; dryRun: boolean; keepHistory: number }) {
  const cfg = storeConfigFromEnv();
  const client = createClient(cfg);
  const manifestKey = `${cfg.prefix}/manifest.json`;
  const manifest: Manifest = (await getJson<Manifest>(client, cfg, manifestKey)) ?? { schemaVersion: 1, generatedAt: '', entries: {} };
  const report: string[] = [];

  for (const meta of collectMetas(resultsDir)) {
    const s = registry.scenarios.find((x) => x.id === meta.scenarioId);
    if (!s) { report.push(`SKIP ${meta.scenarioId}: not in registry`); continue; }
    const prev = manifest.entries[s.id];
    if (prev && prev.signature === meta.signature && !opts.force) { report.push(`UNCHANGED ${s.id}`); continue; }

    const base = `${cfg.prefix}/scenarios/${s.module}/${s.id}/${meta.signature}`;
    const gifUrl = opts.dryRun ? `${cfg.publicBaseUrl}/${base}.gif` : await putFile(client, cfg, `${base}.gif`, meta.gif, 'image/gif', true);
    const posterUrl = opts.dryRun ? `${cfg.publicBaseUrl}/${base}.jpg` : await putFile(client, cfg, `${base}.jpg`, meta.poster, 'image/jpeg', true);
    const mod = registry.modules.find((m) => m.id === s.module)!;
    const now = new Date().toISOString();
    manifest.entries[s.id] = {
      id: s.id, module: s.module, moduleName: mod.name, feature: s.feature, capability: s.capability,
      persona: s.persona, audience: s.audience, title: s.title, description: s.description,
      alt: `${s.title}. ${meta.steps.map((x, i) => `Step ${i + 1}: ${x.title}.`).join(' ')}`,
      steps: meta.steps, gifUrl, posterUrl, bytes: meta.bytes, width: meta.width, durationMs: meta.durationMs,
      signature: meta.signature, appVersion: meta.appVersion, gitSha: meta.gitSha, updatedAt: now,
      status: 'active', order: s.order,
      history: [
        ...(prev && prev.signature !== meta.signature ? [{ signature: prev.signature, gifUrl: prev.gifUrl, updatedAt: prev.updatedAt }] : []),
        ...(prev?.history ?? []),
      ].slice(0, opts.keepHistory),
    };
    report.push(`${prev ? 'UPDATED' : 'ADDED'} ${s.id} (${(meta.bytes / 1024).toFixed(0)} KB, ${(meta.durationMs / 1000).toFixed(1)}s)`);
  }

  for (const s of registry.scenarios) {
    const e = manifest.entries[s.id];
    if (e && s.status === 'deprecated' && e.status !== 'deprecated') { e.status = 'deprecated'; report.push(`DEPRECATED ${s.id}`); }
  }

  const changed = report.some((r) => /^(ADDED|UPDATED|DEPRECATED) /.test(r));
  manifest.generatedAt = new Date().toISOString();
  if (changed && !opts.dryRun) {
    await putJson(client, cfg, `${cfg.prefix}/manifests/history/${manifest.generatedAt.replace(/[:.]/g, '-')}.json`, manifest);
    await putJson(client, cfg, manifestKey, manifest);
  }
  return report;
}
