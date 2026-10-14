import { AdminPageHeader } from '@/components/admin/AdminPageHeader';
import { NewsSourcesManager } from '@/components/admin/NewsSourcesManager';
export default function AdminNewsSources() {
  return (
    <div className="space-y-6">
      <AdminPageHeader
        title="News Sources"
        subtitle="Manage feeds and their publisher Organisations. Review ingestion health and link imported articles."
      />
      <NewsSourcesManager />
    </div>
  );
}
