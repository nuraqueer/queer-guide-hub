require_relative '../ruby/redirects'
api=QueerGuide::RedirectsClient.new(ENV.fetch('REDIRECT_TEST_TOKEN'),base_url:ENV.fetch('REDIRECT_TEST_BASE'))
def check(value); raise 'Assertion failed' unless value; end
check(api.list_domain_choices['count']==0)
folder=api.create_resource('folders',{name:'Héllo & + Ruby'});tag=api.create_resource('tags',{name:'Ruby tag',color:'pink'})
template=api.create_resource('templates',{name:'Ruby template',parameters:{utm_campaign:'Launch & +'}})
check(api.update_resource('folders',folder['id'],{description:'Changed'})['description']=='Changed')
check(api.update_resource('tags',tag['id'],{color:'blue'})['color']=='blue')
check(api.list_resources('templates')['data'].length==1)
check(api.get_resource('folders',folder['id'])['name']=='Héllo & + Ruby')
created=api.create_link({target:'https://example.com/?q=a%26b#detail',slug:'sdk-ruby',startsAt:'2020-01-01T00:00:00Z',clickLimit:25,notes:'SDK notes',folderId:folder['id'],tagIds:[tag['id']]});id=created['link']['id'];check(created['link']['clickLimit']==25 && created['link']['notes']=='SDK notes' && created['link']['startsAt'])
art=api.upload_preview_image(id,ENV.fetch('REDIRECT_TEST_IMAGE'));api.update_presentation(id,{preview:{title:'SDK preview',image:art['image'],video:'https://example.com/a.mp4'},cloaked:true});check(api.get_presentation(id)['preview']['title']=='SDK preview')
api.update_policy(id,{policy:{track_conversions:true,geo_targets:{CH:'/switzerland'}},password:'fixture-sdk-password'})
policy=api.get_policy(id);check(policy['hasPassword']==true);check(policy['policy']['preview']['title']=='SDK preview');check(!policy.to_s.include?('password_hash'));check(!policy.to_s.include?('fixture-sdk-password'))
api.update_policy(id,{policy:{geo_targets:nil},password:nil});policy=api.get_policy(id);check(policy['hasPassword']==false);check(policy['policy']['track_conversions']==true);check(!policy['policy'].key?('geo_targets'))
api.update_link(id,{comment:'SDK update',isEnabled:false});check(api.get_link(id)['folderId']==folder['id'])
check(api.upsert_link({slug:'sdk-ruby',target:'/updated'})['created']==false)
check(api.count_links({ids:[id]})['count']==1)
check(api.iterate_links({search:'sdk-page-'}).to_a.length==101)
batch=api.bulk([{operation:'update',id:id,data:{comment:'Batch'}},{operation:'create',data:{target:'/events'}}]);api.delete_link(batch['data'][1]['link']['id'])
lead={clickId:ENV.fetch('REDIRECT_TEST_CLICK'),customerExternalId:'ruby',eventId:'sdk-lead:ruby'}
api.track_lead(lead);check(api.track_lead(lead)['duplicate']==true)
api.track_sale(lead.merge(eventId:'sdk-sale:ruby',amount:'49.900001',currency:'CHF'))
check(api.analytics({country:'CH'})['totals']);check(!api.events({},limit:1)['data'].empty?)
api.delete_link(id);[['folders',folder],['tags',tag],['templates',template]].each {|kind,item|api.delete_resource(kind,item['id'])}
[['/redirect-probe',302],['/limited-probe',429]].each do |path,status|
 begin;api.request('GET',path);raise 'Expected API error'
 rescue QueerGuide::RedirectApiError => error;check(error.status==status);check(error.retry_after=='17') if status==429;end
end
begin;QueerGuide::RedirectsClient.new('token',base_url:'http://example.com/api');raise 'Insecure base accepted';rescue ArgumentError;end
