import path from 'node:path';
import { KH_ROOT, loadRegistry } from '../lib/registry';

/** Seeded login per persona. Usernames must exist in the app under test; the shared password comes from a Devin secret. */
export const PERSONA_LOGINS: Record<string, { username: string }> = {
  analyst: { username: 'kh.analyst' },
  manager: { username: 'kh.manager' },
  admin: { username: 'kh.admin' },
};

export function authFile(personaId: string): string {
  return path.join(KH_ROOT, 'playwright', '.auth', `${personaId}.json`);
}

export function personaIds(): string[] {
  return loadRegistry().personas.map((p) => p.id);
}
