import { variantCounts } from '@/api/product/variants';
import { describe, expect, it, vi } from 'vitest';

vi.mock('@/lib/supabase', () => ({ supabase: {} }));

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
