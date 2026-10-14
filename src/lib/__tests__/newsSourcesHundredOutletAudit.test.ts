import { describe, expect, it } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';

/**
 * Guards 99991791951035_news_sources_hundred_outlet_audit.sql, which adds the 47
 * verified-live feeds from a 105-outlet audit of the LGBTQ+ news landscape.
 *
 * Two things here are load-bearing and easy to get wrong.
 *
 * (1) EVERY ASSERTION RUNS OVER COMMENT-STRIPPED SQL. The migration's header
 *     names each of the 39 outlets it REFUSES to add, with the measured reason —
 *     towleroad.com, standard.co.uk, afterellen.com and the rest. So an
 *     unstripped `not.toContain('towleroad.com')` fails against a correct file,
 *     and the mirror-image form passes while the statement is gone. The
 *     stripping is itself asserted below, so it cannot silently become a no-op.
 *
 * (2) THE REFUSALS ARE ASSERTED HERE AND DELIBERATELY NOT IN THE MIGRATION.
 *     A row/text postcondition about another session's future work would abort
 *     `db push` for the whole repo (the 20810101100100 trap). In this file a
 *     false alarm costs one PR, which is the right price.
 */

const MIGRATION = '99991791951035_news_sources_hundred_outlet_audit.sql';

const raw = fs.readFileSync(path.join(process.cwd(), 'supabase/migrations', MIGRATION), 'utf8');

/** Strip every `--` comment, anywhere on the line — not just at line start. */
const stripComments = (sql: string) =>
  sql
    .split('\n')
    .map((line) => line.replace(/--.*$/, ''))
    .join('\n');

const stripped = stripComments(raw);

/** The INSERT only: assertions about the row set must not match the verify block. */
const insertBlock = stripped.slice(
  stripped.indexOf('insert into public.news_sources'),
  stripped.indexOf('do $verify$'),
);

/** The verify block only. */
const verifyBlock = stripped.slice(stripped.indexOf('do $verify$'));

/** Every feed URL the migration must carry — the exact set, not a sample. */
const EXPECTED_FEEDS = [
  'https://www.autostraddle.com/feed/',
  'https://www.pride.com/feeds/feed.rss',
  'https://www.intomore.com/feed/',
  'https://instinctmagazine.com/feed/',
  'https://gayety.co/feed/',
  'https://gayletter.com/feed/',
  'https://thegaypassport.com/feed/',
  'https://www.outthere.travel/feed/',
  'https://bearworldmag.com/feed/',
  'https://thefightmag.com/feed/',
  'https://www.competenetwork.com/feed/atom',
  'https://www.curvemag.com/feed/',
  'https://gomag.com/feed/',
  'https://www.erininthemorning.com/feed',
  'https://www.gendergp.com/feed/',
  'http://bi.org/en/feed/',
  'https://prismreports.org/feed/',
  'https://watermarkoutnews.com/feed/',
  'https://www.outsmartmagazine.com/feed/',
  'https://goqnotes.com/feed/',
  'https://focusmidsouth.com/feed/',
  'https://www.losangelesblade.com/feed/',
  'https://windycitytimes.com/feed/',
  'https://pridesource.com/feed.rss',
  'https://lavendermagazine.com/feed/',
  'https://www.theseattlelesbian.com/feed/',
  'https://qvoicenews.com/feed/',
  'https://thepridela.com/feed/',
  'https://outwordmagazine.com/feed/',
  'https://gayly.com/feed/rss.xml',
  'https://www.fugues.com/feed/',
  'https://www.qxmagazine.com/feed/',
  'https://thebuzzmag.ca/feed/',
  'https://inmagazine.ca/feed/',
  'https://pinkplaymags.com/feed/',
  'https://dnamagazine.com.au/feed/',
  'https://qnews.com.au/feed/',
  'https://gayexpress.co.nz/feed/',
  'https://www.queer.de/rss/newsticker2.0.komplett.xml',
  'http://www.l-mag.de/rss.xml',
  'https://www.cromosomax.com/feed',
  'https://www.homosensual.com/feed/',
  'https://shangay.com/actualidad/feed/',
  'https://sentidog.com/feed/',
  'https://gayiceland.is/feed/',
  'https://feeds.nbcnews.com/nbcnews/public/nbcout',
  'https://www.huffpost.com/section/queer-voices/feed',
];

/**
 * Outlets measured and deliberately NOT added. Re-proposing one of these means
 * breaking this check first and reading the migration header's reason for it.
 */
const REFUSED_DOMAINS = [
  'towleroad.com',
  'eriegaynews.com',
  'afterellen.com',
  'standard.co.uk',
  'uol.com.br',
  'thegavoice.com',
  'rvamag.com',
  'lotl.com',
  'hornet.com',
  'queermajority.com',
  'usatoday.com',
  'sgn.org',
  'baywindows.com',
  'siegessaeule.de',
  'schwulissimo.de',
  'sfgn.com',
  'wussymag.com',
  'outandaboutnashville.com',
  'scenemagazine.co.uk',
  'fusemagazine.com.au',
  'campkc.com',
  'gaynrd.com',
  'thevitalvoice.com',
  'revistag.com.br',
  'midlandzone.co.uk',
  'optionsri.org',
  'projectqatlanta.com',
  'gayswithkids.com',
  'zizo-online.be',
  'ebar.com',
  'edgemedianetwork.com',
  'qsaltlake.com',
  'aumag.org',
  'outinjersey.net',
  'outfrontmagazine.com',
  'boyz.co.uk',
  'gaylaxymag.com',
  'thegailygrind.com',
  'qweerist.com',
];

describe('news source 100-outlet audit migration', () => {
  it('carries exactly the 47 audited feeds and no others', () => {
    // Positive control first: an empty slice would satisfy every toContain below
    // by vacuum, and would satisfy the refusal assertions too.
    expect(insertBlock.length).toBeGreaterThan(2000);
    expect(EXPECTED_FEEDS).toHaveLength(47);
    expect(new Set(EXPECTED_FEEDS).size).toBe(47);

    for (const feed of EXPECTED_FEEDS) {
      expect(insertBlock).toContain(`'${feed}'`);
    }

    // The row count is pinned, so adding a 46th row without updating this list
    // fails rather than riding along unreviewed.
    const valueRows = insertBlock.match(/^\s*\('[^\n]*\),?$/gm) ?? [];
    expect(valueRows).toHaveLength(47);
  });

  it('refuses the 39 measured exclusions', () => {
    // Each refused domain must be absent from the INSERT. The header names them
    // all, which is exactly why this runs on stripped SQL.
    for (const domain of REFUSED_DOMAINS) {
      expect(insertBlock).not.toContain(domain);
    }
  });

  it('keeps the comment stripper load-bearing', () => {
    // If the stripper ever becomes a no-op, the refusal test above would start
    // failing against a correct file. Prove the raw file DOES name a refused
    // outlet and that the stripped INSERT does not — i.e. the stripping is what
    // makes the distinction, not luck.
    expect(raw).toContain('towleroad.com');
    expect(raw).toContain('standard.co.uk');
    expect(stripped).not.toContain('towleroad.com');
  });

  it('guards the insert on both url and slug so a re-run composes', () => {
    // news_sources has no unique index on url, only a partial one on slug, so
    // both guards are needed: without the url guard a re-run duplicates rows,
    // without the slug guard it raises on the slug index and aborts db push.
    expect(insertBlock).toMatch(
      /not exists\s*\(\s*select 1 from public\.news_sources s where s\.url = v\.url\s*\)/,
    );
    expect(insertBlock).toMatch(
      /not exists\s*\(\s*select 1 from public\.news_sources s where s\.slug = v\.slug\s*\)/,
    );
  });

  it('never auto-publishes an unreviewed source', () => {
    // These are freshly added, unreviewed outlets; their articles belong in the
    // existing review gate. The insert must hardcode false, not pass it through.
    expect(insertBlock).toMatch(/60,\s*true,\s*false,\s*false/);
    expect(insertBlock).not.toMatch(/auto_publish\s*=>\s*true/);
    expect(insertBlock).toContain("'rss', 'news'");
  });

  it('asserts its postconditions by RAISING, not merely by naming them', () => {
    // A condition can be present while the branch has been gutted to `null;`,
    // so assert the raise itself, and pin each comparison.
    const raises = verifyBlock.match(/raise exception/g) ?? [];
    expect(raises.length).toBe(4);

    expect(verifyBlock).toMatch(/if v_cnt <> 47 then\s*raise exception 'P1 failed/);
    expect(verifyBlock).toMatch(/if v_bad <> 0 then\s*raise exception 'P2 failed/);
    expect(verifyBlock).toMatch(/if v_bad <> 0 then\s*raise exception 'P3 failed/);
    expect(verifyBlock).toMatch(/if v_cnt <> 3 then\s*raise exception 'P4 failed/);

    // No short-circuit left behind in the checks.
    expect(verifyBlock).not.toMatch(/where false/);
    expect(verifyBlock).not.toMatch(/if false then/);
    // The counters must not be pre-seeded to a passing value.
    expect(verifyBlock).not.toMatch(/v_cnt\s+int\s*:=/);
    expect(verifyBlock).not.toMatch(/v_bad\s+int\s*:=/);
  });

  it('keeps the three egress-blocked-but-verified sources', () => {
    // Los Angeles Blade, Lavender and Q Voice News returned a valid fresh feed
    // to one egress and 403 to the pg_net probe. They are in on purpose and are
    // the first rows a later "clean up the broken feeds" pass would drop.
    for (const slug of ['los-angeles-blade', 'lavender-magazine', 'q-voice-news']) {
      expect(insertBlock).toContain(`'${slug}'`);
    }
    expect(verifyBlock).toContain("'los-angeles-blade','lavender-magazine','q-voice-news'");
  });

  it('expects all 47 slugs in the postcondition array', () => {
    const arrayBlock = verifyBlock.slice(
      verifyBlock.indexOf('v_expected text[] := array['),
      verifyBlock.indexOf('v_bad int;'),
    );
    expect(arrayBlock.length).toBeGreaterThan(500);
    const slugs = arrayBlock.match(/'[a-z0-9-]+'/g) ?? [];
    expect(slugs).toHaveLength(47);
    expect(new Set(slugs).size).toBe(47);
  });
});
