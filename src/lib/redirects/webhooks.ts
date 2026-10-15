import { memberRedirectApi } from './memberApi';
export const WEBHOOK_EVENTS = [
  'link.created',
  'link.updated',
  'link.deleted',
  'link.clicked',
  'lead.created',
  'sale.created',
] as const;
export type WebhookEvent = (typeof WEBHOOK_EVENTS)[number];
export interface RedirectWebhook {
  id: string;
  name: string;
  url: string;
  eventTypes: WebhookEvent[];
  linkIds: string[] | null;
  includeCustomerId: boolean;
  enabled: boolean;
  deletedAt: string | null;
  version: string;
  keyVersion: string;
  previousKeyExpiresAt: string | null;
  createdAt: string;
  updatedAt: string;
}
export interface WebhookDelivery {
  id: string;
  sequence: string;
  webhookId: string;
  eventId: string;
  eventType: WebhookEvent | 'webhook.test';
  version: string;
  state: 'queued' | 'leased' | 'retry' | 'delivered' | 'failed' | 'cancelled';
  attempts: number;
  cycleAttempts: number;
  replays: number;
  createdAt: string;
  finishedAt: string | null;
  nextAttemptAt: string;
  httpStatus: number | null;
  errorCode: string | null;
  body?: string;
  responseExcerpt?: string;
  recentAttempts?: Array<{
    id: string;
    number: number;
    httpStatus: number | null;
    errorCode: string | null;
    responseExcerpt: string;
    durationMs: number | null;
  }>;
}
export interface WebhookPage<T> {
  data: T[];
  nextCursor: string | null;
  count?: number;
}
export async function webhookPage<T>(path: string, signal: AbortSignal) {
  const page = await memberRedirectApi<WebhookPage<T>>(path, 'GET', undefined, signal);
  if (
    !Array.isArray(page.data) ||
    page.data.length > 50 ||
    (page.nextCursor !== null && typeof page.nextCursor !== 'string')
  )
    throw new Error('Webhook page changed. Reload it.');
  return page;
}
