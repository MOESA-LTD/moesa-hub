import { planDiff, type PlanSummary } from '@/lib/planDiff';
import { describe, expect, it } from 'vitest';

const plan = (over: Partial<PlanSummary> = {}): PlanSummary => ({
   id: 'p1',
   display_name: 'Plan',
   description: null,
   audience: null,
   price: 0,
   currency: 'EUR',
   billing_period: 'month',
   trial_days: 0,
   position: 1,
   modules: [],
   limits: {},
   ...over
});

describe('planDiff', () => {
   it('lists modules gained and lost', () => {
      const from = plan({ modules: ['product', 'audit_log'] });
      const to = plan({ modules: ['product', 'shipment'] });
      expect(planDiff(from, to)).toMatchObject({
         modulesGained: ['shipment'],
         modulesLost: ['audit_log']
      });
   });

   it('treats a missing limit as unlimited', () => {
      const from = plan({ limits: { max_users: 5, max_branches: 2 } });
      const to = plan({ limits: { max_branches: 2 } });
      expect(planDiff(from, to).limits).toEqual([{ key: 'max_users', from: 5, to: null }]);
      expect(planDiff(to, from).limits).toEqual([{ key: 'max_users', from: null, to: 5 }]);
   });

   it('reports no change between equal plans', () => {
      const a = plan({ modules: ['x'], limits: { max_users: 1 } });
      expect(planDiff(a, { ...a })).toEqual({ modulesGained: [], modulesLost: [], limits: [] });
   });

   it('leaves core modules out of gained and lost', () => {
      const from = plan({ modules: ['branch', 'audit_log'] });
      const to = plan({ modules: [] });
      expect(planDiff(from, to, ['branch'])).toMatchObject({
         modulesGained: [],
         modulesLost: ['audit_log']
      });
   });
});
