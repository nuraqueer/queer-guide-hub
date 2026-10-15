const KEY = 'qg:redirect:attribution';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export interface ClickAttribution {
  clickId: string;
  capturedAt: number;
  expiresAt: number;
}
export function clearRedirectAttribution(storage?: Storage) {
  try {
    (storage ?? localStorage).removeItem(KEY);
  } catch {
    /* Browser storage can be disabled. */
  }
}
export function readRedirectAttribution(
  allowed: boolean,
  storage?: Storage,
  now = Date.now(),
): ClickAttribution | null {
  if (!allowed) {
    clearRedirectAttribution(storage);
    return null;
  }
  try {
    const value = JSON.parse((storage ?? localStorage).getItem(KEY) ?? 'null');
    if (
      !value ||
      typeof value.clickId !== 'string' ||
      !UUID.test(value.clickId) ||
      !Number.isFinite(value.capturedAt) ||
      !Number.isFinite(value.expiresAt) ||
      value.capturedAt > now ||
      value.expiresAt <= now ||
      value.expiresAt - value.capturedAt !== 30 * 86400000
    ) {
      clearRedirectAttribution(storage);
      return null;
    }
    return value;
  } catch {
    clearRedirectAttribution(storage);
    return null;
  }
}
export function captureRedirectAttribution(
  url: URL,
  allowed: boolean,
  storage?: Storage,
  now = Date.now(),
): boolean {
  if (!allowed) {
    clearRedirectAttribution(storage);
    return false;
  }
  const clickId = url.searchParams.get('qg_click_id');
  if (!clickId || !UUID.test(clickId)) return false;
  try {
    (storage ?? localStorage).setItem(
      KEY,
      JSON.stringify({ clickId, capturedAt: now, expiresAt: now + 30 * 86400000 }),
    );
    return true;
  } catch {
    return false;
  }
}
