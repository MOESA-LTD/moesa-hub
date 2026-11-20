import '../setup/mockMain';
import Upsert from '@/views/pages/ops/document/Upsert.vue';
import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, ref, Suspense } from 'vue';

// A new document's dialog closes once it is saved; editing a saved one keeps it open.
const state = vi.hoisted(() => ({ onSaved: null as null | ((row: unknown) => void) }));

vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('@/composables/useFieldAccess', () => ({ provideFieldAccess: () => {} }));
vi.mock('@/composables/useUpsertForm', async () => {
   const { ref } = await import('vue');
   return {
      useUpsertForm: (options: { onSaved: (row: unknown) => void }) => {
         state.onSaved = options.onSaved;
         return {
            values: ref({}),
            errors: ref({}),
            isDirty: ref(false),
            isSubmitting: ref(false),
            readonly: ref(false),
            reset: () => {},
            save: () => {},
            ready: Promise.resolve(),
            draft: { restored: false, stale: false }
         };
      }
   };
});

const close = vi.fn();
const mountDialog = async (props: Record<string, unknown>) => {
   mount(
      defineComponent({
         render: () => h(Suspense, null, { default: () => h(Upsert, props) })
      }),
      {
         global: {
            provide: { dialogRef: ref({ close }) },
            stubs: { FormBox: true, FormField: true, DocumentFileField: true },
            mocks: { $t: (key: string) => key }
         }
      }
   );
   await flushPromises();
};

describe('document dialog', () => {
   beforeEach(() => close.mockClear());

   it('closes once a new document is saved', async () => {
      await mountDialog({ entity_type: 'product', entity_id: 'p1', code: 'OKA-REC' });
      state.onSaved?.({ id: 'd1' });
      expect(close).toHaveBeenCalledOnce();
   });

   it('stays open after saving a document that was already saved', async () => {
      await mountDialog({ id: 'd1' });
      state.onSaved?.({ id: 'd1' });
      expect(close).not.toHaveBeenCalled();
   });
});
