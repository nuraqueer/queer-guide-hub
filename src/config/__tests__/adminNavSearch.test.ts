import { describe, expect, it } from 'vitest';
import { adminNavSections } from '../adminNavigation';
import { getAdminNavSearchText, matchesAdminNavSearch } from '../adminNavSearch';

const find = (id: string) => {
  const section = adminNavSections.find((section) => section.items.some((item) => item.id === id))!;
  return { section, item: section.items.find((item) => item.id === id)! };
};

describe('admin navigation search', () => {
  it.each([
    ['postfach', 'POSTFACH'],
    ['geography', 'countries'],
    ['geography', 'cities'],
    ['organizations', 'hotels'],
    ['tags', 'taxonomy'],
    ['cloudflare', 'cloudflare'],
  ])('finds %s by its familiar alias %s', (id, query) => {
    const { item, section } = find(id);
    expect(matchesAdminNavSearch(item, section, query)).toBe(true);
  });

  it('matches section and group names and requires every query word', () => {
    const { item, section } = find('events');
    expect(matchesAdminNavSearch(item, section, 'content places')).toBe(true);
    expect(matchesAdminNavSearch(item, section, 'events security')).toBe(false);
    expect(getAdminNavSearchText(item, section)).toContain('Places & events');
  });

  it('keeps review access moderator-only after moving requests to Workspace', () => {
    const { item, section } = find('group-requests');
    expect(section.label).toBe('Workspace');
    expect(item.minRole).toBe('moderator');
    expect(item.route).toBe('/admin/content/group-requests');
  });
});
