import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
import { createRedirectTestDb } from './lib/redirect-test-db.mjs';
const sources = [
  'supabase/functions/_shared/redirect-api.ts',
  'supabase/functions/_shared/link-policy.ts',
  'supabase/functions/_shared/redirect-links.ts',
  'src/lib/redirects/importCsv.ts',
].map((path) =>
  readFileSync(path, 'utf8')
    .replace(/^import .*;\s*$/gm, '')
    .replace(/^export\s+/gm, ''),
);
const code = ts.transpileModule(sources.join('\n'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
}).outputText;
const { managedImportCsv, managedLinksCsv } = new Function(
  code + '\nreturn {managedImportCsv,managedLinksCsv};',
)();
const db = await createRedirectTestDb();
try {
  await db.exec('SET ROLE service_role; SET request.jwt.claims = \'{"role":"service_role"}\'');
  const keyOwner = (
    await db.query('INSERT INTO auth.users(id) VALUES(gen_random_uuid()) RETURNING id')
  ).rows[0].id;
  await db.query("INSERT INTO public.user_roles VALUES($1,'admin')", [keyOwner]);
  const token = (
    await db.query(
      "INSERT INTO public.redirect_api_tokens(name,token_hash,prefix,scopes,created_by,expires_at) VALUES('CSV fixture',repeat('a',64),'fixture',ARRAY['links:read','links:write'],$1,now()+interval '1 day') RETURNING id",
      [keyOwner],
    )
  ).rows[0].id;
  const folder = (
    await db.query(
      "INSERT INTO public.redirect_link_folders(name) VALUES('CSV folder') RETURNING id",
    )
  ).rows[0].id;
  const tag = (
    await db.query("INSERT INTO public.redirect_link_tags(name) VALUES('CSV tag') RETURNING id")
  ).rows[0].id;
  const mutate = async (operations) =>
    (
      await db.query('SELECT public.redirect_management_mutate($1::jsonb,$2::uuid) AS data', [
        JSON.stringify(operations),
        token,
      ])
    ).rows[0].data;
  const create = managedImportCsv(
    'slug,target,comment\nCSV-Fixture,https://example.com/events,"Community, \"\"welcome\"\"\nTogether"',
    'create',
  );
  const created = (await mutate(create))[0].link;
  assert.equal(created.comment, 'Community, "welcome"\nTogether');
  await mutate([
    {
      operation: 'update',
      id: created.id,
      data: { folderId: folder, tagIds: [tag], utmDefaults: { utm_source: 'poster' } },
    },
  ]);
  const changed = (
    await mutate(managedImportCsv('slug,target,isArchived\ncsv-fixture,/city,true', 'upsert'))
  )[0].link;
  assert.equal(changed.id, created.id);
  assert.equal(changed.target, '/city');
  assert.equal(changed.folderId, folder);
  assert.deepEqual(changed.tagIds, [tag]);
  assert.equal(changed.comment, created.comment);
  assert.equal(changed.isArchived, true);
  const updated = (
    await mutate(
      managedImportCsv(
        'id,isEnabled,expiresAt\n' + created.id + ',false,2030-01-01T00:00:00Z',
        'update',
      ),
    )
  )[0].link;
  assert.equal(updated.isEnabled, false);
  assert.equal(updated.target, '/city');
  assert.equal(updated.utmDefaults.utm_source, 'poster');
  const roundTrip = (await mutate(managedImportCsv(managedLinksCsv([updated]), 'update')))[0].link;
  for (const field of [
    'slug',
    'target',
    'statusCode',
    'isEnabled',
    'isArchived',
    'queryMode',
    'queryOverride',
    'utmDefaults',
    'expiresAt',
    'folderId',
    'tagIds',
    'comment',
  ])
    assert.deepEqual(roundTrip[field], updated[field], field);
  await assert.rejects(
    () =>
      mutate(managedImportCsv('slug,target\ncsv-rollback,/events\ncsv-fixture,/events', 'create')),
    (error) => error.code === '23505',
  );
  assert.equal(
    (
      await db.query(
        "SELECT count(*)::int AS count FROM public.redirects WHERE slug='csv-rollback'",
      )
    ).rows[0].count,
    0,
  );
  const actor = (
    await db.query('INSERT INTO auth.users(id) VALUES(gen_random_uuid()) RETURNING id')
  ).rows[0].id;
  await db.query("INSERT INTO public.user_roles VALUES($1,'admin')", [actor]);
  const domain = (
    await db.query(
      'SELECT public.redirect_domain_resource(\'create\',$1,p_values=>\'{"hostname":"root-csv.example.com"}\') AS d',
      [actor],
    )
  ).rows[0].d;
  await db.query(
    "UPDATE public.redirect_domains SET ownership_state='verified',verified_at=now(),verified_until=now()+interval '1 day',provider_id='fixture-csv-root',routing_provider_id='fixture-csv-root',routing_protocol=1,routing_seen_at=now() WHERE id=$1",
    [domain.id],
  );
  await db.query(
    "INSERT INTO public.redirect_domain_jobs(domain_id,zone_id,cname_target,requested_by,state,provider_status,ssl_status,checked_at) VALUES($1,repeat('a',32),'links.queer.guide',$2,'ready','active','active',now())",
    [domain.id, actor],
  );
  const root = (
    await mutate(
      managedImportCsv(
        managedLinksCsv([{ domainId: domain.id, isDomainRoot: true, target: '/events' }]),
        'upsert',
      ),
    )
  )[0].link;
  assert.equal(root.isDomainRoot, true);
  assert.equal(root.shortUrl, 'https://root-csv.example.com/');
  const rootRoundTrip = (await mutate(managedImportCsv(managedLinksCsv([root]), 'update')))[0].link;
  assert.equal(rootRoundTrip.id, root.id);
  assert.equal(rootRoundTrip.isDomainRoot, true);
  assert.equal(rootRoundTrip.shortUrl, root.shortUrl);
  const rootUpsert = (
    await mutate(
      managedImportCsv(
        managedLinksCsv([{ domainId: domain.id, isDomainRoot: true, target: '/city' }]),
        'upsert',
      ),
    )
  )[0].link;
  assert.equal(rootUpsert.id, root.id);
  assert.equal(rootUpsert.target, '/city');
  await db.query('UPDATE public.redirect_api_tokens SET revoked_at=now() WHERE id=$1', [token]);
  await assert.rejects(
    () => mutate(managedImportCsv('slug,target\ncsv-denied,/events', 'create')),
    (error) => error.code === '42501',
  );
  console.log(
    'Actual CSV source → migrated PostgreSQL: create/upsert/update, metadata preservation, domain-root upsert/roundtrip, full CSV round trip, atomic rollback and revoked-token rejection passed. No production requests or writes.',
  );
} finally {
  await db.close();
}
