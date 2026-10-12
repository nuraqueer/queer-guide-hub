import { useContext, useState } from 'react';
import { ContentListPanel } from '@/components/cms/ContentListPanel';
import { brandListConfig } from './organisationListConfigs';
import { AdminShellContext } from '@/components/admin/shell/AdminShell';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { BrandReviewQueue } from '@/components/admin/review-queues/BrandReviewQueue';
import type { BrandReviewRow } from '@/components/admin/review-queues/brandReviewVocab';
import { Button } from '@/components/ui/button';
import { untypedRpc } from '@/integrations/supabase/untyped';
import { toast } from 'sonner';
export function BrandsManager() {
  const shell = useContext(AdminShellContext);
  const [review, setReview] = useState<BrandReviewRow | null>(null);
  const [version, setVersion] = useState(0);
  const [applying, setApplying] = useState(false);
  const apply = async () => {
    setApplying(true);
    try {
      const { error } = await untypedRpc('run_marketplace_ownership_apply', {});
      if (error) throw error;
      toast.success('Ownership applied to products');
      setVersion((v) => v + 1);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : 'Could not apply ownership');
    } finally {
      setApplying(false);
    }
  };
  return (
    <>
      <ContentListPanel
        contentTypeId={brandListConfig.id}
        configOverride={brandListConfig}
        workspace
        operational
        hideHeader
        refreshKey={version}
        onEdit={(_type, id) => shell?.openEditor('marketplace_brands', id)}
        onCreate={() => shell?.openEditor('marketplace_brands', null)}
        onEditRow={(row) => shell?.openEditor('marketplace_brands', String(row.id))}
        rowActions={(row) => [
          {
            label: 'Review ownership',
            run: () =>
              setReview({
                ...row,
                top_source: row.top_source ?? null,
                sample_url: row.sample_url ?? null,
              } as unknown as BrandReviewRow),
          },
        ]}
        tools={
          <Button variant="ghost" size="sm" disabled={applying} onClick={() => void apply()}>
            {applying ? 'Applying…' : 'Apply ownership to products'}
          </Button>
        }
      />
      <Dialog
        open={Boolean(review)}
        onOpenChange={(open) => {
          if (!open) setReview(null);
        }}
      >
        <DialogContent className="max-w-3xl max-h-[90vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Review ownership: {review?.display_name}</DialogTitle>
          </DialogHeader>
          {review && (
            <BrandReviewQueue
              key={review.id}
              selectedBrand={review}
              onReviewed={() => {
                setReview(null);
                setVersion((v) => v + 1);
              }}
            />
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}
