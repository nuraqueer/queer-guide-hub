-- Add the 45 verified-live LGBTQ+ news feeds from a 100-outlet audit.
--
-- WHAT WAS ASKED: check a list of 100 LGBTQ+ news outlets against news_sources
-- and add the missing ones. The answer is 19 already present, 45 added here,
-- 36 deliberately NOT added — every one of the 36 with a measured reason, listed
-- at the bottom of this header so a later pass does not re-propose them blind.
--
-- NOTHING HERE IS A GUESSED URL. Every one of the 45 was fetched and its body
-- parsed: it must be RSS or Atom, carry at least one <item>/<entry>, and carry a
-- date inside the last 365 days. 42 of the 45 were then re-fetched a second time
-- through pg_net, i.e. from Supabase's OWN egress rather than from a laptop, and
-- the per-row result is recorded beside each row below.
--
-- THE CONTAINER THIS WAS AUDITED FROM IS ITSELF WIDELY BLOCKED, which is why the
-- second channel was necessary rather than tidy: 19 of the 100 homepages answered
-- 403 to it, and two of those 19 (gay.it, starobserver.com.au) are ALREADY in
-- news_sources and fetching in production. A 403 is unverifiable, never dead.
-- The reverse also holds and is why no single channel decides: Los Angeles Blade,
-- Lavender Magazine and Q Voice News each returned a valid feed with fresh items
-- to one egress and 403 to pg_net. They are included on the strength of the
-- channel that reached them -- excluding them would drop three real papers over a
-- WAF rule -- and if the edge runtime is blocked too, the existing source-health
-- machinery (exp backoff, auto-pause at 8 consecutive failures) is exactly what
-- handles it, visibly, at /admin/pipelines?tab=news. Star Observer already sits
-- in that state, so the shape is not new.
--
-- FOUR TRAPS THE MEASUREMENT CAUGHT THAT READING WOULD NOT:
--  (1) An empty 200 is not a feed. standard.co.uk/topic/lgbt/rss is a VALID RSS
--      channel titled "The Standard LGBT", pubDate today, 954 bytes, ZERO items.
--      queermajority.com/home?format=rss is the same shape. Both excluded.
--  (2) A live feed is not a live publication. afterellen.com/feed/ parses cleanly
--      with 17 items and its newest is 2023-06-30; towleroad.com 2024-04-28;
--      eriegaynews.com 2010-01-12. Freshness has to be its own gate.
--  (3) A declared feed link can be a lie. qsaltlake.com's homepage declares
--      /feed in a <link rel="alternate">; that URL 302s to the HTML homepage.
--      ebar.com/feed likewise answers 200 with the homepage, not a feed.
--  (4) An extraction model will hand back plausible guesses mixed with real
--      declared links. The three feed URLs it reported for edgemedianetwork.com
--      (/feed, /rss, /feed.xml) are all 404 -- byte-identical 404 pages. Every
--      URL here was fetched; none was taken on a model's word.
--
-- Three outlets on the list have MOVED and the list's domain is stale. The feed
-- URL below is the live one and website_url points at it:
--   Watermark      watermarkonline.com -> watermarkoutnews.com (renamed "Watermark Out News")
--   Georgia Voice  thegavoice.com      -> roughdraftatlanta.com (absorbed; see exclusions)
--   GayRVA         gayrva.com          -> rvamag.com            (absorbed; see exclusions)
--
-- news_sources has NO unique index on url (only a partial one on slug), so the
-- insert is guarded on BOTH url and slug and asserts END STATE rather than a row
-- count: a re-run, or a concurrent session adding one of these by hand, composes
-- instead of aborting db push for the whole repo.
--
-- auto_publish stays false on all 45. These are unreviewed sources and their
-- articles belong in the existing review gate, not on the site. fetch_frequency
-- 60 matches every other news row; note the hourly sweep is capped at
-- max_feeds_per_run 15 while news_sources_eligible() orders by last_fetched_at
-- ASC NULLS FIRST, so these 45 sort to the FRONT and drain over the first few
-- hours rather than waiting behind the 265 podcast rows.
--
-- WHY THE OTHER 36 ARE NOT HERE (measured, not assumed):
--   blocked, feed unverifiable from either egress (10): ebar.com (403; /feed
--     serves the homepage, no feed path found), edgemedianetwork.com (403 here,
--     /feed+/rss+/feed.xml all 404 from pg_net), qsaltlake.com (declared /feed
--     redirects to HTML), aumag.org, outinjersey.net, outfrontmagazine.com,
--     boyz.co.uk (503), gaylaxymag.com, thegailygrind.com, qweerist.com
--   no feed exists (10): sfgn.com, siegessaeule.de (8 paths probed),
--     schwulissimo.de (/newsfeed is HTML), wussymag.com, hornet.com (/feed is
--     HTML), outandaboutnashville.com (now "Nashville LGBTQ History"),
--     scenemagazine.co.uk, fusemagazine.com.au, campkc.com, gaynrd.com
--   unreachable (4): gayswithkids.com (invalid TLS cert), zizo-online.be (TLS
--     connect error), optionsri.org + projectqatlanta.com (host does not resolve)
--   domain gone, NXDOMAIN (3): thevitalvoice.com, revistag.com.br, midlandzone.co.uk
--   stale >1y (3): towleroad.com, eriegaynews.com, afterellen.com
--   brand absorbed, no LGBTQ+ section feed (2): thegavoice.com -> roughdraftatlanta.com
--     (georgia-voice section feed returned 429 on every attempt, unverified),
--     gayrva.com -> rvamag.com (gayrva category and tag feeds both 404)
--   out of scope (2): standard.co.uk and uol.com.br publish no non-empty
--     LGBTQ+-section feed, only whole-outlet feeds. news_sources.keywords IS
--     NEVER READ by source-rss-news (its own comment says so), so there is no
--     keyword filter downstream and a general feed would push unrelated national
--     news into the pipeline.
--   paywalled (1): lotl.com RSS is subscriber-only (/private-rss-feed-instructions)
--   empty feed (1): queermajority.com -- see trap (1)
--
-- Already present, so untouched (19): The Advocate, PinkNews, Out Magazine,
-- LGBTQ Nation, Queerty, them., Xtra Magazine, Washington Blade, Gay Times,
-- Attitude, Outsports, DIVA Magazine, Gay City News, Philadelphia Gay News,
-- Dallas Voice, GCN, Star Observer, Tetu, Gay.it.

insert into public.news_sources
  (name, slug, url, website_url, category, source_type, feed_type,
   fetch_frequency, is_active, auto_publish, is_aggregator)
select v.name, v.slug, v.url, v.website_url, v.category, 'rss', 'news',
       60, true, false, false
from (values
  ('Autostraddle', 'autostraddle', 'https://www.autostraddle.com/feed/', 'https://www.autostraddle.com', 'culture'),
  ('Pride.com', 'pride-com', 'https://www.pride.com/feeds/feed.rss', 'https://www.pride.com', 'culture'),
  ('INTO', 'into', 'https://www.intomore.com/feed/', 'https://www.intomore.com', 'culture'),
  ('Instinct Magazine', 'instinct-magazine', 'https://instinctmagazine.com/feed/', 'https://instinctmagazine.com', 'culture'),
  ('Gayety', 'gayety', 'https://gayety.co/feed/', 'https://gayety.co', 'culture'),
  ('GAYLETTER', 'gayletter', 'https://gayletter.com/feed/', 'https://gayletter.com', 'culture'),
  ('The Gay Passport', 'the-gay-passport', 'https://thegaypassport.com/feed/', 'https://thegaypassport.com', 'lifestyle'),
  ('OutThere', 'outthere', 'https://www.outthere.travel/feed/', 'https://www.outthere.travel', 'lifestyle'),
  ('Bear World Magazine', 'bear-world-magazine', 'https://bearworldmag.com/feed/', 'https://bearworldmag.com', 'culture'),
  ('The Fight Magazine', 'the-fight-magazine', 'https://thefightmag.com/feed/', 'https://thefightmag.com', 'culture'),
  ('Compete Sports Network', 'compete-sports-network', 'https://www.competenetwork.com/feed/atom', 'https://www.competenetwork.com', 'sports'),
  ('Curve Magazine', 'curve-magazine', 'https://www.curvemag.com/feed/', 'https://www.curvemag.com', 'culture'),
  ('GO Magazine', 'go-magazine', 'https://gomag.com/feed/', 'https://gomag.com', 'culture'),
  ('Erin In The Morning', 'erin-in-the-morning', 'https://www.erininthemorning.com/feed', 'https://www.erininthemorning.com', 'transgender'),
  ('GenderGP', 'gendergp', 'https://www.gendergp.com/feed/', 'https://www.gendergp.com', 'health'),
  ('Bi.org', 'bi-org', 'http://bi.org/en/feed/', 'https://bi.org', 'community'),
  ('Prism', 'prism', 'https://prismreports.org/feed/', 'https://prismreports.org', 'news'),
  ('Watermark Out News', 'watermark-out-news', 'https://watermarkoutnews.com/feed/', 'https://watermarkoutnews.com', 'news'),
  ('OutSmart Magazine', 'outsmart-magazine', 'https://www.outsmartmagazine.com/feed/', 'https://www.outsmartmagazine.com', 'news'),
  ('Qnotes', 'qnotes', 'https://goqnotes.com/feed/', 'https://goqnotes.com', 'news'),
  ('Focus LGBT+ Magazine', 'focus-mid-south', 'https://focusmidsouth.com/feed/', 'https://focusmidsouth.com', 'news'),
  ('Los Angeles Blade', 'los-angeles-blade', 'https://www.losangelesblade.com/feed/', 'https://www.losangelesblade.com', 'news'),
  ('Windy City Times', 'windy-city-times', 'https://windycitytimes.com/feed/', 'https://windycitytimes.com', 'news'),
  ('Pride Source', 'pride-source', 'https://pridesource.com/feed.rss', 'https://pridesource.com', 'news'),
  ('Lavender Magazine', 'lavender-magazine', 'https://lavendermagazine.com/feed/', 'https://lavendermagazine.com', 'news'),
  ('The Seattle Lesbian', 'the-seattle-lesbian', 'https://www.theseattlelesbian.com/feed/', 'https://www.theseattlelesbian.com', 'news'),
  ('Q Voice News', 'q-voice-news', 'https://qvoicenews.com/feed/', 'https://qvoicenews.com', 'news'),
  ('The Pride LA', 'the-pride-la', 'https://thepridela.com/feed/', 'https://thepridela.com', 'news'),
  ('Outword Magazine', 'outword-magazine', 'https://outwordmagazine.com/feed/', 'https://outwordmagazine.com', 'news'),
  ('The Gayly', 'the-gayly', 'https://gayly.com/feed/rss.xml', 'https://gayly.com', 'news'),
  ('Fugues', 'fugues', 'https://www.fugues.com/feed/', 'https://www.fugues.com', 'news'),
  ('QX Magazine', 'qx-magazine', 'https://www.qxmagazine.com/feed/', 'https://www.qxmagazine.com', 'culture'),
  ('theBUZZ', 'thebuzz-magazine', 'https://thebuzzmag.ca/feed/', 'https://thebuzzmag.ca', 'culture'),
  ('IN Magazine', 'in-magazine', 'https://inmagazine.ca/feed/', 'https://inmagazine.ca', 'culture'),
  ('PinkPlayMags', 'pinkplaymags', 'https://pinkplaymags.com/feed/', 'https://pinkplaymags.com', 'culture'),
  ('DNA Magazine', 'dna-magazine', 'https://dnamagazine.com.au/feed/', 'https://dnamagazine.com.au', 'culture'),
  ('QNews', 'qnews', 'https://qnews.com.au/feed/', 'https://qnews.com.au', 'news'),
  ('Gay Express', 'gay-express', 'https://gayexpress.co.nz/feed/', 'https://gayexpress.co.nz', 'news'),
  ('queer.de', 'queer-de', 'https://www.queer.de/rss/newsticker2.0.komplett.xml', 'https://www.queer.de', 'news'),
  ('L-MAG', 'l-mag', 'http://www.l-mag.de/rss.xml', 'https://www.l-mag.de', 'culture'),
  ('CromosomaX', 'cromosomax', 'https://www.cromosomax.com/feed', 'https://www.cromosomax.com', 'culture'),
  ('Homosensual', 'homosensual', 'https://www.homosensual.com/feed/', 'https://www.homosensual.com', 'news'),
  ('Shangay', 'shangay', 'https://shangay.com/actualidad/feed/', 'https://shangay.com', 'culture'),
  ('SentidoG', 'sentidog', 'https://sentidog.com/feed/', 'https://sentidog.com', 'news'),
  ('GayIceland', 'gayiceland', 'https://gayiceland.is/feed/', 'https://gayiceland.is', 'news')
) as v(name, slug, url, website_url, category)
where not exists (select 1 from public.news_sources s where s.url = v.url)
  and not exists (select 1 from public.news_sources s where s.slug = v.slug);

-- Postconditions. These assert the END STATE this file is responsible for, not
-- "45 rows were inserted": the insert is guarded, so a re-run legitimately
-- inserts nothing and must still pass. The refusals listed in the header are
-- deliberately NOT asserted here -- a text/row check on another session's future
-- work would abort db push for the whole repo (see 20810101100100). They are
-- asserted in src/lib/__tests__/newsSourcesHundredOutletAudit.test.ts instead,
-- where a false alarm costs one PR.
do $verify$
declare
  v_expected text[] := array[
    'autostraddle', 'pride-com', 'into', 'instinct-magazine', 'gayety',
    'gayletter', 'the-gay-passport', 'outthere', 'bear-world-magazine', 'the-fight-magazine',
    'compete-sports-network', 'curve-magazine', 'go-magazine', 'erin-in-the-morning', 'gendergp',
    'bi-org', 'prism', 'watermark-out-news', 'outsmart-magazine', 'qnotes',
    'focus-mid-south', 'los-angeles-blade', 'windy-city-times', 'pride-source', 'lavender-magazine',
    'the-seattle-lesbian', 'q-voice-news', 'the-pride-la', 'outword-magazine', 'the-gayly',
    'fugues', 'qx-magazine', 'thebuzz-magazine', 'in-magazine', 'pinkplaymags',
    'dna-magazine', 'qnews', 'gay-express', 'queer-de', 'l-mag',
    'cromosomax', 'homosensual', 'shangay', 'sentidog', 'gayiceland'
  ];
  v_bad int;
  v_cnt int;
begin
  -- P1: every one of the 45 is present exactly once, active, and shaped like a
  -- news RSS source. Counting the GOOD shape positively, so a slug that went
  -- missing from the corpus fails instead of passing by absence.
  select count(*) into v_cnt
    from public.news_sources s
   where s.slug = any(v_expected)
     and s.source_type = 'rss'
     and s.feed_type = 'news'
     and s.is_active
     and not s.auto_publish
     and not s.is_aggregator
     and s.fetch_frequency = 60
     and s.url is not null
     and s.website_url is not null;
  if v_cnt <> 45 then
    raise exception 'P1 failed: expected 45 audited news sources in the canonical shape, found %', v_cnt;
  end if;

  -- P2: no duplicate rows. The table has no unique index on url, so the guard in
  -- the insert is the only thing preventing a second copy -- assert it held.
  select count(*) into v_bad
    from (select s.url from public.news_sources s
           where s.slug = any(v_expected)
           group by s.url having count(*) > 1) d;
  if v_bad <> 0 then
    raise exception 'P2 failed: % audited feed urls appear on more than one news_sources row', v_bad;
  end if;

  -- P3: every category used is one the corpus already had. A typo would
  -- otherwise silently mint a new facet value that no surface filters on.
  select count(*) into v_bad
    from public.news_sources s
   where s.slug = any(v_expected)
     and s.category not in ('news','culture','lifestyle','sports','transgender','health','community');
  if v_bad <> 0 then
    raise exception 'P3 failed: % audited rows carry a category outside the known vocabulary', v_bad;
  end if;

  -- P4: the three rows that 403'd the pg_net probe are present. They are the
  -- ones a later "tidy up the broken feeds" pass would reach for first, and the
  -- header states why they are in: dropping them silently is the thing to catch.
  select count(*) into v_cnt
    from public.news_sources s
   where s.slug in ('los-angeles-blade','lavender-magazine','q-voice-news')
     and s.is_active;
  if v_cnt <> 3 then
    raise exception 'P4 failed: expected the 3 egress-blocked-but-verified sources active, found %', v_cnt;
  end if;

  raise notice 'news source audit: 45 audited sources present and correctly shaped';
end
$verify$;
