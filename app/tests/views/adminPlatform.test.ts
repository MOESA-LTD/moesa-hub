import '../setup/mockMain';
import en from '@/plugins/i18n/locales/en/index.json';
import Platform from '@/views/pages/admin/platform/Index.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { flushPromises, mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { ref } from 'vue';

const api = vi.hoisted(() => ({ mutate: vi.fn(), toast: vi.fn() }));
const state = vi.hoisted(() => ({ settings: null as unknown as { value: unknown } }));
state.settings = ref({ open_signup: false });

vi.mock('@/api/platformSetting', () => ({
   usePlatformSettings: () => ({ data: state.settings, isPending: ref(false) }),
   useSetPlatformSetting: () => ({ mutateAsync: api.mutate, isPending: ref(false) })
}));
vi.mock('primevue', async (importOriginal) => ({
   ...(await importOriginal<typeof import('primevue')>()),
   useToast: () => ({ add: api.toast })
}));

const mounted: { unmount: () => void }[] = [];

describe('platform settings page', () => {
   beforeAll(() => i18n.setLocaleMessage('en', en));
   afterEach(() => mounted.splice(0).forEach((wrapper) => wrapper.unmount()));
   beforeEach(() => {
      api.mutate.mockReset().mockResolvedValue({ open_signup: true });
      api.toast.mockReset();
      state.settings.value = { open_signup: false };
   });

   it('shows open sign-up as stored and turns it on', async () => {
      const wrapper = mount(Platform, { global: { plugins: [i18NPlugin, PrimeVue] } });
      mounted.push(wrapper);
      await flushPromises();

      const toggle = wrapper.get('[data-open-signup] input');
      expect((toggle.element as HTMLInputElement).checked).toBe(false);
      await toggle.setValue(true);
      await flushPromises();

      expect(api.mutate).toHaveBeenCalledWith({ key: 'open_signup', value: true });
      expect(api.toast).toHaveBeenCalled();
   });
});
