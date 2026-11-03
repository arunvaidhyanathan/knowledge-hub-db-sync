#!/usr/bin/env tsx
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { resolveImpact } from '../lib/impact';
import { publish } from '../lib/manifest';
import { KH_ROOT, loadRegistry } from '../lib/registry';
import { PERSONA_LOGINS } from '../personas/personas';

// Node built-in (>= 20.12): load knowledge-hub/.env written by Devin maintenance; child Playwright inherits it.
if (fs.existsSync(path.join(KH_ROOT, '.env'))) process.loadEnvFile(path.join(KH_ROOT, '.env'));

const OUT = path.join(KH_ROOT, 'out');
const RESULTS = path.join(OUT, 'test-results');

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    base: { type: 'string', default: 'origin/main' },
    ids: { type: 'string' },
    impacted: { type: 'boolean', default: false },
    all: { type: 'boolean', default: false },
    force: { type: 'boolean', default: false },
    'dry-run': { type: 'boolean', default: false },
    strict: { type: 'boolean', default: false },
  },
});

const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
function write(file: string, content: string) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
}

function listTaggedTests(): Set<string> {
  const out = execFileSync('npx', ['playwright', 'test', '--list', '--reporter=json', '--project=kh'], {
    cwd: KH_ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
  });
  const ids = new Set<string>();
  const walk = (suite: any) => {
    for (const spec of suite.specs ?? []) for (const t of spec.tags ?? []) {
      const tag = String(t).replace(/^@?/, '@');
      if (tag.startsWith('@kh:')) ids.add(tag.slice(4));
    }
    for (const c of suite.suites ?? []) walk(c);
  };
  for (const s of JSON.parse(out).suites ?? []) walk(s);
  return ids;
}

function validate(): number {
  const reg = loadRegistry(); // throws with zod errors if invalid
  const errors: string[] = [];
  for (const p of reg.personas) {
    if (!PERSONA_LOGINS[p.id]) errors.push(`persona ${p.id}: no login in personas/personas.ts`);
  }
  for (const s of reg.scenarios) {
    if (!fs.existsSync(path.join(KH_ROOT, s.spec))) errors.push(`${s.id}: spec file missing ${s.spec}`);
  }
  const implemented = listTaggedTests();
  for (const s of reg.scenarios.filter((x) => x.status === 'active')) {
    if (!implemented.has(s.id)) errors.push(`${s.id}: active in registry but no test calls scenario('${s.id}')`);
  }
  console.log(errors.length ? errors.join('\n') : `registry OK: ${reg.scenarios.length} scenarios, ${reg.modules.length} modules`);
  return errors.length ? 1 : 0;
}

function coverage(): number {
  const reg = loadRegistry();
  const rows: string[] = ['| Module | Feature | Capability | Persona | Scenario | Status |', '|---|---|---|---|---|---|'];
  let missing = 0;
  for (const m of reg.modules) for (const f of m.features) for (const cap of f.capabilities) {
    const personas = f.personaSensitive.includes(cap) ? f.personas : [null];
    for (const p of personas) {
      const match = reg.scenarios.find((s) => s.module === m.id && s.feature === f.id && s.capability === cap && (p === null || s.persona === p) && s.status !== 'deprecated');
      const status = match ? match.status : 'MISSING';
      if (!match) missing++;
      rows.push(`| ${m.id} | ${f.id} | ${cap} | ${p ?? 'any'} | ${match?.id ?? '-'} | ${status} |`);
    }
  }
  const md = `# Knowledge Hub coverage\n\nRequired cells: ${rows.length - 2}. Missing: ${missing}.\n\n${rows.join('\n')}\n`;
  write(path.join(OUT, 'coverage.md'), md);
  console.log(`coverage: ${missing} missing of ${rows.length - 2} required (out/coverage.md)`);
  return values.strict && missing > 0 ? 1 : 0;
}

function selectIds(): string[] | 'all' {
  const reg = loadRegistry();
  if (values.all) return 'all';
  if (values.ids) return values.ids.split(',').map((s) => s.trim()).filter(Boolean);
  if (values.impacted) {
    const impact = resolveImpact(reg, values.base!);
    write(path.join(OUT, 'impact.json'), JSON.stringify(impact, null, 2));
    return impact.runAll ? 'all' : impact.scenarios.map((s) => s.id);
  }
  throw new Error('run needs --all, --ids a,b or --impacted');
}

function run(): number {
  const ids = selectIds();
  if (ids !== 'all' && ids.length === 0) { console.log('no impacted scenarios'); return 0; }
  fs.rmSync(RESULTS, { recursive: true, force: true });
  const grep = ids === 'all' ? '@kh:' : `@kh:(?:${ids.map(esc).join('|')})(?![\\w.-])`;
  const res = spawnSync('npx', ['playwright', 'test', '--project=kh', '--grep', grep], { cwd: KH_ROOT, stdio: 'inherit' });
  return res.status ?? 1;
}

function impact(): number {
  const result = resolveImpact(loadRegistry(), values.base!);
  write(path.join(OUT, 'impact.json'), JSON.stringify(result, null, 2));
  const lines = [`# Knowledge Hub impact vs ${result.base}`, '', `Changed files: ${result.changedFiles.length}. Run all: ${result.runAll}.`, '', '| Scenario | Why |', '|---|---|',
    ...result.scenarios.map((s) => `| ${s.id} | ${s.reasons.join('; ')} |`)];
  write(path.join(OUT, 'impact.md'), lines.join('\n') + '\n');
  console.log(lines.join('\n'));
  return 0;
}

async function main(): Promise<number> {
  switch (positionals[0]) {
    case 'validate': return validate();
    case 'coverage': return coverage();
    case 'impact': return impact();
    case 'run': return run();
    case 'publish': {
      const report = await publish(loadRegistry(), RESULTS, { force: !!values.force, dryRun: !!values['dry-run'], keepHistory: 5 });
      write(path.join(OUT, 'publish.md'), report.map((r) => `- ${r}`).join('\n') + '\n');
      console.log(report.join('\n'));
      return 0;
    }
    default:
      console.log('usage: kh <validate|coverage|impact|run|publish> [--base ref] [--ids a,b|--impacted|--all] [--force] [--dry-run] [--strict]');
      return 2;
  }
}

main().then((code) => process.exit(code), (err) => { console.error(err instanceof Error ? err.message : err); process.exit(1); });
