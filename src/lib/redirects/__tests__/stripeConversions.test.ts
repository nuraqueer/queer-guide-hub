import { describe, expect, it } from 'vitest';
import {
  checkoutSale,
  renewalSale,
  stripeChargeMajor,
} from '../../../../supabase/functions/_shared/redirect-stripe';
const click = '00000000-0000-4000-8000-000000000001';
const checkout = {
  id: 'session',
  amount_total: 4990,
  currency: 'chf',
  payment_status: 'paid',
  customer: 'customer',
  metadata: { qg_click_id: click, user_id: '00000000-0000-4000-8000-000000000002' },
};
describe('native Stripe attribution', () => {
  it('converts charge units for ordinary, zero-decimal, three-decimal and compatibility currencies', () => {
    expect(stripeChargeMajor(4990, 'CHF')).toBe('49.90');
    expect(stripeChargeMajor(500, 'JPY')).toBe('500');
    expect(stripeChargeMajor(5010, 'KWD')).toBe('5.010');
    expect(stripeChargeMajor(500, 'ISK')).toBe('5.00');
    expect(stripeChargeMajor(500, 'UGX')).toBe('5.00');
    expect(() => stripeChargeMajor(0.1, 'USD')).toThrow();
  });
  it('attributes only paid tracked checkouts, with stable purchase IDs and verified native customer namespaces', () => {
    expect(checkoutSale(checkout, '2026-10-13T10:00:00Z')).toMatchObject({
      clickId: click,
      customerExternalId: 'native:' + checkout.metadata.user_id,
      eventId: 'stripe:checkout:session',
      amount: '49.90',
      currency: 'CHF',
    });
    expect(
      checkoutSale({ ...checkout, payment_status: 'unpaid' }, '2026-10-13T10:00:00Z'),
    ).toBeNull();
    expect(checkoutSale({ ...checkout, metadata: {} }, '2026-10-13T10:00:00Z')).toBeNull();
  });
  it('carries the original tracked checkout into renewal attribution and skips untracked subscriptions', () => {
    const invoice = { id: 'invoice', amount_paid: 500, currency: 'chf', customer: 'customer' };
    expect(
      renewalSale({ user_id: null, redirect_click_id: click }, invoice, '2026-10-13T10:00:00Z'),
    ).toMatchObject({
      clickId: click,
      customerExternalId: 'stripe:customer',
      eventId: 'stripe:invoice:invoice',
      amount: '5.00',
    });
    expect(renewalSale({ user_id: null }, invoice, '2026-10-13T10:00:00Z')).toBeNull();
  });
});
