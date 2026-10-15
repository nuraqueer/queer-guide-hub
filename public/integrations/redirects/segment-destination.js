/* Install as a Segment Destination Function. apiKey is a SECRET setting.
 * Amounts are major currency units, with up to six decimals; no cents conversion.
 * Forward only trusted server-side conversion events to this destination.
 */
async function onTrack(event, settings) {
  const properties = event.properties || {};
  if (properties.qg_redirects_origin === 'redirects') return;
  const leadName = settings.leadEvent || 'Sign Up';
  const saleName = settings.saleEvent || 'Order Completed';
  if (
    typeof leadName !== 'string' ||
    typeof saleName !== 'string' ||
    !leadName.trim() ||
    !saleName.trim() ||
    leadName.length > 120 ||
    saleName.length > 120 ||
    leadName === saleName
  )
    throw new ValidationError('Choose distinct conversion event names');
  const kind = event.event === leadName ? 'lead' : event.event === saleName ? 'sale' : null;
  if (!kind) return;
  const key = settings.apiKey;
  if (typeof key !== 'string' || !/^qg_redirect_[a-f0-9]{64}$/.test(key))
    throw new ValidationError('Configure the server conversion key');
  const customer = event.userId;
  const message = event.messageId;
  if (
    typeof customer !== 'string' ||
    !customer.trim() ||
    customer.length > 256 ||
    typeof message !== 'string' ||
    !message.trim() ||
    message.length > 248
  )
    throw new InvalidEventPayload('Provide customer userId and stable messageId');
  const traits = (event.context && event.context.traits) || {};
  const click = properties.qg_click_id || traits.qg_click_id;
  if (
    click !== undefined &&
    (typeof click !== 'string' || !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(click))
  )
    throw new InvalidEventPayload('Invalid attribution click ID');
  const body = {
    customerExternalId: customer,
    eventId: 'segment:' + message,
    eventName: event.event,
  };
  if (click) body.clickId = click;
  if (event.timestamp !== undefined) {
    if (
      typeof event.timestamp !== 'string' ||
      !Number.isFinite(Date.parse(event.timestamp)) ||
      Date.parse(event.timestamp) > Date.now() + 300000
    )
      throw new InvalidEventPayload('Invalid event timestamp');
    body.occurredAt = event.timestamp;
  }
  if (kind === 'sale') {
    const amount =
      properties.amount_decimal !== undefined ? properties.amount_decimal : properties.revenue;
    if (
      typeof amount === 'number' &&
      (!Number.isFinite(amount) ||
        amount < 0 ||
        amount >= 1e12 ||
        !Number.isSafeInteger(Math.round(amount * 1e6)) ||
        Math.abs(amount * 1e6 - Math.round(amount * 1e6)) > 0.001)
    )
      throw new InvalidEventPayload('Use an exact amount_decimal string for revenue');
    const decimal = String(amount);
    if (
      !/^\d{1,12}(?:\.\d{1,6})?$/.test(decimal) ||
      typeof properties.currency !== 'string' ||
      !/^[A-Z]{3}$/.test(properties.currency)
    )
      throw new InvalidEventPayload('Sales need a major-unit amount and uppercase currency');
    body.amount = decimal;
    body.currency = properties.currency;
  }
  let response,
    timer,
    expired = false;
  const release = async (value) => {
    try {
      if (value.body && typeof value.body.destroy === 'function') value.body.destroy();
      else if (value.body && typeof value.body.cancel === 'function') await value.body.cancel();
    } catch {
      /* Preserve the received status. */
    }
  };
  try {
    const pending = fetch('https://queer.guide/api/redirects/track/' + kind, {
      method: 'POST',
      redirect: 'manual',
      timeout: 10000,
      headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then(async (value) => {
      if (expired) await release(value);
      return value;
    });
    const deadline = new Promise((resolve, reject) => {
      timer = setTimeout(() => {
        expired = true;
        reject(new RetryError('Redirects request timed out'));
      }, 10000);
    });
    response = await Promise.race([pending, deadline]);
  } catch {
    // A missing receipt is an unknown outcome. Segment retries the same stable eventId.
    throw new RetryError('Redirects transport unavailable');
  } finally {
    clearTimeout(timer);
  }
  await release(response);
  if (response.status === 429 || response.status >= 500)
    throw new RetryError('Redirects temporarily unavailable');
  if (response.status < 200 || response.status >= 300)
    throw new ValidationError('Redirects rejected conversion (HTTP ' + response.status + ')');
}
