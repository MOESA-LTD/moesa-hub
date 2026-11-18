import opsRoutes, { incidentProps } from '@/router/routes/ops';
import { describe, expect, it } from 'vitest';
import { createMemoryHistory, createRouter, type RouteLocationNormalized } from 'vue-router';

// A route dialog renders its page outside the router, so a new incident opened from a project (or
// a gate's rollback) gets its linked record from the query as props.
describe('incident route props', () => {
   it('reads the new incident from the query', () => {
      const route = {
         params: { id: undefined },
         query: { entity_type: 'project', entity_id: 'p1' }
      } as unknown as RouteLocationNormalized;

      expect(incidentProps(route)).toEqual({
         id: undefined,
         entity_type: 'project',
         entity_id: 'p1'
      });
   });

   it('passes them to the incident card', () => {
      const router = createRouter({
         history: createMemoryHistory(),
         routes: [{ path: '/', children: opsRoutes }]
      });
      const route = router.resolve({
         name: 'ops-incident-manage',
         query: { entity_type: 'project', entity_id: 'p1', showDialog: 'center' }
      });
      const record = route.matched.at(-1)!;
      const props = record.props.default as (r: typeof route) => Record<string, unknown>;

      expect(props(route)).toMatchObject({
         entity_type: 'project',
         entity_id: 'p1'
      });
   });
});
