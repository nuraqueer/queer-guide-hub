require_relative 'redirects'
api=QueerGuide::RedirectsClient.new(ENV.fetch('REDIRECT_API_TOKEN'),base_url:ENV.fetch('REDIRECT_API_BASE','https://queer.guide/api/redirects'))
puts api.create_link({target:ENV.fetch('REDIRECT_TARGET','https://example.com')})['link']['shortUrl']
if ENV['REDIRECT_CLICK_ID']
 event={clickId:ENV.fetch('REDIRECT_CLICK_ID'),customerExternalId:ENV.fetch('REDIRECT_CUSTOMER_ID'),eventId:ENV.fetch('REDIRECT_EVENT_ID')};api.track_lead(event)
 api.track_sale(event.merge(eventId:event[:eventId]+':sale',amount:ENV['REDIRECT_AMOUNT'],currency:ENV.fetch('REDIRECT_CURRENCY'))) if ENV['REDIRECT_AMOUNT']
end
