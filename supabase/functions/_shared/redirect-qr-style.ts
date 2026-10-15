import { UUID } from './redirect-api.ts';
export function qrStylePreferenceInput(value: unknown) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Provide QR style fields');
  const data = value as Record<string, unknown>;
  if (Object.keys(data).some(key => !['version','style','logoMode','clearLogo'].includes(key)) || !Object.hasOwn(data,'version') || data.version !== null && (typeof data.version !== 'string' || !UUID.test(data.version)) || !['style','logoMode','clearLogo'].some(key=>Object.hasOwn(data,key))) throw new Error('Provide the current QR style version and overrides');
  if(data.logoMode!==undefined&&!['inherit','none','custom'].includes(data.logoMode as string)||data.clearLogo!==undefined&&typeof data.clearLogo!=='boolean')throw new Error('Invalid logo preference');
  const result={version:data.version,...(data.logoMode!==undefined?{logoMode:data.logoMode}:{}),...(data.clearLogo!==undefined?{clearLogo:data.clearLogo}:{})};
  if(!Object.hasOwn(data,'style'))return result;
  if (data.style === null) return {...result,style:null};
  if (!data.style || typeof data.style !== 'object' || Array.isArray(data.style)) throw new Error('Provide appearance overrides or null to reset');
  const style = data.style as Record<string,unknown>;
  for (const [key,value] of Object.entries(style)) {
    if (!['dots','border','center','foreground','background'].includes(key)) throw new Error('Unknown QR appearance field');
    if (value === null) continue;
    if (typeof value !== 'string' || (key==='dots'?!['square','circle','joined'].includes(value):key==='border'?!['square','rounded','circle'].includes(value):key==='center'?!['square','circle'].includes(value):!/^#[a-f0-9]{6}$/i.test(value))) throw new Error('Invalid QR appearance value');
  }
  return {...result,style};
}
