export function socialPreviewAgent(agent: string) {
 return /facebookexternalhit|Facebot|Twitterbot|LinkedInBot|Slackbot|Discordbot|WhatsApp|TelegramBot|Pinterestbot/i.test(agent.slice(0,512));
}
const presentationEscape=(value:string)=>value.replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]!));
export function presentationPage(preview: {title?:string;description?:string;image?:string;video?:string}|undefined, shortUrl:string, target:string, cloaked:boolean, head=false) {
 const esc=presentationEscape,title=preview?.title||'Open link · queer.guide';
 const tags='<meta property="og:type" content="'+(preview?.video?'video.other':'website')+'"><meta property="og:url" content="'+esc(shortUrl)+'"><meta property="og:title" content="'+esc(title)+'"><meta name="twitter:card" content="summary_large_image">'+(preview?.description?'<meta property="og:description" content="'+esc(preview.description)+'"><meta name="description" content="'+esc(preview.description)+'">':'')+(preview?.image?'<meta property="og:image" content="'+esc(preview.image)+'">':'')+(preview?.video?'<meta property="og:video" content="'+esc(preview.video)+'"><meta property="og:video:secure_url" content="'+esc(preview.video)+'">':'');
 const body=cloaked?'<header><span>This site may block framed pages.</span> <a href="'+esc(target)+'" target="_top" rel="noreferrer">Open destination directly</a></header><iframe title="Link destination" src="'+esc(target)+'" sandbox="allow-scripts allow-forms allow-same-origin allow-popups allow-popups-to-escape-sandbox" referrerpolicy="no-referrer"></iframe>':'<main><h1>'+esc(title)+'</h1><p>'+(preview?.description?esc(preview.description):'Open this link to continue.')+'</p><a href="'+esc(shortUrl)+'">Open link</a></main>';
 const html='<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+esc(title)+'</title>'+tags+'<style>body{margin:0;font:16px system-ui;background:#fafaf5;color:#111}header{padding:1rem;display:flex;gap:1rem;flex-wrap:wrap}iframe{border:0;width:100%;height:calc(100dvh - 5rem)}main{padding:2rem;max-width:40rem}a{color:inherit;text-decoration:underline}</style></head><body>'+body+'</body></html>';
 return new Response(head?null:html,{status:200,headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','X-Robots-Tag':'noindex','Referrer-Policy':'no-referrer','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; frame-src "+(cloaked?new URL(target).origin:"'none'")}});
}
export function previewImageInfo(bytes: Uint8Array) {
 if(!bytes.length||bytes.length>1500000)throw new Error('Preview image must be no larger than 1.5 MB');
 const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
 let width=0,height=0,mime='',extension='';
 if(bytes.length>=33&&[137,80,78,71,13,10,26,10].every((n,i)=>bytes[i]===n)&&view.getUint32(8)===13&&String.fromCharCode(...bytes.slice(12,16))==='IHDR') {width=view.getUint32(16);height=view.getUint32(20);mime='image/png';extension='png';}
 else if(bytes.length>4&&bytes[0]===255&&bytes[1]===216&&bytes[bytes.length-2]===255&&bytes[bytes.length-1]===217) {
  let offset=2;
  while(offset+4<bytes.length){if(bytes[offset]!==255)break;while(bytes[offset]===255)offset++;const marker=bytes[offset++];if(marker===217||marker===218)break;if(marker===1||marker>=208&&marker<=215)continue;const size=view.getUint16(offset);if(size<2||offset+size>bytes.length)break;if([192,193,194,195,197,198,199,201,202,203,205,206,207].includes(marker)&&size>=8){height=view.getUint16(offset+3);width=view.getUint16(offset+5);mime='image/jpeg';extension='jpg';break;}offset+=size;}
 }
 if(!mime||!width||!height||width>4096||height>4096)throw new Error('Use a PNG or JPG image with dimensions no larger than 4096 × 4096');
 return {width,height,mime,extension};
}
