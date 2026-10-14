import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { untypedFrom, untypedRpc } from '@/integrations/supabase/untyped';
import { readInventoryPages } from '@/lib/redirects/inventory';
import type { CampaignFields } from '@/lib/redirects/linkTools';
import type { Redirect } from '@/hooks/useRedirects';

export type WorkspaceResource = 'folders' | 'tags' | 'templates';
export interface LinkFolder {
  id: string;
  name: string;
  description: string;
}
export interface LinkTag {
  id: string;
  name: string;
  color: string;
}
export interface UtmTemplate {
  id: string;
  name: string;
  parameters: CampaignFields;
}
export interface LinkMetadata {
  redirect_key: string;
  folder_id: string | null;
  comment: string;
  tagIds: string[];
  is_archived?: boolean;
}
export interface RedirectWorkspace {
  folders: LinkFolder[];
  tags: LinkTag[];
  templates: UtmTemplate[];
  metadata: Map<string, LinkMetadata>;
}
const TABLES = {
  folders: 'redirect_link_folders',
  tags: 'redirect_link_tags',
  templates: 'redirect_utm_templates',
};
const KEY = ['redirect-link-workspace'];

async function read(
  table: string,
  select: string,
  order: string,
  signal: AbortSignal,
  secondOrder?: string,
) {
  return readInventoryPages(async (offset) => {
    let query = untypedFrom(table)
      .select(select, { count: 'exact' })
      .order(order)
      .range(offset, offset + 999);
    if (secondOrder) query = query.order(secondOrder);
    const { data, count, error } = await query.abortSignal(signal);
    return { data: data as Record<string, unknown>[] | null, count, error };
  });
}

export function useRedirectWorkspace() {
  const client = useQueryClient();
  const query = useQuery<RedirectWorkspace>({
    queryKey: KEY,
    staleTime: 60_000,
    queryFn: async ({ signal }) => {
      const results = await Promise.allSettled([
        read(TABLES.folders, 'id,name,description', 'id', signal),
        read(TABLES.tags, 'id,name,color', 'id', signal),
        read(TABLES.templates, 'id,name,parameters', 'id', signal),
        read(
          'redirect_link_metadata',
          'redirect_key,folder_id,comment,is_archived',
          'redirect_key',
          signal,
        ),
        read(
          'redirect_link_tag_assignments',
          'redirect_key,tag_id',
          'redirect_key',
          signal,
          'tag_id',
        ),
      ]);
      const failed = results.find((result) => result.status === 'rejected');
      if (failed?.status === 'rejected')
        throw new Error(
          failed.reason instanceof Error ? failed.reason.message : 'Could not load link workspace',
        );
      const [folders, tags, templates, metadata, assignments] = results.map((result) =>
        result.status === 'fulfilled' ? result.value : [],
      );
      const links = new Map<string, LinkMetadata>(
        metadata.map((row) => [
          String(row.redirect_key),
          { ...row, tagIds: [] } as unknown as LinkMetadata,
        ]),
      );
      for (const assignment of assignments)
        links.get(String(assignment.redirect_key))?.tagIds.push(String(assignment.tag_id));
      return {
        folders: folders as unknown as LinkFolder[],
        tags: tags as unknown as LinkTag[],
        templates: templates as unknown as UtmTemplate[],
        metadata: links,
      };
    },
  });
  const resource = useMutation({
    mutationFn: async ({
      kind,
      id,
      values,
      remove,
    }: {
      kind: WorkspaceResource;
      id?: string;
      values?: Record<string, unknown>;
      remove?: boolean;
    }) => {
      const table = untypedFrom(TABLES[kind]);
      const result =
        remove && id
          ? await table.delete().eq('id', id)
          : id
            ? await table
                .update(values ?? {})
                .eq('id', id)
                .select()
                .single()
            : await table
                .insert(values ?? {})
                .select()
                .single();
      if (result.error) throw new Error(result.error.message);
      return result.data;
    },
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: KEY });
    },
  });
  const assignment = useMutation({
    mutationFn: async (metadata: LinkMetadata) => {
      const { error } = await untypedRpc('set_redirect_link_metadata', {
        p_redirect_key: metadata.redirect_key,
        p_folder_id: metadata.folder_id,
        p_tag_ids: metadata.tagIds,
        p_comment: metadata.comment,
      });
      if (error) throw new Error(error.message);
    },
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: KEY });
    },
  });
  const bulk = useMutation({
    mutationFn: async ({
      keys,
      action,
      value,
    }: {
      keys: string[];
      action: 'archive' | 'restore' | 'folder' | 'add-tag' | 'remove-tag';
      value?: string | null;
    }) => {
      const { data, error } = await untypedRpc<number>('bulk_redirect_organization', {
        p_keys: keys,
        p_action: action,
        p_value: value ?? null,
      });
      if (error) throw new Error(error.message);
      return data;
    },
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: KEY });
    },
  });
  const createLink = useMutation({
    mutationFn: async ({
      slug,
      target,
      folderId,
      tagIds,
    }: {
      slug: string;
      target: string;
      folderId: string | null;
      tagIds: string[];
    }) => {
      const { data, error } = await untypedRpc<Redirect>('create_redirect_campaign_link', {
        p_slug: slug,
        p_target: target,
        p_folder_id: folderId,
        p_tag_ids: tagIds,
      });
      if (error || !data) throw new Error(error?.message ?? 'Could not create link');
      return data;
    },
    onSuccess: async () => {
      await Promise.allSettled([
        client.invalidateQueries({ queryKey: KEY }),
        client.invalidateQueries({ queryKey: ['cms-content-list'] }),
      ]);
    },
  });
  return { ...query, resource, assignment, createLink, bulk };
}
