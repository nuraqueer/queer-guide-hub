import { memberRedirectApi } from './memberApi';
import { qrStyleError, type QrStyle } from './qr';
export type SavedQrAppearance = Omit<QrStyle, 'logo'>;
export interface QrStylePreference {
  version: string | null;
  style: Partial<SavedQrAppearance>;
  effectiveStyle: SavedQrAppearance;
  domainId: string | null;
}
export interface EffectiveQrStyle {
  id: string;
  style: SavedQrAppearance;
  source: 'default' | 'workspace' | 'domain';
}
export function qrStylePreferencePath(domainId?: string | null) {
  return domainId ? '/qr-styles/domains/' + domainId : '/qr-styles/workspace';
}
export async function readEffectiveQrStyles(ids: string[], signal?: AbortSignal) {
  if (!ids.length) return [];
  const result = await memberRedirectApi<{ data: EffectiveQrStyle[] }>(
    '/qr-styles/links?ids=' + encodeURIComponent([...new Set(ids)].join(',')),
    'GET',
    undefined,
    signal,
  );
  if (
    !Array.isArray(result.data) ||
    result.data.length !== new Set(ids).size ||
    new Set(result.data.map((row) => row.id)).size !== result.data.length ||
    result.data.some(
      (row) =>
        !ids.includes(row.id) ||
        !row.style ||
        qrStyleError(row.style) ||
        !['default', 'workspace', 'domain'].includes(row.source),
    )
  )
    throw new Error('Invalid saved QR style response');
  return result.data;
}
