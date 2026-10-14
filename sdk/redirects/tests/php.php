<?php
require_once __DIR__.'/../php/RedirectsClient.php';
function check($value): void {if (!$value) throw new RuntimeException('Assertion failed');}
$api=new QueerGuide\RedirectsClient(getenv('REDIRECT_TEST_TOKEN'),getenv('REDIRECT_TEST_BASE'));
check($api->listDomainChoices()['count']===0);
$folder=$api->createResource('folders',['name'=>'Héllo & + PHP']);$tag=$api->createResource('tags',['name'=>'PHP tag','color'=>'pink']);
$template=$api->createResource('templates',['name'=>'PHP template','parameters'=>['utm_campaign'=>'Launch & +']]);
check($api->updateResource('folders',$folder['id'],['description'=>'Changed'])['description']==='Changed');
check($api->updateResource('tags',$tag['id'],['color'=>'blue'])['color']==='blue');check(count($api->listResources('templates')['data'])===1);
check($api->getResource('folders',$folder['id'])['name']==='Héllo & + PHP');
$created=$api->createLink(['target'=>'https://example.com/?q=a%26b#detail','slug'=>'sdk-php','folderId'=>$folder['id'],'tagIds'=>[$tag['id']]]);$id=$created['link']['id'];
$art=$api->uploadPreviewImage($id,getenv('REDIRECT_TEST_IMAGE'));$api->updatePresentation($id,['preview'=>['title'=>'SDK preview','image'=>$art['image'],'video'=>'https://example.com/a.mp4'],'cloaked'=>true]);check($api->getPresentation($id)['preview']['title']==='SDK preview');
$api->updatePolicy($id,['policy'=>['track_conversions'=>true,'geo_targets'=>['CH'=>'/switzerland']],'password'=>'fixture-sdk-password']);
$policy=$api->getPolicy($id);check($policy['hasPassword']===true);check($policy['policy']['preview']['title']==='SDK preview');check(!str_contains(json_encode($policy),'password_hash'));check(!str_contains(json_encode($policy),'fixture-sdk-password'));
$api->updatePolicy($id,['policy'=>['geo_targets'=>null],'password'=>null]);$policy=$api->getPolicy($id);check($policy['hasPassword']===false);check($policy['policy']['track_conversions']===true);check(!array_key_exists('geo_targets',$policy['policy']));
$api->updateLink($id,['comment'=>'SDK update','isEnabled'=>false]);check($api->getLink($id)['folderId']===$folder['id']);
check($api->upsertLink(['slug'=>'sdk-php','target'=>'/updated'])['created']===false);check($api->countLinks(['ids'=>[$id]])['count']===1);
check(count(iterator_to_array($api->iterateLinks(['search'=>'sdk-page-']),false))===101);
$batch=$api->bulk([['operation'=>'update','id'=>$id,'data'=>['comment'=>'Batch']],['operation'=>'create','data'=>['target'=>'/events']]]);$api->deleteLink($batch['data'][1]['link']['id']);
$lead=['clickId'=>getenv('REDIRECT_TEST_CLICK'),'customerExternalId'=>'php','eventId'=>'sdk-lead:php'];$api->trackLead($lead);check($api->trackLead($lead)['duplicate']===true);
$api->trackSale(array_merge($lead,['eventId'=>'sdk-sale:php','amount'=>'49.900001','currency'=>'CHF']));
check($api->analytics(['country'=>'CH'])['totals']);check(count($api->events([],['limit'=>1])['data'])===1);
$api->deleteLink($id);foreach ([['folders',$folder],['tags',$tag],['templates',$template]] as [$kind,$item]) $api->deleteResource($kind,$item['id']);
foreach ([['/redirect-probe',302],['/limited-probe',429]] as [$path,$status]) {try {$api->request('GET',$path);throw new RuntimeException('Expected API error');} catch (QueerGuide\RedirectApiError $error) {check($error->status===$status);if ($status===429) check($error->retryAfter==='17');}}
try {new QueerGuide\RedirectsClient('token','http://example.com/api');throw new RuntimeException('Insecure base accepted');} catch (InvalidArgumentException) {}
