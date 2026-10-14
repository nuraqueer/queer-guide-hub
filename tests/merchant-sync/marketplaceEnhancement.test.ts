import { describe, expect, it } from 'vitest';
import { descriptionResponseFormat, parseMarketplaceEnhancement } from '../../supabase/functions/_shared/marketplace-enhancement.ts';

describe('marketplace description output', () => {
  it('extracts fenced output without consuming surrounding prose braces', () => {
    expect(parseMarketplaceEnhancement('```json\n{"description":"A cotton shirt with a printed rainbow.","source_lang":"en"}\n```\n{done}').description).toContain('cotton shirt');
  });
  it('escapes literal line breaks without changing description content', () => {
    expect(parseMarketplaceEnhancement('{"description":"A cotton shirt\nwith a printed rainbow.","source_lang":"de"}').description).toContain('\n');
  });
  it.each([
    '{"description":{"invented":"copy"},"source_lang":"en"}',
    '{"description":"A cotton shirt with a printed rainbow.","source_lang":"unknown"}',
    '{"description":"A cotton shirt with "unescaped" quotes.","source_lang":"en"}',
  ])('rejects invalid copy without coercion', raw => {
    expect(() => parseMarketplaceEnhancement(raw)).toThrow('Invalid marketplace');
  });
  it('requests the native schema only on a supported model', () => {
    expect(descriptionResponseFormat('@cf/meta/llama-3.1-8b-instruct-fast')?.json_schema.required).toEqual(['description', 'source_lang']);
    expect(descriptionResponseFormat('@cf/custom/model')).toBeUndefined();
  });
});
