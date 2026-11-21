import '../setup/mockMain';
import type {
   DashboardEvidenceRow,
   DashboardGateRow,
   DashboardIncidentRow,
   DashboardMarketRow,
   DashboardPurchaseOrderRow,
   DashboardShipmentRow,
   DashboardTaskRow
} from '@/api/dashboard';
import { barTotal, niceMax } from '@/components/service-components/dashboard/charts/types';
import en from '@/plugins/i18n/locales/en/index.json';
import {
   gateAgingChart,
   incidentSeverityChart,
   marketCoverageChart,
   orderPipelineChart,
   productReadinessChart,
   shipmentStatusChart,
   taskHorizonChart,
   VIZ
} from '@/views/pages/dashboard/boxes/charts';
import i18n from '@plugins/i18n';
import { beforeAll, expect, it } from 'vitest';

beforeAll(() => i18n.setLocaleMessage('en', en));

const values = (bar: { segments: { key: string; value: number }[] }) =>
   Object.fromEntries(bar.segments.map((s) => [s.key, s.value]));

it('bands the pending gates by waiting time, stacked by who has to act', () => {
   const gate = (waiting_days: number, needs_management = false, needs_customer_approval = false) =>
      ({ waiting_days, needs_management, needs_customer_approval }) as DashboardGateRow;
   const chart = gateAgingChart([
      gate(0),
      gate(7, true),
      gate(8, false, true),
      gate(14),
      gate(30, true, true),
      gate(31)
   ]);
   expect(chart.count).toBe(6);
   expect(chart.bars.map((b) => b.label)).toEqual(['0–7 d', '8–14 d', '15–30 d', '31+ d']);
   expect(chart.bars.map(values)).toEqual([
      { team: 1, management: 1, customer: 0 },
      { team: 1, management: 0, customer: 1 },
      { team: 0, management: 1, customer: 0 },
      { team: 1, management: 0, customer: 0 }
   ]);
   expect(chart.legend.map((l) => l.label)).toEqual(['Team', 'Management', 'Customer']);
   expect(chart.bars[3].emphasis).toBe('critical');
});
it('marks the open-ended gate band only when a gate is in it', () => {
   const chart = gateAgingChart([{ waiting_days: 2 } as DashboardGateRow]);
   expect(chart.bars.every((b) => b.emphasis === undefined)).toBe(true);
});

it('puts the tasks in an overdue column and one per day, split by whether they hold a gate', () => {
   const task = (days_left: number, blocks_gate = false) =>
      ({ days_left, blocks_gate, overdue: days_left < 0 }) as DashboardTaskRow;
   const chart = taskHorizonChart([task(-3, true), task(-1), task(0), task(2, true), task(5)]);
   expect(chart.count).toBe(5);
   expect(chart.bars.map((b) => b.key)).toEqual(['overdue', 'd0', 'd1', 'd2', 'd3', 'd4', 'd5']);
   expect(chart.bars[0]).toMatchObject({ label: 'Overdue', emphasis: 'critical' });
   expect(chart.bars[1].label).toBe('Today');
   expect(chart.bars.map(barTotal)).toEqual([2, 1, 0, 1, 0, 0, 1]);
   expect(values(chart.bars[0])).toEqual({ blocks_gate: 1, other_tasks: 1 });
   expect(taskHorizonChart([task(1)]).bars[0].emphasis).toBeUndefined();
});

it('lists every provider stage of the order flow in order, empty ones included', () => {
   const order = (status: DashboardPurchaseOrderRow['status']) =>
      ({ status }) as DashboardPurchaseOrderRow;
   const chart = orderPipelineChart([
      order('in_production'),
      order('sent'),
      order('in_production')
   ]);
   expect(chart.count).toBe(3);
   expect(chart.bars.map((b) => b.label)).toEqual([
      'Sent',
      'PI received',
      'PI approved',
      'Deposit paid',
      'In production',
      'Ready',
      'Balance paid'
   ]);
   expect(chart.bars.map(barTotal)).toEqual([1, 0, 0, 0, 2, 0, 0]);
   expect(chart.bars[0].to).toEqual({ name: 'ops-purchase-order-list' });
});
it("shows a client's shared orders by their client status only", () => {
   const chart = orderPipelineChart([
      { status: null, client_status: 'confirmed' } as DashboardPurchaseOrderRow
   ]);
   expect(chart.bars.map((b) => b.key)).toEqual(['ops.purchase_order.client_status.confirmed']);
   expect(barTotal(chart.bars[0])).toBe(1);
});

it('splits each open shipment status into on time and late, disputed only when there is one', () => {
   const shipment = (status: DashboardShipmentRow['status'], overdue = false) =>
      ({ status, overdue }) as DashboardShipmentRow;
   const chart = shipmentStatusChart([
      shipment('in_transit'),
      shipment('in_transit', true),
      shipment('at_customs', true)
   ]);
   expect(chart.bars.map((b) => b.key)).toEqual([
      'planned',
      'booked',
      'loaded',
      'in_transit',
      'at_customs',
      'delivered'
   ]);
   expect(values(chart.bars[3])).toEqual({ on_time: 1, late: 1 });
   expect(values(chart.bars[4])).toEqual({ on_time: 0, late: 1 });
   expect(chart.legend[1]).toMatchObject({ key: 'late', color: VIZ.critical });
   expect(chart.legend[1].icon).toBeTruthy();
   expect(shipmentStatusChart([shipment('disputed')]).bars.at(-1)!.key).toBe('disputed');
});

it('counts the incidents per severity in status colours, with the contained ones and missing notices', () => {
   const incident = (
      severity: DashboardIncidentRow['severity'],
      status: DashboardIncidentRow['status'] = 'open',
      management_notice_missing = false
   ) => ({ severity, status, management_notice_missing }) as DashboardIncidentRow;
   const chart = incidentSeverityChart([
      incident('s1', 'open', true),
      incident('s2', 'contained'),
      incident('s2')
   ]);
   expect(chart.bars.map(barTotal)).toEqual([1, 2, 0]);
   expect(chart.bars.map((b) => b.segments[0].color)).toEqual([
      VIZ.critical,
      VIZ.serious,
      VIZ.warning
   ]);
   expect(chart.bars.every((b) => !!b.icon)).toBe(true);
   expect(chart.bars[1].note).toBe('1 contained');
   expect(chart.bars[0].note).toBeUndefined();
   expect(chart.alert).toBe('1 not reported to management yet');
   expect(incidentSeverityChart([incident('s3')]).alert).toBeUndefined();
});

it('reads each targeted company’s cells against its target, the most live first', () => {
   const names: Record<string, string> = { a: 'Alpha', b: 'Beta', c: 'Gamma' };
   const cells = (tenant_id: string, live: number, target: number) =>
      ({
         tenant_id,
         live_count: live,
         preparing_count: 1,
         suppressed_count: 0,
         target_count: target
      }) as DashboardMarketRow;
   const chart = marketCoverageChart((id) => names[id ?? ''])([
      cells('a', 1, 4),
      cells('b', 3, 5),
      cells('c', 2, 0)
   ]);
   expect(chart.count).toBe(6);
   expect(chart.bars.map((b) => b.label)).toEqual(['Beta', 'Alpha']);
   expect(chart.bars[0]).toMatchObject({ value: '3 / 5', total: 5 });
   expect(values(chart.bars[0])).toEqual({ live: 3, preparing: 1, suppressed: 0 });
   expect(marketCoverageChart(() => '')([cells('c', 2, 0)]).empty).toBe(true);
});

it('gives each company with active SKUs its signed-spec and compliance shares, least ready first', () => {
   const evidence = (tenant_id: string, active: number, signed: number, complete: number) =>
      ({
         tenant_id,
         active_sku_count: active,
         signed_spec_count: signed,
         compliance_complete_count: complete
      }) as DashboardEvidenceRow;
   const view = productReadinessChart((id) => (id === 'a' ? 'Alpha' : 'Beta'))([
      evidence('a', 10, 10, 8),
      evidence('b', 4, 1, 0),
      evidence('c', 0, 0, 0)
   ]);
   expect(view.count).toBe(14);
   expect(view.rows.map((r) => r.label)).toEqual(['Beta', 'Alpha']);
   expect(view.rows[1].meters).toEqual([
      expect.objectContaining({ key: 'signed_spec', value: 10, total: 10 }),
      expect.objectContaining({ key: 'compliance', value: 8, total: 10 })
   ]);
   expect(productReadinessChart(() => '')([evidence('c', 0, 0, 0)]).empty).toBe(true);
});

it('rounds an axis up to a clean maximum', () => {
   expect([0, 1, 3, 5, 6, 12, 48, 51, 130].map(niceMax)).toEqual([
      1, 1, 3, 5, 10, 20, 50, 100, 200
   ]);
});
