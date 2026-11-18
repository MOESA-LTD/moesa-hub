import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { flushPromises, mount } from '@vue/test-utils';
import { computed, defineComponent, h } from 'vue';

const auth = { currentTenant: { id: 'provider' }, scopeTenants: [{ id: 'provider' }] };
vi.mock('@/store/auth', () => ({ useAuthStore: () => auth }));
vi.mock('@/api/useTenantKey', () => ({ useTenantKey: () => computed(() => 'provider') }));

const { sourcingSchema, toSourcingFormValues, toSourcingPayload, ownSourcing, useSourcing } =
   await import('@/api/sourcing');

const PRODUCT = '00000000-0000-4000-8000-000000000001';
const CLIENT = '00000000-0000-4000-8000-000000000002';
const SUPPLIER = '00000000-0000-4000-8000-000000000003';

const withSetup = <T>(composable: () => T): T => {
   let result!: T;
   mount(
      defineComponent({
         setup() {
            result = composable();
            return () => h('div');
         }
      }),
      { global: { plugins: [[VueQueryPlugin, { queryClient: new QueryClient() }]] } }
   );
   return result;
};

describe('useSourcing', () => {
   const fetchMock = vi.fn();

   beforeEach(() => {
      fetchMock.mockReset();
      fetchMock.mockImplementation(async () => new Response('[]', { status: 200 }));
      vi.stubGlobal('fetch', fetchMock);
   });
   afterEach(() => vi.unstubAllGlobals());

   it('useSourcing queries sourcing by product_id without tenant filter', async () => {
      withSetup(() => useSourcing(() => PRODUCT));
      await flushPromises();

      const url = decodeURIComponent(String(fetchMock.mock.calls[0]![0]));
      expect(url).toContain('/rest/v1/sourcing');
      expect(url).toContain(`product_id=eq.${PRODUCT}`);
      expect(url).not.toContain('tenant_id=');
   });

   it('does not query without a product', async () => {
      withSetup(() => useSourcing(() => null));
      await flushPromises();
      expect(fetchMock).not.toHaveBeenCalled();
   });
});

describe('sourcing form', () => {
   const valid = () => toSourcingFormValues(null, { productId: PRODUCT, clientTenantId: CLIENT });

   it('takes a client tenant (uuid) or none', () => {
      expect(sourcingSchema.safeParse(valid()).success).toBe(true);
      expect(sourcingSchema.safeParse({ ...valid(), client_tenant_id: null }).success).toBe(true);
      expect(sourcingSchema.safeParse({ ...valid(), client_tenant_id: 'THO' }).success).toBe(false);
      expect(sourcingSchema.safeParse({ ...valid(), purchase_price: -1 }).success).toBe(false);
      expect(sourcingSchema.safeParse({ ...valid(), customer_id: 'c1' }).success).toBe(false);
   });

   it('sends the product and its client with a new row only, empty fields as null', () => {
      const created = toSourcingPayload(
         sourcingSchema.parse({
            ...valid(),
            supplier_id: SUPPLIER,
            purchase_price: 1.9,
            purchase_currency: 'USD',
            sell_price_eur: 4.5,
            notes: ''
         })
      );
      expect(created).toMatchObject({
         product_id: PRODUCT,
         client_tenant_id: CLIENT,
         supplier_id: SUPPLIER,
         purchase_price: 1.9,
         purchase_currency: 'USD',
         sell_price_eur: 4.5,
         notes: null
      });
      expect(created).not.toHaveProperty('id');
      expect(created).not.toHaveProperty('tenant_id');

      const updated = toSourcingPayload(sourcingSchema.parse({ ...valid(), id: 's1' }));
      expect(updated).toMatchObject({ id: 's1' });
      for (const key of ['product_id', 'client_tenant_id', 'product_sku', 'product_name'])
         expect(updated).not.toHaveProperty(key);
   });

   it('reads a stored row back into the form', () => {
      const values = toSourcingFormValues(
         {
            id: 's1',
            product_id: PRODUCT,
            client_tenant_id: null,
            purchase_price: 2,
            landed_cost_on: '2026-11-03',
            manufacturer_art_no: null
         },
         { productId: PRODUCT, clientTenantId: CLIENT }
      );
      expect(values).toMatchObject({
         id: 's1',
         product_id: PRODUCT,
         client_tenant_id: null,
         purchase_price: 2,
         manufacturer_art_no: ''
      });
      expect(values.landed_cost_on).toBeInstanceOf(Date);
   });
});

describe('ownSourcing', () => {
   it("picks the active tenant's row among the rows in scope", () => {
      const rows = [
         { id: 'client-own', tenant_id: CLIENT },
         { id: 'provider', tenant_id: 'provider' }
      ];
      expect(ownSourcing(rows, 'provider')?.id).toBe('provider');
      expect(ownSourcing(rows, 'other')).toBeNull();
   });
});
