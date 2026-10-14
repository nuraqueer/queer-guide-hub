import { contentKind } from '@/components/cms/fields/structured/structuredValue';
import type { ComponentType } from 'react';
import type { FieldType } from '@/types/cms';
import { TextEditor } from './TextEditor';
import { TextareaEditor } from './TextareaEditor';
import { SelectEditor } from './SelectEditor';
import { BooleanEditor } from './BooleanEditor';
import { TagsEditor } from './TagsEditor';
import { StructuredEditor } from './StructuredEditor';
import { ImageEditor } from './ImageEditor';
import { ImageArrayEditor } from './ImageArrayEditor';
import { RichTextInlineEditor } from './RichTextInlineEditor';
import { LinkListEditor } from './LinkListEditor';
import type { EditorProps } from './types';

const REGISTRY: Partial<Record<FieldType, ComponentType<EditorProps>>> = {
  text: TextEditor,
  url: TextEditor,
  email: TextEditor,
  phone: TextEditor,
  number: TextEditor,
  date: TextEditor,
  datetime: TextEditor,
  textarea: TextareaEditor,
  select: SelectEditor,
  boolean: BooleanEditor,
  tags: TagsEditor,
  json: StructuredEditor,
  image: ImageEditor,
  images: ImageArrayEditor,
  richtext: RichTextInlineEditor,
  link_list: LinkListEditor,
};

export function getEditorForFieldType(
  type: FieldType,
  value?: unknown,
): ComponentType<EditorProps> | null {
  if (['text', 'textarea', 'richtext', 'json'].includes(type)) {
    const kind = contentKind(value);
    if (kind === 'structured' || kind === 'unreadable') return StructuredEditor;
    if (kind === 'richtext') return RichTextInlineEditor;
  }
  return REGISTRY[type] ?? null;
}

export type { EditorProps };
