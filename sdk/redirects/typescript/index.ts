export type JsonObject = Record<string, unknown>;
export interface LinkInput {
  slug?: string;
  target?: string;
  statusCode?: 301 | 302 | 307 | 308;
  isEnabled?: boolean;
  queryMode?: 'PRESERVE' | 'DROP' | 'OVERRIDE';
  queryOverride?: Record<string, string> | null;
  utmDefaults?: Record<string, string> | null;
  expiresAt?: string | null;
  folderId?: string | null;
  tagIds?: string[];
  comment?: string;
}
export interface Link extends LinkInput {
  id: string;
  slug: string;
  target: string;
  clicks: number;
  shortUrl: string;
  updatedAt: string;
}
export interface Page<T> {
  count: number;
  data: T[];
  nextCursor: string | null;
}
export interface Mutation {
  operation: string;
  created?: boolean;
  deleted?: boolean;
  id?: string;
  link?: Link;
}
export interface Conversion {
  clickId?: string;
  customerExternalId: string;
  eventId: string;
  eventName?: string;
  amount?: string | number;
  currency?: string;
  metadata?: JsonObject;
  occurredAt?: string;
}
export type ResourceKind = 'folders' | 'tags' | 'templates';
export class RedirectApiError extends Error {
  readonly status: number;
  readonly retryAfter: string | null;
  constructor(status: number, message: string, retryAfter: string | null) {
    super(message);
    this.name = 'RedirectApiError';
    this.status = status;
    this.retryAfter = retryAfter;
  }
}
export class RedirectsClient {
  private readonly token: string;
  private readonly base: string;
  private readonly timeout: number;
  constructor(token: string, options: { baseUrl?: string; timeoutMs?: number } = {}) {
    if (!token.trim() || /[\r\n]/.test(token)) throw new Error('A server credential is required');
    const url = new URL(options.baseUrl ?? 'https://queer.guide/api/redirects');
    if (
      url.username ||
      url.password ||
      url.search ||
      url.hash ||
      !(
        url.protocol === 'https:' ||
        (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname))
      )
    )
      throw new Error('Use HTTPS or a loopback development API');
    this.token = token;
    this.base = url.href.replace(/\/$/, '');
    this.timeout = options.timeoutMs ?? 10000;
    if (!Number.isFinite(this.timeout) || this.timeout <= 0)
      throw new Error('Timeout must be positive');
  }
  async request<T>(
    method: string,
    path: string,
    body?: unknown,
    query: JsonObject = {},
    signal?: AbortSignal,
  ): Promise<T> {
    if (!/^\/[a-zA-Z0-9_/-]+$/.test(path) || path.includes('//'))
      throw new Error('Invalid API path');
    const url = new URL(this.base + path);
    for (const [key, value] of Object.entries(query))
      if (value !== undefined && value !== null)
        url.searchParams.set(
          key,
          typeof value === 'object' ? JSON.stringify(value) : String(value),
        );
    const response = await fetch(url, {
      method,
      redirect: 'manual',
      headers: { Authorization: 'Bearer ' + this.token, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: signal
        ? AbortSignal.any([signal, AbortSignal.timeout(this.timeout)])
        : AbortSignal.timeout(this.timeout),
    });
    const reader = response.body?.getReader();
    let size = 0;
    const chunks: Uint8Array[] = [];
    if (reader)
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 8 * 1024 * 1024) {
          await reader.cancel();
          throw new Error('API response exceeds 8 MiB');
        }
        chunks.push(value);
      }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    let data: JsonObject = {};
    try {
      data = size ? JSON.parse(new TextDecoder().decode(bytes)) : {};
    } catch {
      if (response.ok) throw new Error('API returned invalid JSON');
    }
    if (!response.ok)
      throw new RedirectApiError(
        response.status,
        typeof data.error === 'string' ? data.error : 'Redirect API request failed',
        response.headers.get('Retry-After'),
      );
    return data as T;
  }
  createLink(data: LinkInput & { target: string }) {
    return this.request<Mutation>('POST', '/links', data);
  }
  getLink(id: string) {
    return this.request<Link>('GET', '/links/' + id);
  }
  updateLink(id: string, data: LinkInput) {
    return this.request<Mutation>('PATCH', '/links/' + id, data);
  }
  upsertLink(data: LinkInput & { slug: string; target: string }) {
    return this.request<Mutation>('PUT', '/links/upsert', data);
  }
  deleteLink(id: string) {
    return this.request<Mutation>('DELETE', '/links/' + id);
  }
  listLinks(filters: JsonObject = {}, limit = 100, cursor?: string) {
    return this.request<Page<Link>>('GET', '/links', undefined, { filters, limit, cursor });
  }
  countLinks(filters: JsonObject = {}) {
    return this.request<{ count: number }>('GET', '/links/count', undefined, { filters });
  }
  bulk(operations: JsonObject[]) {
    return this.request<{ data: Mutation[] }>('POST', '/links/bulk', { operations });
  }
  async *iterateLinks(filters: JsonObject = {}) {
    let cursor: string | undefined;
    const seen = new Set<string>();
    do {
      const page = await this.listLinks(filters, 100, cursor);
      for (const link of page.data) yield link;
      cursor = page.nextCursor ?? undefined;
      if (cursor && seen.has(cursor)) throw new Error('Repeated pagination cursor');
      if (cursor) seen.add(cursor);
    } while (cursor);
  }
  trackLead(data: Conversion) {
    return this.request<JsonObject>('POST', '/track/lead', data);
  }
  trackSale(data: Conversion & { amount: string | number; currency: string }) {
    return this.request<JsonObject>('POST', '/track/sale', data);
  }
  analytics(filters: JsonObject = {}) {
    return this.request<JsonObject>('GET', '/analytics', undefined, { filters });
  }
  events(filters: JsonObject = {}, options: JsonObject = {}) {
    return this.request<JsonObject>('GET', '/events', undefined, { ...options, filters });
  }
  getResource(kind: ResourceKind, id: string) {
    return this.request<JsonObject>('GET', '/' + kind + '/' + id);
  }
  listResources(kind: ResourceKind, limit = 100, cursor?: string) {
    return this.request<Page<JsonObject>>('GET', '/' + kind, undefined, { limit, cursor });
  }
  createResource(kind: ResourceKind, data: JsonObject) {
    return this.request<JsonObject>('POST', '/' + kind, data);
  }
  updateResource(kind: ResourceKind, id: string, data: JsonObject) {
    return this.request<JsonObject>('PATCH', '/' + kind + '/' + id, data);
  }
  deleteResource(kind: ResourceKind, id: string) {
    return this.request<JsonObject>('DELETE', '/' + kind + '/' + id);
  }
}
