import '../setup/mockMain';
import { useUpsertForm } from '@/composables/useUpsertForm';
import { ability } from '@/plugins/casl';
import { mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import ConfirmationService from 'primevue/confirmationservice';
import ToastService from 'primevue/toastservice';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, ref } from 'vue';
import * as z from 'zod';

// Which draft a form keeps its unsaved edits in. A new row's draft belongs to what the form was
// opened for (its prefill): a new document abandoned on one product must not come back in the new
// document form of another record, carrying the first record's link.
const drafts = vi.hoisted(() => ({ forms: [] as string[] }));

vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ query: {} }),
   useRouter: () => ({ push: vi.fn() }),
   onBeforeRouteLeave: () => {}
}));
vi.mock('@/store/auth', () => ({
   useAuthStore: () => ({
      currentTenant: { id: 'tho' },
      scopeTenants: [{ id: 'tho' }],
      canIn: () => true
   })
}));
vi.mock('@/composables/useFormDraft', async () => {
   const { ref } = await import('vue');
   return {
      useFormDraft: ({ form }: { form: string }) => {
         drafts.forms.push(form);
         return { restored: ref(false), stale: ref(false), apply: () => {}, discard: () => {} };
      }
   };
});

type Row = { id: string; entity_type: string; entity_id: string; notes: string };

const draftOf = (id: string | null, prefill?: Partial<Row>) => {
   drafts.forms = [];
   mount(
      defineComponent({
         setup() {
            useUpsertForm({
               id,
               prefill,
               useRow: () => ({ data: ref(null), suspense: () => Promise.resolve() }) as never,
               useSaveRow: () => ({ mutateAsync: vi.fn() }) as never,
               subject: 'document',
               schema: z.object({ entity_id: z.string(), notes: z.string() }),
               toFormValues: (value) => ({
                  entity_id: (value as Partial<Row> | null)?.entity_id ?? '',
                  notes: ''
               }),
               toPayload: (data) => data as unknown as Row
            });
            return () => h('div');
         }
      }),
      { global: { plugins: [PrimeVue, ConfirmationService, ToastService] } }
   );
   return drafts.forms[0];
};

describe('useUpsertForm drafts', () => {
   beforeEach(() => ability.update([{ action: 'manage', subject: 'all' }]));

   it("keeps a saved row's draft under the row", () => {
      expect(draftOf('d1')).toBe('document:d1');
   });

   it('keeps a new row opened for different records in different drafts', () => {
      const product = draftOf(null, { entity_type: 'product', entity_id: 'p1' });
      const project = draftOf(null, { entity_type: 'project', entity_id: 'j1' });
      expect(product).not.toBe(project);
      expect(draftOf(null, { entity_id: 'p1', entity_type: 'product' })).toBe(product);
      expect(draftOf(null)).toBe('document:new');
   });

   it("finds a new row's draft again after a reload although a prefilled date moved on", () => {
      expect(
         draftOf(null, { entity_id: 'p1', happened_at: '2026-11-20T10:00:00.000Z' } as never)
      ).toBe(draftOf(null, { entity_id: 'p1', happened_at: '2026-11-20T10:00:05.000Z' } as never));
      expect(draftOf(null, { notes: 'x' })).toBe('document:new');
   });
});
