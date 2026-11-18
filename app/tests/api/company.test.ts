import {
   brandSchema,
   contactSchema,
   platformAccountSchema,
   toBrandFormValues,
   toBrandPayload,
   toContactFormValues,
   toContactPayload,
   toPlatformAccountFormValues,
   toPlatformAccountPayload,
   toWarehouseFormValues,
   toWarehousePayload,
   warehouseSchema
} from '@/api/company';
import { describe, expect, it } from 'vitest';

const legacyKey = ['customer', 'id'].join('_'); // the column the old model had

describe('company profile forms', () => {
   const warehouse = () => ({
      ...toWarehouseFormValues({ display_name: 'Main', type: 'own' }),
      country: 'DE'
   });

   it('warehouseSchema rejects a payload with a legacy key', () => {
      expect(warehouseSchema.safeParse(warehouse()).success).toBe(true);
      expect(warehouseSchema.safeParse({ ...warehouse(), [legacyKey]: 'x' }).success).toBe(false);
   });

   it('the other schemas reject the legacy key too', () => {
      const plain = { [legacyKey]: 'x' };
      expect(brandSchema.safeParse({ ...toBrandFormValues({ name: 'A' }), ...plain }).success).toBe(
         false
      );
      expect(
         contactSchema.safeParse({ ...toContactFormValues({ name: 'A' }), ...plain }).success
      ).toBe(false);
      expect(
         platformAccountSchema.safeParse({
            ...toPlatformAccountFormValues({ platform_id: 'amazon' }),
            ...plain
         }).success
      ).toBe(false);
   });

   it('toContactPayload keeps only contact columns', () => {
      const parsed = contactSchema.parse(toContactFormValues({ name: 'Ada', email: '' }));
      const payload = toContactPayload({ ...parsed, [legacyKey]: 'x', tenant_id: 't' } as never);
      expect(Object.keys(payload).sort()).toEqual(
         ['can_approve', 'email', 'name', 'phone', 'role'].sort()
      );
      expect(payload.email).toBeNull();
   });

   it('sends the id only when editing and empty text as null', () => {
      const brand = brandSchema.parse(toBrandFormValues({ name: 'A' }));
      expect(toBrandPayload(brand)).toEqual({
         name: 'A',
         registration_status: null,
         brand_program_status: null,
         gs1_prefix_owner: null
      });
      expect(toBrandPayload({ ...brand, id: 'b1' }).id).toBe('b1');
      const account = platformAccountSchema.parse(
         toPlatformAccountFormValues({ platform_id: 'amazon' })
      );
      expect(toPlatformAccountPayload(account)).toMatchObject({
         platform_id: 'amazon',
         account_holder: null,
         access: 'none'
      });
      expect(Object.keys(toWarehousePayload(warehouseSchema.parse(warehouse())))).not.toContain(
         legacyKey
      );
   });
});
