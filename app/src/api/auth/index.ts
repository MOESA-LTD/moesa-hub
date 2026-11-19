import { named } from '@/api/auth/signup';
import { companySchema, toCompany } from '@/api/invitation/accept';
import { email, requiredText } from '@/lib/form/fields';
import { supabase } from '@/lib/supabase';
import type { VerifyOtpParams } from '@supabase/supabase-js';
import * as z from 'zod';

export const loginSchema = z.object({
   email: email(),
   password: requiredText()
});

/** A single e-mail address, e.g. to send a reset link or a new code to. */
export const emailSchema = z.object({ email: email() });

export const otpSchema = z.object({
   email: email(),
   code: z.string().length(6)
});

/**
 * Self-signup: the owner's e-mail and the company, no password (supabase/functions/create-account
 * is verify-first: the password is set after the mailed link has proven the inbox).
 */
export const registerSchema = z.object({
   account: z.object({ email: email() }),
   company: companySchema
});

export type RegisterFormValues = z.input<typeof registerSchema>;

/**
 * Asks for an account: create-account mails a link to the address and answers the same whether or
 * not it is known (202 check_email). Refusals (signup_closed, signup_throttled,
 * signup_payload_invalid) are thrown as a SignupError.
 */
export async function createAccount({ account, company }: z.output<typeof registerSchema>) {
   const { error } = await supabase.functions.invoke('create-account', {
      body: { account: { email: account.email }, company: toCompany(company) }
   });
   if (error) throw await named(error);
}

export async function verifyOtp(email: string, code: string, type: VerifyOtpParams['type']) {
   const { error } = await supabase.auth.verifyOtp({ email, token: code, type } as VerifyOtpParams);
   if (error) throw error;
}
