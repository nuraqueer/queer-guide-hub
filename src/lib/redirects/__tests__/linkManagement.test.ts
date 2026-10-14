import { describe, expect, it } from 'vitest';
import {
  bulkLinkInput,
  linkInput,
  linkListInput,
  randomLinkSlug,
} from '../../../../supabase/functions/_shared/redirect-links';
describe('link management input contract', () => {
  it('accepts root create/upsert without public slug and rejects builtin or malformed flags', () => {
    const domainId = '00000000-0000-4000-8000-000000000001';
    expect(linkInput({ domainId, isDomainRoot: true, target: '/events' }, 'upsert')).toEqual({
      domainId,
      isDomainRoot: true,
      target: '/events',
    });
    expect(linkInput({ isDomainRoot: false }, 'update')).toEqual({ isDomainRoot: false });
    expect(() => linkInput({ isDomainRoot: true, target: '/events' }, 'create')).toThrow(
      /custom domain/,
    );
    expect(() => linkInput({ isDomainRoot: 'true' }, 'update')).toThrow(/flag/);
  });
  it('validates scheduling, nullable limits and notes without resetting omitted fields', () => {
    expect(
      linkInput(
        { startsAt: '2026-10-14T10:00:00+02:00', clickLimit: 7, notes: 'A note' },
        'update',
      ),
    ).toEqual({ startsAt: '2026-10-14T08:00:00.000Z', clickLimit: 7, notes: 'A note' });
    expect(linkInput({ startsAt: null, clickLimit: null, notes: null }, 'update')).toEqual({
      startsAt: null,
      clickLimit: null,
      notes: null,
    });
    for (const data of [
      { clickLimit: 0 },
      { clickLimit: 1.5 },
      { clickLimit: 2147483648 },
      { startsAt: 'bad' },
      { notes: 'a'.repeat(10001) },
      { startsAt: '2030-01-01', expiresAt: '2029-01-01' },
    ])
      expect(() => linkInput(data, 'update')).toThrow();
  });
  it('accepts explicit domain bindings and default-namespace filters while rejecting malformed IDs', () => {
    const domainId = '00000000-0000-4000-8000-000000000001';
    expect(linkInput({ domainId }, 'update')).toEqual({ domainId });
    expect(linkInput({ domainId: null }, 'update')).toEqual({ domainId: null });
    expect(linkListInput({ domainId: null })).toEqual({ domainId: null });
    expect(linkListInput({ domainId })).toEqual({ domainId });
    expect(() => linkInput({ domainId: 'bad' }, 'update')).toThrow('domain');
    expect(() => linkListInput({ domainId: 'bad' })).toThrow('domain');
  });
  it('supports boolean archive patches and filters', () => {
    expect(linkInput({ isArchived: true }, 'update')).toEqual({ isArchived: true });
    expect(linkListInput({ isArchived: false })).toEqual({ isArchived: false });
    expect(() => linkInput({ isArchived: 'true' }, 'update')).toThrow();
    expect(() => linkListInput({ isArchived: null })).toThrow();
  });
  it('preserves public destinations, fragments and explicit clear fields', () => {
    expect(
      linkInput(
        {
          target: 'https://example.com/?x=1#section',
          folderId: null,
          tagIds: [],
          expiresAt: null,
          comment: '',
        },
        'create',
      ),
    ).toMatchObject({
      target: 'https://example.com/?x=1#section',
      folderId: null,
      expiresAt: null,
    });
    expect(randomLinkSlug()).toMatch(/^[a-f0-9]{12}$/);
  });
  it.each([
    { target: 'javascript:alert(1)' },
    { target: 'http://10.0.0.1' },
    { target: 'https://user:secret@example.com' },
    { target: '/go/other' },
    { target: '/events', slug: 'admin' },
    { target: '/events', statusCode: 303 },
    { target: '/events', utmDefaults: { arbitrary: 'field' } },
    { target: '/events', queryOverride: { pw: 'secret' } },
    { target: '/events', isEnabled: null },
    { target: '/events', expiresAt: 'bad' },
    { target: '/events', folderId: '' },
    { target: '/events', comment: 'x'.repeat(10001) },
    { target: '/events', token: 'secret' },
  ])('rejects invalid create fields %j', (fields) =>
    expect(() => linkInput(fields, 'create')).toThrow(),
  );
  it('requires upsert identity and nonempty patches, rejects invalid batch shapes before writes', () => {
    expect(() => linkInput({ target: '/events' }, 'upsert')).toThrow();
    expect(() => linkInput({}, 'update')).toThrow();
    expect(() => bulkLinkInput({ operations: [] })).toThrow();
    expect(() =>
      bulkLinkInput({
        operations: Array(101).fill({ operation: 'create', data: { target: '/events' } }),
      }),
    ).toThrow();
    expect(() =>
      bulkLinkInput({
        operations: [
          {
            operation: 'delete',
            id: '00000000-0000-4000-8000-000000000001',
            data: { target: '/events' },
          },
        ],
      }),
    ).toThrow();
    expect(() => linkListInput({ folderId: 'invalid' })).toThrow();
    expect(() => linkListInput({ search: 'x'.repeat(201) })).toThrow();
    expect(() => linkListInput({ archived: true })).toThrow();
  });
});
