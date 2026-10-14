import { UUID } from './redirect-api.ts';
import { validPublicTarget } from './link-policy.ts';

const reservedLinkSlugs = new Set(['admin','api','go','auth','login','signup','sitemap','robots','favicon','manifest','sw','index','health','status','null','undefined','test','www','mail','ftp','cdn','assets','static','public']);
export const LINK_SCOPES = ['conversions:write', 'events:read', 'links:read', 'links:write', 'workspace:read', 'workspace:write'];
export function randomLinkSlug() {
  return Array.from(crypto.getRandomValues(new Uint8Array(6)), byte => byte.toString(16).padStart(2, '0')).join('');
}
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Expected an object');
  return value as Record<string, unknown>;
}
function uuid(value: unknown) { return typeof value === 'string' && UUID.test(value); }
function stringMap(value: unknown) {
  const map = object(value);
  if (Object.keys(map).length > 100 || Object.entries(map).some(([key, val]) => !key || key.length > 200 || typeof val !== 'string' || val.length > 2000 || ['pw','password','qg_click_id','qg_qr'].includes(key))) throw new Error('Invalid query defaults');
  return map;
}
export function linkInput(value: unknown, operation: 'create' | 'update' | 'upsert') {
  const data = object(value), result: Record<string, unknown> = {};
  const fields = ['slug','target','statusCode','isEnabled','queryMode','queryOverride','utmDefaults','expiresAt','folderId','tagIds','comment'];
  if (Object.keys(data).some(key => !fields.includes(key))) throw new Error('Unknown link field');
  if (operation !== 'update' && data.target === undefined) throw new Error('A destination is required');
  if (operation === 'upsert' && data.slug === undefined) throw new Error('Upsert requires a slug');
  if (operation === 'update' && !Object.keys(data).length) throw new Error('Provide fields to update');
  if (data.slug !== undefined) {
    if (typeof data.slug !== 'string' || !/^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$/.test(data.slug)) throw new Error('Slug must be 3–64 lowercase letters, numbers or hyphens');
    if (reservedLinkSlugs.has(data.slug)) throw new Error('This slug is reserved');
    result.slug = data.slug;
  }
  if (data.target !== undefined) {
    if (typeof data.target !== 'string' || !validPublicTarget(data.target)) throw new Error('Choose a public HTTP(S) destination or a valid site path');
    const url = new URL(data.target, 'https://queer.guide');
    if (['queer.guide','www.queer.guide'].includes(url.hostname) && url.pathname.startsWith('/go/')) throw new Error('Short-link destinations cannot point to another short link');
    result.target = data.target.trim();
  }
  if (data.statusCode !== undefined && ![301,302,307,308].includes(data.statusCode as number)) throw new Error('Invalid redirect status');
  if (data.isEnabled !== undefined && typeof data.isEnabled !== 'boolean') throw new Error('Invalid enabled state');
  if (data.queryMode !== undefined && !['PRESERVE','DROP','OVERRIDE'].includes(data.queryMode as string)) throw new Error('Invalid query mode');
  if (data.expiresAt !== undefined && data.expiresAt !== null && (typeof data.expiresAt !== 'string' || !Number.isFinite(Date.parse(data.expiresAt)))) throw new Error('Invalid expiration date');
  if (data.folderId !== undefined && data.folderId !== null && !uuid(data.folderId)) throw new Error('Invalid folder ID');
  if (data.tagIds !== undefined && (!Array.isArray(data.tagIds) || data.tagIds.length > 100 || data.tagIds.some(id => !uuid(id)))) throw new Error('Invalid tag IDs');
  if (data.comment !== undefined && (typeof data.comment !== 'string' || data.comment.length > 10000)) throw new Error('Comment exceeds 10,000 characters');
  for (const field of fields) if (data[field] !== undefined && result[field] === undefined) result[field] = data[field];
  for (const field of ['queryOverride','utmDefaults']) if (data[field] !== undefined && data[field] !== null) result[field] = stringMap(data[field]);
  if (result.utmDefaults && Object.keys(result.utmDefaults as Record<string, unknown>).some(key => !['utm_source','utm_medium','utm_campaign','utm_term','utm_content','ref'].includes(key))) throw new Error('Unknown campaign default');
  if (typeof result.expiresAt === 'string') result.expiresAt = new Date(result.expiresAt).toISOString();
  if (Array.isArray(result.tagIds)) result.tagIds = [...new Set(result.tagIds)];
  return result;
}
export function bulkLinkInput(value: unknown) {
  const body = object(value);
  if (Object.keys(body).some(key => key !== 'operations') || !Array.isArray(body.operations) || !body.operations.length || body.operations.length > 100) throw new Error('Provide 1–100 operations');
  return body.operations.map(value => {
    const op = object(value);
    if (Object.keys(op).some(key => !['operation','id','data'].includes(key)) || !['create','update','upsert','delete'].includes(op.operation as string)) throw new Error('Invalid bulk operation');
    if (['update','delete'].includes(op.operation as string) ? !uuid(op.id) : op.id !== undefined) throw new Error('Invalid bulk link ID');
    if (op.operation === 'delete') {
      if (op.data !== undefined) throw new Error('Delete does not accept link fields');
      return { operation: 'delete', id: op.id };
    }
    return { operation: op.operation, ...(op.id ? {id: op.id} : {}), data: linkInput(op.data, op.operation as 'create'|'update'|'upsert') };
  });
}
export function linkListInput(value: unknown) {
  const filters = object(value);
  if (Object.keys(filters).some(key => !['search','ids','folderId','tagId','isEnabled'].includes(key))) throw new Error('Unknown link filter');
  if (filters.search !== undefined && (typeof filters.search !== 'string' || filters.search.length > 200)) throw new Error('Search exceeds 200 characters');
  if (filters.ids !== undefined && (!Array.isArray(filters.ids) || filters.ids.length > 100 || filters.ids.some(id => !uuid(id)))) throw new Error('Invalid link IDs');
  for (const key of ['folderId','tagId']) if (filters[key] !== undefined && !uuid(filters[key])) throw new Error('Invalid organization filter');
  if (filters.isEnabled !== undefined && typeof filters.isEnabled !== 'boolean') throw new Error('Invalid enabled filter');
  return filters;
}

export function workspaceInput(kind: string, value: unknown, create: boolean) {
 const data=object(value);
 const allowed=kind==='folders'?['name','description']:kind==='tags'?['name','color']:['name','parameters'];
 if(Object.keys(data).some(key=>!allowed.includes(key))||!Object.keys(data).length)throw new Error('Invalid workspace fields');
 if(create&&data.name===undefined)throw new Error('A resource name is required');
 if(data.name!==undefined&&(typeof data.name!=='string'||!data.name.trim()||data.name.trim().length>100))throw new Error('Name must be 1–100 characters');
 if(data.description!==undefined&&(typeof data.description!=='string'||data.description.length>2000))throw new Error('Description exceeds 2,000 characters');
 if(data.color!==undefined&&!['gray','red','orange','yellow','green','blue','purple','pink'].includes(data.color as string))throw new Error('Invalid tag color');
 if(data.parameters!==undefined){const map=stringMap(data.parameters);if(Object.keys(map).some(key=>!['utm_source','utm_medium','utm_campaign','utm_term','utm_content','ref'].includes(key)))throw new Error('Invalid campaign template');}
 return {...data,...(typeof data.name==='string'?{name:data.name.trim()}:{})};
}
