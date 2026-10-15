import { linkInput } from './redirect-links.ts';
export const MANUAL_REDIRECT_FIELDS=['type','slug','source_path','match_kind','target','status_code','is_enabled','start_at','end_at','query_mode','query_override','utm_defaults','click_limit','notes','domain_id','is_domain_root'];
const MANUAL_MAP:Record<string,string>={slug:'slug',target:'target',status_code:'statusCode',is_enabled:'isEnabled',start_at:'startsAt',end_at:'expiresAt',query_mode:'queryMode',query_override:'queryOverride',utm_defaults:'utmDefaults',click_limit:'clickLimit',notes:'notes',domain_id:'domainId',is_domain_root:'isDomainRoot'};
export function manualRedirectInput(value:unknown,create:boolean){
 if(!value||typeof value!=='object'||Array.isArray(value))throw new Error('Provide redirect fields');
 const values=value as Record<string,unknown>;
 if(!Object.keys(values).length||Object.keys(values).some(key=>!MANUAL_REDIRECT_FIELDS.includes(key)))throw new Error('Unknown or empty redirect fields');
 if(create && !['SHORT','PATH'].includes(values.type as string)||values.type!==undefined&&!['SHORT','PATH'].includes(values.type as string))throw new Error('Choose a redirect type');
 if(values.match_kind!==undefined&&!['EXACT','WILDCARD','REGEX'].includes(values.match_kind as string))throw new Error('Invalid path match kind');
 if(values.source_path!==undefined&&values.source_path!==null&&(typeof values.source_path!=='string'||!values.source_path.startsWith('/')||values.source_path.startsWith('//')||values.source_path.includes('..')||values.source_path.length>8192))throw new Error('Choose a valid source path starting with /');
 if(values.type==='PATH'&&create&&!values.source_path)throw new Error('A source path is required');
 const shared:Record<string,unknown>={};
 for(const[key,field]of Object.entries(MANUAL_MAP))if(values[key]!==undefined&&!(key==='slug'&&values[key]===null))shared[field]=values[key];
 const checked=create||Object.keys(shared).length?linkInput(shared,create?'create':'update'):{};
 if(create&&values.type==='SHORT'&&!checked.slug&&!checked.isDomainRoot)throw new Error('A slug is required');
 const result={...values};for(const[key,field]of Object.entries(MANUAL_MAP))if(Object.hasOwn(checked,field))result[key]=checked[field];
 if(values.type==='PATH'){if(values.domain_id!=null)throw new Error('Path redirects cannot use a short-link domain');result.slug=null;result.domain_id=null;result.is_domain_root=false;}
 return result;
}
