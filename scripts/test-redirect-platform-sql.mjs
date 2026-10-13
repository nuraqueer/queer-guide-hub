import { readFileSync, readdirSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

// Isolated PostgreSQL, never the production project. auth.* models signed JWT
// claims so policy tests cover authorization without inventing user sessions.
const db = new PGlite();
try {
  await db.exec(readFileSync('supabase/tests/fixtures/redirect-platform-bootstrap.sql', 'utf8'));
  const files = readdirSync('supabase/migrations');
  for (const suffix of ['redirect_link_workspace.sql', 'redirect_link_policies.sql']) {
    const file = files.find((name) => name.endsWith(suffix));
    if (!file) throw new Error('Missing migration ' + suffix);
    await db.exec(readFileSync('supabase/migrations/' + file, 'utf8'));
  }
  await db.exec(readFileSync('supabase/tests/redirect_link_workspace.sql', 'utf8'));
  await db.exec(readFileSync('supabase/tests/redirect_link_policies.sql', 'utf8'));
  console.log(
    'Redirect platform SQL: policies, atomic creation, quotas, expiry and variant metrics passed.',
  );
} finally {
  await db.close();
}
