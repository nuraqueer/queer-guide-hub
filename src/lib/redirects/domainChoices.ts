import { memberRedirectApi } from './memberApi';
export interface DomainChoice {
  id: string;
  hostname: string;
}
export interface DomainChoices {
  data: DomainChoice[];
  count: number;
  nextCursor: string | null;
  primaryDomainId: string | null;
  primaryUnavailable: boolean;
}
export async function readRedirectDomainChoices(signal?: AbortSignal): Promise<DomainChoices> {
  const data: DomainChoice[] = [];
  const cursors = new Set<string>();
  let cursor: string | null = null;
  let first: DomainChoices | undefined;
  do {
    const page: DomainChoices = await memberRedirectApi(
      '/domain-choices?limit=100' + (cursor ? '&cursor=' + encodeURIComponent(cursor) : ''),
      'GET',
      undefined,
      signal,
    );
    if (!Array.isArray(page.data)) throw new Error('Invalid domain choices');
    if (
      first &&
      (first.primaryDomainId !== page.primaryDomainId ||
        first.primaryUnavailable !== page.primaryUnavailable)
    )
      throw new Error('Primary domain changed. Refresh the domain choices.');
    first ??= page;
    data.push(...page.data);
    cursor = page.nextCursor;
    if (cursor) {
      if (cursors.has(cursor)) throw new Error('Domain pagination did not advance');
      cursors.add(cursor);
    }
  } while (cursor);
  return { ...first!, data, nextCursor: null };
}
export function selectedDomainUrl(hostname: string | null, slug: string) {
  return hostname
    ? 'https://' + hostname + '/' + encodeURIComponent(slug.trim())
    : 'https://queer.guide/go/' + encodeURIComponent(slug.trim());
}
