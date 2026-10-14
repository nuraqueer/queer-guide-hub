export type JsonObject = Record<string, unknown>;
export interface QrImageOptions {
  label?: string;
  expiresAt?: string | null;
  style?: Partial<{
    dots: 'square' | 'circle' | 'joined';
    border: 'square' | 'rounded' | 'circle';
    center: 'square' | 'circle';
    foreground: string;
    background: string;
  }> | null;
  logoMode?: 'inherit' | 'none' | 'custom';
  logo?: string;
}
export type QrImageInput = QrImageOptions &
  ({ linkId: string; url?: never } | { url: string; linkId?: never });
export interface QrImageLink {
  id: string;
  label: string;
  linkId: string | null;
  version: string;
  createdAt: string;
  expiresAt: string | null;
  revokedAt: string | null;
  style: NonNullable<QrImageOptions['style']>;
  logoMode: 'inherit' | 'none' | 'custom';
  state: 'pending' | 'published';
  logoAsset: {
    id: string;
    key: string;
    url: string;
    mime: 'image/png' | 'image/jpeg';
    bytes: number;
    width: number;
    height: number;
    sha256: string;
  } | null;
}
export interface CreatedQrImageLink extends QrImageLink {
  imageUrls: { png: string; jpg: string; svg: string };
}
export interface LinkInput {
  isDomainRoot?: boolean;
  slug?: string;
  target?: string;
  statusCode?: 301 | 302 | 307 | 308;
  isEnabled?: boolean;
  isArchived?: boolean;
  queryMode?: 'PRESERVE' | 'DROP' | 'OVERRIDE';
  queryOverride?: Record<string, string> | null;
  utmDefaults?: Record<string, string> | null;
  expiresAt?: string | null;
  startsAt?: string | null;
  clickLimit?: number | null;
  notes?: string | null;
  domainId?: string | null;
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
  domainHostname: string | null;
  updatedAt: string;
}
export interface DomainChoice {
  id: string;
  hostname: string;
}
export interface DomainChoices extends Page<DomainChoice> {
  primaryDomainId: string | null;
  primaryUnavailable: boolean;
}
export interface LinkedDomain extends DomainChoice {
  linkCount: number;
}
export interface LinkedDomainsPage extends Page<LinkedDomain> {
  builtinCount: number;
  revision: string;
}
export interface LinkPolicy {
  preview?: { title?: string; description?: string; image?: string; video?: string };
  cloaked?: boolean;
  track_conversions?: boolean;
  device_targets?: Partial<Record<'ios' | 'android', string>>;
  geo_targets?: Record<string, string>;
  experiment?: {
    starts_at: string;
    ends_at: string;
    variants: Array<{ id: string; url: string; weight: number }>;
    completed_target?: string;
  };
  expires_at?: string;
  expired_target?: string;
}
export interface PolicyResponse {
  policy: LinkPolicy;
  hasPassword: boolean;
}
export interface PolicyUpdate {
  policy?: { [K in keyof LinkPolicy]?: LinkPolicy[K] | null };
  password?: string | null;
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
  getPolicy(id: string) {
    return this.request<PolicyResponse>('GET', '/links/' + id + '/policy');
  }
  updatePolicy(id: string, data: PolicyUpdate) {
    return this.request<PolicyResponse>('PATCH', '/links/' + id + '/policy', data);
  }
  getPresentation(id: string) {
    return this.request<JsonObject>('GET', '/links/' + id + '/presentation');
  }
  updatePresentation(id: string, data: JsonObject) {
    return this.request<JsonObject>('PATCH', '/links/' + id + '/presentation', data);
  }
  uploadPreviewImage(id: string, imageBase64: string) {
    return this.request<{ image: string; width: number; height: number }>(
      'POST',
      '/links/' + id + '/preview-image',
      { image: imageBase64 },
    );
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
  upsertLink(data: LinkInput & { target: string } & ({slug: string} | {isDomainRoot: true;domainId: string})) {
    return this.request<Mutation>('PUT', '/links/upsert', data);
  }
  deleteLink(id: string) {
    return this.request<Mutation>('DELETE', '/links/' + id);
  }
  listLinkedDomains(limit = 100, cursor?: string) {
    return this.request<LinkedDomainsPage>('GET', '/linked-domains', undefined, { limit, cursor });
  }
  getQrStyle(id: string) { return this.request<{id:string;style:{dots:string;border:string;center:string;foreground:string;background:string};source:string;effectiveLogo?:{id:string;key:string;mime:string;bytes:number;width:number;height:number;sha256:string;url:string}|null;logoSource?:string}>('GET','/qr-styles/links/'+encodeURIComponent(id)); }
  createQrImage(data: QrImageInput) {
    return this.request<CreatedQrImageLink>('POST', '/qr-images', data);
  }
  listQrImages(limit = 100, cursor?: string) {
    return this.request<Pick<Page<QrImageLink>, 'data' | 'nextCursor'>>(
      'GET',
      '/qr-images',
      undefined,
      { limit, cursor },
    );
  }
  revokeQrImage(id: string, version: string) {
    return this.request<QrImageLink>(
      'DELETE',
      '/qr-images/' + encodeURIComponent(id),
      { version },
    );
  }
  listDomainChoices(limit = 100, cursor?: string) {
    return this.request<DomainChoices>('GET', '/domain-choices', undefined, { limit, cursor });
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
