import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const directory = join(process.cwd(), 'supabase/migrations');
const file = readdirSync(directory)
  .filter((name) => name.endsWith('_tag_image_state_row_locks.sql'))
  .sort()
  .at(-1)!;
const sql = readFileSync(join(directory, file), 'utf8').replace(/--[^\n]*/g, '');

describe('tag image state concurrency', () => {
  for (const name of ['tag_image_apply', 'tag_image_bump_miss']) {
    it(`${name} locks the row before reading state`, () => {
      const start = sql.indexOf(`create or replace function public.${name}(`);
      expect(start).toBeGreaterThanOrEqual(0);
      const body = sql.slice(start, sql.indexOf('$fn$;', start));
      expect(body).toMatch(
        /select coalesce\(enrichment_status,[\s\S]*?from public\.unified_tags where id = p_tag_id for update;/,
      );
      expect(body.indexOf('for update;')).toBeLessThan(body.indexOf('update public.unified_tags'));
    });
  }
});
