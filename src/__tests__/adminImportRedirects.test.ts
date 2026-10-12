import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, it, expect } from 'vitest';
import { adminNavSections, getRouteMinRole } from '@/config/adminNavigation';

const routes = readFileSync(resolve(__dirname, '../routes.tsx'), 'utf8');

describe('admin import consolidation', () => {
  it.each([
    ['imports/data', '/admin/pipelines?tab=sources&sub=imports'],
    ['imports/email-ingestions', '/admin/pipelines?tab=sources&sub=email'],
    ['ingestion-rules', '/admin/pipelines?tab=sources&sub=imports'],
  ])('preserves the %s bookmark', (path, target) => {
    const route = routes.match(
      new RegExp(`<Route\\s+path="${path}"\\s+element=\\{<Navigate to="([^"]+)" replace />\\}`),
    );
    expect(route?.[1]).toBe(target);
  });

  it('has one imports workspace and preserves the admin gate', () => {
    const data = adminNavSections.find((s) => s.id === 'data')!;
    expect(data.items.some((i) => i.route.startsWith('/admin/imports'))).toBe(false);
    expect(data.items.filter((i) => i.route === '/admin/pipelines')).toHaveLength(1);
    expect(getRouteMinRole('/admin/pipelines')).toBe('admin');
    expect(getRouteMinRole('/admin/automation')).toBe('moderator');
  });
});
