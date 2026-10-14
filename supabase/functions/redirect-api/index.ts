import {manualRedirectInput} from '../_shared/redirect-manual-records.ts';
import {domainProviderConfig,domainProviderInput} from '../_shared/redirect-domain-provider.ts';
import {domainInput,checkRedirectDomainDns} from '../_shared/redirect-domains.ts';
import {savedReportInput,reportShareInput,publicReportRequest} from '../_shared/redirect-reports.ts';
import { policyPatchInput } from '../_shared/redirect-policy-api.ts';
import { generateRedirectPreview } from '../_shared/redirect-preview-generation.ts';
import { isLlmConfigured } from '../_shared/llm-client.ts';
import { previewImageInfo } from "../_shared/redirect-presentation.ts";
import { policyErrors, hashLinkPassword } from "../_shared/link-policy.ts";
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
 if(path==='/public-report')return publicReportRequest(req,db,Deno.env.get('REDIRECT_RELAY_SECRET')??Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,cors);
 const tokenCredential=/^qg_redirect_[a-f0-9]{64}$/.test(credential);
 let user: {id:string;created_at:string;email_confirmed_at?:string;confirmed_at?:string;is_anonymous?:boolean} | null=null;
 let identityClient: ReturnType<typeof createClient> | null=null;
 if(!tokenCredential){
  identityClient=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:'Bearer '+credential}}});
  const {data,error}=await identityClient.auth.getUser(credential);
  if(error || !data.user)return json({error:'Unauthorized'},401);
  user=data.user;
 }
 const sessionPrincipal=async(scope:string):Promise<{id:string|null;role?:string;label?:string;failure?:Response}>=>{
  if(!user||user.is_anonymous)return {id:null,failure:json({error:'A registered account is required'},403)};
  const role=await identityClient!.rpc('has_role_jwt',{required_role:'admin'});
  if(role.error)return {id:null,failure:json({error:'Authorization unavailable'},503)};
  if(role.data)return {id:null,role:'owner'};
  const membership=await db.rpc('redirect_session_principal',{p_user_id:user.id,p_scope:scope});
  if(membership.error)return {id:null,failure:rpcError(membership.error)};
  if(!membership.data||typeof membership.data.id!=='string'||!UUID.test(membership.data.id))return {id:null,failure:json({error:'Redirects workspace access is required'},403)};
  return {id:membership.data.id,role:membership.data.role,label:membership.data.label};
 };
 try {
  if(path==='/session'&&req.method==='GET'){if(tokenCredential)return json({error:'Account session required'},403);const principal=await sessionPrincipal('links:read');if(principal.failure)return principal.failure;return json({role:principal.role,label:principal.label??null});}
  const manual=path.match(/^\/manual-records(?:\/([a-f0-9-]{36}))?$/i);
  if(manual){
   if(tokenCredential)return json({error:'Workspace owner account session required'},403);
   const principal=await sessionPrincipal('workspace:write');if(principal.failure)return principal.failure;if(principal.id!==null)return json({error:'Workspace owner access required'},403);
   const id=manual[1]??null;if(id&&!UUID.test(id)||new URL(req.url).search)return json({error:'Invalid manual redirect request'},400);
   let values=null,expected=null;
   if(req.method==='GET'&&id){}
   else if(req.method===(id?'PATCH':'POST')){
    const body=await boundedJson(req,262144);
    if(!body||typeof body!=='object'||Array.isArray(body)||Object.keys(body).some(key=>!['values','expectedUpdatedAt'].includes(key))||id&&(typeof body.expectedUpdatedAt!=='string'||!Number.isFinite(Date.parse(body.expectedUpdatedAt)))||!id&&body.expectedUpdatedAt!=null)return json({error:'Provide redirect fields and the current record timestamp'},400);
    values=manualRedirectInput(body.values,!id);expected=body.expectedUpdatedAt??null;
   }else return json({error:'Method not supported'},405);
   const result=await db.rpc('redirect_manual_record',{p_actor:user!.id,p_id:id,p_values:values,p_expected_updated_at:expected});if(result.error)return rpcError(result.error);return json(result.data,id?200:201);
  }
  if(path==='/domain-choices'||path==='/linked-domains'){
   if(req.method!=='GET')return json({error:'Method not supported'},405);
   let principalId:string|null=null;
   if(tokenCredential){const {data,error}=await db.rpc('authenticate_redirect_api_token',{p_hash:await tokenDigest(credential),p_scope:'links:read'});if(error)return json({error:'Credential verification unavailable'},503);if(!data)return json({error:'Read scope is required'},403);principalId=data.id;}
   else{const principal=await sessionPrincipal('links:read');if(principal.failure)return principal.failure;principalId=principal.id;}
   const q=new URL(req.url).searchParams,limit=Number(q.get('limit')??100),after=q.get('cursor');
   if([...q.keys()].some(key=>!['limit','cursor'].includes(key))||!Number.isInteger(limit)||limit<1||limit>100||after&&!UUID.test(after))return json({error:'Invalid domain page'},400);
   const result=await db.rpc(path==='/linked-domains'?'redirect_linked_domains':'redirect_domain_choices',{p_token_id:principalId,p_limit:limit,p_after:after});if(result.error)return rpcError(result.error);return json(result.data);
  }
  if(path==='/domain-preference'){
   if(tokenCredential)return json({error:'Workspace owner account session required'},403);
   const principal=await sessionPrincipal('workspace:write');if(principal.failure)return principal.failure;if(principal.id!==null)return json({error:'Workspace owner access required'},403);
   if(!['GET','PATCH'].includes(req.method))return json({error:'Method not supported'},405);if(new URL(req.url).search)return json({error:'Invalid preference parameters'},400);
   let values=null;
   if(req.method==='PATCH'){
    const body=await boundedJson(req,16384);
    if(!body||typeof body!=='object'||Array.isArray(body)||Object.keys(body).some(key=>!['domainId','version'].includes(key))||!Object.hasOwn(body,'domainId')||body.domainId!==null&&(typeof body.domainId!=='string'||!UUID.test(body.domainId))||typeof body.version!=='string'||!UUID.test(body.version))return json({error:'Provide a domain ID or null and the current preference version'},400);
    values=body;
   }
   const result=await db.rpc('redirect_domain_preference',{p_actor:user!.id,p_values:values});if(result.error)return rpcError(result.error);return json(result.data);
  }
  const domains=path.match(/^\/domains(?:\/([a-f0-9-]{36}))?(?:\/(verify|rotate|provider)(?:\/(connect|refresh|disconnect|adopt|confirm-absence|restart-validation))?)?$/i);
  if(domains){
   if(tokenCredential)return json({error:'Workspace owner account session required'},403);
   const principal=await sessionPrincipal('workspace:write');if(principal.failure)return principal.failure;
   if(principal.id!==null)return json({error:'Workspace owner access required'},403);
   const [,id,endpoint,providerAction]=domains;if(id&&!UUID.test(id)||endpoint&&!id||providerAction&&endpoint!=='provider')return json({error:'Invalid domain ID'},400);
   const providerConfig=domainProviderConfig(Deno.env.get('REDIRECT_CF_ZONE_ID')??'',Deno.env.get('REDIRECT_CF_API_TOKEN')??'',Deno.env.get('REDIRECT_CNAME_TARGET')??'');
   if(endpoint==='provider'){
    if(req.method!=='POST'||!providerAction)return json({error:'Method not supported'},405);
    if(!providerConfig)return json({error:'Hostname provider is not configured'},503);
    const values=domainProviderInput(await boundedJson(req,16384),providerAction);
    const result=providerAction==='restart-validation'?await db.rpc('request_redirect_domain_validation_restart',{p_actor:user!.id,p_id:id,p_version:values.version,p_zone:providerConfig.zoneId,p_target:providerConfig.cnameTarget}):await db.rpc('redirect_domain_provider_action',{p_actor:user!.id,p_id:id,p_version:values.version,p_action:providerAction.replace('-','_'),p_zone:providerConfig.zoneId,p_target:providerConfig.cnameTarget,p_candidate:values.candidateId??null});if(result.error)return rpcError(result.error);return json(result.data);
   }
   let action:string,values:Record<string,unknown>={},limit=50,after:string|null=null;
   if(endpoint==='verify'&&req.method==='POST'){
    values=domainInput(await boundedJson(req,16384),'version');
    const reserved=await db.rpc('redirect_domain_resource',{p_action:'reserve',p_actor:user!.id,p_id:id,p_values:values});if(reserved.error)return rpcError(reserved.error);
    if(reserved.data.retryAfter)return new Response(JSON.stringify({error:'Please wait before checking DNS again'}),{status:429,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store','Retry-After':String(reserved.data.retryAfter)}});
    const domain=reserved.data.domain,outcome=await checkRedirectDomainDns(domain.verification);
    const result=await db.rpc('redirect_domain_check_result',{p_actor:user!.id,p_id:id,p_version:domain.version,p_attempt:reserved.data.attempt,p_outcome:outcome});if(result.error)return rpcError(result.error);return json(result.data);
   }
   if(endpoint==='rotate'&&req.method==='POST'){action='rotate';values=domainInput(await boundedJson(req,16384),'version');}
   else if(!endpoint&&req.method==='GET'){action=id?'get':'list';const q=new URL(req.url).searchParams;if([...q.keys()].some(key=>!['limit','cursor'].includes(key)))return json({error:'Invalid domain page'},400);limit=Number(q.get('limit')??50);after=q.get('cursor');if(!Number.isInteger(limit)||limit<1||limit>100||after&&!UUID.test(after))return json({error:'Invalid domain page'},400);}
   else if(!id&&req.method==='POST'){action='create';values=domainInput(await boundedJson(req,16384),'create');}
   else if(id&&!endpoint&&req.method==='PATCH'){action='patch';values=domainInput(await boundedJson(req,16384),'patch');}
   else if(id&&!endpoint&&req.method==='DELETE'){action='delete';values=domainInput(await boundedJson(req,16384),'version');}else return json({error:'Method not supported'},405);
   const result=await db.rpc('redirect_domain_resource',{p_action:action,p_actor:user!.id,p_id:id??null,p_values:values,p_limit:limit,p_after:after});if(result.error)return rpcError(result.error);return json(action==='list'?{...result.data,providerSetup:{configured:providerConfig!==null,cnameTarget:providerConfig?.cnameTarget??null}}:result.data,action==='create'?201:200);
  }
  const reports=path.match(/^\/reports(?:\/([a-f0-9-]{36}))?(?:\/(run|shares)(?:\/([a-f0-9-]{36}))?)?$/i);
  if(reports){
   if(tokenCredential)return json({error:'Account session required'},403);
   const principal=await sessionPrincipal('events:read');if(principal.failure)return principal.failure;
   const [,id,endpoint,shareId]=reports;if(id&&!UUID.test(id)||shareId&&!UUID.test(shareId)||endpoint&&!id)return json({error:'Invalid report ID'},400);
   if(endpoint==='shares'){
    let action:string,values:Record<string,unknown>={},passwordHash=null;
    if(req.method==='GET'&&!shareId)action='list';
    else if(req.method==='DELETE'&&shareId)action='revoke';
    else if(req.method==='POST'&&!shareId){action='create';const input=reportShareInput(await boundedJson(req));values=input.values;
     if(input.password){const reserved=await db.rpc('reserve_redirect_report_password',{p_actor:user!.id,p_principal:principal.id});if(reserved.error)return rpcError(reserved.error);if(reserved.data)return new Response(JSON.stringify({error:'Password update limit reached'}),{status:429,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store','Retry-After':String(reserved.data)}});passwordHash=await hashLinkPassword(input.password);}
    }else return json({error:'Method not supported'},405);
    const {data,error}=await db.rpc('redirect_report_share_resource',{p_action:action,p_actor:user!.id,p_principal:principal.id,p_report:id,p_id:shareId??null,p_values:values,p_password_hash:passwordHash});if(error)return rpcError(error);return json(data,action==='create'?201:200);
   }
   let action:string,values:Record<string,unknown>={},limit=50,after:string|null=null;
   if(req.method==='GET'&&endpoint==='run')action='run';
   else if(req.method==='GET'&&!endpoint){action=id?'get':'list';const q=new URL(req.url).searchParams;if([...q.keys()].some(k=>!['limit','cursor'].includes(k)))return json({error:'Invalid report page'},400);limit=Number(q.get('limit')??50);after=q.get('cursor');if(!Number.isInteger(limit)||limit<1||limit>100||after&&!UUID.test(after))return json({error:'Invalid report page'},400);}
   else if(req.method==='POST'&&!id){action='create';values=savedReportInput(await boundedJson(req),true);}
   else if(req.method==='PATCH'&&id&&!endpoint){action='patch';values=savedReportInput(await boundedJson(req),false);}
   else if(req.method==='DELETE'&&id&&!endpoint)action='delete';else return json({error:'Method not supported'},405);
   const {data,error}=await db.rpc('redirect_saved_report_resource',{p_action:action,p_actor:user!.id,p_principal:principal.id,p_id:id??null,p_values:values,p_limit:limit,p_after:after});if(error)return rpcError(error);return json(data,action==='create'?201:200);
  }
  const requestMatch=path.match(/^\/access-requests(?:\/([a-f0-9-]{36}))?$/i);
  if(requestMatch){
   if(tokenCredential)return json({error:'Account session required'},403);
   const principal=await sessionPrincipal('workspace:read');if(principal.failure)return principal.failure;
   const id=requestMatch[1];if(id&&!UUID.test(id))return json({error:'Invalid request ID'},400);
   if(req.method==='GET'&&!id){
    const query=new URL(req.url).searchParams,view=query.get('view')??'mine',limit=Number(query.get('limit')??50),cursor=query.get('cursor');
    if([...query.keys()].some(k=>!['view','limit','cursor'].includes(k))||!['mine','review'].includes(view)||!Number.isInteger(limit)||limit<1||limit>100||cursor&&!UUID.test(cursor))return json({error:'Invalid request page'},400);
    const {data,error}=await db.rpc('redirect_access_requests_page',{p_principal:principal.id,p_view:view,p_limit:limit,p_after:cursor});if(error)return rpcError(error);return json(data);
   }
   let action:string,folder:string|null=null,message='',permission='edit';
   if(req.method==='POST'&&!id){const body=await boundedJson(req);if(!body||typeof body!=='object'||Array.isArray(body)||Object.keys(body).some(k=>!['folderId','message'].includes(k))||typeof body.folderId!=='string'||!UUID.test(body.folderId)||body.message!==undefined&&(typeof body.message!=='string'||body.message.length>1000))return json({error:'Provide a folder and optional message (up to 1,000 characters)'},400);action='create';folder=body.folderId;message=body.message??'';}
   else if(req.method==='PATCH'&&id){const body=await boundedJson(req);if(!body||typeof body!=='object'||Array.isArray(body)||Object.keys(body).some(k=>!['action','permission'].includes(k))||!['approve','deny'].includes(body.action)||body.permission!==undefined&&!['edit','owner'].includes(body.permission))return json({error:'Choose approve or deny and edit or owner access'},400);action=body.action;permission=body.permission??'edit';}
   else if(req.method==='DELETE'&&id)action='cancel';else return json({error:'Method not supported'},405);
   const {data,error}=await db.rpc('redirect_access_request',{p_action:action,p_principal:principal.id,p_id:id??null,p_folder:folder,p_message:message,p_permission:permission,p_actor:user!.id});if(error)return rpcError(error);
   if(data.retryAfter)return new Response(JSON.stringify({error:'Please wait before requesting access again',retryAfter:data.retryAfter}),{status:429,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store','Retry-After':String(data.retryAfter)}});
   return json(data,action==='create'&&!data.duplicate?201:200);
  }
  const memberMatch=path.match(/^\/members(?:\/([a-f0-9-]{36}))?$/i);
  if(memberMatch){
   if(tokenCredential||!user||user.is_anonymous)return json({error:'Admin session required'},403);
   const role=await identityClient!.rpc('has_role_jwt',{required_role:'admin'});if(role.error)return json({error:'Authorization unavailable'},503);if(!role.data)return json({error:'Forbidden'},403);
   const id=memberMatch[1],select='id,user_id,kind,label,role,active,created_at';if(id&&!UUID.test(id))return json({error:'Invalid member ID'},400);
   if(req.method==='GET'&&!id){
    const query=new URL(req.url).searchParams,offset=Number(query.get('offset')??0);if([...query.keys()].some(k=>k!=='offset')||!Number.isInteger(offset)||offset<0||offset>1e7)return json({error:'Invalid member page'},400);
    const {data,count,error}=await db.from('redirect_workspace_members').select(select,{count:'exact'}).order('id').range(offset,offset+99);if(error)return rpcError(error);return json({data,count});
   }
   if(req.method==='DELETE'&&id){const {data,error}=await db.from('redirect_workspace_members').delete().eq('id',id).select('id');if(error)return rpcError(error);return json({deleted:!!data?.length,id});}
   if(req.method==='POST'&&!id||req.method==='PATCH'&&id){
    const body=await boundedJson(req),create=req.method==='POST',allowed=create?['label','role','active','kind','userId']:['label','role','active'];
    if(!body||typeof body!=='object'||Array.isArray(body)||!Object.keys(body).length||Object.keys(body).some(k=>!allowed.includes(k)))return json({error:'Invalid membership fields'},400);
    if((create||body.label!==undefined)&&(typeof body.label!=='string'||!body.label.trim()||body.label.trim().length>100))return json({error:'Member label must be 1–100 characters'},400);
    if(body.role!==undefined&&!['member','viewer'].includes(body.role)||body.active!==undefined&&typeof body.active!=='boolean')return json({error:'Invalid membership role or status'},400);
    if(create&&(!['user','machine'].includes(body.kind)||body.kind==='user'&&(typeof body.userId!=='string'||!UUID.test(body.userId))||body.kind==='machine'&&body.userId!=null))return json({error:'Choose an existing account UUID or a machine member'},400);
    const values={...(body.label!==undefined?{label:body.label.trim()}:{}),...(body.role!==undefined?{role:body.role}:{}),...(body.active!==undefined?{active:body.active}:{}),...(create?{kind:body.kind,user_id:body.kind==='user'?body.userId:null}:{})};
    const table=db.from('redirect_workspace_members'),change=create?table.insert(values):table.update(values).eq('id',id!);
    const {data,error}=await change.select(select).single();if(error)return rpcError(error);return json(data,create?201:200);
   }
   return json({error:'Method not supported'},405);
  }
  const accessMatch=path.match(/^\/folders\/([a-f0-9-]{36})\/access$/i);
  if(accessMatch){
   if(!UUID.test(accessMatch[1]))return json({error:'Invalid folder ID'},400);
   if(!['GET','PATCH'].includes(req.method))return json({error:'Method not supported'},405);
   const accessScope=req.method==='GET'?'workspace:read':'workspace:write';let principalId:string|null=null;
   if(tokenCredential){const {data,error}=await db.rpc('authenticate_redirect_api_token',{p_hash:await tokenDigest(credential),p_scope:accessScope});if(error)return json({error:'Credential verification unavailable'},503);if(!data||data.redirect_ids!==null)return json({error:'Unrestricted workspace scope is required'},403);principalId=data.id;}
   else{const principal=await sessionPrincipal(accessScope);if(principal.failure)return principal.failure;principalId=principal.id;}
   const values=req.method==='PATCH'?await boundedJson(req):null;
   if(req.method==='PATCH'&&(!values||typeof values!=='object'||Array.isArray(values)))return json({error:'Provide access settings'},400);
   const {data,error}=await db.rpc('redirect_folder_access',{p_folder:accessMatch[1],p_values:values,p_token_id:principalId});if(error)return rpcError(error);return json(data);
  }
  const resourceMatch=path.match(/^\/(folders|tags|templates)(?:\/([a-f0-9-]+))?$/i);
  if(resourceMatch){
   const [,kind,id]=resourceMatch, read=req.method==='GET';let tokenId:string|null=null;
   if(tokenCredential){const {data,error}=await db.rpc('authenticate_redirect_api_token',{p_hash:await tokenDigest(credential),p_scope:read?'workspace:read':'workspace:write'});if(error)return json({error:'Credential verification unavailable'},503);if(!data)return json({error:'Workspace scope is required'},403);if(data.redirect_ids!==null)return json({error:'Workspace permissions require an unrestricted credential'},403);tokenId=data.id;}
   else{const principal=await sessionPrincipal(read?'workspace:read':'workspace:write');if(principal.failure)return principal.failure;tokenId=principal.id;}
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
   else{const principal=await sessionPrincipal(scope);if(principal.failure)return principal.failure;tokenId=principal.id;}
   const variants=path.match(/^\/links\/([a-f0-9-]{36})\/variants$/i);
   if(variants){if(req.method!=='GET')return json({error:'Method not supported'},405);if(!UUID.test(variants[1]))return json({error:'Invalid link ID'},400);const {data,error}=await db.rpc('redirect_scoped_variant_performance',{p_redirect_id:variants[1],p_token_id:tokenId});if(error)return rpcError(error);return json(data);}
   const policyMatch=path.match(/^\/links\/([a-f0-9-]{36})\/policy$/i);
   if(policyMatch){
    const linkId=policyMatch[1];if(!UUID.test(linkId))return json({error:'Invalid link ID'},400);
    if(req.method!=='GET'&&req.method!=='PATCH')return json({error:'Method not supported'},405);
    const input=req.method==='PATCH'?policyPatchInput(await boundedJson(req)):{patch:{},changePassword:false,password:null};
    let passwordHash=null;
    if(input.changePassword&&typeof input.password==='string'){
     const reserved=await db.rpc('reserve_redirect_policy_password',{p_redirect_id:linkId,p_token_id:tokenId,p_actor_id:user?.id??null});if(reserved.error)return rpcError(reserved.error);
     if(reserved.data)return new Response(JSON.stringify({error:'Password update limit reached'}),{status:429,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store','Retry-After':String(reserved.data)}});
     passwordHash=await hashLinkPassword(input.password);
    }
    const {data,error}=await db.rpc('redirect_policy_resource',{p_redirect_id:linkId,p_action:req.method==='GET'?'get':'patch',p_patch:input.patch,p_password_hash:passwordHash,p_change_password:input.changePassword,p_token_id:tokenId});if(error)return rpcError(error);return json(data);
   }
   const presentationMatch=path.match(/^\/links\/([a-f0-9-]{36})\/(presentation|preview-image|preview-generate)$/i);
   if(presentationMatch){
    const [,linkId,endpoint]=presentationMatch;if(!UUID.test(linkId))return json({error:'Invalid link ID'},400);
    if(endpoint==='preview-generate'&&req.method==='POST'){
     const access=await db.rpc('redirect_presentation',{p_redirect_id:linkId,p_action:'check',p_token_id:tokenId});if(access.error)return rpcError(access.error);
     const body=await boundedJson(req);if(!body||typeof body!=='object'||Array.isArray(body)||Object.keys(body).length)return json({error:'Generation accepts an empty object'},400);
     const apiKey=Deno.env.get('FIRECRAWL_API_KEY');
     if(!apiKey||(!isLlmConfigured()&&!Deno.env.get('NVIDIA_API_KEY'))||Deno.env.get('AI_DISABLED')==='1')return json({error:'Preview generation is not configured'},503);
     const reservation=await db.rpc('reserve_redirect_preview',{p_redirect_id:linkId,p_token_id:tokenId,p_actor_id:user?.id??null});if(reservation.error)return rpcError(reservation.error);
     if(reservation.data.retryAfter)return new Response(JSON.stringify({error:'Preview generation limit reached'}),{status:429,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store','Retry-After':String(reservation.data.retryAfter)}});
     let draft;try{draft=await generateRedirectPreview(reservation.data.target,apiKey,linkId);}catch{return json({error:'Could not generate a preview from this destination. Try again later or enter it manually.'},503);}
     const checked=await db.rpc('redirect_presentation',{p_redirect_id:linkId,p_action:'check',p_token_id:tokenId});if(checked.error)return rpcError(checked.error);
     return json(draft);
    }
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
   if(path==='/links/bulk'&&req.method==='POST')operations=bulkLinkInput(await boundedJson(req,2100000));
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
  if((path==='/analytics'||path==='/events')&&['GET','POST'].includes(req.method)) {
   const query=new URL(req.url).searchParams;
   if(new URL(req.url).search.length>16384)return json({error:'Filters are too large'},400);
   let tokenId:string|null=null;
   if(tokenCredential){const {data,error}=await db.rpc('authenticate_redirect_api_token',{p_hash:await tokenDigest(credential),p_scope:'events:read'});if(error)return json({error:'Credential verification unavailable'},503);if(!data)return json({error:'Read scope is required'},403);tokenId=data.id;}
   else{const principal=await sessionPrincipal('events:read');if(principal.failure)return principal.failure;tokenId=principal.id;}
   let body:Record<string,unknown>|null=null;
   if(req.method==='POST'){body=await boundedJson(req);if(!body||typeof body!=='object'||Array.isArray(body)||new URL(req.url).search||Object.keys(body).some(k=>!(path==='/events'?['filters','limit','snapshot','cursor']:['filters']).includes(k)))return json({error:'Invalid analytics body'},400);}
   if(body&&path==='/events'&&(body.snapshot!==undefined&&body.snapshot!==null&&typeof body.snapshot!=='string'||body.limit!==undefined&&typeof body.limit!=='number'))return json({error:'Invalid event page'},400);
   const filters=analyticsFilters(body?body.filters??{}:JSON.parse(query.get('filters')??'{}'));
   const name='redirect_scoped_analytics';let args:Record<string,unknown>={p_action:path==='/events'?'events':'report',p_filters:filters,p_token_id:tokenId};
   if(path==='/events'){
    const limit=Number(body?body.limit??50:query.get('limit')??50),snapshot=body?(typeof body.snapshot==='string'?body.snapshot:null):query.get('snapshot');
    const cursor:any=body?body.cursor??null:query.has('cursor')?JSON.parse(query.get('cursor')!):null;
    if(!Number.isInteger(limit)||limit<1||limit>100||snapshot&&!Number.isFinite(Date.parse(snapshot))||cursor&&(!Number.isFinite(Date.parse(cursor.at))||typeof cursor.id!=='string'||cursor.id.length>100))return json({error:'Invalid event page'},400);
    args={...args,p_limit:limit,p_snapshot:snapshot,p_before_at:cursor?.at??null,p_before_id:cursor?.id??null};
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
   const select='id,name,prefix,scopes,redirect_ids,member_id,created_at,expires_at,revoked_at,last_used_at';
   if(path==='/tokens' && req.method==='GET') {
    const offset=Number(new URL(req.url).searchParams.get('offset') ?? '0');
    if(!Number.isInteger(offset) || offset<0 || offset>1e7)return json({error:'Invalid page offset'},400);
    const {data,count,error}=await db.from('redirect_api_tokens').select(select,{count:'exact'}).order('created_at',{ascending:false}).order('id',{ascending:false}).range(offset,offset+99);
    if(error)return json({error:'Could not load credentials'},503);
    return json({data,count});
   }
   if(path==='/tokens' && req.method==='POST') {
    const body=await boundedJson(req);
    if(!body || typeof body!=='object' || Object.keys(body).some(key=>!['name','expiresAt','redirectIds','scopes','memberId'].includes(key)) || typeof body.name!=='string' || !body.name.trim() || body.name.length>100)return json({error:'Provide a credential name (1–100 characters)'},400);
    const end=typeof body.expiresAt==='string'?Date.parse(body.expiresAt):NaN;
    if(!Number.isFinite(end) || end<=Date.now() || end>Date.now()+366*86400000)return json({error:'Credentials must expire within one year'},400);
    if(body.redirectIds!==undefined && (!Array.isArray(body.redirectIds) || body.redirectIds.length<1 || body.redirectIds.length>100 || body.redirectIds.some((id:unknown)=>typeof id!=='string' || !UUID.test(id))))return json({error:'Invalid link scope'},400);
    const scopes=body.scopes??['conversions:write'];
    if(!Array.isArray(scopes)||scopes.length<1||scopes.some(scope=>!LINK_SCOPES.includes(scope)))return json({error:'Invalid credential permissions'},400);
    const ids=body.redirectIds? [...new Set(body.redirectIds)] : null;
    if(ids&&scopes.some(scope=>scope.startsWith('workspace:')))return json({error:'Workspace permissions require an unrestricted credential'},400);
    if(ids){const {data,error}=await db.from('redirects').select('id').in('id',ids).eq('type','SHORT');if(error || data?.length!==ids.length)return json({error:'One or more managed links were not found'},400);}
    if(body.memberId!==undefined&&(typeof body.memberId!=='string'||!UUID.test(body.memberId)))return json({error:'Invalid member binding'},400);
    if(body.memberId){const member=await db.from('redirect_workspace_members').select('id').eq('id',body.memberId).eq('active',true).maybeSingle();if(member.error)return rpcError(member.error);if(!member.data)return json({error:'Active workspace member required'},400);}
    const secret=createRedirectToken();
    const {data,error}=await db.from('redirect_api_tokens').insert({name:body.name.trim(),token_hash:await tokenDigest(secret),prefix:secret.slice(0,20),scopes:[...new Set(scopes)],redirect_ids:ids,member_id:body.memberId??null,created_by:user!.id,expires_at:new Date(end).toISOString()}).select(select).single();
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
