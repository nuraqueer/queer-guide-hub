import { lazy, Suspense } from 'react';
import { ContentSanitizer } from '@/components/security/ContentSanitizer';
import { isRichTextDocument, normalizeStructured } from './structured/structuredValue';

const RichTextEditor = lazy(() =>
  import('@/components/cms/editor/RichTextEditor').then((module) => ({
    default: module.RichTextEditor,
  })),
);

/** Formatted previews for imported HTML and rich-text documents, including loading states. */
export function RenderedContent({ value }: { value: unknown }) {
  const normalized = normalizeStructured(value);
  if (isRichTextDocument(normalized)) {
    return (
      <Suspense
        fallback={
          <p role="status" className="text-13 text-muted-foreground">
            Loading content…
          </p>
        }
      >
        <RichTextEditor value={normalized} editable={false} />
      </Suspense>
    );
  }
  return (
    <ContentSanitizer
      content={typeof normalized === 'string' ? normalized : ''}
      className="rich-text-content min-w-0 break-words text-13"
      allowedTags={[
        '#text',
        'p',
        'br',
        'strong',
        'b',
        'em',
        'i',
        'u',
        's',
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
        'ul',
        'ol',
        'li',
        'blockquote',
        'a',
        'span',
        'sup',
        'sub',
        'table',
        'thead',
        'tbody',
        'tr',
        'th',
        'td',
        'hr',
      ]}
      allowedAttrs={['href', 'title', 'colspan', 'rowspan']}
    />
  );
}
