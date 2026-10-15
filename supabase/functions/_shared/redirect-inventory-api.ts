import { deployedRedirectManifest } from './redirect-inventory-manifest.ts';
import { UUID } from './redirect-api.ts';
export function inventoryQuery(query: URLSearchParams) {
  const allowed = [
    'limit',
    'after',
    'search',
    'folderId',
    'tagId',
    'domainId',
    'origin',
    'kind',
    'excludeManaged',
    'isArchived',
  ];
  if ([...query.keys()].some((key) => !allowed.includes(key)))
    throw new Error('Unknown inventory filter');
  const limit = Number(query.get('limit') ?? 50),
    after = query.get('after');
  if (!Number.isInteger(limit) || limit < 0 || limit > 100 || (after?.length ?? 0) > 4096)
    throw new Error('Invalid inventory page');
  const filters: Record<string, unknown> = {};
  for (const key of ['search', 'origin', 'kind'])
    if (query.has(key)) {
      const value = query.get(key)!;
      if (value.length > 200) throw new Error('Inventory filter is too long');
      filters[key] = value;
    }
  if (filters.kind && !['Manual', 'Automatic', 'Static', 'Client'].includes(String(filters.kind)))
    throw new Error('Invalid inventory kind');
  for (const key of ['folderId', 'tagId', 'domainId'])
    if (query.has(key)) {
      const value = query.get(key)!;
      if (key === 'domainId' && value === 'builtin') filters[key] = null;
      else {
        if (!UUID.test(value)) throw new Error('Invalid inventory resource ID');
        filters[key] = value;
      }
    }
  for (const key of ['excludeManaged', 'isArchived'])
    if (query.has(key)) {
      const value = query.get(key);
      if (!['true', 'false'].includes(value ?? '')) throw new Error('Invalid inventory flag');
      filters[key] = value === 'true';
    }
  return {
    p_manifest: deployedRedirectManifest,
    p_filters: filters,
    p_limit: limit,
    p_after: after,
  };
}
export function inventoryOperations(body: unknown) {
  if (!Array.isArray(body) || body.length < 1 || body.length > 100)
    throw new Error('Select 1–100 inventory records');
  const seen = new Set<string>();
  for (const raw of body) {
    if (
      !raw ||
      typeof raw !== 'object' ||
      Array.isArray(raw) ||
      Object.keys(raw).some((key) => !['id', 'version', 'values'].includes(key))
    )
      throw new Error('Invalid inventory operation');
    const op = raw as Record<string, unknown>;
    if (typeof op.id !== 'string' || !op.id || op.id.length > 4096 || seen.has(op.id))
      throw new Error('Invalid or duplicate inventory record');
    seen.add(op.id);
    if (
      !Object.hasOwn(op, 'version') ||
      (op.version !== null && (typeof op.version !== 'string' || !UUID.test(op.version)))
    )
      throw new Error('Provide the current metadata version');
    const values = op.values as Record<string, unknown>;
    if (
      !values ||
      typeof values !== 'object' ||
      Array.isArray(values) ||
      !Object.keys(values).length ||
      Object.keys(values).some(
        (key) => !['folderId', 'tagIds', 'comment', 'isArchived'].includes(key),
      )
    )
      throw new Error('Only inventory organization fields may be changed');
    if (
      values.folderId !== undefined &&
      values.folderId !== null &&
      (typeof values.folderId !== 'string' || !UUID.test(values.folderId))
    )
      throw new Error('Invalid folder ID');
    if (
      (values.comment !== undefined &&
        (typeof values.comment !== 'string' || values.comment.length > 10000)) ||
      (values.isArchived !== undefined && typeof values.isArchived !== 'boolean')
    )
      throw new Error('Invalid comment or archive flag');
    if (
      values.tagIds !== undefined &&
      (!Array.isArray(values.tagIds) ||
        values.tagIds.length > 100 ||
        values.tagIds.some((id) => typeof id !== 'string' || !UUID.test(id)))
    )
      throw new Error('Invalid tags');
  }
  return body;
}
export const redirectInventoryManifest = deployedRedirectManifest;
