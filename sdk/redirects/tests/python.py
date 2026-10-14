import os, sys
sys.path.insert(0,os.path.join(os.path.dirname(__file__),'../python'))
from redirects import RedirectsClient, RedirectApiError
api=RedirectsClient(os.environ['REDIRECT_TEST_TOKEN'],os.environ['REDIRECT_TEST_BASE'])
assert api.list_domain_choices()['count']==0
folder=api.create_resource('folders',{'name':'Héllo & + Python'})
tag=api.create_resource('tags',{'name':'Python tag','color':'pink'})
template=api.create_resource('templates',{'name':'Python template','parameters':{'utm_campaign':'Launch & +'}})
assert api.update_resource('folders',folder['id'],{'description':'Changed'})['description']=='Changed'
assert api.update_resource('tags',tag['id'],{'color':'blue'})['color']=='blue'
assert len(api.list_resources('templates')['data'])==1
assert api.get_resource('folders',folder['id'])['name']=='Héllo & + Python'
created=api.create_link({'target':'https://example.com/?q=a%26b#detail','slug':'sdk-python','startsAt':'2020-01-01T00:00:00Z','clickLimit':25,'notes':'SDK notes','folderId':folder['id'],'tagIds':[tag['id']]})
id=created['link']['id']
assert created['link']['clickLimit']==25 and created['link']['notes']=='SDK notes' and created['link']['startsAt']
art=api.upload_preview_image(id,os.environ['REDIRECT_TEST_IMAGE']);api.update_presentation(id,{'preview':{'title':'SDK preview','image':art['image'],'video':'https://example.com/a.mp4'},'cloaked':True});assert api.get_presentation(id)['preview']['title']=='SDK preview'
api.update_policy(id,{'policy':{'track_conversions':True,'geo_targets':{'CH':'/switzerland'}},'password':'fixture-sdk-password'})
policy=api.get_policy(id);assert policy['hasPassword'] is True;assert policy['policy']['preview']['title']=='SDK preview';assert 'password_hash' not in str(policy);assert 'fixture-sdk-password' not in str(policy)
api.update_policy(id,{'policy':{'geo_targets':None},'password':None});policy=api.get_policy(id);assert policy['hasPassword'] is False;assert policy['policy']['track_conversions'] is True;assert 'geo_targets' not in policy['policy']
api.update_link(id,{'comment':'SDK update','isEnabled':False})
assert api.get_link(id)['folderId']==folder['id']
assert api.upsert_link({'slug':'sdk-python','target':'/updated'})['created'] is False
assert api.count_links({'ids':[id]})['count']==1
assert len(list(api.iterate_links({'search':'sdk-page-'})))==101
batch=api.bulk([{'operation':'update','id':id,'data':{'comment':'Batch'}},{'operation':'create','data':{'target':'/events'}}])
api.delete_link(batch['data'][1]['link']['id'])
lead={'clickId':os.environ['REDIRECT_TEST_CLICK'],'customerExternalId':'python','eventId':'sdk-lead:python'}
api.track_lead(lead)
assert api.track_lead(lead)['duplicate'] is True
api.track_sale({**lead,'eventId':'sdk-sale:python','amount':'49.900001','currency':'CHF'})
assert api.analytics({'country':'CH'})['totals']
assert api.events(limit=1)['data']
api.delete_link(id)
for kind,item in [('folders',folder),('tags',tag),('templates',template)]: api.delete_resource(kind,item['id'])
for path,status in [('/redirect-probe',302),('/limited-probe',429)]:
    try: api.request('GET',path); raise AssertionError('Expected API error')
    except RedirectApiError as error:
        assert error.status==status
        if status==429: assert error.retry_after=='17'
try: RedirectsClient('token','http://example.com/api'); raise AssertionError('Insecure base accepted')
except ValueError: pass
