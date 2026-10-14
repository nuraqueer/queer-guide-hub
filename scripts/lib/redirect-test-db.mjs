import { readFileSync, readdirSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';
export async function createRedirectTestDb() {
  const db = new PGlite();
  try {
    await db.exec(readFileSync('supabase/tests/fixtures/redirect-platform-bootstrap.sql', 'utf8'));
    const files = readdirSync('supabase/migrations');
    for (const suffix of [
      'redirect_link_workspace.sql',
      'redirect_link_policies.sql',
      'redirect_conversion_attribution.sql',
      'redirect_analytics_reports.sql',
      'redirect_password_throttle.sql',
      'redirect_link_management_api.sql',
      'redirect_workspace_api.sql',
      'redirect_presentations.sql',
      'redirect_preview_generation.sql',
    ]) {
      const name = files.find((file) => file.endsWith(suffix));
      if (!name) throw new Error('Missing migration ' + suffix);
      await db.exec(readFileSync('supabase/migrations/' + name, 'utf8'));
    }
    return db;
  } catch (error) {
    await db.close();
    throw error;
  }
}
