import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import YAML from 'yaml';
import { Registry, type Scenario } from '../registry/schema';

export const KH_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REG_DIR = path.join(KH_ROOT, 'registry');

function readYaml(file: string): any {
  return YAML.parse(fs.readFileSync(file, 'utf8')) ?? {};
}

function readDir(dir: string): any[] {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith('.yaml'))
    .sort()
    .map((f) => readYaml(path.join(dir, f)));
}

let cached: Registry | undefined;

/** Merges registry/registry.yaml + registry/modules/*.yaml + registry/scenarios/*.yaml and validates. */
export function loadRegistry(): Registry {
  if (cached) return cached;
  const root = readYaml(path.join(REG_DIR, 'registry.yaml'));
  const modules = readDir(path.join(REG_DIR, 'modules')).flatMap((d) => d.modules ?? []);
  const scenarios = readDir(path.join(REG_DIR, 'scenarios')).flatMap((d) => d.scenarios ?? []);
  cached = Registry.parse({ ...root, modules, scenarios });
  return cached;
}

export function getScenario(id: string): Scenario {
  const s = loadRegistry().scenarios.find((x) => x.id === id);
  if (!s) throw new Error(`Scenario "${id}" is not registered in knowledge-hub/registry/scenarios/*.yaml`);
  return s;
}

export function activeScenarios(): Scenario[] {
  return loadRegistry().scenarios.filter((s) => s.status === 'active');
}
