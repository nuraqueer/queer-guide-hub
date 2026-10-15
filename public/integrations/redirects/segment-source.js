/* Install as a Segment Source Function. Store signingSecret and optional
 * previousSigningSecret in SECRET settings. Uses Segment's exposed Node crypto.
 */
async function onRequest(request, settings) {
  if (typeof request.text !== 'function') throw new ValidationError('Raw request text is required');
  const raw = await request.text();
  const id = request.headers.get('webhook-id') || '';
  const timestamp = request.headers.get('webhook-timestamp') || '';
  const signature = request.headers.get('webhook-signature') || '';
  if (
    typeof raw !== 'string' ||
    Buffer.byteLength(raw, 'utf8') > 32768 ||
    !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(id) ||
    !/^\d{1,12}$/.test(timestamp) ||
    Math.abs(Math.floor(Date.now() / 1000) - Number(timestamp)) > 300 ||
    signature.length > 2048
  )
    throw new ValidationError('Invalid signed request');
  const candidates = signature
    .split(/\s+/)
    .filter((value) => /^v1,[A-Za-z0-9+/]{43}=$/.test(value));
  if (!candidates.length || candidates.length > 20)
    throw new ValidationError('Invalid signed request');
  const secrets = [
    settings.signingSecret,
    ...(settings.previousSigningSecret ? [settings.previousSigningSecret] : []),
  ];
  let valid = false;
  for (const secret of secrets) {
    if (typeof secret !== 'string' || !/^whsec_[A-Za-z0-9+/]{43}=$/.test(secret))
      throw new ValidationError('Configure the signing secret');
    const key = Buffer.from(secret.slice(6), 'base64');
    if (key.length !== 32 || key.toString('base64') !== secret.slice(6))
      throw new ValidationError('Invalid signing secret');
    const expected = crypto
      .createHmac('sha256', key)
      .update(id + '.' + timestamp + '.' + raw)
      .digest();
    for (const candidate of candidates) {
      const provided = Buffer.from(candidate.slice(3), 'base64');
      valid =
        (provided.length === expected.length && crypto.timingSafeEqual(expected, provided)) ||
        valid;
    }
  }
  if (!valid) throw new ValidationError('Invalid signed request');
  let event;
  try {
    event = JSON.parse(raw);
  } catch {
    throw new InvalidEventPayload('Invalid event JSON');
  }
  const names = {
    'link.created': 'Redirect Link Created',
    'link.updated': 'Redirect Link Updated',
    'link.deleted': 'Redirect Link Deleted',
    'link.clicked': 'Redirect Link Clicked',
    'lead.created': 'Redirect Lead Created',
    'sale.created': 'Redirect Sale Created',
    'webhook.test': 'Redirect Integration Test',
  };
  if (
    !event ||
    event.id !== id ||
    !Object.hasOwn(names, event.type) ||
    !event.data ||
    typeof event.data !== 'object' ||
    Array.isArray(event.data) ||
    typeof event.timestamp !== 'string' ||
    !Number.isFinite(Date.parse(event.timestamp))
  )
    throw new InvalidEventPayload('Invalid event envelope');
  const data = event.data;
  const properties = { qg_redirects_origin: 'redirects', qg_event_type: event.type };
  // Never forward arbitrary properties or private identity, even in a signed envelope.
  for (const field of [
    'linkId',
    'clickId',
    'shortUrl',
    'isDomainRoot',
    'enabled',
    'archived',
    'country',
    'device',
    'qr',
    'variantId',
    'eventName',
    'currency',
    'amount',
    'occurredAt',
  ]) {
    if (Object.hasOwn(data, field) && ['string', 'boolean'].includes(typeof data[field]))
      properties[field] = data[field];
  }
  const customer = data.customerExternalId;
  const identity =
    typeof customer === 'string' && customer.trim() && customer.length <= 256
      ? { userId: customer }
      : { anonymousId: typeof data.clickId === 'string' ? data.clickId : id };
  await Segment.track({
    ...identity,
    event: names[event.type],
    messageId: 'qg:' + id,
    timestamp: event.timestamp,
    properties,
  });
}
