import '../setup/mockMain';
import BarList from '@/components/service-components/dashboard/charts/BarList.vue';
import ColumnChart from '@/components/service-components/dashboard/charts/ColumnChart.vue';
import MeterList from '@/components/service-components/dashboard/charts/MeterList.vue';
import StatTile from '@/components/service-components/dashboard/charts/StatTile.vue';
import type { ChartBar } from '@/components/service-components/dashboard/charts/types';
import { DASHBOARD_EDITING } from '@/constants/dashboard';
import en from '@/plugins/i18n/locales/en/index.json';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { mount } from '@vue/test-utils';
import PrimeVue from 'primevue/config';
import Tooltip from 'primevue/tooltip';
import { beforeAll, beforeEach, expect, it, vi } from 'vitest';
import { ref, type Component } from 'vue';

const push = vi.fn();
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRouter: () => ({ push })
}));

const mountPart = (component: Component, props: Record<string, unknown>, editing = false) =>
   mount(component, {
      props,
      global: {
         plugins: [i18NPlugin, PrimeVue],
         directives: { tooltip: Tooltip },
         provide: { [DASHBOARD_EDITING]: ref(editing) }
      }
   });

const bar = (key: string, parts: [string, number][], extra: Partial<ChartBar> = {}): ChartBar => ({
   key,
   label: key.toUpperCase(),
   segments: parts.map(([k, value]) => ({ key: k, label: k, color: 'red', value })),
   to: { name: 'ops-shipment-list' },
   ...extra
});

beforeAll(() => i18n.setLocaleMessage('en', en));
beforeEach(() => push.mockReset());

it('draws each bar against the longest one, skipping empty parts, with its figure', () => {
   const w = mountPart(BarList, {
      caption: 'Shipments',
      bars: [
         bar('a', [
            ['on', 3],
            ['late', 1]
         ]),
         bar('b', [
            ['on', 2],
            ['late', 0]
         ])
      ]
   });
   const rows = w.findAll('.bar-row');
   expect(rows.map((r) => r.get('.bar-value').text())).toEqual(['4', '2']);
   expect(rows[0].findAll('.bar-segment').map((s) => s.attributes('style'))).toEqual([
      expect.stringContaining('width: 75%'),
      expect.stringContaining('width: 25%')
   ]);
   expect(rows[1].findAll('.bar-segment')).toHaveLength(1);
   expect(rows[0].attributes('aria-label')).toBe('A: 4 (on 3, late 1)');
});
it('shows where a bar stands against its target', () => {
   const w = mountPart(BarList, {
      caption: 'Market',
      bars: [bar('a', [['live', 1]], { total: 4, value: '1 / 4' })]
   });
   expect(w.get('.bar-target').attributes('style')).toContain('inset-inline-start: 100%');
   expect(w.get('.bar-segment').attributes('style')).toContain('width: 25%');
   expect(w.get('.bar-value').text()).toBe('1 / 4');
});
it('opens the list from a bar, but not while the dashboard is being arranged', async () => {
   const w = mountPart(BarList, { caption: 'Shipments', bars: [bar('a', [['on', 1]])] });
   await w.get('button.bar-row').trigger('click');
   expect(push).toHaveBeenCalledWith({ name: 'ops-shipment-list' });
   const editing = mountPart(BarList, { caption: 'S', bars: [bar('a', [['on', 1]])] }, true);
   expect(editing.find('button.bar-row').exists()).toBe(false);
});
it('gives screen readers the figures as a table', () => {
   const w = mountPart(BarList, {
      caption: 'Shipments',
      bars: [
         bar('a', [
            ['on', 3],
            ['late', 1]
         ])
      ]
   });
   const table = w.get('table.sr-only');
   expect(table.findAll('th').map((th) => th.text())).toEqual([
      'Shipments',
      'on',
      'late',
      'Total',
      'A'
   ]);
   expect(table.findAll('td').map((td) => td.text())).toEqual(['3', '1', '4']);
});

it('stacks each column up to a clean axis, with its total on the cap', () => {
   const w = mountPart(ColumnChart, {
      caption: 'Gates',
      bars: [
         bar('a', [
            ['team', 2],
            ['management', 1]
         ]),
         bar('b', [
            ['team', 0],
            ['management', 0]
         ])
      ]
   });
   const stacks = w.findAll('.column-stack');
   expect(stacks[0].attributes('style')).toContain('height: 100%');
   expect(stacks[0].get('.column-cap').text()).toBe('3');
   expect(stacks[0].findAll('.column-segment')).toHaveLength(2);
   expect(stacks[1].find('.column-cap').exists()).toBe(false);
   expect(w.findAll('.column-tick').map((t) => t.text())).toEqual(['3', '0']);
});
it('names a column that needs attention with an icon as well', () => {
   const w = mountPart(ColumnChart, {
      caption: 'Tasks',
      bars: [bar('overdue', [['x', 1]], { emphasis: 'critical' }), bar('d0', [['x', 1]])]
   });
   const labels = w.findAll('.column-label');
   expect(labels[0].find('.pi-exclamation-triangle').exists()).toBe(true);
   expect(labels[1].find('.pi-exclamation-triangle').exists()).toBe(false);
});

it('shows each meter as a share of its whole and opens its list', async () => {
   const w = mountPart(MeterList, {
      rows: [
         {
            key: 't',
            label: 'THO',
            meters: [
               {
                  key: 's',
                  label: 'Signed spec',
                  value: 1,
                  total: 4,
                  to: { name: 'ops-product-list' }
               },
               { key: 'c', label: 'Compliance', value: 0, total: 0 }
            ]
         }
      ]
   });
   const fills = w.findAll('.meter-fill');
   expect(fills[0].attributes('style')).toContain('width: 25%');
   expect(fills[1].attributes('style')).toContain('width: 0%');
   expect(w.text()).toContain('25%');
   await w.get('button.meter').trigger('click');
   expect(push).toHaveBeenCalledWith({ name: 'ops-product-list' });
   expect(w.findAll('button.meter')).toHaveLength(1);
});

it('shows a placeholder until the figure is read, then the figure and its context', async () => {
   const w = mountPart(StatTile, {
      label: 'Open incidents',
      icon: 'pi pi-bolt',
      iconClass: '',
      value: null,
      to: { name: 'ops-incident-list' }
   });
   expect(w.find('.p-skeleton').exists()).toBe(true);
   await w.setProps({ value: 6, sub: '1 S1 critical', alert: true });
   expect(w.text()).toContain('6');
   expect(w.text()).toContain('1 S1 critical');
   expect(w.find('.pi-exclamation-triangle').exists()).toBe(true);
   await w.trigger('click');
   expect(push).toHaveBeenCalledWith({ name: 'ops-incident-list' });
   await w.setProps({ disabled: true });
   expect(w.element.tagName).toBe('DIV');
});
