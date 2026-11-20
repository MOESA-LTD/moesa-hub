import { fetchVariantCounts, VARIANT_PAGE_SIZE, variantCounts } from '@/api/product/variants';
import { beforeEach, describe, expect, it, vi } from 'vitest';

// Every range() call; throwOnError resolves with the next page.
const ranges: [number, number][] = [];
let pages: { parent_id: string }[][] = [];
const builder: object = new Proxy(
   {},
   {
      get: (_, method: string) =>
         method === 'then'
            ? undefined
            : (...args: unknown[]) => {
                 if (method === 'range') ranges.push(args as [number, number]);
                 return method === 'throwOnError'
                    ? Promise.resolve({ data: pages.shift() ?? [], error: null })
                    : builder;
              }
   }
);

vi.mock('@/lib/supabase', () => ({ supabase: { from: () => builder } }));

const page = (parent: string, size: number) =>
   Array.from({ length: size }, () => ({ parent_id: parent }));

describe('variantCounts', () => {
   it("counts each parent's variants and leaves out products without a parent", () => {
      const counts = variantCounts([
         { parent_id: 'rec' },
         { parent_id: 'rec' },
         { parent_id: 'we' },
         { parent_id: null }
      ]);
      expect([...counts]).toEqual([
         ['rec', 2],
         ['we', 1]
      ]);
   });
});

describe('fetchVariantCounts', () => {
   beforeEach(() => {
      ranges.length = 0;
   });

   it('reads past the API row cap, page by page', async () => {
      pages = [page('a', VARIANT_PAGE_SIZE), page('b', 3)];
      const counts = await fetchVariantCounts(new AbortController().signal);
      expect(counts.get('a')).toBe(VARIANT_PAGE_SIZE);
      expect(counts.get('b')).toBe(3);
      expect(ranges).toEqual([
         [0, VARIANT_PAGE_SIZE - 1],
         [VARIANT_PAGE_SIZE, 2 * VARIANT_PAGE_SIZE - 1]
      ]);
   });

   it('stops after a short first page', async () => {
      pages = [page('a', 2)];
      const counts = await fetchVariantCounts(new AbortController().signal);
      expect(counts.get('a')).toBe(2);
      expect(ranges).toHaveLength(1);
   });
});
