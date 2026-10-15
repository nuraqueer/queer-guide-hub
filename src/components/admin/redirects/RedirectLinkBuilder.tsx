import { randomLinkSlug } from '../../../../supabase/functions/_shared/redirect-links';
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';
import { useAuth } from '@/hooks/useAuth';
import { useRedirectDomainChoices } from '@/hooks/useRedirectDomainChoices';
import { memberRedirectApi, type MemberLink } from '@/lib/redirects/memberApi';
import { RedirectDomainSelect } from './RedirectDomainSelect';
import {
  buildCampaignDestination,
  CAMPAIGN_FIELDS,
  suggestCampaignSlug,
  targetWithoutCampaign,
  type CampaignFields,
} from '@/lib/redirects/linkTools';
import { validateSlug } from '@/lib/redirects/validation';
import type { InventoryRedirect } from '@/lib/redirects/inventory';
import { QrExport } from './RedirectQrDialog';
import { useRedirectWorkspace } from '@/hooks/useRedirectWorkspace';

export function RedirectLinkBuilder({
  seed,
  onClose,
  defaultFolderId,
}: {
  seed: InventoryRedirect | null;
  onClose: () => void;
  defaultFolderId?: string;
}) {
  const [target, setTarget] = useState(seed?.target ?? '');
  const [isDomainRoot, setIsDomainRoot] = useState(false);
  const [slug, setSlug] = useState(suggestCampaignSlug(seed?.target ?? ''));
  const [campaign, setCampaign] = useState<CampaignFields>(seed?.campaign ?? {});
  const [parameters, setParameters] = useState<Array<{ id: string; key: string; value: string }>>(
    Object.entries(seed?.prefill ?? {}).map(([key, value]) => ({ id: key, key, value })),
  );
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [savedId, setSavedId] = useState<string>();
  const [savedUrl, setSavedUrl] = useState<string | null>(null);
  const workspace = useRedirectWorkspace();
  const seedMetadata = seed ? workspace.data?.metadata.get(seed.id) : undefined;
  const [folderOverride, setFolderOverride] = useState<string | null>(null);
  const [tagOverride, setTagOverride] = useState<string[] | null>(null);
  const folderId = folderOverride ?? seedMetadata?.folder_id ?? defaultFolderId ?? '';
  const tagIds = tagOverride ?? seedMetadata?.tagIds ?? [];
  const [templateName, setTemplateName] = useState('');
  const { user } = useAuth();
  const domain = useRedirectDomainChoices(user?.id);
  const client = useQueryClient();
  let destination = '';
  let destinationError = '';
  try {
    destination = buildCampaignDestination(target, campaign, parameters);
  } catch (err) {
    destinationError = err instanceof Error ? err.message : 'Invalid destination';
  }

  const save = async () => {
    setError('');
    const valid = isDomainRoot
      ? {
          valid: !!domain.domainId,
          error: domain.domainId ? undefined : 'Choose a custom domain for its homepage link.',
        }
      : validateSlug(slug);
    if (!valid.valid || destinationError) {
      setError(valid.error ?? destinationError);
      return;
    }
    setSaving(true);
    try {
      if (!domain.valid) throw new Error('Choose an available domain before creating a link.');
      const result = await memberRedirectApi<{ link: MemberLink }>('/links', 'POST', {
        ...(isDomainRoot ? {} : { slug: slug.trim() }),
        isDomainRoot,
        target: destination,
        domainId: domain.domainId,
        folderId: folderId || null,
        tagIds,
      });
      if (!result?.link?.shortUrl)
        throw new Error(
          'Could not create the link. Check that the slug is available and try again.',
        );
      setSavedId(result.link.id);
      setSavedUrl(result.link.shortUrl);
      await client.invalidateQueries({ queryKey: ['redirect-link-workspace'] });
      await client.invalidateQueries({ queryKey: ['cms-content-list'] });
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not create link');
    } finally {
      setSaving(false);
    }
  };
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !saving) onClose();
      }}
    >
      <DialogContent className="max-h-[90dvh] max-w-2xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{savedUrl ? 'Your tracked link' : 'Create a tracked link'}</DialogTitle>
          <DialogDescription>
            {savedUrl
              ? 'Visits through this short link will appear in its tracking report.'
              : 'Create a short link with campaign tags and optional destination prefill parameters.'}
          </DialogDescription>
        </DialogHeader>
        {savedUrl ? (
          <QrExport url={savedUrl} managedShortLink linkId={savedId} />
        ) : (
          <form
            className="space-y-4"
            onSubmit={(event) => {
              event.preventDefault();
              void save();
            }}
          >
            <div className="space-y-2">
              <Label htmlFor="campaign-target">Destination</Label>
              <Input
                id="campaign-target"
                value={target}
                onChange={(e) => setTarget(e.target.value)}
                placeholder="/events/pride-zurich"
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="campaign-slug">Short-link slug</Label>
              <Input
                id="campaign-slug"
                disabled={isDomainRoot}
                value={slug}
                onChange={(e) => setSlug(e.target.value.toLowerCase())}
                required
              />
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={isDomainRoot}
                onClick={() => setSlug(randomLinkSlug())}
              >
                Generate random slug
              </Button>
            </div>
            <RedirectDomainSelect
              selection={domain}
              slug={slug}
              isDomainRoot={isDomainRoot}
              disabled={saving}
            />
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={isDomainRoot}
                onChange={(e) => setIsDomainRoot(e.target.checked)}
              />
              Use domain homepage
            </label>
            {isDomainRoot && !domain.domainId && (
              <p role="alert">Choose a custom domain for its homepage link.</p>
            )}
            <fieldset>
              <legend className="mb-2 font-medium">Campaign tracking</legend>
              {workspace.data && (
                <div className="mb-4 flex flex-wrap gap-2">
                  <select
                    aria-label="Apply UTM template"
                    className="max-w-full rounded-element border bg-background p-2 text-sm"
                    value=""
                    onChange={(event) => {
                      const template = workspace.data.templates.find(
                        (item) => item.id === event.target.value,
                      );
                      if (template) {
                        setTarget(targetWithoutCampaign(target));
                        setCampaign({ ...template.parameters });
                      }
                    }}
                  >
                    <option value="">Apply a saved UTM template</option>
                    {workspace.data.templates.map((template) => (
                      <option value={template.id} key={template.id}>
                        {template.name}
                      </option>
                    ))}
                  </select>
                  <Input
                    aria-label="New UTM template name"
                    className="min-w-0 flex-1"
                    placeholder="Template name"
                    value={templateName}
                    onChange={(event) => setTemplateName(event.target.value)}
                    maxLength={100}
                  />
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={!templateName.trim() || workspace.resource.isPending}
                    onClick={() =>
                      void workspace.resource
                        .mutateAsync({
                          kind: 'templates',
                          values: { name: templateName.trim(), parameters: campaign },
                        })
                        .then(() => setTemplateName(''))
                        .catch(() => {})
                    }
                  >
                    Save template
                  </Button>
                </div>
              )}
              {workspace.resource.isError && (
                <p role="alert" className="text-destructive">
                  {workspace.resource.error.message}
                </p>
              )}
              <div className="grid gap-4 sm:grid-cols-2">
                {CAMPAIGN_FIELDS.map((key) => (
                  <div className="space-y-2" key={key}>
                    <Label htmlFor={key}>
                      {key === 'ref'
                        ? 'Referral'
                        : key.replace('utm_', '').replace(/^./, (letter) => letter.toUpperCase())}
                    </Label>
                    <Input
                      id={key}
                      value={campaign[key] ?? ''}
                      onChange={(e) => setCampaign({ ...campaign, [key]: e.target.value })}
                    />
                  </div>
                ))}
              </div>
            </fieldset>
            {workspace.data && (
              <fieldset className="space-y-2">
                <legend className="font-medium">Organization</legend>
                <select
                  aria-label="New link folder"
                  className="w-full rounded-element border bg-background p-2 text-sm"
                  value={folderId}
                  onChange={(event) => setFolderOverride(event.target.value)}
                >
                  <option value="">Unfiled</option>
                  {workspace.data.folders.map((folder) => (
                    <option key={folder.id} value={folder.id}>
                      {folder.name}
                    </option>
                  ))}
                </select>
                <div className="flex flex-wrap gap-4">
                  {workspace.data.tags.map((tag) => (
                    <label key={tag.id} className="flex items-center gap-2 text-sm">
                      <input
                        type="checkbox"
                        checked={tagIds.includes(tag.id)}
                        onChange={(event) =>
                          setTagOverride(
                            event.target.checked
                              ? [...tagIds, tag.id]
                              : tagIds.filter((id) => id !== tag.id),
                          )
                        }
                      />
                      {tag.name}
                    </label>
                  ))}
                </div>
              </fieldset>
            )}
            <fieldset className="space-y-2">
              <legend className="font-medium">Destination prefill</legend>
              <p className="text-xs text-muted-foreground">
                Add query parameters for pages that accept them. Existing parameters and URL
                fragments are preserved.
              </p>
              {parameters.map((parameter) => (
                <div className="flex flex-wrap gap-2" key={parameter.id}>
                  <Input
                    className="min-w-0 flex-1 basis-32"
                    aria-label="Parameter name"
                    placeholder="Parameter name"
                    value={parameter.key}
                    onChange={(e) =>
                      setParameters(
                        parameters.map((p) =>
                          p.id === parameter.id ? { ...p, key: e.target.value } : p,
                        ),
                      )
                    }
                  />
                  <Input
                    className="min-w-0 flex-1 basis-32"
                    aria-label="Parameter value"
                    placeholder="Value"
                    value={parameter.value}
                    onChange={(e) =>
                      setParameters(
                        parameters.map((p) =>
                          p.id === parameter.id ? { ...p, value: e.target.value } : p,
                        ),
                      )
                    }
                  />
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    onClick={() => setParameters(parameters.filter((p) => p.id !== parameter.id))}
                  >
                    Remove
                  </Button>
                </div>
              ))}
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() =>
                  setParameters([...parameters, { id: crypto.randomUUID(), key: '', value: '' }])
                }
              >
                Add parameter
              </Button>
            </fieldset>
            {destination && (
              <div className="rounded-element bg-muted p-4">
                <p className="mb-2 text-xs font-medium">Destination preview</p>
                <p className="break-all font-mono text-xs">{destination}</p>
              </div>
            )}
            {error && (
              <p role="alert" className="text-destructive">
                {error}
              </p>
            )}
            <Button type="submit" disabled={saving || !!destinationError || !domain.valid}>
              {saving ? 'Creating…' : 'Create tracked link'}
            </Button>
            {target && destinationError && (
              <p className="text-xs text-muted-foreground">{destinationError}</p>
            )}
          </form>
        )}
      </DialogContent>
    </Dialog>
  );
}
