import type { Filter, SortSpec } from './viewSpec';
import type { ContentTypeConfig } from '@/types/cms';
function values(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [value];
}
function compare(a: unknown, b: unknown): number {
  if (typeof a === 'number' || typeof b === 'number') return Number(a) - Number(b);
  return String(a ?? '').localeCompare(String(b ?? ''));
}
function matches(row: Record<string, unknown>, filter: Filter) {
  const value = row[filter.field];
  const wanted = filter.value;
  const list = values(wanted).filter((v) => v !== null && v !== undefined && v !== '');
  if (['in', 'not_in', 'has_all', 'has_any'].includes(filter.op) && list.length === 0) return true;
  if (
    !['is_empty', 'is_not_empty', 'is_true', 'is_false'].includes(filter.op) &&
    (wanted == null || wanted === '')
  )
    return true;
  const empty = value == null || value === '' || (Array.isArray(value) && value.length === 0);
  const text = String(value ?? '').toLocaleLowerCase();
  const term = String(wanted ?? '').toLocaleLowerCase();
  switch (filter.op) {
    case 'is_empty':
      return empty;
    case 'is_not_empty':
      return !empty;
    case 'is_true':
      return value === true;
    case 'is_false':
      return value === false;
    case 'on':
      return String(value ?? '').slice(0, 10) === String(wanted ?? '').slice(0, 10);
    case 'eq':
      return String(value ?? '') === String(wanted ?? '');
    case 'neq':
      return value != null && String(value) !== String(wanted ?? '');
    case 'in':
      return list.includes(value);
    case 'not_in':
      return value != null && !list.includes(value);
    case 'has_all':
      return list.every((v) => values(value).includes(v));
    case 'has_any':
      return list.some((v) => values(value).includes(v));
    case 'contains':
      return text.includes(term);
    case 'not_contains':
      return value != null && !text.includes(term);
    case 'starts_with':
      return text.startsWith(term);
    case 'gt':
    case 'after':
      return value != null && compare(value, wanted) > 0;
    case 'gte':
      return value != null && compare(value, wanted) >= 0;
    case 'lt':
    case 'before':
      return value != null && compare(value, wanted) < 0;
    case 'lte':
      return value != null && compare(value, wanted) <= 0;
    case 'between': {
      const range = wanted as { from?: unknown; to?: unknown; min?: unknown; max?: unknown };
      const lo = range.from ?? range.min;
      const hi = range.to ?? range.max;
      return (
        value != null &&
        (lo == null || compare(value, lo) >= 0) &&
        (hi == null || compare(value, hi) <= 0)
      );
    }
    default:
      return true;
  }
}
export function queryLocalRows(
  rows: Record<string, unknown>[],
  config: ContentTypeConfig,
  search: string,
  filters: Filter[],
  sorts: SortSpec[],
  page: number,
  size: number,
) {
  const term = search.trim().toLocaleLowerCase();
  const fields = config.listSearchFields ?? [config.titleField];
  const filtered = rows.filter(
    (row) =>
      (!term ||
        fields.some((field) =>
          String(row[field] ?? '')
            .toLocaleLowerCase()
            .includes(term),
        )) &&
      filters.every((f) => matches(row, f)),
  );
  filtered.sort((a, b) => {
    for (const sort of sorts) {
      const field = sort.field === 'title' ? config.titleField : sort.field;
      const av = a[field],
        bv = b[field];
      let result: number;
      if (av == null && bv != null) result = 1;
      else if (bv == null && av != null) result = -1;
      else if (typeof av === 'number' && typeof bv === 'number') result = av - bv;
      else result = String(av ?? '').localeCompare(String(bv ?? ''), undefined, { numeric: true });
      if (result) return sort.dir === 'desc' ? -result : result;
    }
    return String(a[config.primaryKey]).localeCompare(String(b[config.primaryKey]));
  });
  return { rows: filtered.slice(page * size, (page + 1) * size), total: filtered.length };
}
