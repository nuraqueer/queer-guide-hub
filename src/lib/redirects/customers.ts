import { memberRedirectApi } from './memberApi';
import type {
  CustomerProfile,
  CustomerProfileChanges,
  CustomerJourneyPage,
  CustomerJourneyCursor,
} from '../../../sdk/redirects/typescript/index';
export type { CustomerProfile, CustomerProfileChanges, CustomerJourneyCursor, CustomerJourneyPage };
export function readCustomer(id: string, signal: AbortSignal) {
  return memberRedirectApi<CustomerProfile>(
    '/customers/profile?id=' + encodeURIComponent(id),
    'GET',
    undefined,
    signal,
  ).then((data) => {
    if (data.customerExternalId !== id || typeof data.canEdit !== 'boolean')
      throw new Error('Invalid customer profile response');
    return data;
  });
}
export function updateCustomer(id: string, data: CustomerProfileChanges) {
  return memberRedirectApi<CustomerProfile>('/customers/profile', 'PATCH', {
    ...data,
    customerExternalId: id,
  });
}
export function clearCustomer(id: string, version: string | null) {
  return memberRedirectApi<CustomerProfile>('/customers/profile', 'DELETE', {
    customerExternalId: id,
    version,
  });
}
export async function readCustomerJourney(
  id: string,
  cursor: CustomerJourneyCursor | null,
  signal: AbortSignal,
) {
  const page = await memberRedirectApi<CustomerJourneyPage>(
    '/customers/journey?' +
      new URLSearchParams({
        id,
        limit: '50',
        ...(cursor ? { cursor: JSON.stringify(cursor) } : {}),
      }),
    'GET',
    undefined,
    signal,
  );
  if (
    !Array.isArray(page.data) ||
    (page.nextCursor &&
      cursor &&
      page.nextCursor.at === cursor.at &&
      page.nextCursor.id === cursor.id)
  )
    throw new Error('Customer journey pagination did not advance');
  return page;
}
