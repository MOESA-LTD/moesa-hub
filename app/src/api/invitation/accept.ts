import { email, optional, phone, website } from '@/lib/form/fields';
import type { PlanSummary } from '@/lib/planDiff';
import { publicSchema, supabase } from '@/lib/supabase';
import { readRefusal } from './refusal';
import * as z from 'zod';

// The page a client opens from its invitation e-mail. The token is the link's path segment: it goes
// into the preview call and the accept request body, and nowhere else (never logged, stored or put
// in a query key).

/**
 * A provider staff member the invitation brings (final review I2): a name and a role, never an
 * e-mail or a user id. `index` is how the accept call names them.
 */
export type InvitationStaff = { index: number; display_name: string | null; role_name: string };

/** What `invitation_preview` returns for the signed-in invitee (supabase/migrations/071). */
export type InvitationPreview = {
   company_name: string | null;
   email: string;
   provider_name: string | null;
   procurement_model: string;
   recommended_plan_id: string | null;
   expires_at: string | null;
   seats: number;
   /** The staff who would join (absent in an older preview). */
   staff?: InvitationStaff[];
   needs_password: boolean;
   plans: PlanSummary[];
};

/** A refusal the page names: the code of `invitation_preview` / the accept function. */
export class InvitationError extends Error {
   constructor(public readonly code: string) {
      super(code);
      this.name = 'InvitationError';
   }
}

/**
 * The invitation behind a token. Refusals arrive as a 200 with `{ error: code }` (the database does
 * not raise them, so its attempt counts persist) and are thrown as an InvitationError.
 */
export async function previewInvitation(token: string): Promise<InvitationPreview> {
   const { data, error } = await publicSchema.rpc('invitation_preview', { token });
   if (error) throw error;
   const result = data as unknown as InvitationPreview & { error?: string };
   if (result?.error) throw new InvitationError(result.error);
   return result;
}

/** The new company's details: the keys private.create_company takes, and no others. */
export const COMPANY_KEYS = [
   'display_name',
   'legal_name',
   'email',
   'phone',
   'website',
   'country',
   'city',
   'district',
   'address',
   'tax_office',
   'tax_number'
] as const;

const text = () => optional(z.string().trim());

export const companySchema = z.object({
   display_name: z.string().trim().min(3),
   legal_name: text(),
   email: email(),
   phone: optional(phone()),
   website: optional(website()),
   country: text(),
   city: text(),
   district: text(),
   address: text(),
   tax_office: text(),
   tax_number: text()
});

export type CompanyValues = z.input<typeof companySchema>;

/** Only the filled-in keys of the allowlist: nothing else can go to the function. */
export const toCompany = (values: z.output<typeof companySchema>) =>
   Object.fromEntries(
      COMPANY_KEYS.map((key) => [key, values[key]] as const).filter(
         ([, value]) => typeof value === 'string' && value !== ''
      )
   ) as Record<(typeof COMPANY_KEYS)[number], string>;

/** The refusal of the function as an InvitationError (its body carries the code). */
const named = async (error: unknown) => {
   const refusal = await readRefusal(error);
   return refusal ? new InvitationError(refusal.code) : error;
};

/**
 * Accepts the invitation: creates the company on the chosen plan. The body is exactly the token,
 * the company and the plan, and, when the invitation brings staff, the indexes of those the
 * customer keeps: the model, the staff themselves and their roles come from the invitation.
 */
export async function acceptInvitation(
   token: string,
   company: Record<string, string>,
   planId: string | null,
   staff?: number[]
) {
   const body = { token, company, plan_id: planId, ...(staff ? { staff } : {}) };
   const { data, error } = await supabase.functions.invoke<{ tenant_id: string; error?: string }>(
      'provider-invitation/accept',
      { method: 'POST', body }
   );
   if (error) throw await named(error);
   if (data?.error) throw new InvitationError(String(data.error));
   return data as { tenant_id: string };
}

/** Sets the invitee's password and marks it set, so the preview no longer asks for one. */
export async function setInvitationPassword(password: string) {
   const { error } = await supabase.auth.updateUser({ password, data: { password_set: true } });
   if (error) throw error;
}
