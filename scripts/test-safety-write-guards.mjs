import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

// Disposable database only. Minimal geography models the unchanged predicate
// inputs; real migration DDL and actual PostgreSQL trigger ordering are tested.
const db = new PGlite();
const migration = readdirSync('supabase/migrations').find((file) =>
  file.endsWith('_entity_safety_flag_write_guards.sql'),
);
assert.ok(migration);
try {
  await db.exec(`
    CREATE TABLE geo_country_profiles(place_id uuid primary key, lgbti_criminalization jsonb);
    CREATE TABLE geo_places(id uuid primary key, place_type text, country_id uuid);
    CREATE TABLE venues(id integer primary key, country_id uuid, city_id uuid,
      category text, address text, safety_gated boolean NOT NULL DEFAULT false,
      duplicate_of_id integer, note text);
    CREATE TABLE organizations(LIKE venues INCLUDING ALL);
    INSERT INTO geo_country_profiles VALUES
      ('10000000-0000-4000-8000-000000000001','{"legal":true}'),
      ('10000000-0000-4000-8000-000000000002','{"legal":false}');
    INSERT INTO geo_places VALUES
      ('20000000-0000-4000-8000-000000000002','city','10000000-0000-4000-8000-000000000002');
    CREATE FUNCTION location_is_high_risk(p_country_id uuid,p_city_id uuid) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT EXISTS(SELECT 1 FROM geo_country_profiles cp
        WHERE cp.place_id=coalesce(p_country_id,(SELECT country_id FROM geo_places
          WHERE id=p_city_id AND place_type='city'))
        AND cp.lgbti_criminalization->>'legal'='false');
    $$;
    CREATE FUNCTION venue_is_safety_gated(p_country_id uuid,p_city_id uuid,p_category text)
    RETURNS boolean LANGUAGE sql STABLE AS $$
      SELECT public.location_is_high_risk(p_country_id,p_city_id)
        OR coalesce(p_category='cruising',false);
    $$;
    CREATE FUNCTION set_entity_safety_gated() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN NEW.safety_gated:=public.location_is_high_risk(NEW.country_id,NEW.city_id);
        RETURN NEW; END;
    $$;
    CREATE FUNCTION set_venue_safety_gated() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN NEW.safety_gated:=public.venue_is_safety_gated(NEW.country_id,NEW.city_id,NEW.category);
        RETURN NEW; END;
    $$;
    CREATE FUNCTION fixture_address_country() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN NEW.country_id:=NEW.address::uuid; RETURN NEW; END;
    $$;
    CREATE TRIGGER zzzx_address_country BEFORE INSERT OR UPDATE OF address
      ON venues FOR EACH ROW WHEN(NEW.address IS NOT NULL)
      EXECUTE FUNCTION fixture_address_country();
    CREATE TRIGGER zzzx_address_country BEFORE INSERT OR UPDATE OF address
      ON organizations FOR EACH ROW WHEN(NEW.address IS NOT NULL)
      EXECUTE FUNCTION fixture_address_country();
    CREATE TRIGGER zzzzzz_venues_safety_gated BEFORE INSERT OR UPDATE OF country_id,city_id,category
      ON venues FOR EACH ROW EXECUTE FUNCTION set_venue_safety_gated();
    CREATE TRIGGER trg_organizations_safety_gated BEFORE INSERT OR UPDATE OF country_id,city_id
      ON organizations FOR EACH ROW EXECUTE FUNCTION set_entity_safety_gated();
    INSERT INTO venues(id,country_id) VALUES(1,'10000000-0000-4000-8000-000000000001');
    INSERT INTO venues(id,country_id) VALUES(2,'10000000-0000-4000-8000-000000000002');
    INSERT INTO organizations(id,country_id) VALUES(1,'10000000-0000-4000-8000-000000000001');
    INSERT INTO organizations(id,country_id) VALUES(2,'10000000-0000-4000-8000-000000000002');
    UPDATE venues SET safety_gated=NOT safety_gated;
    UPDATE organizations SET safety_gated=NOT safety_gated;
  `);
  const drift = async (table, predicate) =>
    (
      await db.query(
        `SELECT count(*)::int AS n FROM ${table} WHERE safety_gated IS DISTINCT FROM ${predicate}`,
      )
    ).rows[0].n;
  const venuePredicate = 'public.venue_is_safety_gated(country_id,city_id,category)';
  const orgPredicate = 'public.location_is_high_risk(country_id,city_id)';
  assert.equal(
    await drift('venues', venuePredicate),
    2,
    'old direct writes must reproduce both drift directions',
  );
  assert.equal(await drift('organizations', orgPredicate), 2);
  // Old late address mutation leaves the previously evaluated false flag behind.
  await db.exec(`INSERT INTO organizations(id,country_id,address) VALUES(3,
    '10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002');`);
  assert.equal(await drift('organizations', orgPredicate), 3);
  const sql = readFileSync('supabase/migrations/' + migration, 'utf8');
  await db.exec(sql);
  assert.equal(await drift('venues', venuePredicate), 0);
  assert.equal(await drift('organizations', orgPredicate), 0);
  for (const table of ['venues', 'organizations']) {
    await db.exec(`
      UPDATE ${table} SET safety_gated=NOT safety_gated;
      INSERT INTO ${table}(id,country_id,address,safety_gated) VALUES(4,
        '10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002',false);
      UPDATE ${table} SET address='10000000-0000-4000-8000-000000000002' WHERE id=1;
      UPDATE ${table} SET address='10000000-0000-4000-8000-000000000001' WHERE id=2;
      INSERT INTO ${table}(id,city_id,safety_gated) VALUES(5,
        '20000000-0000-4000-8000-000000000002',false);
      UPDATE ${table} SET note='unrelated',safety_gated=false WHERE id=5;
    `);
    assert.equal(await drift(table, table === 'venues' ? venuePredicate : orgPredicate), 0);
    assert.equal(
      (await db.query(`SELECT safety_gated FROM ${table} WHERE id=1`)).rows[0].safety_gated,
      true,
    );
    assert.equal(
      (await db.query(`SELECT safety_gated FROM ${table} WHERE id=2`)).rows[0].safety_gated,
      false,
    );
    assert.equal(
      (await db.query(`SELECT safety_gated FROM ${table} WHERE id=5`)).rows[0].safety_gated,
      true,
    );
  }
  await db.exec(`UPDATE venues SET category='cruising',safety_gated=false WHERE id=2`);
  assert.equal(
    (await db.query('SELECT safety_gated FROM venues WHERE id=2')).rows[0].safety_gated,
    true,
  );
  await db.exec(`UPDATE venues SET category=NULL,safety_gated=true WHERE id=2`);
  assert.equal(
    (await db.query('SELECT safety_gated FROM venues WHERE id=2')).rows[0].safety_gated,
    false,
  );
  await db.exec(sql);
  assert.equal(await drift('venues', venuePredicate), 0);
  assert.equal(await drift('organizations', orgPredicate), 0);
  console.log(
    'Final safety write guards: old direct-write/late-address failures reproduced; real migration repairs both drift directions and protects inserts, direct flags, address/country changes, city fallback, cruising/null categories, unrelated edits and repeat application. Isolated PostgreSQL only.',
  );
} finally {
  await db.close();
}
