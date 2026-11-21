import '../setup/mockMain';
import { ability } from '@/plugins/casl';
import en from '@/plugins/i18n/locales/en/index.json';
import DashboardOverview from '@/views/pages/dashboard/DashboardOverview.vue';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { abilitiesPlugin } from '@casl/vue';
import { mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import { ref } from 'vue';

vi.mock('@/lib/supabase', () => ({ supabase: {} }));
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRouter: () => ({ push: vi.fn() })
}));
const rows = vi.hoisted(() => ({
   gates: [
      { needs_management: true, needs_customer_approval: false },
      { needs_management: false, needs_customer_approval: true },
      { needs_management: false, needs_customer_approval: false }
   ],
   shipments: [
      { status: 'in_transit', overdue: true },
      { status: 'loaded', overdue: false },
      { status: 'planned', overdue: false }
   ]
}));
vi.mock('@/api/dashboard', async (importOriginal) => {
   const actual = await importOriginal<typeof import('@/api/dashboard')>();
   const query = (data: unknown[] | undefined) => () => ({
      data: ref(data),
      isPending: ref(data === undefined)
   });
   return {
      ...actual,
      useDashboardGates: query(rows.gates),
      useDashboardShipments: query(rows.shipments),
      useDashboardTasks: query(undefined),
      useDashboardPurchaseOrders: query([]),
      useDashboardIncidents: query([]),
      useDashboardMarket: query([])
   };
});

const mountOverview = (...subjects: string[]) => {
   ability.update(subjects.map((subject) => ({ action: 'select', subject })));
   return mount(DashboardOverview, {
      global: { plugins: [i18NPlugin, PrimeVue, [abilitiesPlugin, ability]] }
   });
};

beforeAll(() => i18n.setLocaleMessage('en', en));
afterEach(() => ability.update([]));

it('shows a figure only where the user may read its records', () => {
   const w = mountOverview('project_gate', 'shipment');
   expect(w.findAll('.stat-tile')).toHaveLength(2);
   expect(w.text()).toContain('Pending gates');
   expect(w.text()).not.toContain('Open incidents');
});
it('counts the gates with who acts, and the shipments on the way with the late ones', () => {
   const w = mountOverview('project_gate', 'shipment');
   const [gates, shipments] = w.findAll('.stat-tile');
   expect(gates.text()).toContain('3');
   expect(gates.text()).toContain('1 management · 1 customer');
   expect(shipments.text()).toContain('2');
   expect(shipments.text()).toContain('1 late');
   expect(shipments.find('.pi-exclamation-triangle').exists()).toBe(true);
});
it('shows a placeholder while the figure is being read', () => {
   expect(mountOverview('project_task').find('.p-skeleton').exists()).toBe(true);
});
it('shows nothing when the user may read none of them', () => {
   expect(mountOverview('tenant').find('section').exists()).toBe(false);
});
