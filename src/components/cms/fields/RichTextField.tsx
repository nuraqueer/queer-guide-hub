import { useCallback, lazy, Suspense } from 'react';
import { FieldWrapper } from './FieldWrapper';
import { RenderedContent } from './RenderedContent';
import { normalizeStructured, isRichTextDocument } from './structured/structuredValue';
import type { FieldProps } from './FieldRenderer';

/**
 * Rich text editor field for the 'richtext' type.
 * Lazy-loads the RichTextEditor from the CMS editor module.
 * Value can be stored as HTML string or JSON (TipTap/ProseMirror doc).
 * Shows a formatted preview while the editor loads.
 */

const RichTextEditor = lazy(() =>
  // Named export only. A `?? mod.default` fallback collapses the inferred
  // component type to `any`, which is what previously hid the prop mismatches
  // below from tsc.
  import('@/components/cms/editor/RichTextEditor').then((mod) => ({
    default: mod.RichTextEditor,
  })),
);

export function RichTextField({ field, value, onChange, error, disabled }: FieldProps) {
  const normalized = normalizeStructured(value);
  const editorValue =
    typeof normalized === 'string' || isRichTextDocument(normalized) ? normalized : '';

  // Text columns store HTML; JSON columns keep the rich-text document object.
  const handleEditorChange = useCallback(
    (_json: Record<string, unknown>, html: string) => {
      onChange(field.type === 'json' ? _json : html);
    },
    [onChange, field.type],
  );

  return (
    <FieldWrapper field={field} error={error}>
      <Suspense
        fallback={
          <div aria-busy="true" className="min-h-48 rounded-element bg-card p-4">
            <RenderedContent value={editorValue} />
            <p role="status" className="mt-4 text-13 text-muted-foreground">
              Loading editor…
            </p>
          </div>
        }
      >
        <RichTextEditor
          value={editorValue}
          onChange={handleEditorChange}
          editable={!disabled}
          placeholder={field.placeholder}
        />
      </Suspense>
    </FieldWrapper>
  );
}
