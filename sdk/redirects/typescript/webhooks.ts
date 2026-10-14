/** Verify the original request bytes before parsing JSON. Receiver must also deduplicate webhook-id. */
export async function verifyWebhook(
  secret: string | string[],
  rawBody: Uint8Array | string,
  headers: { id: string; timestamp: string; signature: string },
  now = Math.floor(Date.now() / 1000),
): Promise<boolean> {
  const secrets = Array.isArray(secret) ? secret : [secret];
  const body = typeof rawBody === 'string' ? new TextEncoder().encode(rawBody) : rawBody;
  if (
    body.byteLength > 32768 ||
    !secrets.length ||
    secrets.length > 5 ||
    !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(headers.id) ||
    !/^\d{1,12}$/.test(headers.timestamp) ||
    !Number.isSafeInteger(now) ||
    Math.abs(now - Number(headers.timestamp)) > 300 ||
    headers.signature.length > 2048
  )
    return false;
  const signatures = headers.signature
    .split(/\s+/)
    .filter((value) => /^v1,[A-Za-z0-9+/]{43}=$/.test(value));
  if (!signatures.length || signatures.length > 20) return false;
  const prefix = new TextEncoder().encode(headers.id + '.' + headers.timestamp + '.'),
    message = new Uint8Array(prefix.length + body.length);
  message.set(prefix);
  message.set(body, prefix.length);
  let valid = false;
  for (const value of secrets) {
    if (!/^whsec_[A-Za-z0-9+/]{43}=$/.test(value)) return false;
    const decoded = atob(value.slice(6));
    if (decoded.length !== 32 || btoa(decoded) !== value.slice(6)) return false;
    const key = await crypto.subtle.importKey(
      'raw',
      Uint8Array.from(decoded, (ch) => ch.charCodeAt(0)),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['verify'],
    );
    for (const signature of signatures) {
      const bytes = Uint8Array.from(atob(signature.slice(3)), (ch) => ch.charCodeAt(0));
      valid = (await crypto.subtle.verify('HMAC', key, bytes, message)) || valid;
    }
  }
  return valid;
}
