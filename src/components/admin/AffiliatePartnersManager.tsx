import { ContentListPanel } from '@/components/cms/ContentListPanel';
import { partnerListConfig } from '@/components/admin/business/organisationListConfigs';
import { useMemo, useState } from 'react';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Switch } from '@/components/ui/switch';
import { useAffiliateLinks } from '@/hooks/useAffiliateLinks';
import { toast } from 'sonner';
import { StructuredValueEditor } from '@/components/cms/fields/structured/StructuredValueEditor';

const SUB_FIELDS = ['sub_id', 'booking_label', 'gyg_placement'] as const;

const emptyForm = {
  partner_name: '',
  domains: '',
  url_patterns: '',
  parameters: {} as Record<string, unknown>,
  redirect_template: '',
  notes: '',
  enabled: true,
  go_key: '',
  sub_field: 'sub_id',
};

export function AffiliatePartnersManager({
  organizationId,
  embedded = false,
}: {
  /** Scope to one business: shows only that org's partner rows. */
  organizationId?: string;
  /** Drop the page-level container — the host already provides padding. */
  embedded?: boolean;
} = {}) {
  const {
    partners: allPartners,
    loading,
    error: fetchError,
    fetchPartners,
    createPartner,
    updatePartner,
    deletePartner,
  } = useAffiliateLinks();
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editId, setEditId] = useState<string | null>(null);
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);

  const shell = embedded ? '' : 'p-6 max-w-[1000px] mx-auto';

  const openCreate = () => {
    setEditId(null);
    setForm(emptyForm);
    setDialogOpen(true);
  };

  const openEdit = (p: (typeof allPartners)[0]) => {
    setEditId(p.id);
    setForm({
      partner_name: p.partner_name,
      domains: p.domains.join(', '),
      url_patterns: (p.url_patterns ?? []).join(', '),
      parameters: { ...(p.parameters ?? {}) },
      redirect_template: p.redirect_template ?? '',
      notes: ((p as unknown as Record<string, unknown>).notes as string) ?? '',
      enabled: p.enabled,
      go_key: ((p as unknown as Record<string, unknown>).go_key as string) ?? '',
      sub_field: ((p as unknown as Record<string, unknown>).sub_field as string) ?? 'sub_id',
    });
    setDialogOpen(true);
  };

  const handleSave = async () => {
    if (!form.partner_name.trim()) {
      toast.error('Name is required');
      return;
    }
    // URL query parameters are strings; drop blank names/values.
    const params: Record<string, string> = Object.fromEntries(
      Object.entries(form.parameters)
        .filter(([k, v]) => k.trim() && v !== null && v !== undefined && String(v).trim())
        .map(([k, v]) => [k.trim(), String(v).trim()]),
    );
    setSaving(true);
    try {
      const payload = {
        partner_name: form.partner_name.trim(),
        domains: form.domains
          .split(',')
          .map((d) => d.trim())
          .filter(Boolean),
        url_patterns: form.url_patterns
          ? form.url_patterns
              .split(',')
              .map((d) => d.trim())
              .filter(Boolean)
          : [],
        parameters: params,
        redirect_template: form.redirect_template || null,
        notes: form.notes || null,
        enabled: form.enabled,
        go_key: form.go_key.trim() || null,
        sub_field: form.sub_field,
      };
      if (editId) {
        await updatePartner(editId, payload);
        toast.success('Partner updated');
      } else {
        await createPartner({
          ...payload,
          ...(organizationId ? { organization_id: organizationId } : {}),
        });
        toast.success('Partner created');
      }
      setDialogOpen(false);
      fetchPartners();
    } catch (e: unknown) {
      toast.error(e instanceof Error ? e.message : 'Save failed');
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async (id: string, name: string) => {
    if (!confirm(`Delete partner "${name}"?`)) return;
    try {
      await deletePartner(id);
      toast.success('Partner deleted');
      fetchPartners();
    } catch (e: unknown) {
      toast.error(e instanceof Error ? e.message : 'Delete failed');
    }
  };

  const listRows = useMemo(
    () =>
      allPartners
        .filter(
          (p) =>
            !organizationId ||
            (p as unknown as Record<string, unknown>).organization_id === organizationId,
        )
        .map((p) => ({ ...p, status: p.enabled ? 'active' : 'disabled' })),
    [allPartners, organizationId],
  );
  return (
    <div className={shell}>
      <ContentListPanel
        contentTypeId={partnerListConfig.id}
        configOverride={partnerListConfig}
        workspace
        operational
        hideHeader
        source={{ rows: listRows, loading, error: fetchError, refresh: fetchPartners }}
        onCreate={openCreate}
        onEditRow={(row) => openEdit(row as unknown as (typeof allPartners)[number])}
        rowActions={(row) => [
          {
            label: row.enabled ? 'Disable' : 'Enable',
            run: async () => {
              await updatePartner(String(row.id), { enabled: !row.enabled });
              fetchPartners();
            },
          },
          {
            label: 'Delete…',
            destructive: true,
            run: () => handleDelete(String(row.id), String(row.partner_name)),
          },
        ]}
      />
      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>{editId ? 'Edit Partner' : 'Add Affiliate Partner'}</DialogTitle>
          </DialogHeader>
          <div className="flex flex-col gap-4 mt-2">
            <div className="flex flex-col gap-2">
              <Label htmlFor="partner_name">Partner Name *</Label>
              <Input
                id="partner_name"
                value={form.partner_name}
                onChange={(e) => setForm((f) => ({ ...f, partner_name: e.target.value }))}
                required
              />
            </div>
            <div className="flex flex-col gap-2">
              <Label htmlFor="domains">Domains (comma-separated)</Label>
              <Input
                id="domains"
                value={form.domains}
                onChange={(e) => setForm((f) => ({ ...f, domains: e.target.value }))}
                placeholder="aviasales.com, search.aviasales.com"
              />
              <p className="text-xs text-muted-foreground">Domains to match (without www)</p>
            </div>
            <div className="flex flex-col gap-2">
              <Label htmlFor="url_patterns">URL Patterns (comma-separated, optional)</Label>
              <Input
                id="url_patterns"
                value={form.url_patterns}
                onChange={(e) => setForm((f) => ({ ...f, url_patterns: e.target.value }))}
                placeholder="/flights/*, /hotels/*"
              />
            </div>
            <div className="flex flex-col gap-2">
              <Label>Parameters</Label>
              <StructuredValueEditor
                value={form.parameters}
                onChange={(v) =>
                  setForm((f) => ({
                    ...f,
                    parameters:
                      v && typeof v === 'object' && !Array.isArray(v)
                        ? (v as Record<string, unknown>)
                        : {},
                  }))
                }
                label="Parameters"
              />
              <p className="text-xs text-muted-foreground">
                Key-value pairs appended to matching URLs
              </p>
            </div>
            <div className="grid grid-cols-2 gap-4">
              <div className="flex flex-col gap-2">
                <Label htmlFor="go_key">Go key</Label>
                <Input
                  id="go_key"
                  value={form.go_key}
                  onChange={(e) => setForm((f) => ({ ...f, go_key: e.target.value }))}
                  placeholder="booking"
                />
                <p className="text-xs text-muted-foreground">
                  /go?p= key. Enabled rows with a go key are served live to the redirect worker.
                </p>
              </div>
              <div className="flex flex-col gap-2">
                <Label htmlFor="sub_field">Sub-id field</Label>
                <select
                  id="sub_field"
                  className="h-9 rounded-element border border-input bg-background px-2 text-sm"
                  value={form.sub_field}
                  onChange={(e) => setForm((f) => ({ ...f, sub_field: e.target.value }))}
                >
                  {SUB_FIELDS.map((s) => (
                    <option key={s} value={s}>
                      {s}
                    </option>
                  ))}
                </select>
              </div>
            </div>
            <div className="flex flex-col gap-2">
              <Label htmlFor="redirect_template">Redirect Template (optional)</Label>
              <Input
                id="redirect_template"
                value={form.redirect_template}
                onChange={(e) => setForm((f) => ({ ...f, redirect_template: e.target.value }))}
                placeholder="https://tp.media/r?..."
              />
            </div>
            <div className="flex flex-col gap-2">
              <Label htmlFor="notes">Notes</Label>
              <Textarea
                id="notes"
                value={form.notes}
                onChange={(e) => setForm((f) => ({ ...f, notes: e.target.value }))}
                rows={2}
              />
            </div>
            <div className="flex items-center gap-2">
              <Switch
                id="enabled"
                checked={form.enabled}
                onCheckedChange={(v) => setForm((f) => ({ ...f, enabled: v }))}
              />
              <Label htmlFor="enabled">Enabled</Label>
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDialogOpen(false)}>
              Cancel
            </Button>
            <Button onClick={handleSave} disabled={saving}>
              {saving ? 'Saving...' : editId ? 'Update' : 'Create'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

export default AffiliatePartnersManager;
