"""Server SDK using Python's standard library. No automatic mutation retries."""
import json
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.error import HTTPError
from urllib.parse import urlsplit, urlencode

class RedirectApiError(Exception):
    def __init__(self, status, message, retry_after=None):
        super().__init__(message)
        self.status, self.retry_after = status, retry_after

class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

class RedirectsClient:
    def __init__(self, token, base_url='https://queer.guide/api/redirects', timeout=10):
        parsed = urlsplit(base_url)
        if not token.strip() or '\r' in token or '\n' in token:
            raise ValueError('A server credential is required')
        if parsed.username or parsed.password or parsed.query or parsed.fragment or not (parsed.scheme == 'https' or parsed.scheme == 'http' and parsed.hostname in ('localhost','127.0.0.1','::1')):
            raise ValueError('Use HTTPS or a loopback development API')
        if timeout <= 0: raise ValueError('Timeout must be positive')
        self._token, self._base, self._timeout = token, base_url.rstrip('/'), timeout
        self._opener = build_opener(_NoRedirect())

    def request(self, method, path, body=None, query=None):
        if not path.startswith('/') or '//' in path or any(not (c.isascii() and (c.isalnum() or c in '/_-')) for c in path):
            raise ValueError('Invalid API path')
        params = {k: json.dumps(v, ensure_ascii=False, separators=(',', ':')) if isinstance(v, (dict,list)) else str(v).lower() if isinstance(v,bool) else str(v) for k,v in (query or {}).items() if v is not None}
        url = self._base + path + ('?' + urlencode(params) if params else '')
        req = Request(url, data=None if body is None else json.dumps(body, ensure_ascii=False).encode(), method=method, headers={'Authorization':'Bearer '+self._token, 'Content-Type':'application/json'})
        try: response = self._opener.open(req, timeout=self._timeout)
        except HTTPError as error: response = error
        with response:
            raw = response.read(8*1024*1024+1)
            if len(raw)>8*1024*1024: raise ValueError('API response exceeds 8 MiB')
            try: data = json.loads(raw) if raw else {}
            except ValueError:
                if 200<=response.code<300: raise ValueError('API returned invalid JSON')
                data = {}
            if not 200<=response.code<300: raise RedirectApiError(response.code, data.get('error','Redirect API request failed'), response.headers.get('Retry-After'))
            return data

    def get_policy(self, link_id): return self.request('GET', '/links/' + link_id + '/policy')
    def update_policy(self, link_id, data): return self.request('PATCH', '/links/' + link_id + '/policy', data)
    def get_presentation(self, link_id): return self.request('GET','/links/'+link_id+'/presentation')
    def update_presentation(self, link_id, data): return self.request('PATCH','/links/'+link_id+'/presentation',data)
    def upload_preview_image(self, link_id, image_base64): return self.request('POST','/links/'+link_id+'/preview-image',{'image':image_base64})
    def create_link(self, data): return self.request('POST','/links',data)
    def get_link(self, link_id): return self.request('GET','/links/'+link_id)
    def update_link(self, link_id, data): return self.request('PATCH','/links/'+link_id,data)
    def upsert_link(self, data): return self.request('PUT','/links/upsert',data)
    def delete_link(self, link_id): return self.request('DELETE','/links/'+link_id)
    def list_links(self, filters=None, limit=100, cursor=None): return self.request('GET','/links',query={'filters':filters or {},'limit':limit,'cursor':cursor})
    def count_links(self, filters=None): return self.request('GET','/links/count',query={'filters':filters or {}})
    def bulk(self, operations): return self.request('POST','/links/bulk',{'operations':operations})
    def iterate_links(self, filters=None):
        cursor, seen = None, set()
        while True:
            page = self.list_links(filters, cursor=cursor)
            yield from page['data']
            cursor = page.get('nextCursor')
            if not cursor: break
            if cursor in seen: raise ValueError('Repeated pagination cursor')
            seen.add(cursor)
    def track_lead(self, data): return self.request('POST','/track/lead',data)
    def track_sale(self, data): return self.request('POST','/track/sale',data)
    def analytics(self, filters=None): return self.request('GET','/analytics',query={'filters':filters or {}})
    def events(self, filters=None, **options): return self.request('GET','/events',query={**options,'filters':filters or {}})
    def get_resource(self, kind, resource_id): return self.request('GET','/'+kind+'/'+resource_id)
    def list_resources(self, kind, limit=100, cursor=None): return self.request('GET','/'+kind,query={'limit':limit,'cursor':cursor})
    def create_resource(self, kind, data): return self.request('POST','/'+kind,data)
    def update_resource(self, kind, resource_id, data): return self.request('PATCH','/'+kind+'/'+resource_id,data)
    def delete_resource(self, kind, resource_id): return self.request('DELETE','/'+kind+'/'+resource_id)
