import { z } from 'zod';

export const Capability = z.enum([
  'nav', 'auth', 'list', 'view', 'create', 'edit', 'delete', 'search', 'filter', 'sort',
  'bulk', 'import', 'export', 'upload', 'workflow', 'rbac', 'validation', 'empty',
  'notify', 'audit', 'settings', 'help',
]);
export type Capability = z.infer<typeof Capability>;

const Id = z.string().regex(/^[a-z0-9]+(\.[a-z0-9-]+)+$/, 'ids look like module.feature.capability[.variant]');

export const Feature = z.object({
  id: z.string().regex(/^[a-z0-9-]+$/),
  name: z.string(),
  routes: z.array(z.string()).default([]),
  capabilities: z.array(Capability).min(1),
  personas: z.array(z.string()).min(1),
  /** Capabilities whose UI differs by persona; one scenario per persona is required for these. */
  personaSensitive: z.array(Capability).default([]),
});

export const Module = z.object({
  id: z.string().regex(/^[a-z0-9-]+$/),
  name: z.string(),
  owner: z.string(),
  frontendPaths: z.array(z.string()).default([]),
  backendPaths: z.array(z.string()).default([]),
  dbTables: z.array(z.string()).default([]),
  features: z.array(Feature).min(1),
});

export const Scenario = z.object({
  id: Id,
  title: z.string().min(5).max(80),
  description: z.string().min(10).max(300),
  module: z.string(),
  feature: z.string(),
  capability: Capability,
  persona: z.string(),
  owner: z.string(),
  spec: z.string().regex(/\.kh\.spec\.ts$/),
  routes: z.array(z.string()).default([]),
  impactGlobs: z.array(z.string()).default([]),
  dataDeps: z.array(z.string()).default([]),
  maxSeconds: z.number().min(3).max(12).default(10),
  status: z.enum(['active', 'draft', 'deprecated', 'waived']).default('active'),
  waiverReason: z.string().optional(),
  audience: z.array(z.enum(['end-user', 'admin', 'support'])).default(['end-user']),
  sinceRelease: z.string().optional(),
  order: z.number().int().default(100),
});

export const Registry = z
  .object({
    version: z.literal(1),
    globalImpact: z.array(z.string()),
    personas: z.array(z.object({ id: z.string(), label: z.string() })).min(1),
    modules: z.array(Module),
    scenarios: z.array(Scenario),
  })
  .superRefine((r, ctx) => {
    const seen = new Set<string>();
    const personas = new Set(r.personas.map((p) => p.id));
    const features = new Map<string, Set<string>>(
      r.modules.map((m) => [m.id, new Set(m.features.map((f) => f.id))]),
    );
    for (const s of r.scenarios) {
      if (seen.has(s.id)) ctx.addIssue({ code: 'custom', message: `duplicate scenario id ${s.id}` });
      seen.add(s.id);
      if (!personas.has(s.persona)) ctx.addIssue({ code: 'custom', message: `${s.id}: unknown persona ${s.persona}` });
      if (!features.get(s.module)?.has(s.feature)) {
        ctx.addIssue({ code: 'custom', message: `${s.id}: unknown module/feature ${s.module}/${s.feature}` });
      }
      if (s.status === 'waived' && !s.waiverReason) {
        ctx.addIssue({ code: 'custom', message: `${s.id}: waived scenarios need waiverReason` });
      }
    }
  });

export type Registry = z.infer<typeof Registry>;
export type Scenario = z.infer<typeof Scenario>;
export type Module = z.infer<typeof Module>;
