export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export interface ConversionInput {
 kind: 'lead'|'sale'; clickId?: string; customerExternalId: string; eventId: string;
 eventName: string; amount?: number|string; currency?: string; metadata?: Record<string,unknown>; occurredAt?: string;
}
export function conversionInput(body: unknown, kind: 'lead'|'sale'): ConversionInput {
 if (!body || typeof body!=='object' || Array.isArray(body)) throw new Error('Expected a conversion object');
 const value=body as Record<string,unknown>;
 const allowed=['clickId','customerExternalId','eventId','eventName','amount','currency','metadata','occurredAt'];
 if(Object.keys(value).some(key=>!allowed.includes(key))) throw new Error('Unknown conversion field');
 for(const key of ['customerExternalId','eventId']) if(typeof value[key]!=='string' || !(value[key] as string).trim() || (value[key] as string).length>256) throw new Error(key+' must be 1–256 characters');
 if(value.clickId!==undefined && (typeof value.clickId!=='string' || !UUID.test(value.clickId))) throw new Error('Invalid click ID');
 if(value.eventName!==undefined && (typeof value.eventName!=='string' || !value.eventName.trim() || value.eventName.length>120)) throw new Error('Event name must be 1–120 characters');
 if(value.metadata!==undefined && (!value.metadata || typeof value.metadata!=='object' || Array.isArray(value.metadata) || new TextEncoder().encode(JSON.stringify(value.metadata)).length>8192)) throw new Error('Metadata must be an object no larger than 8 KB');
 if(value.occurredAt!==undefined && (typeof value.occurredAt!=='string' || !Number.isFinite(Date.parse(value.occurredAt)) || Date.parse(value.occurredAt)>Date.now()+300000)) throw new Error('Invalid conversion date');
 if(kind==='lead' && (value.amount!==undefined || value.currency!==undefined)) throw new Error('Lead events do not have revenue');
 const amountValid=typeof value.amount==='string' ? /^\d{1,12}(?:\.\d{1,6})?$/.test(value.amount) : typeof value.amount==='number' && Number.isFinite(value.amount) && value.amount>=0 && value.amount<1e12 && Math.abs(value.amount*1e6-Math.round(value.amount*1e6))<=0.001;
 if(kind==='sale' && (!amountValid || typeof value.currency!=='string' || !/^[A-Z]{3}$/.test(value.currency))) throw new Error('Sales need a nonnegative amount with at most 6 decimals and a three-letter currency');
 return {...value,kind,eventName:value.eventName ?? (kind==='lead'?'Lead':'Sale')} as ConversionInput;
}
export async function tokenDigest(value: string) {
 const data=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)));
 return Array.from(data,byte=>byte.toString(16).padStart(2,'0')).join('');
}
export function createRedirectToken() {
 return 'qg_redirect_'+Array.from(crypto.getRandomValues(new Uint8Array(32)),byte=>byte.toString(16).padStart(2,'0')).join('');
}
export async function boundedJson(req: Request,maxBytes=65536) {
 if(!req.headers.get('content-type')?.toLowerCase().startsWith('application/json')) throw new Error('Use application/json');
 if(!req.body) throw new Error('Missing request body');
 const reader=req.body.getReader(),chunks:Uint8Array[]=[];let total=0;
 for(;;){const {done,value}=await reader.read();if(done)break;total+=value.length;if(total>maxBytes){await reader.cancel();throw new Error('Request body exceeds '+maxBytes+' bytes');}chunks.push(value);}
 const bytes=new Uint8Array(total);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
 return JSON.parse(new TextDecoder().decode(bytes));
}
