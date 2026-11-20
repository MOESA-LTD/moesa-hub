import { resolvePlanModules, type ModuleRequirement } from '@/lib/planModules';
import { describe, expect, it } from 'vitest';

const modules: ModuleRequirement[] = [
   { id: 'product', is_core: true, requires: [] },
   { id: 'purchase_order', is_core: false, requires: [] },
   { id: 'shipment', is_core: false, requires: ['purchase_order'] },
   { id: 'market_matrix', is_core: false, requires: ['product'] },
   { id: 'listing', is_core: false, requires: ['market_matrix'] },
   { id: 'insight', is_core: false, requires: ['listing'] },
   { id: 'incident', is_core: false, requires: null }
];

describe('resolvePlanModules', () => {
   it('adds what a picked module requires', () => {
      expect(resolvePlanModules([], ['shipment'], modules)).toEqual(['shipment', 'purchase_order']);
   });

   it('adds requirements transitively and never a core module', () => {
      expect(resolvePlanModules([], ['insight'], modules)).toEqual([
         'insight',
         'listing',
         'market_matrix'
      ]);
   });

   it('drops what requires a dropped module, transitively', () => {
      expect(
         resolvePlanModules(
            ['incident', 'market_matrix', 'listing', 'insight'],
            ['incident', 'listing', 'insight'],
            modules
         )
      ).toEqual(['incident']);
   });

   it('leaves an unrelated change alone', () => {
      expect(
         resolvePlanModules(['purchase_order'], ['purchase_order', 'incident'], modules)
      ).toEqual(['purchase_order', 'incident']);
   });

   it('keeps a requirement already picked', () => {
      expect(
         resolvePlanModules(['purchase_order'], ['purchase_order', 'shipment'], modules)
      ).toEqual(['purchase_order', 'shipment']);
   });
});
