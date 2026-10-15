import { qrStyleError } from '@/lib/redirects/qr';
import { hydrateQrStyles, type LoadedQrStyle } from '@/lib/redirects/qrLogos';
import { useQuery } from '@tanstack/react-query';
import { useAuth } from './useAuth';
import type { InventoryRedirect } from '@/lib/redirects/inventory';
import { memberRedirectApi } from '@/lib/redirects/memberApi';
import {
  qrStylePreferencePath,
  readEffectiveQrStyles,
  type QrStylePreference,
} from '@/lib/redirects/qrPreferences';
export function useRedirectBulkQrStyles(rows: InventoryRedirect[], skipLogos = false) {
  const { user } = useAuth();
  return useQuery({
    queryKey: [
      'redirect-qr-style',
      user?.id,
      'bulk',
      skipLogos,
      rows.map((row) => [row.id, row.isShortLink, row.manualId, row.source, row.domainHostname]),
    ],
    enabled: !!user,
    retry: false,
    gcTime: 60000,
    staleTime: 0,
    queryFn: async ({ signal }) => {
      const managed = rows.filter((row) => row.isShortLink && row.manualId);
      const needsWorkspace = managed.length !== rows.length;
      const [effective, workspace] = await Promise.all([
        readEffectiveQrStyles(
          managed.map((row) => row.manualId!),
          signal,
        ),
        needsWorkspace
          ? memberRedirectApi<QrStylePreference>(qrStylePreferencePath(), 'GET', undefined, signal)
          : Promise.resolve(null),
      ]);
      const raw = rows.map((row) => {
        const result =
          row.isShortLink && row.manualId
            ? effective.find((item) => item.id === row.manualId)
            : workspace
              ? { style: workspace.effectiveStyle, effectiveLogo: workspace.effectiveLogo }
              : null;
        if (!result?.style || qrStyleError(result.style)) throw new Error('Missing saved QR style');
        return { id: row.id, style: result.style, effectiveLogo: result.effectiveLogo };
      });
      const loaded = await hydrateQrStyles(raw, signal, skipLogos);
      return new Map<string, LoadedQrStyle>(loaded.map((row) => [row.id, row.style]));
    },
  });
}
