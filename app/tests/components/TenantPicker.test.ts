import '../setup/mockMain';
import type { Tenant } from '@/api/access';
import TenantPicker from '@/components/service-components/tenant-picker/TenantPicker.vue';
import { i18NPlugin } from '@plugins/i18n';
import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import PrimeVue from 'primevue/config';
import Tooltip from 'primevue/tooltip';
import type { TreeNode } from 'primevue/treenode';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed, reactive, ref } from 'vue';

const tenants = ref<Tenant[]>([]);
const scopeIds = ref<string[]>([]);
const setScope = vi.fn((ids: string[]) => {
   scopeIds.value = ids;
   return Promise.resolve();
});

vi.mock('@/store/auth', () => ({
   useAuthStore: () =>
      reactive({
         branches: tenants,
         currentTenant: ref(null),
         currentLogoPath: ref(null),
         scopeTenants: computed(() =>
            tenants.value.filter(({ id }) => scopeIds.value.includes(id))
         ),
         setScope,
         changeCurrentTenant: vi.fn(() => Promise.resolve())
      })
}));

const mountPicker = () =>
   mount(TenantPicker, {
      global: {
         plugins: [createPinia(), i18NPlugin, PrimeVue] as never,
         directives: { tooltip: Tooltip }
      }
   });

const options = (wrapper: ReturnType<typeof mountPicker>) =>
   wrapper.findComponent({ name: 'TreeSelect' }).props('options') as TreeNode[];

describe('TenantPicker', () => {
   beforeEach(() => {
      setActivePinia(createPinia());
      tenants.value = [
         { id: 'P', display_name: 'Provider', code: 'PRV', parent_id: null },
         { id: 'PB', display_name: 'Provider Branch', parent_id: 'P' },
         { id: 'C', display_name: 'Client', code: 'CLI', parent_id: null }
      ];
      scopeIds.value = ['P'];
      setScope.mockClear();
   });

   it('shows a client tenant as its own root next to the provider tree', () => {
      const roots = options(mountPicker());
      expect(roots.map(({ key }) => key)).toEqual(['P', 'C']);
      expect(roots[0].children?.map(({ key }) => key)).toEqual(['PB']);
      expect(roots[1].children).toEqual([]);
      expect(roots[0].label).toBe('Provider');
      expect(roots[0].data.code).toBe('PRV');
   });

   it('selecting two roots sets x-tenant-ids to both', async () => {
      const wrapper = mountPicker();
      wrapper.findComponent({ name: 'TreeSelect' }).vm.$emit('update:modelValue', {
         P: true,
         C: true
      });
      await Promise.resolve();
      expect(setScope).toHaveBeenCalledWith(['P', 'C']);
   });

   it('is hidden for a user with one tenant', () => {
      tenants.value = [tenants.value[0]];
      expect(mountPicker().findComponent({ name: 'TreeSelect' }).exists()).toBe(false);
   });
});
