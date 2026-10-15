import type { QrLogoAsset } from './qrLogos';
export interface PasswordBranding {
  linkId: string;
  version: string | null;
  updatedAt: string | null;
  brandName: string | null;
  logoAsset: QrLogoAsset | null;
  canEdit: boolean;
}
