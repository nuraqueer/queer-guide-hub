import { previewImageInfo } from "../_shared/redirect-presentation.ts";
import { policyErrors } from "../_shared/link-policy.ts";
import { bulkLinkInput, linkInput, linkListInput, workspaceInput, LINK_SCOPES } from "../_shared/redirect-links.ts";
import { analyticsFilters } from "../_shared/redirect-analytics.ts";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2.50.5";
import { boundedJson, conversionInput, createRedirectToken, tokenDigest, UUID } from "../_shared/redirect-api.ts";

Deno.serve(async (req: Request) => {
 const origin=req.headers.get('origin') ?? '';
 const cors={ 'Access-Control-Allow-Origin':['https://queer.guide','https://www.queer.guide','http://localhost:5173','http://localhost:4178'].includes(origin)?origin:'', 'Access-Control-Allow-Headers':'authorization, apikey, x-client-info, content-type', 'Access-Control-Allow-Methods':'GET, POST, PUT, PATCH, DELETE, OPTIONS', Vary:'Origin' };
 const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store'}});
 const rpcError=(error:{code?:string;message:string})=>{const status=error.code==='23505'?409:error.code==='42501'?403:error.code==='P0002'?404:(error.code?.startsWith('22')||['23503','23514'].includes(error.code??''))?400:503;return json({error:status===503?'Redirect API temporarily unavailable':error.message},status);};
 if(req.method==='OPTIONS') return new Response(null,{headers:cors});
 const path=new URL(req.url).pathname.split('/redirect-api')[1]?.replace(/\/$/,'') ?? '';
 const credential=req.headers.get('Authorization')?.replace(/^Bearer\s+/i,'') ?? '';
 if(!credential)return json({error:'Unauthorized'},401);
 const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
 const tokenCredential=/^qg_redirect_[a-f0-9]{64}$/.test(credential);
 let user: {id:string;created_at:string;email_confirmed_at?:string;confirmed_at?:string;is_anonymous?:boolean} | null=null;
 let identityClient: ReturnType<typeof createClient> | null=null;
 if(!tokenCredential){
  identityClient=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:'Bearer '+credential}}});
  const {data,error}=await identityClient.auth.getUser(credential);
  if(error || !data.user)return json({error:'Unauthorized'},401);
  user=data.user;
 }
 try {
  const resourceMatch=path.match(/^\/(folders|tags|templates)(?:\/([a-f0-9-]+))?$/i);
  if(resourceMatch){
   const [,kind,id]=resourceMatch, read=req.method==='GET';let tokenId:string|null=null;
   if(tokenCredential){const {data,error}=await db.rpc('authenticate_redirect_api_token',{p_hash:await tokenDigest(credential),p_scope:read?'workspace:read':'workspace:write'});if(error)return json({error:'Credential verification unavailable'},503);if(!data)return json({error:'Workspace scope is required'},403);if(data.redirect_ids!==null)return json({error:'Workspace permissions require an unrestricted credential'},403);tokenId=data.id;}
   else{const {data,error}=await identityClient!.rpc('has_role_jwt',{required_role:'admin'});if(error)return json({error:'Authorization unavailable'},503);if(!data)return json({error:'Forbidden'},403);}
   if(id&&!UUID.test(id))return json({error:'Invalid resource ID'},400);
   let action:string,values:Record<string,unknown>={},limit=50,after:string|null=null;
   if(read&&!id){const query=new URL(req.url).searchParams;if([...query.keys()].some(key=>!['limit','cursor'].includes(key)))return json({error:'Unknown resource page parameter'},400);limit=Number(query.get('limit')??50);after=query.get('cursor');if(!Number.isInteger(limit)||limit<1||limit>100||after&&!UUID.test(after))return json({error:'Invalid resource page'},400);action='list';}
   else if(read&&id)action='get';
   else if(req.method==='POST'&&!id){action='create';values=workspaceInput(kind,await boundedJson(req),true);}
   else if(req.method==='PATCH'&&id){action='update';values=workspaceInput(kind,await boundedJson(req),false);}
   else if(req.method==='DELETE'&&id)action='delete';
   else return json({error:'Method not supported'},405);
   const {data,error}=await db.rpc('redirect_workspace_resource',{p_kind:kind,p_action:action,p_id:id??null,p_values:values,p_limit:limit,p_after:after,p_token_id:tokenId});if(error)return rpcError(error);return json(data,action==='create'?201:200);
  }
  if(path==='/links'||path.startsWith('/links/')) {
   const read=req.method==='GET', scope=read?'links:read':'links:write';
   let tokenId:string|null=null;
   if(tokenCredential){const {data,error}=await db.rpc('authenticate_redirect_api_token',{p_hash:await tokenDigest(credential),p_scope:scope});if(error)return json({error:'Credential verification unavailable'},503);if(!data)return json({error:'Required link scope is missing'},403);tokenId=data.id;}
   else{const {data,error}=await identityClient!.rpc('has_role_jwt',{required_role:'admin'});if(error)return json({error:'Authorization unavailable'},503);if(!data)return json({error:'Forbidden'},403);}
   const presentationMatch=path.match(/^\/links\/([a-f0-9-]{36})\/(presentation|preview-image)$/i);
   if(presentationMatch){
    const [,linkId,endpoint]=presentationMatch;if(!UUID.test(linkId))return json({error:'Invalid link ID'},400);
    if(endpoint==='preview-image'&&req.method==='POST'){
     const access=await db.rpc('redirect_presentation',{p_redirect_id:linkId,p_action:'check',p_token_id:tokenId});
     if(access.error)return rpcError(access.error);
     const body=await boundedJson(req,2100000);
     if(!body||Object.keys(body).some(key=>key!=='image')||typeof body.image!=='string'||body.image.length>2000000||!body.image.length||!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(body.image))return json({error:'Provide a base64 PNG or JPG image'},400);
     const bytes=Uint8Array.from(atob(body.image),char=>char.charCodeAt(0)),info=previewImageInfo(bytes);
     if(info.width!==1200||info.height!==630)return json({error:'Preview artwork must be 1200 × 630 pixels'},400);
     const key=linkId+'/'+crypto.randomUUID()+'.'+info.extension,bucket=db.storage.from('redirect-previews');
     const {error:uploadError}=await bucket.upload(key,bytes,{contentType:info.mime,upsert:false,cacheControl:'3600'});if(uploadError)return json({error:'Image upload unavailable'},503);
     const image=bucket.getPublicUrl(key).data.publicUrl;
     const saved=await db.rpc('redirect_presentation',{p_redirect_id:linkId,p_action:'check',p_token_id:tokenId});
     if(saved.error){try{await bucket.remove([key]);}catch{/* Keep the primary authorization failure if asset cleanup is unavailable. */}return rpcError(saved.error);}return json({image,width:info.width,height:info.height},201);
    }
    if(endpoint==='presentation'&&(req.method==='GET'||req.method==='PATCH')){
     let values:Record<string,unknown>={};
     if(req.method==='PATCH'){
      const body=await boundedJson(req);if(!body||typeof body!=='object'||Array.isArray(body)||!Object.keys(body).length||Object.keys(body).some(key=>!['preview','cloaked'].includes(key)))return json({error:'Invalid presentation fields'},400);
      const errors=policyErrors({...body,...(body.preview===null?{preview:undefined}:{})});if(errors.length)return json({error:errors.join('; ')},400);values=body;
     }
     const {data,error}=await db.rpc('redirect_presentation',{p_redirect_id:linkId,p_action:req.method==='GET'?'get':'patch',p_values:values,p_token_id:tokenId});if(error)return rpcError(error);return json(data);
    }
    return json({error:'Method not supported'},405);
   }
   const query=new URL(req.url).searchParams;
   if(new URL(req.url).search.length>16384)return json({error:'Filters are too large'},400);
   const id=path.slice('/links/'.length), byId=UUID.test(id);
   if(read&&(path==='/links'||path==='/links/count'||byId)) {
    if([...query.keys()].some(key=>!['filters','limit','cursor'].includes(key)))return json({error:'Unknown page parameter'},400);
    const filters=byId?{ids:[id]}:linkListInput(JSON.parse(query.get('filters')??'{}'));
    const count=path==='/links/count',limit=count?0:byId?1:Number(query.get('limit')??50),cursor=query.get('cursor');
    if(!Number.isInteger(limit)||limit<0||limit>100||!count&&limit===0||cursor&&!UUID.test(cursor))return json({error:'Invalid link page'},400);
    const {data,error}=await db.rpc('redirect_management_list',{p_filters:filters,p_limit:limit,p_after:byId?null:cursor,p_token_id:tokenId});
    if(error)return rpcError(error);
    if(byId)return data.data.length?json(data.data[0]):json({error:'Link not found'},404);
    return json(count?{count:data.count}:data);
   }
   let operations:unknown[];
   if(path==='/links/bulk'&&req.method==='POST')operations=bulkLinkInput(await boundedJson(req));
   else if(path==='/links'&&req.method==='POST')operations=[{operation:'create',data:linkInput(await boundedJson(req),'create')}];
   else if(path==='/links/upsert'&&req.method==='PUT')operations=[{operation:'upsert',data:linkInput(await boundedJson(req),'upsert')}];
   else if(byId&&req.method==='PATCH')operations=[{operation:'update',id,data:linkInput(await boundedJson(req),'update')}];
   else if(byId&&req.method==='DELETE')operations=[{operation:'delete',id}];
   else return json({error:'Method or endpoint not supported'},405);
   const {data,error}=await db.rpc('redirect_management_mutate',{p_operations:operations,p_token_id:tokenId,p_actor_id:user?.id??null});
   if(error)return rpcError(error);
   if(path==='/links/bulk')return json({data});
   return json(data[0],data[0]?.created?201:200);
  }
  if((path==='/analytics'||path==='/events')&&req.method==='GET') {
   const query=new URL(req.url).searchParams;
   if(new URL(req.url).search.length>16384)return json({error:'Filters are too large'},400);
   let ids:string[]|null=null;
   if(tokenCredential){const {data,error}=await db.rpc('authenticate_redirect_api_token',{p_hash:await tokenDigest(credential),p_scope:'events:read'});if(error)return json({error:'Credential verification unavailable'},503);if(!data)return json({error:'Read scope is required'},403);ids=data.redirect_ids;}
   else{const {data,error}=await identityClient!.rpc('has_role_jwt',{required_role:'admin'});if(error)return json({error:'Authorization unavailable'},503);if(!data)return json({error:'Forbidden'},403);}
   const filters=analyticsFilters(JSON.parse(query.get('filters')??'{}'));
   let name='redirect_analytics_report',args:Record<string,unknown>={p_filters:filters,p_allowed_ids:ids};
   if(path==='/events'){
    const limit=Number(query.get('limit')??50),snapshot=query.get('snapshot');
    const cursor=query.has('cursor')?JSON.parse(query.get('cursor')!):null;
    if(!Number.isInteger(limit)||limit<1||limit>100||snapshot&&!Number.isFinite(Date.parse(snapshot))||cursor&&(!Number.isFinite(Date.parse(cursor.at))||typeof cursor.id!=='string'||cursor.id.length>100))return json({error:'Invalid event page'},400);
    name='redirect_analytics_page';args={...args,p_limit:limit,p_snapshot:snapshot,p_before_at:cursor?.at??null,p_before_id:cursor?.id??null};
   }
   const {data,error}=await db.rpc(name,args);if(error)return rpcError(error);return json(data);
  }
  if(path==='/native/signup' && req.method==='POST') {
   if(!user || user.is_anonymous || !(user.email_confirmed_at || user.confirmed_at)) return json({error:'A verified account is required'},403);
   const body=await boundedJson(req);
   if(!body || typeof body!=='object' || Object.keys(body).some(key=>key!=='clickId') || typeof body.clickId!=='string' || !UUID.test(body.clickId))return json({error:'Provide an attributed click ID'},400);
   const {data,error}=await db.rpc('record_redirect_conversion',{p_event:{kind:'lead',clickId:body.clickId,customerExternalId:'native:'+user.id,eventId:'native:signup:'+user.id,eventName:'Sign up',occurredAt:user.created_at},p_registered_at:user.created_at});
   if(error)return rpcError(error);
   return json(data,data.duplicate?200:201);
  }
  const kind=path==='/track/lead'?'lead':path==='/track/sale'?'sale':null;
  if(kind && req.method==='POST') {
   let tokenId:string|null=null;
   if(tokenCredential){
    const {data,error}=await db.rpc('authenticate_redirect_api_token',{p_hash:await tokenDigest(credential),p_scope:'conversions:write'});
    if(error)return json({error:'Credential verification unavailable'},503);
    if(!data)return json({error:'Credential expired, revoked, or missing conversion scope'},403);
    tokenId=data.id;
   }else{
    const {data,error}=await identityClient!.rpc('has_role_jwt',{required_role:'admin'});
    if(error || !data)return json({error:'Forbidden'},403);
   }
   const event=conversionInput(await boundedJson(req),kind);
   const {data,error}=await db.rpc('record_redirect_conversion',{p_event:event,p_token_id:tokenId});
   if(error)return rpcError(error);
   return json(data,data.duplicate?200:201);
  }
  if(path==='/tokens' || /^\/tokens\/[a-f0-9-]+$/i.test(path)) {
   if(tokenCredential)return json({error:'Admin session required'},403);
   const {data:admin,error:roleError}=await identityClient!.rpc('has_role_jwt',{required_role:'admin'});
   if(roleError || !admin)return json({error:'Forbidden'},403);
   const select='id,name,prefix,scopes,redirect_ids,created_at,expires_at,revoked_at,last_used_at';
   if(path==='/tokens' && req.method==='GET') {
    const offset=Number(new URL(req.url).searchParams.get('offset') ?? '0');
    if(!Number.isInteger(offset) || offset<0 || offset>1e7)return json({error:'Invalid page offset'},400);
    const {data,count,error}=await db.from('redirect_api_tokens').select(select,{count:'exact'}).order('created_at',{ascending:false}).order('id',{ascending:false}).range(offset,offset+99);
    if(error)return json({error:'Could not load credentials'},503);
    return json({data,count});
   }
   if(path==='/tokens' && req.method==='POST') {
    const body=await boundedJson(req);
    if(!body || typeof body!=='object' || Object.keys(body).some(key=>!['name','expiresAt','redirectIds','scopes'].includes(key)) || typeof body.name!=='string' || !body.name.trim() || body.name.length>100)return json({error:'Provide a credential name (1–100 characters)'},400);
    const end=typeof body.expiresAt==='string'?Date.parse(body.expiresAt):NaN;
    if(!Number.isFinite(end) || end<=Date.now() || end>Date.now()+366*86400000)return json({error:'Credentials must expire within one year'},400);
    if(body.redirectIds!==undefined && (!Array.isArray(body.redirectIds) || body.redirectIds.length<1 || body.redirectIds.length>100 || body.redirectIds.some((id:unknown)=>typeof id!=='string' || !UUID.test(id))))return json({error:'Invalid link scope'},400);
    const scopes=body.scopes??['conversions:write'];
    if(!Array.isArray(scopes)||scopes.length<1||scopes.some(scope=>!LINK_SCOPES.includes(scope)))return json({error:'Invalid credential permissions'},400);
    const ids=body.redirectIds? [...new Set(body.redirectIds)] : null;
    if(ids&&scopes.some(scope=>scope.startsWith('workspace:')))return json({error:'Workspace permissions require an unrestricted credential'},400);
    if(ids){const {data,error}=await db.from('redirects').select('id').in('id',ids).eq('type','SHORT');if(error || data?.length!==ids.length)return json({error:'One or more managed links were not found'},400);}
    const secret=createRedirectToken();
    const {data,error}=await db.from('redirect_api_tokens').insert({name:body.name.trim(),token_hash:await tokenDigest(secret),prefix:secret.slice(0,20),scopes:[...new Set(scopes)],redirect_ids:ids,created_by:user!.id,expires_at:new Date(end).toISOString()}).select(select).single();
    if(error)return json({error:'Could not create credential'},503);
    return json({...data,secret},201);
   }
   const id=path.slice('/tokens/'.length);
   if(req.method==='DELETE' && UUID.test(id)){
    const {data,error}=await db.from('redirect_api_tokens').update({revoked_at:new Date().toISOString()}).eq('id',id).is('revoked_at',null).select('id');
    if(error)return json({error:'Could not revoke credential'},503);
    return json({revoked:!!data?.length});
   }
   return json({error:'Method not allowed'},405);
  }
  return json({error:'Endpoint not found'},404);
 } catch(error){return json({error:error instanceof Error?error.message:'Invalid request'},400);}
});
