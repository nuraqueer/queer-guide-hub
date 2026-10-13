import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2.50.5";
import { boundedJson, conversionInput, createRedirectToken, tokenDigest, UUID } from "../_shared/redirect-api.ts";

Deno.serve(async (req: Request) => {
 const origin=req.headers.get('origin') ?? '';
 const cors={ 'Access-Control-Allow-Origin':['https://queer.guide','https://www.queer.guide','http://localhost:5173','http://localhost:4178'].includes(origin)?origin:'', 'Access-Control-Allow-Headers':'authorization, apikey, x-client-info, content-type', 'Access-Control-Allow-Methods':'GET, POST, DELETE, OPTIONS', Vary:'Origin' };
 const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store'}});
 const rpcError=(error:{code?:string;message:string})=>{const status=error.code==='23505'?409:error.code==='42501'?403:error.code==='P0002'?404:error.code?.startsWith('22')?400:503;return json({error:status===503?'Conversion recording unavailable':error.message},status);};
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
    if(!body || typeof body!=='object' || Object.keys(body).some(key=>!['name','expiresAt','redirectIds'].includes(key)) || typeof body.name!=='string' || !body.name.trim() || body.name.length>100)return json({error:'Provide a credential name (1–100 characters)'},400);
    const end=typeof body.expiresAt==='string'?Date.parse(body.expiresAt):NaN;
    if(!Number.isFinite(end) || end<=Date.now() || end>Date.now()+366*86400000)return json({error:'Credentials must expire within one year'},400);
    if(body.redirectIds!==undefined && (!Array.isArray(body.redirectIds) || body.redirectIds.length<1 || body.redirectIds.length>100 || body.redirectIds.some((id:unknown)=>typeof id!=='string' || !UUID.test(id))))return json({error:'Invalid link scope'},400);
    const ids=body.redirectIds? [...new Set(body.redirectIds)] : null;
    if(ids){const {data,error}=await db.from('redirects').select('id').in('id',ids).eq('type','SHORT');if(error || data?.length!==ids.length)return json({error:'One or more managed links were not found'},400);}
    const secret=createRedirectToken();
    const {data,error}=await db.from('redirect_api_tokens').insert({name:body.name.trim(),token_hash:await tokenDigest(secret),prefix:secret.slice(0,20),scopes:['conversions:write'],redirect_ids:ids,created_by:user!.id,expires_at:new Date(end).toISOString()}).select(select).single();
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
