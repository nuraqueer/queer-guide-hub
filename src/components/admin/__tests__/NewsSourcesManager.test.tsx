import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
const roles = vi.hoisted(() => ({ isAdmin: true, isModerator: false, loading: false }));
vi.mock('@/hooks/useAdminRoles', () => ({ useAdminRoles: () => roles }));
vi.mock('@/components/admin/news-sources/NewsSourcesWorkspace', () => ({
  NewsSourcesWorkspace: ({ canManagePublishers }: { canManagePublishers: boolean }) => (
    <div>Source workspace {canManagePublishers ? 'publisher tools' : 'feed controls'}</div>
  ),
}));
import { NewsSourcesManager } from '../NewsSourcesManager';
beforeEach(() => {
  roles.isAdmin = true;
  roles.isModerator = false;
  roles.loading = false;
});
describe('Shared NewsSourcesManager entry point', () => {
  it('opens the shared workspace for administrators', () => {
    render(<NewsSourcesManager />);
    expect(screen.getByText(/Source workspace/)).toBeVisible();
  });
  it('keeps moderator feed controls while restricting publisher tools', () => {
    roles.isAdmin = false;
    roles.isModerator = true;
    render(<NewsSourcesManager />);
    expect(screen.getByText('Source workspace feed controls')).toBeVisible();
  });
  it('hides privileged publisher management from other pipeline users', () => {
    roles.isAdmin = false;
    render(<NewsSourcesManager />);
    expect(screen.getByText(/Staff access is required/)).toBeVisible();
    expect(screen.queryByText(/Source workspace/)).toBeNull();
  });
});
