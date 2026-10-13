import { useAdminRoles } from '@/hooks/useAdminRoles';
import { NewsSourcesWorkspace } from './news-sources/NewsSourcesWorkspace';

/** One source-management surface, shared by Pipelines and publisher Organisations. */
export function NewsSourcesManager(props: Parameters<typeof NewsSourcesWorkspace>[0] = {}) {
  const { isAdmin, isModerator, loading } = useAdminRoles();
  if (loading) return <p className="text-13">Loading source permissions…</p>;
  if (!isAdmin && !isModerator)
    return (
      <p className="text-13 text-muted-foreground">
        Staff access is required to manage news sources.
      </p>
    );
  return <NewsSourcesWorkspace {...props} canManagePublishers={isAdmin} />;
}
