import {
   isOwnerAbove,
   isProfileManagedElsewhere,
   toUserFormValues,
   toUserPayload,
   userSchema
} from '@/api/user';
import { FunctionsHttpError } from '@supabase/supabase-js';
import { describe, expect, it } from 'vitest';

const payload = (values: Parameters<typeof toUserFormValues>[0]) =>
   toUserPayload(userSchema.parse(toUserFormValues(values)));

describe('toUserPayload', () => {
   it('sends the email to invite a new member', () => {
      expect(
         payload({ email: 'new@moesa-panel.test', user_metadata: { display_name: 'New' } })
      ).toMatchObject({
         id: undefined,
         attributes: { email: 'new@moesa-panel.test', user_metadata: { display_name: 'New' } }
      });
   });

   it('never sends sign-in details for an existing member', () => {
      const { attributes } = payload({
         id: 'user',
         email: 'member@moesa-panel.test',
         phone: '+905550000000',
         user_metadata: { display_name: 'Member' }
      });
      expect(attributes).toEqual({ user_metadata: { display_name: 'Member' } });
   });
});

describe('isOwnerAbove', () => {
   it('is false without a user (loading placeholder rows)', () => {
      expect(isOwnerAbove(null)).toBe(false);
      expect(isOwnerAbove(undefined)).toBe(false);
   });

   it('is true only for a user without a tenant of this branch', () => {
      expect(isOwnerAbove({ tenant_id: null } as never)).toBe(true);
      expect(isOwnerAbove({ tenant_id: 't1' } as never)).toBe(false);
   });
});

describe('isProfileManagedElsewhere', () => {
   const refusal = (status: number, message: string) =>
      new FunctionsHttpError(
         new Response(JSON.stringify({ message }), {
            status,
            headers: { 'Content-Type': 'application/json' }
         })
      );

   it('recognises the refusal to change an account another company uses', async () => {
      expect(await isProfileManagedElsewhere(refusal(403, 'user_not_allowed'))).toBe(true);
   });

   it('lets every other failure through', async () => {
      expect(await isProfileManagedElsewhere(refusal(403, 'field_write_forbidden'))).toBe(false);
      expect(await isProfileManagedElsewhere(refusal(404, 'user_not_found'))).toBe(false);
      expect(await isProfileManagedElsewhere(new Error('offline'))).toBe(false);
   });
});
