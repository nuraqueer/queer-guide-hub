import { readFileSync } from 'node:fs';
import { strict as assert } from 'node:assert';
import Stripe from 'stripe';
import ts from 'typescript';
import { webcrypto } from 'node:crypto';
import { createRedirectTestDb } from './lib/redirect-test-db.mjs';
const root = 'supabase/functions/';
function source(file) {
  let value = readFileSync(root + file, 'utf8');
  const tree = ts.createSourceFile(file, value, ts.ScriptTarget.Latest, true);
  for (const statement of [...tree.statements].reverse())
    if (ts.isImportDeclaration(statement))
      value = value.slice(0, statement.getStart(tree)) + value.slice(statement.end);
  return value.replace(/^export\s+/gm, '');
}
const db = await createRedirectTestDb();
try {
  await db.exec('SET ROLE service_role; SET request.jwt.claims=\'{"role":"service_role"}\';');
  const {
    rows: [link],
  } = await db.query(
    "INSERT INTO public.redirects(type,slug,target) VALUES('SHORT','stripe-fixture','https://example.com/donate') RETURNING id",
  );
  const {
    rows: [visit],
  } = await db.query(
    "SELECT public.record_redirect_visit($1,'/go/stripe-fixture',NULL,NULL,'fixture','CH','fixture',302,'a','https://example.com/donate') AS id",
    [link.id],
  );
  const user = '00000000-0000-4000-8000-000000000001';
  const metadata = { qg_click_id: visit.id, user_id: user };
  const records = [];
  const client = {
    rpc: async (name, args) => {
      assert.equal(name, 'record_redirect_conversion');
      records.push(args.p_event);
      try {
        const {
          rows: [result],
        } = await db.query('SELECT public.record_redirect_conversion($1::jsonb) AS data', [
          JSON.stringify(args.p_event),
        ]);
        return { data: result.data, error: null };
      } catch (error) {
        return { data: null, error: { message: error.message, code: error.code } };
      }
    },
    from: () => {
      const query = {
        select: () => query,
        eq: () => query,
        order: () => query,
        limit: () => query,
        single: async () => ({
          data: {
            user_id: user,
            email: 'fixture@example.com',
            currency: 'chf',
            redirect_click_id: visit.id,
          },
          error: null,
        }),
        update: () => ({ eq: async () => ({ error: null }) }),
        insert: async () => ({ error: null }),
      };
      return query;
    },
  };
  let handler;
  const code = ts.transpileModule(
    [
      '_shared/redirect-api.ts',
      '_shared/redirect-stripe.ts',
      'stripe-webhook/helpers.ts',
      'stripe-webhook/index.ts',
    ]
      .map(source)
      .join('\n'),
    { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } },
  ).outputText;
  const secret = 'whsec_offline_redirect_fixture';
  new Function('Deno', 'Stripe', 'getServiceClient', 'reportApiError', 'crypto', code)(
    {
      env: { get: (key) => (key === 'STRIPE_WEBHOOK_SECRET' ? secret : 'sk_test_offline_fixture') },
      serve: (fn) => {
        handler = fn;
      },
    },
    Stripe,
    () => client,
    () => {},
    webcrypto,
  );
  const created = Math.floor(Date.now() / 1000) + 2;
  const checkout = {
    id: 'cs_fixture',
    payment_status: 'paid',
    amount_total: 4990,
    currency: 'chf',
    customer: 'cus_fixture',
    metadata,
  };
  const call = async (type, object, eventId = 'evt_fixture', valid = true) => {
    const payload = JSON.stringify({
      id: eventId,
      object: 'event',
      type,
      created,
      data: { object },
      livemode: false,
    });
    const signature = Stripe.webhooks.generateTestHeaderString({
      payload,
      secret: valid ? secret : 'wrong_secret',
    });
    return handler(
      new Request('https://fixture.supabase.co/functions/v1/stripe-webhook', {
        method: 'POST',
        headers: { 'stripe-signature': signature },
        body: payload,
      }),
    );
  };
  const oldConsoleError = console.error;
  console.error = () => {};
  try {
    assert.equal(
      (await call('checkout.session.completed', checkout, 'evt_invalid', false)).status,
      400,
    );
  } finally {
    console.error = oldConsoleError;
  }
  assert.equal(records.length, 0, 'Invalid signature reached tracking');
  assert.equal(
    (
      await call(
        'checkout.session.completed',
        { ...checkout, payment_status: 'unpaid' },
        'evt_unpaid',
      )
    ).status,
    200,
  );
  assert.equal(records.length, 0, 'Unpaid checkout credited revenue');
  assert.equal((await call('checkout.session.completed', checkout)).status, 200);
  assert.equal((await call('checkout.session.completed', checkout)).status, 200);
  assert.equal(
    (
      await call(
        'invoice.paid',
        {
          id: 'in_fixture',
          subscription: 'sub_fixture',
          customer: 'cus_fixture',
          currency: 'chf',
          amount_paid: 500,
          billing_reason: 'subscription_cycle',
        },
        'evt_renewal',
      )
    ).status,
    200,
  );
  const {
    rows: [totals],
  } = await db.query(
    'SELECT count(*)::int AS events,sum(amount)::text AS amount FROM public.redirect_link_conversions',
  );
  assert.equal(totals.events, 2, 'Webhook retry inflated conversion counts');
  assert.equal(Number(totals.amount), 54.9, 'Stripe minor units were misinterpreted');
  const {
    rows: [performance],
  } = await db.query('SELECT * FROM public.redirect_variant_performance($1)', [link.id]);
  assert.equal(Number(performance.sales), 2, 'Verified sales did not reach experiment metrics');
  console.log(
    'Offline Stripe→redirect conversions: real signature verification, paid-only revenue, retry deduplication, renewal attribution and A/B metrics passed.',
  );
} finally {
  await db.close();
}
