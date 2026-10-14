import { useId, useRef, useState, type SetStateAction } from 'react';
import { qrAppearance, type LoadedQrStyle } from '@/lib/redirects/qrLogos';
import type { QrStyle } from '@/lib/redirects/qr';

// Appearance edits must never copy the first link's saved logo to a bulk selection.
export function useQrExportStyle(scope: string) {
  const instance = useId();
  const sequence = useRef(0);
  const [raw, setRaw] = useState<{
    scope: string;
    appearance?: Omit<QrStyle, 'logo'>;
    logo?: { mode: 'none' | 'custom'; data?: string; identity: string };
  }>();
  const local = raw?.scope === scope ? raw : undefined;
  const compose = (baseline: LoadedQrStyle): LoadedQrStyle => ({
    ...qrAppearance(local?.appearance ?? baseline),
    logo: local?.logo ? local.logo.data : baseline.logo,
    logoIdentity: local?.logo ? local.logo.identity : baseline.logoIdentity,
  });
  const change = (baseline: LoadedQrStyle, value: SetStateAction<QrStyle>) => {
    const previous = compose(baseline);
    const next = typeof value === 'function' ? value(previous) : value;
    setRaw({
      scope,
      appearance:
        JSON.stringify(qrAppearance(previous)) === JSON.stringify(qrAppearance(next))
          ? local?.appearance
          : qrAppearance(next),
      logo:
        previous.logo === next.logo
          ? local?.logo
          : {
              mode: next.logo ? 'custom' : 'none',
              data: next.logo,
              identity: instance + ':' + ++sequence.current,
            },
    });
  };
  return {
    compose,
    change,
    hasAppearance: !!local?.appearance,
    logoMode: local?.logo?.mode ?? ('saved' as const),
    skipLogos: !!local?.logo,
    hideLogo: () => setRaw({ ...local, scope, logo: { mode: 'none', identity: 'none' } }),
    savedLogo: () => setRaw({ ...local, scope, logo: undefined }),
    savedAppearance: () => setRaw({ ...local, scope, appearance: undefined }),
    reset: () => setRaw(undefined),
  };
}
