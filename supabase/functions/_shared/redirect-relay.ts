// Optional authenticated client-IP relay. Never trust arbitrary forwarded IP headers.
const relayEncoder = new TextEncoder();
async function relayKey(secret: string) {
  return crypto.subtle.importKey('raw', relayEncoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}
export async function signRedirectRelay(ip: string, slug: string, secret: string, now = Date.now()) {
  if (secret.length < 32 || !ip || ip.length > 64) return null;
  const timestamp = String(Math.floor(now / 1000));
  const bytes = new Uint8Array(await crypto.subtle.sign('HMAC', await relayKey(secret), relayEncoder.encode(`${timestamp}\n${slug}\n${ip}`)));
  return { ip, timestamp, signature: Array.from(bytes, n => n.toString(16).padStart(2, '0')).join('') };
}
export async function redirectClientIp(headers: Headers, slug: string, secret?: string, now = Date.now()) {
  const ip = headers.get('x-qg-relay-ip') ?? '';
  const timestamp = headers.get('x-qg-relay-time') ?? '';
  const signature = headers.get('x-qg-relay-signature') ?? '';
  if (secret && secret.length >= 32 && ip && ip.length <= 64 && /^\d{10}$/.test(timestamp) && /^[0-9a-f]{64}$/.test(signature) && Math.abs(now / 1000 - Number(timestamp)) <= 120) {
    const bytes = Uint8Array.from(signature.match(/../g)!, pair => parseInt(pair, 16));
    if (await crypto.subtle.verify('HMAC', await relayKey(secret), bytes, relayEncoder.encode(`${timestamp}\n${slug}\n${ip}`))) return ip;
  }
  return headers.get('cf-connecting-ip')?.slice(0, 64) || 'unknown';
}
