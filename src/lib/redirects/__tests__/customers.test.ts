import { describe, it, expect, vi } from 'vitest';
import {
  customerId,
  customerProfileInput,
  customerPage,
} from '../../../../supabase/functions/_shared/redirect-customers';
import { readCustomer, readCustomerJourney } from '../customers';
import { memberRedirectApi } from '../memberApi';
vi.mock('../memberApi', () => ({ memberRedirectApi: vi.fn() }));
const version = '00000000-0000-4000-8000-000000000001';
describe('private customer contracts', () => {
  it('accepts encoded opaque IDs and explicit nullable profile fields without public metadata', () => {
    const id = 'customer:with/slash & ü';
    expect(customerId(id)).toBe(id);
    expect(
      customerProfileInput({
        customerExternalId: id,
        version: null,
        name: ' Avery ',
        email: 'avery@example.com',
        avatarUrl: '',
      }),
    ).toEqual({
      id,
      values: { version: null, name: 'Avery', email: 'avery@example.com', avatarUrl: null },
    });
    expect(customerProfileInput({ customerExternalId: id, version }, true)).toEqual({
      id,
      values: { version },
    });
    for (const value of [
      { customerExternalId: id, name: 'Avery' },
      { customerExternalId: id, version: null, metadata: {} },
      { customerExternalId: id, version: null, email: 'bad' },
      { customerExternalId: id, version: null, avatarUrl: 'http://example.com/avatar.png' },
      { customerExternalId: id, version: null, avatarUrl: 'https://127.0.0.1/avatar.png' },
      {
        customerExternalId: id,
        version: null,
        avatarUrl: 'https://user:secret@example.com/avatar.png',
      },
    ])
      expect(() => customerProfileInput(value)).toThrow();
    expect(() =>
      customerProfileInput({ customerExternalId: id, version, name: 'change' }, true),
    ).toThrow();
  });
  it('bounds and validates paired chronological cursors', () => {
    const cursor = { at: '2026-10-14T12:00:00Z', id: 'click:' + version };
    expect(
      customerPage(
        new URLSearchParams({ id: 'opaque', limit: '1', cursor: JSON.stringify(cursor) }),
      ),
    ).toEqual({ id: 'opaque', limit: 1, cursor });
    const invalidPages: Record<string, string>[] = [
      { id: 'opaque', limit: '101' },
      { id: 'opaque', cursor: '{}' },
      { id: 'opaque', cursor: JSON.stringify({ ...cursor, secret: 'extra' }) },
      { id: 'opaque', cursor: JSON.stringify({ ...cursor, id: 'wrong' }) },
    ];
    for (const input of invalidPages)
      expect(() => customerPage(new URLSearchParams(input))).toThrow();
    expect(() => customerPage(new URLSearchParams('id=one&id=two'))).toThrow();
  });
  it('isolates returned profiles and rejects nonadvancing journeys', async () => {
    vi.mocked(memberRedirectApi).mockResolvedValueOnce({
      customerExternalId: 'other',
      canEdit: true,
    });
    await expect(readCustomer('selected', new AbortController().signal)).rejects.toThrow('Invalid');
    const cursor = { at: '2026-10-14T12:00:00Z', id: 'click:' + version };
    vi.mocked(memberRedirectApi).mockResolvedValueOnce({ data: [], nextCursor: cursor });
    await expect(
      readCustomerJourney('selected', cursor, new AbortController().signal),
    ).rejects.toThrow('advance');
    expect(vi.mocked(memberRedirectApi).mock.calls[1][0]).toContain('cursor=');
  });
});
