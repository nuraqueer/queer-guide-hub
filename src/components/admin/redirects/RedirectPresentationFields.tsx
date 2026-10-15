import { useState, type Dispatch, type SetStateAction } from 'react';
import { supabase } from '@/integrations/supabase/client';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Button } from '@/components/ui/button';
import { preparePreviewImage } from '@/lib/redirects/previewImage';
import type { LinkPolicy } from '../../../../supabase/functions/_shared/link-policy';
export function RedirectPresentationFields({
  id,
  policy,
  onChange,
  onUploading,
}: {
  id: string;
  policy: LinkPolicy;
  onChange: Dispatch<SetStateAction<LinkPolicy>>;
  onUploading: (busy: boolean) => void;
}) {
  const [busy, setBusy] = useState(false),
    [error, setError] = useState('');
  const changePreview = (key: 'title' | 'description' | 'image' | 'video', value: string) => {
    onChange((current) => {
      const preview = { ...current.preview };
      if (value) preview[key] = value;
      else delete preview[key];
      return { ...current, preview };
    });
  };
  const upload = async (file: File) => {
    setBusy(true);
    onUploading(true);
    setError('');
    try {
      const image = await preparePreviewImage(file);
      const { data, error: uploadError } = await supabase.functions.invoke(
        'redirect-api/links/' + id + '/preview-image',
        { body: { image } },
      );
      if (uploadError || data?.error) throw new Error(data?.error ?? uploadError?.message);
      changePreview('image', data.image);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not upload artwork');
    } finally {
      setBusy(false);
      onUploading(false);
    }
  };
  const generate = async () => {
    setBusy(true);
    onUploading(true);
    setError('');
    try {
      const { data, error: generationError } = await supabase.functions.invoke(
        'redirect-api/links/' + id + '/preview-generate',
        { body: {} },
      );
      if (generationError || data?.error) throw new Error(data?.error ?? generationError?.message);
      if (typeof data?.title !== 'string' || typeof data?.description !== 'string')
        throw new Error('Invalid generated preview');
      onChange((current) => ({
        ...current,
        preview: { ...current.preview, title: data.title, description: data.description },
      }));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not generate preview');
    } finally {
      setBusy(false);
      onUploading(false);
    }
  };
  return (
    <fieldset className="space-y-4" disabled={busy}>
      <legend className="font-medium">Sharing and presentation</legend>
      <label className="flex items-center gap-2">
        <input
          type="checkbox"
          checked={policy.preview !== undefined}
          onChange={(event) => {
            const next = { ...policy };
            if (event.target.checked) next.preview = {};
            else delete next.preview;
            onChange(next);
          }}
        />
        Custom social preview
      </label>
      {policy.preview && (
        <div className="space-y-4">
          <Button type="button" variant="outline" onClick={() => void generate()}>
            Generate title and description
          </Button>
          <p className="text-xs text-muted-foreground">
            Uses the saved destination’s public page content through Firecrawl and the configured AI
            provider. Review the draft, then Save to apply it. Generation replaces the draft title
            and description.
          </p>
          {busy && <p role="status">Preparing preview…</p>}
          <div className="space-y-2">
            <Label htmlFor="redirect-preview-title">Preview title</Label>
            <Input
              id="redirect-preview-title"
              maxLength={120}
              value={policy.preview.title ?? ''}
              onChange={(event) => changePreview('title', event.target.value)}
            />
            <p className="text-xs text-muted-foreground">{policy.preview.title?.length ?? 0}/120</p>
          </div>
          <div className="space-y-2">
            <Label htmlFor="redirect-preview-description">Preview description</Label>
            <textarea
              className="w-full rounded-element border bg-background p-4"
              id="redirect-preview-description"
              maxLength={240}
              rows={3}
              value={policy.preview.description ?? ''}
              onChange={(event) => changePreview('description', event.target.value)}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="redirect-preview-image">Upload artwork</Label>
            <Input
              id="redirect-preview-image"
              type="file"
              accept="image/png,image/jpeg"
              onChange={(event) => {
                const file = event.target.files?.[0];
                if (file) void upload(file);
                event.target.value = '';
              }}
            />
            <p className="text-sm text-muted-foreground">
              PNG or JPG, up to 1.5 MB. Center-cropped to 1200 × 630. Uploaded artwork is public;
              use public campaign images.
            </p>
          </div>
          {policy.preview.image && (
            <div className="space-y-2">
              <img
                className="aspect-[1200/630] w-full rounded-element object-cover"
                src={policy.preview.image}
                alt="Social preview artwork"
                referrerPolicy="no-referrer"
              />
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => changePreview('image', '')}
              >
                Remove preview image
              </Button>
              <p className="text-xs text-muted-foreground">
                Removes the image from this preview. Its public asset URL remains available.
              </p>
            </div>
          )}
          <div className="space-y-2">
            <Label htmlFor="redirect-preview-video">Video preview URL</Label>
            <Input
              id="redirect-preview-video"
              placeholder="https://example.com/preview.mp4"
              value={policy.preview.video ?? ''}
              onChange={(event) => changePreview('video', event.target.value)}
            />
            <p className="text-xs text-muted-foreground">
              Public HTTPS video. Use an image fallback for platforms that do not support video
              previews.
            </p>
          </div>
          <div className="border-t pt-4">
            <p className="break-words font-medium">
              {policy.preview.title || 'Open link · queer.guide'}
            </p>
            <p className="break-words text-sm text-muted-foreground">
              {policy.preview.description || 'Open this link to continue.'}
            </p>
          </div>
        </div>
      )}
      {error && (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      )}
      <label className="flex items-center gap-2">
        <input
          type="checkbox"
          checked={policy.cloaked === true}
          onChange={(event) => onChange({ ...policy, cloaked: event.target.checked })}
        />
        Keep the short URL while showing the destination in a frame
      </label>
      <p className="text-sm text-muted-foreground">
        Framing requires HTTPS. Some sites block frames or third-party cookies; visitors always have
        a direct-link fallback. Social crawlers see your custom preview. Protected links require the
        password first.
      </p>
    </fieldset>
  );
}
