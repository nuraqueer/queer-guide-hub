import os
from redirects import RedirectsClient
api=RedirectsClient(os.environ['REDIRECT_API_TOKEN'],os.environ.get('REDIRECT_API_BASE','https://queer.guide/api/redirects'))
print(api.create_link({'target':os.environ.get('REDIRECT_TARGET','https://example.com')})['link']['shortUrl'])
if os.environ.get('REDIRECT_CLICK_ID'):
    event={'clickId':os.environ['REDIRECT_CLICK_ID'],'customerExternalId':os.environ['REDIRECT_CUSTOMER_ID'],'eventId':os.environ['REDIRECT_EVENT_ID']}
    api.track_lead(event)
    if os.environ.get('REDIRECT_AMOUNT'): api.track_sale({**event,'eventId':event['eventId']+':sale','amount':os.environ['REDIRECT_AMOUNT'],'currency':os.environ['REDIRECT_CURRENCY']})
