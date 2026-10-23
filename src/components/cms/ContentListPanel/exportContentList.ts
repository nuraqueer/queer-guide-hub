/**
 * exportContentList — generic "export current content type to Excel" for the
 * unified content browser. Reuses src/utils/excelExport (lazy-loads exceljs)
 * so the bespoke per-entity export the legacy admin pages carried is now a
 * built-in capability of /admin/content/:type.
 *
 * Columns mirror the type's configured list columns (plus the title); values
 * are formatted by field type. Exports the full table (matching the legacy
 * pages' "export all rows" behaviour), not just the current page.
 */

import type { ContentTypeConfig, FieldConfig } from '@/types/cms';
import {
  exportToExcel,
  fetchAllRows,
  formatArray,
  formatBoolean,
  generateFilename,
  type ExportColumnDef,
} from '@/utils/excelExport';
import { exportToCsv } from '@/utils/csvExport';
import {
  applyArchivedView,
  applyContentSearch,
  applyFilters,
  applyMergedView,
  type ArchivedView,
  type MergedView,
} from './filterOps';
import type { Filter } from './viewSpec';
import { formatDate, formatDateTime } from '@/lib/format';

type Row = Record<string, unknown>;

function accessorFor(
  field: FieldConfig,
): (row: Row) => string | number | boolean | null | undefined {
  return (row) => {
    const v = row[field.name];
    if (v === null || v === undefined) return '';
    switch (field.type) {
      case 'boolean':
        return formatBoolean(v as boolean);
      case 'date':
        return formatDate(v as string);
      case 'datetime':
        return formatDateTime(v as string);
      case 'tags':
      case 'images':
      case 'multiselect':
        return Array.isArray(v) ? formatArray(v as string[]) : String(v);
      case 'number':
        return typeof v === 'number' ? v : Number(v) || 0;
      case 'json':
      case 'location':
      case 'social_links':
        return typeof v === 'object' ? JSON.stringify(v) : String(v);
      default:
        if (Array.isArray(v)) return formatArray(v as string[]);
        if (typeof v === 'object') return JSON.stringify(v);
        return String(v);
    }
  };
}

/**
 * The slice of the list the export should match. Omitted = every row in the
 * table, which is what the taxonomy-wide export wants.
 */
export interface ExportScope {
  filters?: Filter[];
  search?: string;
  archivedView?: ArchivedView;
  mergedView?: MergedView;
}

/** Title first, then the export fields (deduped by column name), then the id. */
export function exportColumnsFor(
  config: ContentTypeConfig,
  fields: FieldConfig[],
): ExportColumnDef<Row>[] {
  const seen = new Set<string>([config.titleField, config.primaryKey]);
  const rest = fields.filter((f) => {
    if (f.virtual || seen.has(f.name)) return false;
    seen.add(f.name);
    return true;
  });
  return [
    { header: 'Title', accessor: (r) => (r[config.titleField] as string) ?? '' },
    ...rest.map((f) => ({ header: f.label, accessor: accessorFor(f) })),
    { header: 'ID', accessor: (r) => String(r[config.primaryKey] ?? '') },
  ];
}

/** Narrow a fetch to what the list currently shows, with a stable tiebreak. */
function scopeRefiner(config: ContentTypeConfig, scope?: ExportScope) {
  return <Q>(query: Q): Q => {
    let q = query as never;
    if (scope?.search) q = applyContentSearch(q, config, scope.search) as never;
    if (scope?.filters?.length) q = applyFilters(q, scope.filters) as never;
    if (scope?.archivedView)
      q = applyArchivedView(q, config.lifecycle?.archive, scope.archivedView) as never;
    if (scope?.mergedView) q = applyMergedView(q, config.merge, scope.mergedView) as never;
    // Offset pagination over a non-unique order can skip or repeat rows
    // between pages; the primary key makes the order total.
    return (q as unknown as { order: (c: string, o: object) => Q }).order(config.primaryKey, {
      ascending: true,
    });
  };
}

export function fetchContentRows(config: ContentTypeConfig, scope?: ExportScope) {
  return fetchAllRows<Row>(
    config.tableName,
    '*',
    { column: config.titleField, ascending: true },
    1000,
    scopeRefiner(config, scope),
  );
}

export async function exportContentType(
  config: ContentTypeConfig,
  listColumns: FieldConfig[],
  format: ExportFormat = 'Excel',
  scope?: ExportScope,
): Promise<void> {
  // Types with no list columns (tags) export their configured fields rather
  // than a file of names alone.
  const exportFields = listColumns.length === 0 ? config.fields : listColumns;
  const columns = exportColumnsFor(config, exportFields);
  const rows = await fetchContentRows(config, scope);

  if (format === 'CSV') {
    exportToCsv(rows, columns, generateFilename(config.id).replace(/\.xlsx$/, '.csv'));
  } else {
    await exportToExcel(rows, columns, generateFilename(config.id));
  }
}

export type ExportFormat = 'Excel' | 'CSV';
