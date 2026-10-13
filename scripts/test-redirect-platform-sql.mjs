import { readFileSync } from 'node:fs';
import { createRedirectTestDb } from './lib/redirect-test-db.mjs';

// Isolated PostgreSQL only; never the production project.
const db = await createRedirectTestDb();
try {
  await db.exec(readFileSync('supabase/tests/redirect_link_workspace.sql', 'utf8'));
  await db.exec(readFileSync('supabase/tests/redirect_link_policies.sql', 'utf8'));
  await db.exec(readFileSync('supabase/tests/redirect_conversion_attribution.sql', 'utf8'));
  console.log(
    'Redirect platform SQL: policies, atomic creation, quotas, expiry, variant metrics and conversion attribution passed.',
  );
} finally {
  await db.close();
}
