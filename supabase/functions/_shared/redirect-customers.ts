/* eslint no-control-regex: "off" -- Rejecting ASCII control characters is intentional input/header validation. */
import { UUID } from './redirect-api.ts';
import { validPublicTarget } from './link-policy.ts';
export function customerId(value: unknown) {
  if (typeof value !== 'string' || !value.trim() || value.length > 256 || /[\x00-\x1f\x7f]/.test(value))
    throw new Error('Provide a customer ID up to 256 characters');
  return value;
}
export function customerProfileInput(value: unknown, clear = false) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Provide profile fields');
  const data = value as Record<string, unknown>;
  if (Object.keys(data).some(key => !(clear ? ['customerExternalId', 'version'] : ['customerExternalId', 'version', 'name', 'email', 'avatarUrl']).includes(key)) ||
      !Object.hasOwn(data, 'version') || (data.version !== null && (typeof data.version !== 'string' || !UUID.test(data.version))))
    throw new Error('Provide the current profile version');
  const id = customerId(data.customerExternalId);
  const values: Record<string, unknown> = { version: data.version };
  for (const field of ['name', 'email', 'avatarUrl']) {
    if (!Object.hasOwn(data, field)) continue;
    const raw = data[field];
    if (raw !== null && typeof raw !== 'string') throw new Error('Profile fields must be text or null');
    const text = typeof raw === 'string' ? raw.trim() : '';
    if (/[\x00-\x1f\x7f]/.test(text)) throw new Error('Profile text cannot contain control characters');
    if (field === 'name' && text.length > 120) throw new Error('Name must be up to 120 characters');
    if (field === 'email' && text && (text.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text)))
      throw new Error('Provide a valid email address');
    if (field === 'avatarUrl' && text && (text.length > 2048 || !text.startsWith('https://') || !validPublicTarget(text)))
      throw new Error('Avatar must use a public HTTPS URL without credentials');
    values[field] = text || null;
  }
  if (!clear && Object.keys(values).length === 1) throw new Error('Provide profile changes');
  return { id, values };
}
export function customerPage(query: URLSearchParams) {
  if ([...query.keys()].some(key => !['id', 'limit', 'cursor'].includes(key) || query.getAll(key).length !== 1))
    throw new Error('Invalid customer page');
  const id = customerId(query.get('id')), limit = Number(query.get('limit') ?? 50);
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new Error('Invalid customer page size');
  const raw = query.get('cursor');
  let cursor: { at: string; id: string } | null = null;
  if (raw) {
    if (raw.length > 256) throw new Error('Invalid customer cursor');
    const value = JSON.parse(raw);
    if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).sort().join(',') !== 'at,id' ||
        typeof value.at !== 'string' || !Number.isFinite(Date.parse(value.at)) || typeof value.id !== 'string' ||
        !/^(?:click|conversion):[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value.id))
      throw new Error('Invalid customer cursor');
    cursor = value;
  }
  return { id, limit, cursor };
}
