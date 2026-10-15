<?php
require_once __DIR__.'/RedirectsClient.php';
$api=new QueerGuide\RedirectsClient(getenv('REDIRECT_API_TOKEN')?:'',getenv('REDIRECT_API_BASE')?:'https://queer.guide/api/redirects');
echo $api->createLink(['target'=>getenv('REDIRECT_TARGET')?:'https://example.com'])['link']['shortUrl'].PHP_EOL;
if (getenv('REDIRECT_CLICK_ID')) {
 $event=['clickId'=>getenv('REDIRECT_CLICK_ID'),'customerExternalId'=>getenv('REDIRECT_CUSTOMER_ID')?:'','eventId'=>getenv('REDIRECT_EVENT_ID')?:''];$api->trackLead($event);
 if (getenv('REDIRECT_AMOUNT')) $api->trackSale(array_merge($event,['eventId'=>$event['eventId'].':sale','amount'=>getenv('REDIRECT_AMOUNT'),'currency'=>getenv('REDIRECT_CURRENCY')?:'']));
}
