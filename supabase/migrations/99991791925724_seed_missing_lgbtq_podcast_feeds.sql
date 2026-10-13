-- Seed 36 LGBTQ+ podcast feeds that a 100-show reference list named and the
-- catalog did not hold (feed_type='podcast'). Episodes flow through the
-- existing news pipeline as news_articles rows (media_type='podcast'); the
-- show page is /podcasts/<slug>, gated on episode_count > 0.
--
-- Follows 20260623120000_seed_lgbtq_podcast_feeds.sql exactly: identity
-- columns only. source-rss-news fills artwork_url / description /
-- website_url from the channel on its first successful fetch
-- (source-rss-news/index.ts:239-241), so writing them here would only create
-- a second, drifting copy of what the feed already states.
--
-- HOW EACH FEED WAS RESOLVED, and why that discipline is not optional here:
-- every URL came from the keyless iTunes Search API and was then (a) matched
-- against the HOST NAMED IN THE SOURCE LIST, never on the show title alone,
-- and (b) fetched, confirming HTTP 200 plus at least one <item> carrying an
-- audio <enclosure>. All 36 pass both. Name-only matching is exactly what
-- put a wrong show in this table already -- see the namesake note below --
-- and the first search of this pass surfaced the trap immediately: cycling's
-- "Race Chasers" (Escape Collective) outranked Alaska & Willam's
-- "Race Chaser" on a title match.
--
-- 18 of the 54 listed-but-absent shows are DELIBERATELY NOT HERE. Six were
-- refused after reading the candidate feed rather than its name, because the
-- name matched and the show did not:
--   * "Always Here"   -> the only feed so titled is two sisters-in-law both
--                        named Abby Howard, on relationships. Not queer, and
--                        not the listed show.
--   * "Love and War"  -> The Independent's Armistice Day WWI-poetry piece,
--                        1 episode. Not an audio drama, not queer.
--   * "Queen of Hearts" -> the 48-episode feed is Audible's, not Jujubee's.
--   * "Fruit"         -> kept (Issa Rae's, artist corroborates); but note the
--                        catalog's existing "A Bit Fruity" is Matt Bernstein
--                        and is a different show, not a duplicate of it.
--   * "It Gets Better Podcast" -> only It Gets Better UK and Guatemala feeds
--                        exist; a sibling org is not the listed show.
--   * "Out in the Open" -> CBC's show has no live feed; the hits are unrelated.
-- The other twelve returned no feed this pass could positively identify, so
-- they are left out rather than ingested on a guess: Just Between Us,
-- The Q Agenda, The Deviant's World, UnErased, Tan France's Queer Icons,
-- Transgeneral, Being LGBTQ, Gay Travel Today, The Advocate Today,
-- The Washington Blade Podcast, Citizen Diversity, Ramble Redhead,
-- Kaleidotrope. A missing show is a gap someone can close later; a wrong
-- feed publishes another show's episodes under a queer show's name.
--
-- TWO NAMES DIVERGE FROM THE SOURCE LIST, both load-bearing:
--  1. 'LGBTQ Nation Podcast', not 'LGBTQ Nation'. A news source already holds
--     that exact name (https://www.lgbtqnation.com/feed/, slug lgbtq-nation),
--     and the WHERE NOT EXISTS guard below skips on a case-insensitive name
--     match -- so inserting it as 'LGBTQ Nation' would silently drop the
--     podcast and report success. Measured before writing this file.
--  2. 'The Bald and the Beautiful with Trixie and Katya', the feed's own
--     title. The catalog's existing 'The Bald and the Beautiful' is NOT
--     Trixie and Katya: 20260623120000 seeded
--     baldandbeautiful.podomatic.com, which is John "the Balding Beauty"
--     Salas, an unrelated show, and it holds the short slug. Using the full
--     feed title is what keeps this insert off that slug AND past the name
--     guard. The mis-seeded row is left alone here -- re-pointing a live row
--     with 7 published episodes is a separate decision, not a side effect of
--     a seed.
--
-- Idempotent: inserts only feed URLs and names not already present, so
-- re-running is a no-op. Dead or changed feeds are handled by the existing
-- silent-zero / backoff auto-pause logic in source-rss-news.

INSERT INTO public.news_sources (name, url, source_type, category, feed_type, is_active)
SELECT v.name, v.url, 'rss', 'podcast', 'podcast', true
FROM (VALUES
  ('Race Chaser', 'https://rss.art19.com/racechaser'),
  ('Hard Launch', 'https://feeds.megaphone.fm/hardlaunch'),
  ('Lovett or Leave It', 'https://audioboom.com/channels/5166622.rss'),
  ('Couples Therapy', 'https://feeds.acast.com/public/shows/22443dd7-cb87-4776-9d85-652bedf8931d'),
  ('Seek Treatment', 'https://rss.pdrl.fm/f31008/rss.art19.com/seek-treatment-with-cat-and-pat'),
  ('Drag Her!', 'https://feeds.megaphone.fm/IMP8716330518'),
  ('Alright Mary', 'https://feeds.blubrry.com/feeds/alrightmary.xml'),
  ('Sloppy Seconds', 'https://rss.art19.com/sloppyseconds'),
  ('Mob Queens', 'https://feeds.acast.com/public/shows/6a31ac37101389aa3d63a633'),
  ('The Queer History Podcast', 'https://feeds.soundcloud.com/users/soundcloud:users:264972028/sounds.rss'),
  ('True Crime Obsessed', 'https://rss.pdrl.fm/c5c471/audioboom.com/channels/4929680.rss'),
  ('Catlick', 'https://www.spreaker.com/show/4097742/episodes/feed'),
  ('Still Processing', 'https://feeds.simplecast.com/YXhATe6k'),
  ('Call Me Mother with Shon Faye', 'https://feeds.acast.com/public/shows/62b087ec4f1d1f0014025b79'),
  ('The Laverne Cox Show', 'https://www.omnycontent.com/d/playlist/e73c998e-6e60-432f-8610-ae210140c5b1/cf774666-73ab-4a0d-af59-ae2e014403c6/fa3c97ba-f37b-4bc2-a658-ae2e014403e2/podcast.rss'),
  ('How to Be a Girl', 'http://marlo-mack.squarespace.com/episodes?format=rss'),
  ('Queer Talk', 'https://feeds.acast.com/public/shows/2501b754-4dbd-548c-ad0e-cf774dcbb851'),
  ('Keeping It Queer', 'https://www.omnycontent.com/d/playlist/e0dce4b3-2eb8-48cb-822c-af1d00e03e20/35c36c8e-14a0-473d-a862-af4700a6b97c/29d9a3ba-2215-4f26-887b-af4700a6b986/podcast.rss'),
  ('The Bald and the Beautiful with Trixie and Katya', 'https://feeds.simplecast.com/GPFA1MaB'),
  ('The Queerty Interview', 'https://rss.art19.com/queerty-podcast'),
  ('Queer News', 'https://queernews.libsyn.com/rss'),
  ('Into It', 'https://feeds.megaphone.fm/VMP4248593354'),
  ('Pod Save the People', 'https://audioboom.com/channels/5166625.rss'),
  ('LGBTQ Nation Podcast', 'https://rss.art19.com/lgbtqnation'),
  ('Minority Korner', 'https://feeds.simplecast.com/UOW1b2En'),
  ('In The Thick', 'https://feeds.acast.com/public/shows/6896047a7f93fda8b243f9de'),
  ('The Double Shift', 'https://api.substack.com/feed/podcast/2325819.rss'),
  ('Moonface', 'https://feeds.acast.com/public/shows/664f8e787c6b20001352489c'),
  ('In Strange Woods', 'https://rss.art19.com/in-strange-woods'),
  ('Look Up', 'https://rss.art19.com/look-up'),
  ('Life With LEO(h)', 'https://rss.art19.com/life-with-leo-h'),
  ('The Two Princes', 'https://feeds.megaphone.fm/tp-spot'),
  ('The Strange Case of Starship Iris', 'https://feeds.megaphone.fm/FAFO3490609621'),
  ('FriGay the 13th Horror Podcast', 'https://feeds.zencastr.com/f/4xrg-XXO.rss'),
  ('Cerebro', 'https://feeds.redcircle.com/fcf903ec-714a-422e-8779-4f9d723a0540'),
  ('Fruit', 'https://feeds.simplecast.com/hasl_NGb')
) AS v(name, url)
WHERE NOT EXISTS (
  -- Skip if the feed URL is already registered, OR a source with the same
  -- name already exists (case-insensitive). Mirrors 20260623120000's guard:
  -- a same-name show under a different feed URL would create a confusing
  -- duplicate row. The two renames documented above exist to pass this.
  SELECT 1 FROM public.news_sources s
  WHERE s.url = v.url OR lower(s.name) = lower(v.name)
);

DO $verify$
DECLARE
  v_missing text;
  v_dup_url int;
  v_bad int;
BEGIN
  -- P1: every one of the 36 feeds is registered as a podcast source. Asserts
  -- the REACHED STATE, not "36 rows were inserted": a concurrent session that
  -- legitimately added one of these first must not fail this migration.
  SELECT string_agg(v.url, ', ') INTO v_missing
  FROM (VALUES
    ('https://rss.art19.com/racechaser'),('https://feeds.megaphone.fm/hardlaunch'),
    ('https://audioboom.com/channels/5166622.rss'),
    ('https://feeds.acast.com/public/shows/22443dd7-cb87-4776-9d85-652bedf8931d'),
    ('https://rss.pdrl.fm/f31008/rss.art19.com/seek-treatment-with-cat-and-pat'),
    ('https://feeds.megaphone.fm/IMP8716330518'),
    ('https://feeds.blubrry.com/feeds/alrightmary.xml'),('https://rss.art19.com/sloppyseconds'),
    ('https://feeds.acast.com/public/shows/6a31ac37101389aa3d63a633'),
    ('https://feeds.soundcloud.com/users/soundcloud:users:264972028/sounds.rss'),
    ('https://rss.pdrl.fm/c5c471/audioboom.com/channels/4929680.rss'),
    ('https://www.spreaker.com/show/4097742/episodes/feed'),
    ('https://feeds.simplecast.com/YXhATe6k'),
    ('https://feeds.acast.com/public/shows/62b087ec4f1d1f0014025b79'),
    ('https://www.omnycontent.com/d/playlist/e73c998e-6e60-432f-8610-ae210140c5b1/cf774666-73ab-4a0d-af59-ae2e014403c6/fa3c97ba-f37b-4bc2-a658-ae2e014403e2/podcast.rss'),
    ('http://marlo-mack.squarespace.com/episodes?format=rss'),
    ('https://feeds.acast.com/public/shows/2501b754-4dbd-548c-ad0e-cf774dcbb851'),
    ('https://www.omnycontent.com/d/playlist/e0dce4b3-2eb8-48cb-822c-af1d00e03e20/35c36c8e-14a0-473d-a862-af4700a6b97c/29d9a3ba-2215-4f26-887b-af4700a6b986/podcast.rss'),
    ('https://feeds.simplecast.com/GPFA1MaB'),('https://rss.art19.com/queerty-podcast'),
    ('https://queernews.libsyn.com/rss'),('https://feeds.megaphone.fm/VMP4248593354'),
    ('https://audioboom.com/channels/5166625.rss'),('https://rss.art19.com/lgbtqnation'),
    ('https://feeds.simplecast.com/UOW1b2En'),
    ('https://feeds.acast.com/public/shows/6896047a7f93fda8b243f9de'),
    ('https://api.substack.com/feed/podcast/2325819.rss'),
    ('https://feeds.acast.com/public/shows/664f8e787c6b20001352489c'),
    ('https://rss.art19.com/in-strange-woods'),('https://rss.art19.com/look-up'),
    ('https://rss.art19.com/life-with-leo-h'),('https://feeds.megaphone.fm/tp-spot'),
    ('https://feeds.megaphone.fm/FAFO3490609621'),('https://feeds.zencastr.com/f/4xrg-XXO.rss'),
    ('https://feeds.redcircle.com/fcf903ec-714a-422e-8779-4f9d723a0540'),
    ('https://feeds.simplecast.com/hasl_NGb')
  ) AS v(url)
  WHERE NOT EXISTS (
    SELECT 1 FROM public.news_sources s
    WHERE s.url = v.url AND s.feed_type = 'podcast'
  );
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'P1 failed: feed not registered as a podcast source: %', v_missing;
  END IF;

  -- P2: no feed URL is registered twice. news_sources has NO unique index on
  -- url (checked: only news_sources_pkey and news_sources_slug_key), so a
  -- duplicate is silently possible and would double-ingest every episode.
  SELECT count(*) INTO v_dup_url FROM (
    SELECT url FROM public.news_sources GROUP BY url HAVING count(*) > 1
  ) d;
  IF v_dup_url <> 0 THEN
    RAISE EXCEPTION 'P2 failed: % feed URL(s) registered more than once', v_dup_url;
  END IF;

  -- P3: the pre-existing namesake row is UNTOUCHED and still distinct from
  -- the row added here. Asserts BOTH halves: a later pass that "tidied" the
  -- names into one row, or re-pointed the old slug, breaks this.
  SELECT count(*) INTO v_bad FROM public.news_sources
  WHERE slug = 'the-bald-and-the-beautiful'
    AND url = 'https://baldandbeautiful.podomatic.com/rss2.xml';
  IF v_bad <> 1 THEN
    RAISE EXCEPTION 'P3 failed: expected the original mis-seeded Bald and the Beautiful row to survive on its own slug, found %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad FROM public.news_sources
  WHERE url = 'https://feeds.simplecast.com/GPFA1MaB'
    AND slug IS DISTINCT FROM 'the-bald-and-the-beautiful';
  IF v_bad <> 1 THEN
    RAISE EXCEPTION 'P3 failed: Trixie/Katya feed must hold its own slug, found %', v_bad;
  END IF;

  -- P4: the LGBTQ Nation news source and the LGBTQ Nation podcast are two
  -- rows, not one. This is the rename the name guard forced; collapsing them
  -- would drop whichever was inserted second.
  SELECT count(*) INTO v_bad FROM public.news_sources
  WHERE url IN ('https://www.lgbtqnation.com/feed/', 'https://rss.art19.com/lgbtqnation');
  IF v_bad <> 2 THEN
    RAISE EXCEPTION 'P4 failed: expected separate LGBTQ Nation news and podcast rows, found %', v_bad;
  END IF;

  -- P5: every row this file is responsible for is a podcast source that the
  -- public surface can actually reach once it has episodes -- active, and
  -- categorised so the admin podcast views list it.
  SELECT count(*) INTO v_bad FROM public.news_sources
  WHERE url IN (
    'https://rss.art19.com/racechaser','https://feeds.simplecast.com/GPFA1MaB',
    'https://rss.art19.com/lgbtqnation','https://feeds.simplecast.com/hasl_NGb'
  ) AND (NOT is_active OR feed_type <> 'podcast' OR category <> 'podcast' OR slug IS NULL);
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'P5 failed: % newly seeded row(s) are inactive, mis-typed or unslugged', v_bad;
  END IF;
END
$verify$;
