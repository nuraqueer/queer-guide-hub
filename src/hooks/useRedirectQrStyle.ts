import { hydrateQrStyles } from '@/lib/redirects/qrLogos';
import { qrStyleError } from '@/lib/redirects/qr';
import { useQuery } from '@tanstack/react-query';
import { useAuth } from './useAuth';
import { memberRedirectApi } from '@/lib/redirects/memberApi';
import {
  readEffectiveQrStyles,
  qrStylePreferencePath,
  type EffectiveQrStyle,
  type QrStylePreference,
} from '@/lib/redirects/qrPreferences';
export function useRedirectQrStyle(linkId?: string, skipLogos = false) {
  const { user } = useAuth();
  return useQuery({
    queryKey: ['redirect-qr-style', user?.id, linkId ?? 'workspace', skipLogos],
    enabled: !!user,
    queryFn: async ({ signal }) => {
      if (linkId)
        return (
          await hydrateQrStyles(await readEffectiveQrStyles([linkId], signal), signal, skipLogos)
        )[0];
      const result = await memberRedirectApi<QrStylePreference>(
        qrStylePreferencePath(),
        'GET',
        undefined,
        signal,
      );
      if (!result.effectiveStyle || qrStyleError(result.effectiveStyle))
        throw new Error('Invalid saved QR style response');
      return (
        await hydrateQrStyles(
          [
            {
              id: 'workspace',
              effectiveLogo: result.effectiveLogo,
              logoSource: result.logoSource,
              style: result.effectiveStyle,
              source: Object.keys(result.style).length ? 'workspace' : 'default',
            } as EffectiveQrStyle,
          ],
          signal,
          skipLogos,
        )
      )[0];
    },
    gcTime: 60000,
    staleTime: 0,
    retry: false,
    refetchOnWindowFocus: 'always',
  });
}
