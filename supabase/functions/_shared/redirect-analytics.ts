import {UUID} from './redirect-api.ts';
export function analyticsFilters(input:unknown):Record<string,unknown> {
 if(!input||typeof input!=='object'||Array.isArray(input))throw new Error('Invalid analytics filters');
 const value=input as Record<string,unknown>,allowed=['linkIds','folderId','tagId','start','end','event','country','city','device','browser','os','domain','referrer','variant','excludeBots','qr','interval'];
 if(Object.keys(value).some(key=>!allowed.includes(key)))throw new Error('Unknown analytics filter');
 for(const key of ['folderId','tagId'])if(value[key]!==undefined&&(typeof value[key]!=='string'||!UUID.test(value[key] as string)))throw new Error('Invalid '+key);
 if(value.linkIds!==undefined&&(!Array.isArray(value.linkIds)||value.linkIds.length>1000||value.linkIds.some(id=>typeof id!=='string'||!UUID.test(id))))throw new Error('Invalid link IDs');
 for(const key of ['start','end'])if(value[key]!==undefined&&(typeof value[key]!=='string'||!Number.isFinite(Date.parse(value[key] as string))))throw new Error('Invalid '+key+' date');
 if(value.start&&value.end&&Date.parse(value.start as string)>=Date.parse(value.end as string))throw new Error('Start must precede end');
 for(const key of ['excludeBots','qr'])if(value[key]!==undefined&&typeof value[key]!=='boolean')throw new Error('Invalid '+key);
 for(const key of ['country','city','device','browser','os','domain','referrer','variant'])if(value[key]!==undefined&&(typeof value[key]!=='string'||!(value[key] as string).length||(value[key] as string).length>253))throw new Error('Invalid '+key);
 if(value.event!==undefined&&!['all','click','lead','sale'].includes(value.event as string))throw new Error('Invalid event');
 if(value.interval!==undefined&&!['hour','day','week','month'].includes(value.interval as string))throw new Error('Invalid interval');
 return value;
}
