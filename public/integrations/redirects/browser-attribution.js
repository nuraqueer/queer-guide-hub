/* Optional web-container helper. No API key, network request or conversion write.
 * After your CMP resolves consent, call qgRedirects.setConsent(true/false).
 */
(function (window) {
  'use strict';
  const key = 'qg:redirect:attribution';
  const cookie = 'qg_click_id';
  const ttl = 30 * 86400000;
  const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
  let allowed = false;
  let announced = null;
  const erase = function () {
    try {
      window.localStorage.removeItem(key);
    } catch {
      /* Disabled storage. */
    }
    try {
      window.document.cookie =
        cookie +
        '=; Max-Age=0; Path=/; SameSite=Lax' +
        (window.location.protocol === 'https:' ? '; Secure' : '');
    } catch {
      /* Browser cookies can be disabled. */
    }
    announced = null;
  };
  const read = function () {
    if (!allowed) return null;
    try {
      const value = JSON.parse(window.localStorage.getItem(key) || 'null');
      const now = Date.now();
      if (
        !value ||
        typeof value.clickId !== 'string' ||
        !uuid.test(value.clickId) ||
        !Number.isFinite(value.capturedAt) ||
        !Number.isFinite(value.expiresAt) ||
        value.capturedAt > now ||
        value.expiresAt <= now ||
        value.expiresAt - value.capturedAt !== ttl
      ) {
        erase();
        return null;
      }
      return value;
    } catch {
      erase();
      return null;
    }
  };
  window.qgRedirects = {
    setConsent: function (granted) {
      allowed = granted === true;
      if (!allowed) {
        erase();
        return null;
      }
      const clickId = new URL(window.location.href).searchParams.get('qg_click_id');
      let value = read();
      if (clickId && uuid.test(clickId) && (!value || value.clickId !== clickId)) {
        const now = Date.now();
        value = { clickId: clickId, capturedAt: now, expiresAt: now + ttl };
        try {
          window.localStorage.setItem(key, JSON.stringify(value));
        } catch {
          return null;
        }
      }
      if (!value) return null;
      try {
        window.document.cookie =
          cookie +
          '=' +
          value.clickId +
          '; Max-Age=' +
          Math.max(0, Math.floor((value.expiresAt - Date.now()) / 1000)) +
          '; Path=/; SameSite=Lax' +
          (window.location.protocol === 'https:' ? '; Secure' : '');
      } catch {
        /* Browser cookies can be disabled. */
      }
      if (announced !== value.clickId) {
        window.dataLayer = window.dataLayer || [];
        if (typeof window.dataLayer.push === 'function')
          window.dataLayer.push({ event: 'qg_redirect_attribution', qg_click_id: value.clickId });
        announced = value.clickId;
      }
      return value.clickId;
    },
    getClickId: function () {
      const value = read();
      return value ? value.clickId : null;
    },
    clear: function () {
      allowed = false;
      erase();
    },
  };
})(window);
