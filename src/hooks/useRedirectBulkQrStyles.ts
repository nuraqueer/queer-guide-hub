import { useQuery } from '@tanstack/react-query';
import { useAuth } from './useAuth';
import type { InventoryRedirect } from '@/lib/redirects/inventory';
import { memberRedirectApi } from '@/lib/redirects/memberApi';
import {
  qrStylePreferencePath,
  readEffectiveQrStyles,
  type QrStylePreference,
} from '@/lib/redirects/qrPreferences';
import type { QrStyle } from '@/lib/redirects/qr';
export function useRedirectBulkQrStyles(rows: InventoryRedirect[]) {
  const { user } = useAuth();
  return useQuery({
    queryKey: [
      'redirect-qr-style',
      user?.id,
      'bulk',
      rows.map((row) => [row.id, row.isShortLink, row.manualId, row.source, row.domainHostname]),
    ],
    enabled: !!user,
    retry: false,
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
      const byId = new Map(effective.map((row) => [row.id, row.style]));
      return new Map<string, QrStyle>(
        rows.map((row) => {
          const style =
            row.isShortLink && row.manualId ? byId.get(row.manualId) : workspace?.effectiveStyle;
          if (!style) throw new Error('Missing saved QR style');
          return [row.id, style];
        }),
      );
    },
  });
}
