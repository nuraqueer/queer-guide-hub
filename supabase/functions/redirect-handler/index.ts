import { DOMAIN_HEALTH_PATH, hasDomainRelay, verifyDomainRelay } from "../_shared/redirect-domain-relay.ts";
import { socialPreviewAgent, presentationPage } from "../_shared/redirect-presentation.ts";
import { redirectClientIp } from "../_shared/redirect-relay.ts";
import { visitorMetadata } from "../_shared/redirect-visitor.ts";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2.50.5";
import { chooseLinkTarget, deviceFromAgent, policyErrors, validPublicTarget, verifyLinkPassword, type LinkPolicy, type PasswordHash } from "../_shared/link-policy.ts";

const responseHeaders = {"Cache-Control":"no-cache, no-store","X-Robots-Tag":"noindex","Referrer-Policy":"no-referrer"};
const escapeHtml = (value: string) => value.replace(/[&<>"']/g, (letter) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[letter]!));
function page(status: number, title: string, message: string, password = false, head = false): Response {
  const form = password ? '<form method="post"><label for="password">Link password</label><input id="password" name="password" type="password" maxlength="256" autocomplete="current-password" required><button type="submit">Continue</button></form>' : '';
  const html = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+escapeHtml(title)+' · queer.guide</title><style>body{font:16px system-ui;margin:0;background:#fafaf5;color:#111;display:grid;min-height:100vh;place-items:center}main{max-width:32rem;padding:2rem}input,button{display:block;margin:1rem 0;padding:.8rem;font:inherit}button{cursor:pointer}p{line-height:1.5}</style></head><body><main><h1>'+escapeHtml(title)+'</h1><p>'+escapeHtml(message)+'</p>'+form+'</main></body></html>';
  return new Response(head ? null : html,{status,headers:{...responseHeaders,"Content-Type":"text/html; charset=utf-8","Content-Security-Policy":"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"}});
}
function mergeQuery(target: string, mode: string, incoming: URLSearchParams, overrides: Record<string,string> | null, defaults: Record<string,string> | null) {
  const parsed=new URL(target,"https://queer.guide");
  if (mode !== "DROP") {
    if (mode === "OVERRIDE") for (const [key,value] of Object.entries(overrides ?? {})) parsed.searchParams.set(key,value);
    for (const [key,value] of incoming) if (!parsed.searchParams.has(key)) parsed.searchParams.set(key,value);
    for (const [key,value] of Object.entries(defaults ?? {})) if (!parsed.searchParams.has(key)) parsed.searchParams.set(key,value);
  }
  return parsed.href;
}
async function postedPassword(req: Request) {
  if (!req.body || !req.headers.get("content-type")?.startsWith("application/x-www-form-urlencoded")) return "";
  const reader=req.body.getReader(); let total=0; const chunks:Uint8Array[]=[];
  for (;;) {const {done,value}=await reader.read();if(done)break;total+=value.length;if(total>4096){await reader.cancel();throw new Error("Password form is too large");}chunks.push(value);}
  const body=new Uint8Array(total);let offset=0;for(const chunk of chunks){body.set(chunk,offset);offset+=chunk.length;}
  return new URLSearchParams(new TextDecoder().decode(body)).get("password") ?? "";
}
function cleanReferrer(value: string | null) {
  if (!value) return null;
  try {const url=new URL(value);url.searchParams.delete("pw");url.searchParams.delete("password");return url.href;}catch{return null;}
}

Deno.serve(async (req: Request) => {
  const head=req.method === "HEAD";
  if (!["GET","HEAD","POST"].includes(req.method)) return new Response("Method not allowed",{status:405,headers:{...responseHeaders,Allow:"GET, HEAD, POST"}});
  const url=new URL(req.url), slug=url.searchParams.get("slug")?.toLowerCase().trim() ?? "";
  const branded=hasDomainRelay(req.headers);
  const relay=branded ? await verifyDomainRelay(req,Deno.env.get("REDIRECT_RELAY_SECRET")) : null;
  if (branded && !relay) return page(404,"Link not found","This short link does not exist.",false,head);
  const validSlug=/^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$/.test(slug);
  if (!branded && !validSlug) return page(404,"Link not found","This short link does not exist.",false,head);
  const incoming=new URLSearchParams(url.searchParams.get("q") ?? "");
  let password=url.searchParams.get("pw") ?? incoming.get("pw") ?? "";
  const isQr=incoming.get("qg_qr") === "1";
  incoming.delete("qg_qr");incoming.delete("pw");incoming.delete("password");incoming.delete("qg_click_id");
  if (incoming.toString().length>8192) return page(400,"Invalid link","The query string is too long.",false,head);
  try {
    if (req.method === "POST") password=await postedPassword(req);
    const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    let domain: {id:string;hostname:string;rootUrl:string|null;notFoundUrl:string|null;expiredUrl:string|null;needsRouteRefresh?:boolean}|null=null;
    if (relay) {
      const {data,error}=await db.rpc("redirect_public_domain",{p_hostname:relay.hostname});
      if(error)return page(503,"Link unavailable","Please try again shortly.",false,head);
      if(!data)return page(404,"Link not found","This domain is unavailable.",false,head);
      domain=data;
      if(data.needsRouteRefresh && relay.path!==DOMAIN_HEALTH_PATH) {
        const {data:refreshed,error:refreshError}=await db.rpc("record_redirect_domain_route",{p_hostname:relay.hostname});
        if(refreshError || refreshed!==true)return page(503,"Link unavailable","Please try again shortly.",false,head);
      }
      if(relay.path===DOMAIN_HEALTH_PATH) {
        if(req.method!=="GET")return new Response(null,{status:405,headers:{...responseHeaders,Allow:"GET"}});
        const {data:recorded,error:recordError}=await db.rpc("record_redirect_domain_route",{p_hostname:relay.hostname});
        return new Response(JSON.stringify({ready:!recordError&&recorded===true,protocol:1}),{status:!recordError&&recorded===true?200:503,headers:{...responseHeaders,"Content-Type":"application/json"}});
      }
    }
    const fallback=async(target:string|null|undefined) => {
      if(!target || !validPublicTarget(target))return null;
      const parsed=new URL(target,"https://queer.guide");
      const {data:managed,error}=await db.from("redirect_domains").select("id").eq("hostname",parsed.hostname).maybeSingle();
      if(error || managed?.id || ["queer.guide","www.queer.guide"].includes(parsed.hostname)&&parsed.pathname.startsWith("/go/"))return null;
      return new Response(null,{status:302,headers:{...responseHeaders,Location:parsed.href}});
    };
    const rootRequest=!!domain && relay?.path==="/";
    if(!rootRequest&&!validSlug)return await fallback(domain?.notFoundUrl) ?? page(404,"Link not found","This short link does not exist.",false,head);
    const baseQuery=db.from("redirects").select("*").eq("type","SHORT").eq("is_domain_root",rootRequest);
    const query=rootRequest ? baseQuery : baseQuery.eq("slug",slug);
    const {data:link,error:lookupError}=await (domain ? query.eq("domain_id",domain.id) : query.is("domain_id",null)).maybeSingle();
    if (lookupError) return page(503,"Link unavailable","Please try again shortly.",false,head);
    if(rootRequest&&!link)return await fallback(domain?.rootUrl) ?? page(404,"Link not found","No destination is configured for this domain.",false,head);
    if (!link || !link.is_enabled || link.start_at && Date.parse(link.start_at)>Date.now()) return await fallback(domain?.notFoundUrl) ?? page(404,"Link not found","This link is unavailable.",false,head);
    const {data:settings,error:settingsError}=await db.from("redirect_link_policies").select("policy,password_hash").eq("redirect_id",link.id).maybeSingle();
    if (settingsError) return page(503,"Link unavailable","Please try again shortly.",false,head);
    const policy:LinkPolicy={...(settings?.policy ?? {}),...(link.end_at ? {expires_at:link.end_at} : {}),...(!settings?.policy?.expired_target && domain?.expiredUrl ? {expired_target:domain.expiredUrl} : {})};
    if (policyErrors(policy).length || !validPublicTarget(link.target)) return page(503,"Link unavailable","The destination settings need attention.",false,head);
    const ip=relay?.ip ?? await redirectClientIp(req.headers,slug,Deno.env.get("REDIRECT_RELAY_SECRET"));
    const hash=new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(ip+(Deno.env.get("REDIRECT_IP_HASH_SALT") ?? "qg-redirect-salt-2026"))));
    const ipHash=Array.from(hash,(value)=>value.toString(16).padStart(2,"0")).join("");
    if (settings?.password_hash) {
      if (head || !password && req.method !== "POST") return page(401,"Protected link","Enter the password to open this link.",true,head);
      const {data:retry,error:attemptError}=await db.rpc("reserve_redirect_password_attempt",{p_redirect_id:link.id,p_client_hash:ipHash});
      if(attemptError || !Number.isInteger(retry) || retry<0 || retry>900) return page(503,"Link unavailable","Please try again shortly.",false,head);
      if(retry>0) {
        const response=page(429,"Try again later","Too many password attempts. Please wait "+Math.ceil(retry/60)+" minute(s) before trying again.");
        response.headers.set("Retry-After",String(retry));return response;
      }
      if(!await verifyLinkPassword(password,settings.password_hash as PasswordHash)) return page(401,"Protected link","That password was not accepted.",true,head);
    }
    const country=req.headers.get("x-qg-visitor-country") || req.headers.get("cf-ipcountry");
    const words=crypto.getRandomValues(new Uint32Array(1));
    let stats=[];
    if (policy.experiment && Date.parse(policy.experiment.ends_at)<=Date.now() && !policy.experiment.completed_target) {
      const {data,error}=await db.rpc("redirect_variant_performance",{p_redirect_id:link.id});
      if(error)return page(503,"Link unavailable","Please try again shortly.",false,head);
      stats=data ?? [];
    }
    const selected=chooseLinkTarget(link.target,policy,{device:deviceFromAgent(req.headers.get("user-agent") ?? ""),country,bucket:words[0]/4294967296*100},stats);
    if (selected.expired && !selected.target) return page(410,"Link expired","This link is no longer available.",false,head);
    if (!selected.target || !validPublicTarget(selected.target)) return page(503,"Link unavailable","The destination settings need attention.",false,head);
    let destination=mergeQuery(selected.target,link.query_mode,incoming,link.query_override,link.utm_defaults);
    const targetUrl=new URL(destination);
    targetUrl.searchParams.delete("qg_click_id"); destination=targetUrl.href;
    if (["queer.guide","www.queer.guide"].includes(targetUrl.hostname) && targetUrl.pathname.startsWith("/go/")) return page(508,"Link loop","This link points to another short link.",false,head);
    const {data:managedTarget,error:targetError}=await db.from("redirect_domains").select("id").eq("hostname",targetUrl.hostname).maybeSingle();
    if(targetError)return page(503,"Link unavailable","Please try again shortly.",false,head);
    if(managedTarget?.id)return page(508,"Link loop","This link points to another short link.",false,head);
    const canonical=domain ? "https://"+domain.hostname+"/"+(rootRequest ? "" : slug) : "https://queer.guide/go/"+slug;
    if(!selected.expired&&policy.preview&&socialPreviewAgent(req.headers.get("user-agent")??"")) {
      if(link.click_limit!==null&&link.click_limit!==undefined&&link.click_count>=link.click_limit)return page(410,"Link unavailable","This link has reached its visit limit.",false,head);
      return presentationPage(policy.preview,canonical,destination,false,head);
    }
    if(policy.cloaked&&!selected.expired&&!destination.startsWith("https://"))return page(503,"Link unavailable","Framed destinations require HTTPS.",false,head);
    if (!head && !selected.expired) {
      const {data:clickId,error}=await db.rpc("record_redirect_visit",{p_redirect_id:link.id,p_path:domain ? rootRequest ? "/" : "/"+slug : "/go/"+slug,p_query:incoming.toString() || null,p_referer:cleanReferrer(req.headers.get("referer")),p_user_agent:req.headers.get("user-agent"),p_country:country,p_ip_hash:ipHash,p_status:link.status_code,p_variant_id:selected.variantId,p_destination:destination,p_metadata:{...visitorMetadata(req,isQr),domain:domain?.hostname ?? "queer.guide"}});
      if(error)return page(503,"Link unavailable","Please try again shortly.",false,head);
      if(!clickId)return page(410,"Link unavailable","This link has expired or reached its visit limit.",false,head);
      if(policy.track_conversions){targetUrl.searchParams.set("qg_click_id",clickId);destination=targetUrl.href;}
    }
    if(policy.cloaked&&!selected.expired)return presentationPage(policy.preview,canonical,destination,true,head);
    return new Response(null,{status:selected.expired ? 302 : link.status_code,headers:{...responseHeaders,Location:destination}});
  } catch {return page(503,"Link unavailable","Please try again shortly.",false,head);}
});
