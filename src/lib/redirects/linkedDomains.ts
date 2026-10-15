import { memberRedirectApi } from './memberApi';
export interface LinkedDomain {
  id: string;
  hostname: string;
  linkCount: number;
}
export interface LinkedDomainsPage {
  data: LinkedDomain[];
  count: number;
  builtinCount: number;
  nextCursor: string | null;
  revision: string;
}
export async function readLinkedDomains(signal?: AbortSignal): Promise<LinkedDomainsPage> {
  const data: LinkedDomain[] = [];
  const cursors = new Set<string>();
  let cursor: string | null = null;
  let first: LinkedDomainsPage | undefined;
  do {
    const page: LinkedDomainsPage = await memberRedirectApi(
      '/linked-domains?limit=100' + (cursor ? '&cursor=' + encodeURIComponent(cursor) : ''),
      'GET',
      undefined,
      signal,
    );
    if (!Array.isArray(page.data)) throw new Error('Invalid linked-domain page');
    if (first && first.revision !== page.revision)
      throw new Error('Domain visibility changed. Refresh the domain filters.');
    first ??= page;
    data.push(...page.data);
    cursor = page.nextCursor;
    if (cursor) {
      if (cursors.has(cursor)) throw new Error('Linked-domain pagination did not advance');
      cursors.add(cursor);
    }
  } while (cursor);
  return { ...first!, data, nextCursor: null };
}
