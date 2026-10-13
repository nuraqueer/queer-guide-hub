import type { LinkMetadata } from '@/hooks/useRedirectWorkspace';
import type { InventoryRedirect } from './inventory';

export function filterWorkspaceLinks(
  rows: InventoryRedirect[],
  metadata: Map<string, LinkMetadata>,
  folderId: string,
  tagId: string,
) {
  return rows.filter((row) => {
    const link = metadata.get(row.id);
    const folderMatches =
      !folderId || (folderId === 'unfiled' ? !link?.folder_id : link?.folder_id === folderId);
    return folderMatches && (!tagId || !!link?.tagIds.includes(tagId));
  });
}

export function commentSegments(comment: string): Array<{ text: string; url?: string }> {
  return comment
    .split(/(https?:\/\/[^\s<>]+)/g)
    .filter(Boolean)
    .map((text) => {
      if (!/^https?:\/\//.test(text)) return { text };
      try {
        const url = new URL(text);
        return ['http:', 'https:'].includes(url.protocol) ? { text, url: url.href } : { text };
      } catch {
        return { text };
      }
    });
}
