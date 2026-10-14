import { memberRedirectApi } from './memberApi';
import { MANUAL_REDIRECT_FIELDS } from '../../../supabase/functions/_shared/redirect-manual-records';
export async function loadManualRedirect(id: string) {
  return memberRedirectApi<Record<string, unknown>>('/manual-records/' + id);
}
export function manualRedirectValues(data: Record<string, unknown>) {
  const values = Object.fromEntries(
    Object.entries(data).filter(([key]) => MANUAL_REDIRECT_FIELDS.includes(key)),
  );
  if (values.type === 'PATH') {
    values.slug = null;
    values.domain_id = null;
  }
  if (values.type === 'SHORT') {
    values.source_path = null;
    values.match_kind = 'EXACT';
  }
  return values;
}
export async function saveManualRedirect(
  id: string | null,
  data: Record<string, unknown>,
  expectedUpdatedAt: string | null,
) {
  const values = manualRedirectValues(data);
  return memberRedirectApi<Record<string, unknown>>(
    '/manual-records' + (id ? '/' + id : ''),
    id ? 'PATCH' : 'POST',
    { values, expectedUpdatedAt: id ? expectedUpdatedAt : null },
  );
}
