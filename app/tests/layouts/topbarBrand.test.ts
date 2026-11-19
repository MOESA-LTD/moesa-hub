import TopbarBrand from '@/layouts/dashboard/TopbarBrand.vue';
import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';

describe('TopbarBrand', () => {
   it('shows the MOESA Hub lockup without a company logo', () => {
      const wrapper = mount(TopbarBrand, { props: { logo: null } });
      expect(wrapper.text()).toContain('MOESA');
      expect(wrapper.text()).toContain('Hub');
      expect(wrapper.find('img[src="/brand/moesa_mark.png"]').exists()).toBe(true);
   });

   it('shows only the company logo when there is one', () => {
      const wrapper = mount(TopbarBrand, {
         props: { logo: 'https://x/logo.png', alt: 'Kernhaus Living' }
      });
      const img = wrapper.find('img[src="https://x/logo.png"]');
      expect(img.exists()).toBe(true);
      expect(img.attributes('alt')).toBe('Kernhaus Living');
      expect(wrapper.text()).not.toContain('MOESA');
      expect(wrapper.find('img[src="/brand/moesa_mark.png"]').exists()).toBe(false);
   });
});
