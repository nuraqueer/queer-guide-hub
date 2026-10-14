require 'json'
require 'net/http'
require 'uri'
module QueerGuide
  class RedirectApiError < StandardError
    attr_reader :status, :retry_after
    def initialize(status, message, retry_after = nil)
      super(message); @status, @retry_after = status, retry_after
    end
  end
  class RedirectsClient
    def initialize(token, base_url: 'https://queer.guide/api/redirects', timeout: 10)
      uri = URI(base_url)
      raise ArgumentError, 'A server credential is required' if token.strip.empty? || token.match?(/[\r\n]/)
      safe = uri.scheme == 'https' || uri.scheme == 'http' && ['localhost','127.0.0.1','[::1]'].include?(uri.host)
      raise ArgumentError, 'Use HTTPS or a loopback development API' unless safe && !uri.userinfo && !uri.query && !uri.fragment
      raise ArgumentError, 'Timeout must be positive' unless timeout > 0
      @token, @base, @timeout = token, base_url.sub(%r{/$}, ''), timeout
    end
    def request(method, path, body = nil, query = {})
      raise ArgumentError, 'Invalid API path' unless path.match?(%r{\A/[a-zA-Z0-9_/-]+\z}) && !path.include?('//')
      uri = URI(@base + path)
      params = query.reject { |_,v| v.nil? }.map { |k,v| [k, (v.is_a?(Hash) || v.is_a?(Array)) ? JSON.generate(v) : v.to_s] }
      uri.query = URI.encode_www_form(params) unless params.empty?
      req = Net::HTTPGenericRequest.new(method, !body.nil?, true, uri.request_uri, {'Authorization'=>'Bearer '+@token,'Content-Type'=>'application/json'})
      req.body = JSON.generate(body) unless body.nil?
      raw = ''; status = nil; retry_after = nil
      Net::HTTP.start(uri.host,uri.port,use_ssl: uri.scheme=='https',open_timeout:@timeout,read_timeout:@timeout) do |http|
        http.request(req) do |response|
          status, retry_after = response.code.to_i, response['Retry-After']
          response.read_body { |chunk| raw << chunk; raise 'API response exceeds 8 MiB' if raw.bytesize > 8*1024*1024 }
        end
      end
      begin; data = raw.empty? ? {} : JSON.parse(raw)
      rescue JSON::ParserError; raise 'API returned invalid JSON' if (200...300).include?(status); data = {}; end
      raise RedirectApiError.new(status,data['error'] || 'Redirect API request failed',retry_after) unless (200...300).include?(status)
      data
    end
    def create_link(data); request('POST','/links',data); end
    def get_link(id); request('GET','/links/'+id); end
    def update_link(id,data); request('PATCH','/links/'+id,data); end
    def upsert_link(data); request('PUT','/links/upsert',data); end
    def delete_link(id); request('DELETE','/links/'+id); end
    def list_links(filters={},limit:100,cursor:nil); request('GET','/links',nil,{filters:filters,limit:limit,cursor:cursor}); end
    def count_links(filters={}); request('GET','/links/count',nil,{filters:filters}); end
    def bulk(operations); request('POST','/links/bulk',{operations:operations}); end
    def iterate_links(filters={})
      return enum_for(:iterate_links,filters) unless block_given?
      cursor = nil; seen = {}
      loop do
        page = list_links(filters,cursor:cursor); page['data'].each { |link| yield link }
        cursor = page['nextCursor']; break unless cursor
        raise 'Repeated pagination cursor' if seen[cursor]; seen[cursor]=true
      end
    end
    def track_lead(data); request('POST','/track/lead',data); end
    def track_sale(data); request('POST','/track/sale',data); end
    def analytics(filters={}); request('GET','/analytics',nil,{filters:filters}); end
    def events(filters={},**options); request('GET','/events',nil,options.merge(filters:filters)); end
    def get_resource(kind,id); request('GET','/'+kind+'/'+id); end
    def list_resources(kind,limit:100,cursor:nil); request('GET','/'+kind,nil,{limit:limit,cursor:cursor}); end
    def create_resource(kind,data); request('POST','/'+kind,data); end
    def update_resource(kind,id,data); request('PATCH','/'+kind+'/'+id,data); end
    def delete_resource(kind,id); request('DELETE','/'+kind+'/'+id); end
  end
end
