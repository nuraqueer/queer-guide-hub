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
export function useRedirectQrStyle(linkId?: string) {
  const { user } = useAuth();
  return useQuery({
    queryKey: ['redirect-qr-style', user?.id, linkId ?? 'workspace'],
    enabled: !!user,
    queryFn: async ({ signal }) => {
      if (linkId) return (await readEffectiveQrStyles([linkId], signal))[0];
      const result = await memberRedirectApi<QrStylePreference>(
        qrStylePreferencePath(),
        'GET',
        undefined,
        signal,
      );
      if (!result.effectiveStyle || qrStyleError(result.effectiveStyle))
        throw new Error('Invalid saved QR style response');
      return {
        id: 'workspace',
        style: result.effectiveStyle,
        source: Object.keys(result.style).length ? 'workspace' : 'default',
      } as EffectiveQrStyle;
    },
    staleTime: 0,
    retry: false,
    refetchOnWindowFocus: 'always',
  });
}
