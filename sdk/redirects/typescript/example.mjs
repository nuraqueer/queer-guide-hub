import {RedirectsClient} from './dist/index.js';
const api=new RedirectsClient(process.env.REDIRECT_API_TOKEN??'',{baseUrl:process.env.REDIRECT_API_BASE});
const result=await api.createLink({target:process.env.REDIRECT_TARGET??'https://example.com'});
console.log(result.link.shortUrl);
if(process.env.REDIRECT_CLICK_ID){
 const event={clickId:process.env.REDIRECT_CLICK_ID,customerExternalId:process.env.REDIRECT_CUSTOMER_ID??'',eventId:process.env.REDIRECT_EVENT_ID??''};
 await api.trackLead(event);
 if(process.env.REDIRECT_AMOUNT)await api.trackSale({...event,eventId:event.eventId+':sale',amount:process.env.REDIRECT_AMOUNT,currency:process.env.REDIRECT_CURRENCY??''});
}
