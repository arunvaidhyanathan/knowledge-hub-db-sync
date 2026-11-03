import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import picomatch from 'picomatch';
import type { Registry, Scenario } from '../registry/schema';
import { KH_ROOT } from './registry';

const REPO_ROOT = path.resolve(KH_ROOT, '..');

export interface ImpactResult {
  base: string;
  changedFiles: string[];
  runAll: boolean;
  scenarios: { id: string; reasons: string[] }[];
}

function git(args: string[]): string {
  return execFileSync('git', args, { cwd: REPO_ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
}

export function changedFiles(base: string): string[] {
  const committed = git(['diff', '--name-only', `${base}...HEAD`]);
  const working = git(['diff', '--name-only', 'HEAD']);
  const untracked = git(['ls-files', '--others', '--exclude-standard']);
  return [...new Set([...committed.split('\n'), ...working.split('\n'), ...untracked.split('\n')].map((s) => s.trim()).filter(Boolean))].sort();
}

function diffText(base: string, pathspec: string): string {
  return git(['diff', '-U0', `${base}...HEAD`, '--', pathspec]);
}

const TESTID_RE = /data-testid=\{?["'`]([\w.:-]+)["'`]/g;

function changedTestIds(base: string): Set<string> {
  const ids = new Set<string>();
  for (const line of diffText(base, 'frontend/').split('\n')) {
    if (!/^[+-]/.test(line) || /^(\+\+\+|---)/.test(line)) continue;
    for (const m of line.matchAll(TESTID_RE)) ids.add(m[1]);
  }
  return ids;
}

/** Official Playwright --only-changed: test files changed vs base, plus test files importing changed files. */
function playwrightOnlyChanged(base: string): Set<string> {
  const ids = new Set<string>();
  try {
    const out = execFileSync('npx', ['playwright', 'test', '--list', `--only-changed=${base}`, '--reporter=json', '--project=kh'], {
      cwd: KH_ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024,
    });
    const walk = (suite: any) => {
      for (const spec of suite.specs ?? []) {
        for (const t of spec.tags ?? []) {
          const tag = String(t).replace(/^@?/, '@');
          if (tag.startsWith('@kh:')) ids.add(tag.slice(4));
        }
      }
      for (const child of suite.suites ?? []) walk(child);
    };
    for (const s of JSON.parse(out).suites ?? []) walk(s);
  } catch {
    // "No tests found" exits non-zero; treat as no matches.
  }
  return ids;
}

export function resolveImpact(registry: Registry, base: string): ImpactResult {
  const files = changedFiles(base);
  const active = registry.scenarios.filter((s) => s.status === 'active');
  const hits = new Map<string, Set<string>>();
  const hit = (s: Scenario, reason: string) => {
    if (!hits.has(s.id)) hits.set(s.id, new Set());
    hits.get(s.id)!.add(reason);
  };

  // R1: shared surfaces -> everything
  const isGlobal = picomatch(registry.globalImpact, { dot: true });
  const globalFiles = files.filter((f) => isGlobal(f));
  if (globalFiles.length > 0) {
    for (const s of active) hit(s, `global: ${globalFiles.slice(0, 3).join(', ')}${globalFiles.length > 3 ? ' ...' : ''}`);
    return { base, changedFiles: files, runAll: true, scenarios: [...hits].map(([id, r]) => ({ id, reasons: [...r] })) };
  }

  for (const s of active) {
    // R2: scenario-specific globs
    if (s.impactGlobs.length) {
      const m = picomatch(s.impactGlobs, { dot: true });
      const f = files.find((x) => m(x));
      if (f) hit(s, `impactGlobs: ${f}`);
    }
    // R3: module front/back-end paths
    const mod = registry.modules.find((x) => x.id === s.module)!;
    const modGlobs = [...mod.frontendPaths, ...mod.backendPaths];
    if (modGlobs.length) {
      const m = picomatch(modGlobs, { dot: true });
      const f = files.find((x) => m(x));
      if (f) hit(s, `module ${mod.id}: ${f}`);
    }
    // R4: the scenario's own spec changed
    if (files.includes(path.posix.join('knowledge-hub', s.spec))) hit(s, 'spec changed');
  }

  // R5: data-testid added/removed/changed in the frontend diff, referenced by a spec
  const testIds = changedTestIds(base);
  if (testIds.size) {
    for (const s of active) {
      const specPath = path.join(KH_ROOT, s.spec);
      if (!fs.existsSync(specPath)) continue;
      const src = fs.readFileSync(specPath, 'utf8');
      for (const id of testIds) if (src.includes(`'${id}'`) || src.includes(`"${id}"`)) hit(s, `testid ${id}`);
    }
  }

  // R6: Playwright import graph (helpers, page objects)
  for (const id of playwrightOnlyChanged(base)) {
    const s = active.find((x) => x.id === id);
    if (s) hit(s, 'playwright --only-changed');
  }

  // R7: database artifacts (see db/ spec): master data files and schema changes naming a table
  const masterChanged = files.filter((f) => f.startsWith('db/master/') && f.endsWith('.csv')).map((f) => path.basename(f, '.csv'));
  const schemaDiff = files.some((f) => f.startsWith('db/schema/')) ? diffText(base, 'db/schema/') : '';
  for (const s of active) {
    const mod = registry.modules.find((x) => x.id === s.module)!;
    const tables = new Set([...s.dataDeps, ...mod.dbTables]);
    for (const t of tables) {
      if (masterChanged.includes(t)) hit(s, `master data ${t}`);
      const bare = t.split('.').pop()!;
      if (schemaDiff && new RegExp(`\\b${bare}\\b`).test(schemaDiff)) hit(s, `schema change mentions ${t}`);
    }
  }

  return {
    base,
    changedFiles: files,
    runAll: false,
    scenarios: [...hits].map(([id, r]) => ({ id, reasons: [...r] })).sort((a, b) => a.id.localeCompare(b.id)),
  };
}
