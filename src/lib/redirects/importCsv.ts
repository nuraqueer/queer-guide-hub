import { linkInput } from '../../../supabase/functions/_shared/redirect-links';
import { UUID } from '../../../supabase/functions/_shared/redirect-api';
export type ImportMode = 'create' | 'update' | 'upsert';
export interface ImportOperation {
  operation: ImportMode;
  id?: string;
  data: Record<string, unknown>;
}
export const IMPORT_HEADERS = [
  'id',
  'slug',
  'domainId',
  'target',
  'statusCode',
  'isEnabled',
  'isArchived',
  'queryMode',
  'queryOverride',
  'utmDefaults',
  'expiresAt',
  'folderId',
  'tagIds',
  'comment',
];
export const MANAGED_IMPORT_MAX_BYTES = 2100000;
const MAX_BYTES = MANAGED_IMPORT_MAX_BYTES;
/** RFC-style quoted fields, escaped quotes and multiline cells; no silent row skipping. */
export function parseRedirectCsv(text: string): string[][] {
  if (new TextEncoder().encode(text).byteLength > MAX_BYTES)
    throw new Error('CSV must be at most 2.1 MB');
  if (text.includes('\0')) throw new Error('CSV contains invalid characters');
  const input = text.replace(/^\uFEFF/, '');
  const rows: string[][] = [];
  let row: string[] = [],
    cell = '',
    quoted = false,
    closed = false;
  const finishCell = () => {
    row.push(cell);
    cell = '';
    closed = false;
  };
  const finishRow = () => {
    finishCell();
    if (row.some((value) => value.trim())) rows.push(row);
    row = [];
  };
  for (let i = 0; i < input.length; i++) {
    const char = input[i];
    if (quoted) {
      if (char === '"') {
        if (input[i + 1] === '"') {
          cell += '"';
          i++;
        } else {
          quoted = false;
          closed = true;
        }
      } else cell += char;
      continue;
    }
    if (char === ',') {
      finishCell();
      continue;
    }
    if (char === '\r' || char === '\n') {
      if (char === '\r' && input[i + 1] === '\n') i++;
      finishRow();
      continue;
    }
    if (closed) {
      if (char === ' ' || char === '\t') continue;
      throw new Error('Unexpected text after a closing CSV quote');
    }
    if (char === '"') {
      if (cell.trim()) throw new Error('Quotes must enclose the whole CSV field');
      cell = '';
      quoted = true;
    } else cell += char;
  }
  if (quoted) throw new Error('CSV has an unclosed quoted field');
  if (cell || row.length || closed) finishRow();
  if (rows.length < 2) throw new Error('Need at least a header row and one data row');
  if (rows.length > 101) throw new Error('Import at most 100 rows in one atomic batch');
  const width = rows[0].length;
  for (let index = 1; index < rows.length; index++)
    if (rows[index].length !== width)
      throw new Error('Row ' + (index + 1) + ' has a different number of fields than the header');
  return rows;
}
export function managedImportCsv(text: string, mode: ImportMode): ImportOperation[] {
  if (!['create', 'update', 'upsert'].includes(mode))
    throw new Error('Choose a supported import mode');
  const [header, ...rows] = parseRedirectCsv(text);
  const fields = header.map((value) =>
    value.trim().toLowerCase().replace(/_/g, '') === 'commentjson'
      ? 'comment'
      : IMPORT_HEADERS.find(
          (field) => field.toLowerCase() === value.trim().toLowerCase().replace(/_/g, ''),
        ),
  );
  if (fields.some((field) => !field))
    throw new Error('Unknown CSV header. Use the managed-link template.');
  if (new Set(fields).size !== fields.length) throw new Error('CSV has duplicate headers');
  const identities = new Set<string>();
  const operations = rows.map((values, index) => {
    try {
      const data: Record<string, unknown> = {};
      let id: string | undefined;
      for (let col = 0; col < fields.length; col++) {
        const field = fields[col]!;
        const raw = values[col];
        if (!raw.trim()) continue;
        if (
          field === 'comment' &&
          header[col].trim().toLowerCase().replace(/_/g, '') === 'commentjson'
        ) {
          const comment = JSON.parse(raw);
          if (typeof comment !== 'string')
            throw new Error('commentJson must contain a JSON string');
          data.comment = comment;
          continue;
        }
        if (field === 'id') {
          id = raw.trim();
          if (!UUID.test(id)) throw new Error('Invalid link ID');
          continue;
        }
        if (['isEnabled', 'isArchived'].includes(field)) {
          const normalized = raw.trim().toLowerCase();
          if (!['true', 'false', '1', '0'].includes(normalized))
            throw new Error(field + ' must be true or false');
          data[field] = ['true', '1'].includes(normalized);
        } else if (field === 'statusCode') {
          if (!/^\d+$/.test(raw.trim())) throw new Error('Invalid HTTP status');
          data[field] = Number(raw);
        } else if (['queryOverride', 'utmDefaults', 'tagIds'].includes(field))
          data[field] = JSON.parse(raw);
        else if (['expiresAt', 'folderId', 'domainId'].includes(field) && raw.trim() === 'null')
          data[field] = null;
        else
          data[field] =
            field === 'comment' ? raw : field === 'slug' ? raw.trim().toLowerCase() : raw.trim();
      }
      if (mode === 'update' && !id) throw new Error('Update requires a link ID');
      const checked = linkInput(data, mode);
      const identity =
        mode === 'update'
          ? id
          : checked.slug
            ? `${checked.domainId ?? 'builtin'}:${checked.slug}`
            : undefined;
      if (identity) {
        const key = String(identity);
        if (identities.has(key)) throw new Error('Duplicate link identity in this batch');
        identities.add(key);
      }
      return { operation: mode, ...(mode === 'update' ? { id } : {}), data: checked };
    } catch (err) {
      throw new Error(
        'Row ' + (index + 2) + ': ' + (err instanceof Error ? err.message : 'Invalid row'),
        { cause: err },
      );
    }
  });
  if (new TextEncoder().encode(JSON.stringify({ operations })).byteLength > MAX_BYTES)
    throw new Error('Encoded import exceeds the 2.1 MB API limit. Use fewer rows.');
  return operations;
}
export function managedLinksCsv(links: Record<string, unknown>[]) {
  const quote = (value: string) => '"' + value.replace(/"/g, '""') + '"';
  const headers = IMPORT_HEADERS.map((field) => (field === 'comment' ? 'commentJson' : field));
  const lines = [
    headers,
    ...links.map((link) =>
      IMPORT_HEADERS.map((field) => {
        const value = link[field];
        if (field === 'comment') return value === undefined ? '' : JSON.stringify(String(value));
        return value === undefined
          ? ''
          : value === null
            ? 'null'
            : typeof value === 'object'
              ? JSON.stringify(value)
              : String(value);
      }),
    ),
  ];
  const csv = lines.map((line) => line.map(quote).join(',')).join('\r\n');
  if (new TextEncoder().encode(csv).byteLength > MAX_BYTES)
    throw new Error('Managed CSV exceeds 2.1 MB. Select fewer links.');
  return csv;
}
