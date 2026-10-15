import { UUID, type ConversionInput } from './redirect-api.ts';
// Charge units, not payout units. ISK and UGX remain /100 for API compatibility.
// https://docs.stripe.com/currencies#special-cases
const ZERO_CHARGE = new Set(['bif','clp','djf','gnf','jpy','kmf','krw','mga','pyg','rwf','vnd','vuv','xaf','xof','xpf']);
const THREE_CHARGE = new Set(['bhd','jod','kwd','omr','tnd']);
export function stripeChargeMajor(amount:number,currency:string):string {
 if(!Number.isSafeInteger(amount)||amount<0||!currency||!/^[a-z]{3}$/i.test(currency))throw new Error('Invalid Stripe payment amount');
 const digits=ZERO_CHARGE.has(currency.toLowerCase())?0:THREE_CHARGE.has(currency.toLowerCase())?3:2;
 const scale=10**digits;return String(Math.floor(amount/scale))+(digits?'.'+String(amount%scale).padStart(digits,'0'):'');
}
function customerKey(userId:string|undefined|null,customer:string|{id:string}|null|undefined,fallback?:string) {
 if(userId&&UUID.test(userId))return 'native:'+userId;
 const id=typeof customer==='string'?customer:customer?.id;
 return id?'stripe:'+id:fallback?'stripe:session:'+fallback:null;
}
export interface CheckoutAttribution {
 id:string;created?:number;payment_status?:string;amount_total:number|null;currency:string|null;
 customer?:string|{id:string}|null;metadata:Record<string,string>|null;
}
export function checkoutSale(session:CheckoutAttribution,occurredAt:string):ConversionInput|null {
 const click=session.metadata?.qg_click_id;
 if(!click||!UUID.test(click)||!['paid','no_payment_required'].includes(session.payment_status??'')||session.amount_total===null||!session.currency)return null;
 return {kind:'sale',clickId:click,customerExternalId:customerKey(session.metadata?.user_id,session.customer,session.id)!,eventId:'stripe:checkout:'+session.id,eventName:'Donation',amount:stripeChargeMajor(session.amount_total,session.currency),currency:session.currency.toUpperCase(),occurredAt};
}
export function renewalSale(original:{user_id:string|null;redirect_click_id?:string|null},invoice:{id:string;amount_paid:number;currency:string;customer?:string|{id:string}|null},occurredAt:string):ConversionInput|null {
 if(!original.redirect_click_id||!UUID.test(original.redirect_click_id))return null;
 const customer=customerKey(original.user_id,invoice.customer);
 if(!customer)return null;
 return {kind:'sale',clickId:original.redirect_click_id,customerExternalId:customer,eventId:'stripe:invoice:'+invoice.id,eventName:'Recurring donation',amount:stripeChargeMajor(invoice.amount_paid,invoice.currency),currency:invoice.currency.toUpperCase(),occurredAt};
}
