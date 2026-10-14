import type { AdminNavItem, AdminNavSection } from './adminNavigation';

/** Shared search vocabulary for the sidebar and command palette. */
export function getAdminNavSearchText(item: AdminNavItem, section: AdminNavSection): string {
  return [item.label, section.label, item.group, item.route, ...(item.keywords ?? [])]
    .filter(Boolean)
    .join(' ');
}

export function matchesAdminNavSearch(
  item: AdminNavItem,
  section: AdminNavSection,
  query: string,
): boolean {
  const text = getAdminNavSearchText(item, section).toLocaleLowerCase();
  return query
    .trim()
    .toLocaleLowerCase()
    .split(/\s+/)
    .every((term) => text.includes(term));
}
