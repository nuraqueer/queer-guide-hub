<?php
declare(strict_types=1);
namespace QueerGuide;
class RedirectApiError extends \RuntimeException {
    public function __construct(public readonly int $status, string $message, public readonly ?string $retryAfter = null) { parent::__construct($message); }
}
final class RedirectsClient {
    private string $base;
    public function __construct(private string $token, string $baseUrl = 'https://queer.guide/api/redirects', private float $timeout = 10) {
        $url = parse_url($baseUrl);
        if (trim($token)==='' || preg_match('/[\r\n]/', $token)) throw new \InvalidArgumentException('A server credential is required');
        $safe = $url && (($url['scheme']??'')==='https' || ($url['scheme']??'')==='http' && in_array($url['host']??'', ['localhost','127.0.0.1','[::1]'], true));
        if (!$safe || isset($url['user']) || isset($url['pass']) || isset($url['query']) || isset($url['fragment'])) throw new \InvalidArgumentException('Use HTTPS or a loopback development API');
        if ($timeout<=0) throw new \InvalidArgumentException('Timeout must be positive');
        $this->base = rtrim($baseUrl,'/');
    }
    public function request(string $method, string $path, mixed $body = null, array $query = []): array {
        if (!preg_match('~^/[a-zA-Z0-9_/-]+$~D',$path) || str_contains($path,'//')) throw new \InvalidArgumentException('Invalid API path');
        $params=[];foreach ($query as $key=>$value) if ($value!==null) $params[$key] = is_array($value)||is_object($value) ? json_encode($value,JSON_THROW_ON_ERROR) : (is_bool($value)?($value?'true':'false'):(string)$value);
        $url=$this->base.$path.($params?'?'.http_build_query($params,'','&',PHP_QUERY_RFC3986):'');
        $options=['method'=>$method,'header'=>"Authorization: Bearer ".$this->token."\r\nContent-Type: application/json\r\n",'timeout'=>$this->timeout,'ignore_errors'=>true,'follow_location'=>0,'max_redirects'=>0];
        if ($body!==null) $options['content']=json_encode($body,JSON_THROW_ON_ERROR);
        $stream=@fopen($url,'rb',false,stream_context_create(['http'=>$options]));
        if ($stream===false) throw new \RuntimeException('Redirect API connection failed');
        try {
            $meta=stream_get_meta_data($stream);$headers=$meta['wrapper_data']??[];$status=0;$retry=null;
            foreach ($headers as $header) {if (preg_match('~^HTTP/\S+ (\d{3})~',$header,$m)) $status=(int)$m[1];if (stripos($header,'Retry-After:')===0) $retry=trim(substr($header,12));}
            $raw=stream_get_contents($stream,8*1024*1024+1);
            if ($raw===false) throw new \RuntimeException('API response read failed');
            if (strlen($raw)>8*1024*1024) throw new \RuntimeException('API response exceeds 8 MiB');
            try {$data=$raw===''?[]:json_decode($raw,true,512,JSON_THROW_ON_ERROR);}
            catch (\JsonException $error) {if ($status>=200&&$status<300) throw new \RuntimeException('API returned invalid JSON',0,$error);$data=[];}
            if ($status<200||$status>=300) throw new RedirectApiError($status,$data['error']??'Redirect API request failed',$retry);
            if (!is_array($data)) throw new \RuntimeException('API returned invalid JSON object');
            return $data;
        } finally {fclose($stream);}
    }
    public function getPolicy(string $id): array {return $this->request('GET','/links/'.$id.'/policy');}
    public function updatePolicy(string $id,array $data): array {return $this->request('PATCH','/links/'.$id.'/policy',$data);}
    public function getPresentation(string $id): array {return $this->request('GET','/links/'.$id.'/presentation');}
    public function updatePresentation(string $id,array $data): array {return $this->request('PATCH','/links/'.$id.'/presentation',$data);}
    public function uploadPreviewImage(string $id,string $imageBase64): array {return $this->request('POST','/links/'.$id.'/preview-image',['image'=>$imageBase64]);}
    public function createLink(array $data): array {return $this->request('POST','/links',$data);}
    public function getLink(string $id): array {return $this->request('GET','/links/'.$id);}
    public function updateLink(string $id,array $data): array {return $this->request('PATCH','/links/'.$id,$data);}
    public function upsertLink(array $data): array {return $this->request('PUT','/links/upsert',$data);}
    public function deleteLink(string $id): array {return $this->request('DELETE','/links/'.$id);}
    public function listLinkedDomains(int $limit=100,?string $cursor=null): array {return $this->request('GET','/linked-domains',null,['limit'=>$limit,'cursor'=>$cursor]);}
    public function getQrStyle(string $id): array {return $this->request('GET','/qr-styles/links/'.rawurlencode($id));}
    public function createQrImage(array $data): array {return $this->request('POST','/qr-images',$data);}
    public function listQrImages(int $limit=100,?string $cursor=null): array {return $this->request('GET','/qr-images',null,['limit'=>$limit,'cursor'=>$cursor]);}
    public function revokeQrImage(string $id,string $version): array {return $this->request('DELETE','/qr-images/'.rawurlencode($id),['version'=>$version]);}
    public function listDomainChoices(int $limit=100,?string $cursor=null): array {return $this->request('GET','/domain-choices',null,['limit'=>$limit,'cursor'=>$cursor]);}
    public function listLinks(array $filters=[],int $limit=100,?string $cursor=null): array {return $this->request('GET','/links',null,['filters'=>(object)$filters,'limit'=>$limit,'cursor'=>$cursor]);}
    public function countLinks(array $filters=[]): array {return $this->request('GET','/links/count',null,['filters'=>(object)$filters]);}
    public function bulk(array $operations): array {return $this->request('POST','/links/bulk',['operations'=>$operations]);}
    public function iterateLinks(array $filters=[]): \Generator {
        $cursor=null;$seen=[];do {$page=$this->listLinks($filters,100,$cursor);foreach ($page['data'] as $link) yield $link;$cursor=$page['nextCursor'];if ($cursor!==null) {if (isset($seen[$cursor])) throw new \RuntimeException('Repeated pagination cursor');$seen[$cursor]=true;}} while ($cursor!==null);
    }
    public function trackLead(array $data): array {return $this->request('POST','/track/lead',$data);}
    public function trackSale(array $data): array {return $this->request('POST','/track/sale',$data);}
    public function analytics(array $filters=[]): array {return $this->request('GET','/analytics',null,['filters'=>(object)$filters]);}
    public function events(array $filters=[],array $options=[]): array {return $this->request('GET','/events',null,array_merge($options,['filters'=>(object)$filters]));}
    public function getCustomer(string $id): array {return $this->request('GET','/customers/profile',null,['id'=>$id]);}
    public function updateCustomer(string $id,array $data): array {return $this->request('PATCH','/customers/profile',array_merge($data,['customerExternalId'=>$id]));}
    public function clearCustomer(string $id,?string $version): array {return $this->request('DELETE','/customers/profile',['customerExternalId'=>$id,'version'=>$version]);}
    public function customerJourney(string $id,int $limit=50,?array $cursor=null): array {return $this->request('GET','/customers/journey',null,['id'=>$id,'limit'=>$limit,'cursor'=>$cursor]);}
    public function createReport(array $data): array {if (isset($data['filters']) && is_array($data['filters'])) $data['filters']=(object)$data['filters'];return $this->request('POST','/reports',$data);}
    public function getReport(string $id): array {return $this->request('GET','/reports/'.rawurlencode($id));}
    public function listReports(int $limit=50,?string $cursor=null): array {return $this->request('GET','/reports',null,['limit'=>$limit,'cursor'=>$cursor]);}
    public function updateReport(string $id,array $data): array {if (isset($data['filters']) && is_array($data['filters'])) $data['filters']=(object)$data['filters'];return $this->request('PATCH','/reports/'.rawurlencode($id),$data);}
    public function deleteReport(string $id): array {return $this->request('DELETE','/reports/'.rawurlencode($id));}
    public function runReport(string $id): array {return $this->request('GET','/reports/'.rawurlencode($id).'/run');}
    public function createReportShare(string $id,array $data): array {return $this->request('POST','/reports/'.rawurlencode($id).'/shares',$data);}
    public function listReportShares(string $id): array {return $this->request('GET','/reports/'.rawurlencode($id).'/shares');}
    public function revokeReportShare(string $id,string $shareId): array {return $this->request('DELETE','/reports/'.rawurlencode($id).'/shares/'.rawurlencode($shareId));}
    public function readPublicReport(?array $data=null): array {if (isset($data['dates']) && is_array($data['dates'])) $data['dates']=(object)$data['dates'];return $this->request($data===null?'GET':'POST','/public-report',$data===[]?(object)[]:$data);}
    public function getResource(string $kind,string $id): array {return $this->request('GET','/'.$kind.'/'.$id);}
    public function listResources(string $kind,int $limit=100,?string $cursor=null): array {return $this->request('GET','/'.$kind,null,['limit'=>$limit,'cursor'=>$cursor]);}
    public function createResource(string $kind,array $data): array {return $this->request('POST','/'.$kind,$data);}
    public function updateResource(string $kind,string $id,array $data): array {return $this->request('PATCH','/'.$kind.'/'.$id,$data);}
    public function deleteResource(string $kind,string $id): array {return $this->request('DELETE','/'.$kind.'/'.$id);}
}
