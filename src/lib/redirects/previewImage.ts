import { previewImageInfo } from '../../../supabase/functions/_shared/redirect-presentation';
export async function preparePreviewImage(file: File): Promise<string> {
  if (file.size > 1500000) throw new Error('Preview image must be no larger than 1.5 MB');
  const original = new Uint8Array(await file.arrayBuffer());
  previewImageInfo(original);
  const bitmap = await createImageBitmap(file);
  try {
    const canvas = document.createElement('canvas');
    canvas.width = 1200;
    canvas.height = 630;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('Image editing is unavailable');
    // Artwork is composited onto white paper, independently of the admin UI theme.
    context.fillStyle = 'white';
    context.fillRect(0, 0, 1200, 630);
    const scale = Math.max(1200 / bitmap.width, 630 / bitmap.height);
    context.drawImage(
      bitmap,
      (1200 - bitmap.width * scale) / 2,
      (630 - bitmap.height * scale) / 2,
      bitmap.width * scale,
      bitmap.height * scale,
    );
    const encoded = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, 'image/jpeg', 0.9),
    );
    if (!encoded) throw new Error('Could not prepare preview artwork');
    const bytes = new Uint8Array(await encoded.arrayBuffer());
    previewImageInfo(bytes);
    let text = '';
    for (let i = 0; i < bytes.length; i += 8192)
      text += String.fromCharCode(...bytes.subarray(i, i + 8192));
    return btoa(text);
  } finally {
    bitmap.close();
  }
}
