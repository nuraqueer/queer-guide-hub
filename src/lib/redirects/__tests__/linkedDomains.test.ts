import { beforeEach, describe, it, expect, vi } from 'vitest';
import { readLinkedDomains } from '../linkedDomains';
const mocks = vi.hoisted(() => ({ api: vi.fn() }));
vi.mock('../memberApi', () => ({ memberRedirectApi: mocks.api }));
beforeEach(() => vi.resetAllMocks());
const base = { count: 2, builtinCount: 3, revision: 'revision-a' };
describe('scoped linked-domain pagination', () => {
  it('loads all used domain facets with cancellation without consulting creation choices', async () => {
    mocks.api
      .mockResolvedValueOnce({
        ...base,
        data: [{ id: 'a', hostname: 'lost.community.com', linkCount: 1 }],
        nextCursor: 'a',
      })
      .mockResolvedValueOnce({
        ...base,
        data: [{ id: 'b', hostname: 'other.community.com', linkCount: 2 }],
        nextCursor: null,
      });
    const signal = new AbortController().signal;
    const result = await readLinkedDomains(signal);
    expect(result.data.map((domain) => domain.id)).toEqual(['a', 'b']);
    expect(result.builtinCount).toBe(3);
    expect(mocks.api).toHaveBeenLastCalledWith(
      '/linked-domains?limit=100&cursor=a',
      'GET',
      undefined,
      signal,
    );
  });
  it('rejects repeated cursors and facets changing while pages are loaded', async () => {
    mocks.api.mockResolvedValue({ ...base, data: [], nextCursor: 'repeat' });
    await expect(readLinkedDomains()).rejects.toThrow('pagination');
    mocks.api
      .mockReset()
      .mockResolvedValueOnce({ ...base, data: [], nextCursor: 'a' })
      .mockResolvedValueOnce({ ...base, data: [], revision: 'changed', nextCursor: null });
    await expect(readLinkedDomains()).rejects.toThrow('visibility changed');
  });
});
