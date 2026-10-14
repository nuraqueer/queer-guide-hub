import { UUID } from './redirect-api.ts';
export function qrStylePreferenceInput(value: unknown) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Provide QR style fields');
  const data = value as Record<string, unknown>;
  if (Object.keys(data).some(key => !['version','style'].includes(key)) || !Object.hasOwn(data,'version') || data.version !== null && (typeof data.version !== 'string' || !UUID.test(data.version)) || !Object.hasOwn(data,'style')) throw new Error('Provide the current QR style version and overrides');
  if (data.style === null) return { version:data.version,style:null };
  if (!data.style || typeof data.style !== 'object' || Array.isArray(data.style)) throw new Error('Provide appearance overrides or null to reset');
  const style = data.style as Record<string,unknown>;
  for (const [key,value] of Object.entries(style)) {
    if (!['dots','border','center','foreground','background'].includes(key)) throw new Error('Unknown QR appearance field');
    if (value === null) continue;
    if (typeof value !== 'string' || (key==='dots'?!['square','circle','joined'].includes(value):key==='border'?!['square','rounded','circle'].includes(value):key==='center'?!['square','circle'].includes(value):!/^#[a-f0-9]{6}$/i.test(value))) throw new Error('Invalid QR appearance value');
  }
  return {version:data.version,style};
}
