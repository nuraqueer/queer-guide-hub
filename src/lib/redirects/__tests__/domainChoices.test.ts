import { describe, it, expect, vi, beforeEach } from 'vitest';
import { readRedirectDomainChoices } from '../domainChoices';
const mocks = vi.hoisted(() => ({ api: vi.fn() }));
vi.mock('../memberApi', () => ({ memberRedirectApi: mocks.api }));
beforeEach(() => vi.resetAllMocks());
describe('domain choice pagination', () => {
  const page = {
    data: [{ id: 'a', hostname: 'links.community.com' }],
    count: 2,
    primaryDomainId: 'a',
    primaryUnavailable: false,
  };
  it('loads every page with the cancellation signal', async () => {
    mocks.api
      .mockResolvedValueOnce({ ...page, nextCursor: 'a' })
      .mockResolvedValueOnce({
        ...page,
        data: [{ id: 'b', hostname: 'other.community.com' }],
        nextCursor: null,
      });
    const signal = new AbortController().signal;
    expect((await readRedirectDomainChoices(signal)).data.map((item) => item.id)).toEqual([
      'a',
      'b',
    ]);
    expect(mocks.api).toHaveBeenLastCalledWith(
      '/domain-choices?limit=100&cursor=a',
      'GET',
      undefined,
      signal,
    );
  });
  it('rejects repeated cursors and primary changes rather than silently constructing incomplete choices', async () => {
    mocks.api.mockResolvedValue({ ...page, nextCursor: 'a' });
    await expect(readRedirectDomainChoices()).rejects.toThrow('pagination');
    mocks.api
      .mockReset()
      .mockResolvedValueOnce({ ...page, nextCursor: 'a' })
      .mockResolvedValueOnce({ ...page, primaryDomainId: 'b', nextCursor: null });
    await expect(readRedirectDomainChoices()).rejects.toThrow('Primary domain changed');
  });
});
