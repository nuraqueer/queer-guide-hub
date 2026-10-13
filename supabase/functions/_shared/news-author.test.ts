import { assertEquals } from 'https://deno.land/std@0.168.0/testing/asserts.ts';
import { personAuthorCandidate } from './news-author.ts';

Deno.test('rejects non-person credits supplied by the reported feeds', () => {
  for (const value of ['Editors', 'EDITOR', 'https://www.facebook.com/6030918854', 'Big Money Players Network and iHeartPodcasts', 'Dyking Out - a Lesbian and LGBTQ Podcast for Everyone!', 'Redaktion', 'newsroom', 'editorial team']) {
    assertEquals(personAuthorCandidate(value), null, value);
  }
  assertEquals(personAuthorCandidate('Example Magazine', ['Example Magazine']), null);
});
Deno.test('preserves international names, mononyms and explicitly credited people', () => {
  for (const value of ['Cher', '李明', 'José Muñoz', 'J. Smith', "O’Brien", 'Casey Tanner, Sarah York']) assertEquals(personAuthorCandidate(value), value);
  assertEquals(personAuthorCandidate('By Alex Doe'), 'Alex Doe');
  assertEquals(personAuthorCandidate('Alex Doe https://example.com/alex'), 'Alex Doe');
  assertEquals(personAuthorCandidate('["Alex Doe", "Editors", "Jane Smith"]'), 'Alex Doe, Jane Smith');
  assertEquals(personAuthorCandidate(['Alex Doe', 'Editors']), 'Alex Doe');
});
