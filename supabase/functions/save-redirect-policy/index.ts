import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2.50.5";
import { hashLinkPassword, policyErrors, type LinkPolicy } from "../_shared/link-policy.ts";

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin") ?? "";
  const cors = {
    "Access-Control-Allow-Origin": ["https://queer.guide","https://www.queer.guide","http://localhost:5173","http://localhost:4178"].includes(origin) ? origin : "",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
  const json = (body: unknown, status=200) => new Response(JSON.stringify(body), {status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});
  if (req.method === "OPTIONS") return new Response(null,{headers:cors});
  if (req.method !== "POST") return json({error:"Method not allowed"},405);
  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({error:"Unauthorized"},401);
  const url = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const user = createClient(url,anon,{global:{headers:{Authorization:authorization}}});
  const { data: identity, error: authError } = await user.auth.getUser(authorization.replace(/^Bearer /i,""));
  if (authError || !identity.user) return json({error:"Unauthorized"},401);
  const { data: admin, error: roleError } = await user.rpc("has_role_jwt",{required_role:"admin"});
  if (roleError || !admin) return json({error:"Forbidden"},403);
  try {
    const body = await req.json() as {redirect_id:string;policy:LinkPolicy;password?:string;remove_password?:boolean};
    if (!/^[a-f0-9-]{36}$/i.test(body.redirect_id ?? "")) return json({error:"Invalid redirect ID"},400);
    const errors = policyErrors(body.policy);
    if (errors.length) return json({error:errors.join("; ")},400);
    const changePassword = body.remove_password === true || typeof body.password === "string";
    const db = createClient(url,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{global:{headers:{"x-qg-redirect-session-actor":identity.user.id}}});
    if (typeof body.password === "string") {
      const reserved = await db.rpc("reserve_redirect_policy_password",{p_redirect_id:body.redirect_id,p_actor_id:identity.user.id});
      if (reserved.error) return json({error:reserved.error.message},reserved.error.code === "42501" ? 403 : 400);
      if (reserved.data) return new Response(JSON.stringify({error:"Password update limit reached"}),{status:429,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store","Retry-After":String(reserved.data)}});
    }
    const passwordHash = typeof body.password === "string" ? await hashLinkPassword(body.password) : null;
    const {data,error} = await db.rpc("set_redirect_link_policy",{p_redirect_id:body.redirect_id,p_policy:body.policy,p_password_hash:passwordHash,p_change_password:changePassword});
    if (error) return json({error:error.message},error.code === "42501" ? 403 : 400);
    return json(data);
  } catch (error) { return json({error:error instanceof Error ? error.message : "Invalid policy"},400); }
});
