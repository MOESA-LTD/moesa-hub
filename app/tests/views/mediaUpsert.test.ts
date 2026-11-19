import '../setup/mockMain';
import en from '@/plugins/i18n/locales/en/index.json';
import MediaUpsert from '@/views/pages/ops/media/Upsert.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { beforeAll, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, ref, Suspense } from 'vue';

// The form itself is useUpsertForm (a stand-in here); the dialog shows the file and its texts.
const api = vi.hoisted(() => ({ options: undefined as unknown }));

vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('@/composables/useUpsertForm', () => ({
   useUpsertForm: (options: unknown) => {
      api.options = options;
      return {
         values: ref({ id: 'm1', title: '', alt_text: '', tags: [] }),
         errors: ref({}),
         isDirty: ref(false),
         isSubmitting: ref(false),
         readonly: ref(false),
         reset: vi.fn(),
         save: vi.fn(),
         ready: Promise.resolve(),
         draft: {},
         row: ref({
            id: 'm1',
            file_name: 'front.png',
            mime_type: 'image/png',
            storage_path: 't1/m1/front.png',
            thumbnail_path: null
         })
      };
   }
}));
vi.mock('@/api/media/signedUrls', async () => {
   const { computed } = await import('vue');
   return { useSignedUrl: () => computed(() => undefined) };
});

const Slot = defineComponent({
   setup:
      (_, { slots }) =>
      () =>
         h('div', slots.default?.({}))
});
const mountUpsert = async () => {
   const wrapper = mount(
      defineComponent({
         render: () => h(Suspense, null, { default: () => h(MediaUpsert, { id: 'm1' }) })
      }),
      {
         global: {
            plugins: [i18NPlugin, PrimeVue],
            directives: { focustrap: {} },
            stubs: { FormBox: Slot, FormField: Slot, AutoComplete: true }
         }
      }
   );
   await flushPromises();
   return wrapper;
};

describe('media edit dialog', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));

   it('shows the file it describes and edits its media row', async () => {
      const wrapper = await mountUpsert();

      expect(wrapper.get('[data-file-name]').text()).toBe('front.png');
      expect(api.options).toMatchObject({ subject: 'media' });
   });
});
