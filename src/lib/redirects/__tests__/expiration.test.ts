import { describe, expect, it } from 'vitest';
import { parseLinkExpiration } from '../expiration';
describe('natural link expiration', () => {
  it('parses durations relative to the current instant', () => {
    const reference = new Date('2026-10-13T12:00:00Z');
    expect(parseLinkExpiration('in 2 hours', reference)).toBe('2026-10-13T14:00:00.000Z');
  });
  it('uses local calendar time for tomorrow and rejects unreadable input', () => {
    const reference = new Date(2026, 9, 13, 12, 0, 0);
    const date = new Date(parseLinkExpiration('tomorrow at 5PM', reference));
    expect(date.getDate()).toBe(14);
    expect(date.getHours()).toBe(17);
    expect(() => parseLinkExpiration('not a date', reference)).toThrow('Could not read');
  });
});
