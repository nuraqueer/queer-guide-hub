#!/usr/bin/env node
/** Bounded, resumable rollout for the unified Organisation content type. */
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) throw new Error('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.');
const db = createClient(url, key, { auth: { persistSession: false } });
const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  const value = i < 0 ? fallback : Number(process.argv[i + 1]);
  if (!Number.isInteger(value) || value < 1) throw new Error(`${name} must be a positive integer.`);
  return value;
};
let batchSize = Math.min(arg('--batch-size', 100), 500);
const maxBatches = arg('--max-batches', 10);
const remaining = async () => {
  const { count, error } = await db.from('venues').select('id', { count: 'exact', head: true }).is('organization_id', null).is('duplicate_of_id', null);
  if (error) throw error;
  return count;
};
console.log(`Unlinked canonical locations: ${await remaining()}`);
if (!process.argv.includes('--run')) {
  console.log('Read-only check. Pass --run to backfill; reruns resume from remaining locations.');
} else {
  for (let i = 0; i < maxBatches; i++) {
    let data;
    while (true) {
      const result = await db.rpc('cms_backfill_venue_organisations', { p_limit: batchSize });
      if (result.error?.code === '57014' && batchSize > 1) {
        batchSize = Math.max(1, Math.floor(batchSize / 2));
        console.log(`Database timeout; retrying the rolled-back batch with ${batchSize} locations.`);
        continue;
      }
      if (result.error) throw result.error;
      data = result.data;
      break;
    }
    console.log(`Batch ${i + 1}: linked ${data} locations`);
    if (data === 0) break;
  }
  const left = await remaining();
  console.log(`Remaining: ${left}. ${left === 0 ? 'Coverage complete; verify before releasing the CMS.' : 'Rerun to continue. Release the CMS after coverage reaches zero.'}`);
}
