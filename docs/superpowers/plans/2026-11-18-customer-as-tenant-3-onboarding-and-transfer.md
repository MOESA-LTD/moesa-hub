# Customer = Tenant, Plan 3 of 3: Onboarding, Tenant Transfer and Walk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Customers join by the provider's invitation (one step creates their tenant, the accepted relationship, the provider staff memberships with stored roles, and starts sharing), choose a plan from a side-by-side explanation, open self-signup sits behind a platform setting that is off by default, the general tenant-to-tenant copy/move tool replaces M21 with a rights gate in both tenants, and the four-user browser walk passes.

**Architecture:** The invitation token is generated in the database, stored only as a SHA-256 hash, and never returned to the provider: the `provider-invitation` Edge Function creates the invitation with the service role after checking the caller's rights, then has Supabase Auth mail the link (an invite e-mail for a new address, a magic link for an existing account) with the token in the redirect URL. So the person who opens the link has proven control of the invited address, and every acceptance runs as that signed-in user: `public.accept_provider_invitation` checks the e-mail claim against the stored address and reads the procurement model, staff and roles only from the stored invitation. The transfer tool ports the M21 engine from git history (`git show 055b03b:supabase/migrations/04[0-5]_*.sql`), keeps its product-only path (dry-run report, decisions, id map, file copy) and replaces "owner of both companies" with table and field rights in both tenants. New migrations `070`–`074`.

**Tech Stack:** Postgres 15 + pgTAP + pgcrypto, Supabase Auth (GoTrue admin API), Deno Edge Functions, Vue 3.5 + PrimeVue 4 + TanStack Query + CASL + zod, vitest.

**Spec:** `docs/superpowers/specs/2026-11-18-customer-as-tenant-design.md` (decisions 2, 5, 6, 11, 14, 16–18; "Calls made": relationship needs both sides). Depends on Plans 1 and 2 (`docs/superpowers/plans/2026-11-18-customer-as-tenant-1-foundation.md`, `…-2-sharing.md`).

## Global Constraints

- Invitation records "the customer's e-mail and company name; the procurement model; the contract terms; the provider staff who will work in the new tenant, with their roles." Acceptance "creates the customer's tenant, with the customer as owner; creates the provider relationship, already accepted; adds the chosen provider staff with their roles; starts sharing if the provider procures."
- "Invitations expire, are single-use and can be revoked by the provider." "The invited e-mail must match the account that accepts the invitation. If the address already has an account, they sign in instead of signing up."
- Only a hash of the token is stored. The accepting user can never choose the provider staff, their roles or the procurement model.
- "Open self-signup is closed by default. It sits behind a platform setting … With the setting on, it is today's flow: a standalone tenant with no relationship."
- Plan step: "each plan side by side: its modules, its limits, who it suits, and what changes later if they upgrade or downgrade." "The provider may mark a recommended plan … The customer can still choose another." Payment collection is out of scope; "The chosen plan becomes the tenant's subscription, as today."
- Transfer: "the caller must hold the needed table and field rights in both the source and the target tenant." "Rows already created stay where they were created."
- No "MOESA" in schema, error codes or copy.
- Every new definer callable by `authenticated` is added to the 064 allowlist; service-role-only functions get `REVOKE … FROM PUBLIC, anon, authenticated` and `GRANT EXECUTE … TO service_role`.

- pgTAP snippets write fixture values as `:'name'`. psql does not interpolate inside `$$`, so write them as the existing tests do: a fixed UUID literal (`'00000000-0000-4000-8000-0000000NNNNN'`) or `current_setting('test.<name>')::UUID` set by the fixture. Helpers named `tests.*` are added to `private.create_test_helpers()` by the task that first uses them.
## Review Focus

- **A provider invites an address that already owns a tenant:** the magic-link path signs them in and acceptance creates a second tenant they own; the first is untouched (Task 4 test `an existing owner accepts into a new tenant`).
- **Provider staff named in the invitation leave the provider before acceptance:** acceptance skips them and reports them in its result; it does not fail and does not add a non-member (Task 4 test `a departed staff member is skipped`).
- **The chosen plan's user limit is lower than 1 + the number of provider staff:** acceptance fails with `plan_limit_users` and nothing is created; the plan step disables such plans with the reason (Task 4 test, Task 10 vitest `disables a plan whose user limit is below the invitation's seats`).
- **Two tabs accept the same invitation at once:** exactly one tenant is created (Task 7 HTTP test `concurrent acceptance creates one tenant`).
- **A transfer that moves a client product referenced by a provider order line:** the dry-run report lists the provider rows that will lose their product link (snapshots remain), and the move proceeds (Task 12 test `report lists cross-tenant links left behind`).

---

## File Structure

- Create migrations: `supabase/migrations/070_signup_and_plans.sql`, `071_provider_invitation.sql`, `072_transfer_core.sql`, `073_transfer_copy.sql`, `074_transfer_files.sql`
- Create tests: `supabase/tests/database/070_signup_and_plans.test.sql`, `071_provider_invitation.test.sql`, `072_transfer_core.test.sql`, `073_transfer_copy.test.sql`, `074_transfer_files.test.sql`
- Create Edge Function: `supabase/functions/provider-invitation/index.ts`; modify `supabase/functions/create-account/index.ts`, `supabase/functions/user/index.ts`, `supabase/config.toml`
- Deno tests: `supabase/functions/tests/provider_invitation_test.ts`, `create_account_test.ts`, `user_test.ts`; HTTP: `supabase/functions/http-tests/invitation_http_test.ts`, `transfer_http_test.ts`
- App: `app/src/api/invitation/index.ts`, `app/src/api/platform/index.ts`, `app/src/lib/planDiff.ts`, `app/src/components/service-components/plan-compare/PlanCompare.vue`, `app/src/views/pages/ops/client/` (relationships, invitations), `app/src/views/pages/auth/invitation/`, `app/src/views/pages/ops/transfer/` (restored and reshaped), `app/src/api/transfer/index.ts`, `app/src/views/pages/admin/platform/Index.vue`
- Seeds: `supabase/seed.sql` (platform setting row), `supabase/seed_story.sql`, `supabase/seed_story.check.sql`

---

### Task 1: Platform setting and plan audience

**Files:**
- Create: `supabase/migrations/070_signup_and_plans.sql` (section 1)
- Modify: `supabase/functions/create-account/index.ts`
- Test: `supabase/tests/database/070_signup_and_plans.test.sql`, `supabase/functions/tests/create_account_test.ts`

**Interfaces:**
- Produces:
  - `private.platform_setting (key TEXT PRIMARY KEY, value JSONB NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_by UUID)`; row `('open_signup', 'false')` inserted by the migration.
  - `public.platform_settings() RETURNS JSONB` SECURITY DEFINER (super admin only, else 42501 `super_admin_required`); `public.set_platform_setting(key TEXT, value JSONB) RETURNS JSONB` SECURITY DEFINER (super admin only; `key` must already exist: `platform_setting_unknown`).
  - `public.open_signup_enabled() RETURNS BOOLEAN` SECURITY DEFINER, `GRANT EXECUTE … TO service_role` only.
  - `public.plan.audience TEXT NULL` ("who it suits", editable in the admin plan editor; `save_plan` accepts it).
  - `create-account`: `GET` → `200 { open: boolean }`; `POST` when closed → `403 { code: 'signup_closed' }` before any user is created; when open, unchanged.
- [ ] **Step 1: Failing tests.** `070_signup_and_plans.test.sql` (`SELECT plan(6)`; section 2 adds 4 → final `plan(10)`):

```sql
SELECT is((SELECT value FROM private.platform_setting WHERE key = 'open_signup'), 'false'::JSONB, 'open signup is off by default');
SELECT is(public.open_signup_enabled(), FALSE, 'open_signup_enabled reads it');
SELECT ok(NOT has_function_privilege('authenticated', 'public.open_signup_enabled()', 'EXECUTE'), 'only the service role asks');
SELECT tests.authenticate_as('ayse@moesa-panel.test');
SELECT throws_ok($$ SELECT public.set_platform_setting('open_signup', 'true') $$, '42501', NULL, 'a company owner cannot open signup');
SELECT tests.authenticate_as('admin@moesa-panel.test');
SELECT lives_ok($$ SELECT public.set_platform_setting('open_signup', 'true') $$, 'the super admin can');
SELECT has_column('public', 'plan', 'audience', 'plans say who they suit');
```
  `create_account_test.ts`: `Deno.test('POST is refused with signup_closed when the setting is off')` (stub `rpc('open_signup_enabled')` → `false`; assert status 403, body code `signup_closed`, and `auth.admin.createUser` never called); `Deno.test('GET reports the setting')`.
- [ ] **Step 2: Run** `cd supabase && supabase db reset && supabase test db --file tests/database/070_signup_and_plans.test.sql` and `cd supabase/functions && deno task test` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both → PASS.
- [ ] **Step 5: Commit** `feat(onboarding): open self-signup behind a platform setting, off by default`.

---

### Task 2: Company creation and standard roles, shared by signup and invitation

**Files:**
- Modify: `supabase/migrations/070_signup_and_plans.sql` (section 2), `supabase/migrations/009_init_rpc.sql` (`public.register_tenant` delegates), `supabase/seed.sql` (`private.seed_ops_roles`/`seed_client_roles` call the new function)
- Test: `supabase/tests/database/070_signup_and_plans.test.sql` (section 2)

**Interfaces:**
- Produces:
  - `private.create_company(p_owner UUID, p_company JSONB, p_plan_id UUID) RETURNS public.tenant` SECURITY DEFINER: inserts the tenant from the allowlisted keys `display_name, legal_name, email, phone, website, country, city, district, address, tax_office, tax_number` (any other key: `company_payload_invalid`), the owner (`tenant_owner`) and membership (`tenant_user`), runs `private.create_standard_roles`, and leaves the subscription to `private.subscribe_new_company`, then sets it to `p_plan_id` when given (`plan_inactive` if the plan is not `is_active`), `is_trial` and `ends_at` from the plan's `trial_days` as the default subscription does.
  - `private.create_standard_roles(p_tenant UUID) RETURNS VOID`: roles `management` (every permission of the modules in the tenant's plan and of branch, user, role, audit_log), `coordinator` (the same without changing settings, users, roles, the company and its branches), `viewer` (select on product, project, purchase_order, shipment, market_matrix, media, document, provider_relationship); field defaults via `private.apply_field_defaults(role_id, profile)` with `private.field_default` rows for profile `viewer`: `sell_price` read, `contract` read, `personal_data` read. (This is the body of seed.sql's `seed_ops_roles` and Plan 1's `seed_client_roles`, moved into a migration so acceptance can use it.)
  - `public.register_tenant(owner_id UUID, company JSONB)` keeps its signature and calls `private.create_company(owner_id, company, NULL)`.
- [ ] **Step 1: Failing tests** (section 2, 4 assertions): `create_company` with a `tenant_id` key throws `company_payload_invalid`; creates three roles; owner is owner and member; with an inactive plan id throws `plan_inactive`.
- [ ] **Step 2–4: Run → FAIL; implement; run → PASS (`070` 10/10; `099_seed.test.sql` still passes).**
- [ ] **Step 5: Commit** `refactor(onboarding): one company-creation path with standard roles`.

---

### Task 3: Provider invitation table; create, rotate, revoke

**Files:**
- Create: `supabase/migrations/071_provider_invitation.sql` (section 1)
- Modify: `supabase/migrations/049_field_catalog.sql` (classification rows), `docs/superpowers/specs/2026-11-08-field-classification.md`
- Test: `supabase/tests/database/071_provider_invitation.test.sql` (section 1)

**Interfaces:**
- Produces:
  - `CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions` (if not already present).
  - Enum `public.invitation_status AS ENUM ('pending', 'accepted', 'revoked')` (expiry is `expires_at <= now()`, not a stored status).
  - `public.provider_invitation` (row lives in the provider tenant): `id UUID PK, tenant_id UUID NOT NULL`, `email TEXT NOT NULL CHECK (email = lower(email))`, `company_name TEXT NOT NULL CHECK (length(company_name) >= 3)`, `client_code TEXT NOT NULL CHECK (client_code ~ '^[A-Z]{3}$')`, `procurement_model public.procurement_model NOT NULL`, contract terms `commercial_model, packages, contract_status DEFAULT 'onboarding', start_on, deposit_rate, extra_cost_rule, eu_responsible_person`, `recommended_plan_id UUID NULL → plan`, `token_hash BYTEA NOT NULL UNIQUE`, `expires_at TIMESTAMPTZ NOT NULL DEFAULT now() + interval '14 days'`, `status public.invitation_status NOT NULL DEFAULT 'pending'`, `failed_attempts INT NOT NULL DEFAULT 0`, `accepted_at, accepted_by UUID, client_tenant_id UUID, revoked_at, created_by UUID NOT NULL, created_at, updated_at`. Partial unique index `provider_invitation_one_pending ON (tenant_id, email) WHERE status = 'pending'`; a pending invitation's `client_code` must not be used by a relationship of the tenant (`client_code_taken`).
  - `public.provider_invitation_staff (invitation_id UUID, tenant_id UUID, user_id UUID, role_name TEXT CHECK (role_name IN ('management', 'coordinator', 'viewer')), PRIMARY KEY (invitation_id, user_id))`, FK `(invitation_id, tenant_id) → provider_invitation(id, tenant_id) ON DELETE CASCADE`.
  - RLS: both tables tenant-scoped (`enable_tenant_level_security`), permissions (module `client`): select on both, update on `provider_invitation` limited to the columns `expires_at` (column grant through the api view), no insert or delete for `authenticated` (creation is service-role; revocation is an RPC). `token_hash` is classified `sensitive` group `internal_note` and no role default grants it (management included), so the api view always returns NULL for it; `failed_attempts` is open.
  - `public.create_provider_invitation(p_tenant UUID, p_actor UUID, p_invitation JSONB, p_staff JSONB) RETURNS TABLE (id UUID, token TEXT)` SECURITY DEFINER, `service_role` only. Rules: `p_actor` must hold `insert` on `public.provider_invitation` in `p_tenant` (`private.tenants_permitting(p_actor, ARRAY[p_tenant], 'public.provider_invitation', 'insert')`), else 42501 `invitation_forbidden`; allowlisted keys of `p_invitation`: `email, company_name, client_code, procurement_model, commercial_model, packages, contract_status, start_on, deposit_rate, extra_cost_rule, eu_responsible_person, recommended_plan_id` (else `invitation_payload_invalid`); each staff entry `{user_id, role_name}` names a member of `p_tenant` (`invitation_staff_invalid`); at most 50 invitations created per tenant per 24 h (`invitation_throttled`). Token: `encode(extensions.gen_random_bytes(32), 'base64')` made URL-safe (`+`→`-`, `/`→`_`, no `=`); stored `extensions.digest(token, 'sha256')`.
  - `public.rotate_provider_invitation_token(p_invitation UUID, p_actor UUID) RETURNS TEXT` SECURITY DEFINER, `service_role` only: pending invitations only (`invitation_invalid`), same right check, new token and hash, `expires_at := now() + 14 days`, `failed_attempts := 0`.
  - `public.revoke_provider_invitation(invitation_id UUID) RETURNS VOID` SECURITY DEFINER, `authenticated`: caller holds `update` on `public.provider_invitation` in its tenant; pending only; sets `status 'revoked', revoked_at now()`.
- [ ] **Step 1: Failing tests** (section 1, 9 assertions; file `SELECT plan(24)`):

```sql
SELECT ok(NOT has_function_privilege('authenticated', 'public.create_provider_invitation(uuid,uuid,jsonb,jsonb)', 'EXECUTE'), 'authenticated cannot mint tokens');
SELECT lives_ok($$ SELECT * FROM public.create_provider_invitation(:'P', :'baris', '{"email":"new@client.test","company_name":"New Client","client_code":"NEW","procurement_model":"provider"}', '[{"user_id":"' || :'koordinator' || '","role_name":"coordinator"}]') $$, 'the owner invites');
SELECT is((SELECT length(token_hash) FROM public.provider_invitation WHERE email = 'new@client.test'), 32, 'only a SHA-256 hash is stored');
SELECT is_empty($$ SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'provider_invitation' AND column_name ILIKE '%token%' AND column_name <> 'token_hash' $$, 'no column holds a plaintext token');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(:'P', :'portal', '{"email":"x@client.test","company_name":"X Ltd","client_code":"XXA","procurement_model":"provider"}', '[]') $$, '42501', NULL, 'a user without the right is refused');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(:'P', :'baris', '{"email":"y@client.test","company_name":"Y Ltd","client_code":"YYA","procurement_model":"provider","owner_id":"' || :'baris' || '"}', '[]') $$, '23514', 'invitation_payload_invalid', 'unknown keys refused');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(:'P', :'baris', '{"email":"z@client.test","company_name":"Z Ltd","client_code":"ZZA","procurement_model":"provider"}', '[{"user_id":"' || :'thomas' || '","role_name":"management"}]') $$, '23514', 'invitation_staff_invalid', 'staff must be provider members');
SELECT tests.authenticate_as_scope('koordinator', ARRAY[:'P']);
SELECT is((SELECT token_hash FROM api.provider_invitation WHERE email = 'new@client.test'), NULL, 'the api view never returns the hash');
SELECT tests.authenticate_as_scope('baris', ARRAY[:'P']);
SELECT lives_ok($$ SELECT public.revoke_provider_invitation((SELECT id FROM api.provider_invitation WHERE email = 'new@client.test')) $$, 'the provider revokes');
```
- [ ] **Step 2–4: Run → FAIL; implement; run → section 1 PASS.**
- [ ] **Step 5: Commit** `feat(onboarding): provider invitations with hashed, rotating tokens`.

---

### Task 4: Invitation preview and acceptance

**Files:**
- Modify: `supabase/migrations/071_provider_invitation.sql` (section 2), `supabase/tests/database/064_field_security_cutover.test.sql` (allowlist +2)
- Test: `supabase/tests/database/071_provider_invitation.test.sql` (section 2)

**Interfaces:**
- Produces:
  - `private.invitation_attempt (key TEXT PRIMARY KEY, window_start TIMESTAMPTZ NOT NULL, count INT NOT NULL)` and `private.invitation_throttle(p_key TEXT, p_limit INT, p_window INTERVAL) RETURNS BOOLEAN` (upsert; TRUE while `count <= p_limit` in the window). Limits: `preview:<uid>` 30 per 10 minutes, `accept:<uid>` 10 per hour; an invitation whose `failed_attempts` reaches 10 stops accepting (`invitation_invalid`) until the provider rotates it. Refusal: `RAISE SQLSTATE 'PGRST'` with `{"code":"P0001","message":"invitation_throttled"}` and status 429 (the `next_code` error shape).
  - `public.invitation_preview(token TEXT) RETURNS JSONB` SECURITY DEFINER, `authenticated`: `{ company_name, email, provider_name, procurement_model, contract: {commercial_model, packages, start_on, deposit_rate}, recommended_plan_id, expires_at, seats: 1 + staff count, needs_password: BOOLEAN (auth.users.encrypted_password empty), plans: [{ id, display_name, description, audience, price, currency, billing_period, trial_days, position, modules: [module id], limits: {limit_key: value} }] }` (active plans, ordered by `position`). Same validity and e-mail rules as acceptance, without consuming the invitation; staff identities are not returned.
  - `public.accept_provider_invitation(token TEXT, company JSONB, plan_id UUID) RETURNS JSONB` SECURITY DEFINER, `authenticated`. The exact rule:

```text
uid := auth.uid(); if uid IS NULL → 401 'invitation_invalid'
if not private.invitation_throttle('accept:' || uid, 10, '1 hour') → 429 'invitation_throttled'
h := extensions.digest(token, 'sha256')
inv := SELECT … FROM public.provider_invitation WHERE token_hash = h FOR UPDATE          -- serialises concurrent accepts
if inv IS NULL or inv.status <> 'pending' or inv.expires_at <= now() or inv.failed_attempts >= 10:
    → 404 'invitation_invalid'                                                           -- one answer for unknown, used, revoked, expired, locked
email := lower(auth.jwt() ->> 'email')                                                   -- GoTrue sets it only for a confirmed address
if email IS DISTINCT FROM inv.email:
    UPDATE … SET failed_attempts = failed_attempts + 1; → 403 'invitation_email_mismatch' -- committed: raise after an autonomous count is not possible,
                                                                                          -- so return the error JSON instead of raising (see note)
company keys ⊆ allowlist of private.create_company, minus 'email' (the company e-mail defaults to inv.email) → else 400 'invitation_payload_invalid'
t := private.create_company(uid, company || {"email": inv.email unless given}, plan_id)  -- owner, member, standard roles, subscription
UPDATE public.tenant SET code = inv.client_code WHERE id = t.id
INSERT public.provider_relationship (tenant_id = inv.tenant_id, client_tenant_id = t.id, client_code = inv.client_code,
       client_name = inv.company_name, provider_name = (provider tenant display_name), procurement_model = inv.procurement_model,
       status 'active', accepted_at now(), contract terms = inv's)
skipped := []
FOR s IN provider_invitation_staff of inv:
    if s.user_id is no longer a member of inv.tenant_id: skipped += s.user_id; continue
    INSERT tenant_user (s.user_id, t.id)                                                  -- plan_limit_users may refuse: the whole call fails
    INSERT user_role (s.user_id, role of t named s.role_name)
UPDATE inv SET status 'accepted', accepted_at now(), accepted_by uid, client_tenant_id t.id
RETURN {"tenant_id": t.id, "skipped_staff": skipped}
```
    Note on the mismatch counter: the function catches the mismatch, increments `failed_attempts`, and returns `{"error": "invitation_email_mismatch"}` without raising, so the increment commits; the Edge Function and the app map that body to 403. Everything else raises, so a failure leaves nothing behind. Sharing "starts" by itself: the provider can now create orders with `client_tenant_id = t.id` (Plan 1 guard: active, provider-procures).
  - Allowlist in `064_field_security_cutover.test.sql`: `public.invitation_preview(text)`, `public.accept_provider_invitation(text,jsonb,uuid)`, `public.revoke_provider_invitation(uuid)`.
- [ ] **Step 1: Failing tests** (section 2, 15 assertions). Fixture: invitation `inv1` for `new@client.test` (staff: koordinator as coordinator, akif as management), its token in `:'tok1'`; user `newbie` with that confirmed e-mail; user `other` with another e-mail; `inv2` for `ali@moesa-panel.test` (an existing owner of Nova Yazılım).

```sql
SELECT tests.authenticate_as('other');
SELECT is(public.accept_provider_invitation(:'tok1', '{"display_name":"New Client GmbH"}', NULL) ->> 'error', 'invitation_email_mismatch', 'wrong account refused');
SELECT is((SELECT failed_attempts FROM public.provider_invitation WHERE id = :'inv1'), 1, 'the mismatch is counted');
SELECT tests.authenticate_as('newbie');
SELECT throws_ok($$ SELECT public.accept_provider_invitation(:'tok1', '{"display_name":"New Client GmbH","procurement_model":"client"}', NULL) $$, 'PGRST', NULL, 'a payload naming the model is refused');
SELECT throws_ok($$ SELECT public.accept_provider_invitation('not-a-token', '{"display_name":"X Ltd"}', NULL) $$, 'PGRST', NULL, 'unknown token: invitation_invalid');
SELECT lives_ok($$ SELECT public.accept_provider_invitation(:'tok1', '{"display_name":"New Client GmbH","country":"Germany"}', :'pro_plan') $$, 'the invited user accepts');
SELECT ok(EXISTS (SELECT 1 FROM public.tenant_owner o JOIN public.tenant t ON t.id = o.tenant_id WHERE o.user_id = :'newbie' AND t.display_name = 'New Client GmbH'), 'the customer owns the new tenant');
SELECT results_eq($$ SELECT procurement_model::TEXT, status::TEXT, client_code FROM public.provider_relationship WHERE client_tenant_id = (SELECT id FROM public.tenant WHERE display_name = 'New Client GmbH') $$, $$ VALUES ('provider', 'active', 'NEW') $$, 'relationship from the invitation, already accepted');
SELECT set_eq($$ SELECT u.email || ':' || r.display_name FROM public.user_role ur JOIN public.role r ON r.id = ur.role_id JOIN public.user u ON u.id = ur.user_id WHERE r.tenant_id = (SELECT id FROM public.tenant WHERE display_name = 'New Client GmbH') AND u.id <> :'newbie' $$, ARRAY['koordinator@moesa-panel.test:coordinator', 'akif@moesa-panel.test:management'], 'staff and roles from the invitation');
SELECT is((SELECT p.display_name FROM public.subscription s JOIN public.plan p ON p.id = s.plan_id WHERE s.tenant_id = (SELECT id FROM public.tenant WHERE display_name = 'New Client GmbH')), 'Pro', 'the chosen plan is the subscription');
SELECT throws_ok($$ SELECT public.accept_provider_invitation(:'tok1', '{"display_name":"Again Ltd"}', NULL) $$, 'PGRST', NULL, 'single use');
SELECT tests.authenticate_as('ali@moesa-panel.test');
SELECT lives_ok($$ SELECT public.accept_provider_invitation(:'tok2', '{"display_name":"Nova Ventures"}', NULL) $$, 'an existing owner accepts into a new tenant');
SELECT is((SELECT count(*)::INT FROM public.tenant_owner WHERE user_id = (SELECT id FROM public.user WHERE email = 'ali@moesa-panel.test')), 2, 'the first tenant is untouched');
-- staff departed before acceptance; the expiry; the plan limit
SELECT is(public.accept_provider_invitation(:'tok3', '{"display_name":"Third Co"}', NULL) -> 'skipped_staff', jsonb_build_array(:'departed'), 'a departed staff member is skipped');
SELECT throws_ok($$ SELECT public.accept_provider_invitation(:'tok_expired', '{"display_name":"Late Co"}', NULL) $$, 'PGRST', NULL, 'an expired invitation is invalid');
SELECT throws_ok($$ SELECT public.accept_provider_invitation(:'tok_seats', '{"display_name":"Small Co"}', :'basic_plan_2_users') $$, NULL, 'plan_limit_users', 'a plan below the seats fails and creates nothing');
```
  (`tok3` belongs to an invitation for `third@client.test` accepted by user `third`; set the matching `tests.authenticate_as` before each. The `PGRST`-shaped errors raise SQLSTATE `PGRST` with the JSON message; where the state alone is not enough, assert the message with `throws_like(…, '%invitation_invalid%')`.)
- [ ] **Step 2–4: Run → FAIL; implement; run → `071` 24/24, `064` PASS.**
- [ ] **Step 5: Commit** `feat(onboarding): invitation preview and one-step acceptance`.

---

### Task 5: Edge Function `provider-invitation`

**Files:**
- Create: `supabase/functions/provider-invitation/index.ts`
- Modify: `supabase/config.toml` (`[functions.provider-invitation] verify_jwt = true`), `supabase/functions/_shared/http.ts` (status mapping of `invitation_*` codes if needed)
- Test: `supabase/functions/tests/provider_invitation_test.ts`

**Interfaces:**
- Produces: `export const handler(req: Request): Promise<Response>`, routes:
  - `POST /provider-invitation` `{ invitation, staff }` → `withAuthorization(req, [['insert', 'provider_invitation']])`; calls `create_provider_invitation(p_tenant: activeTenant, p_actor: caller id, …)` with the service client; then mails: `service.from('user').select('id').eq('email', email)` decides the path — existing account → `service.auth.signInWithOtp({ email, options: { shouldCreateUser: false, emailRedirectTo: `${SITE_URL}/invitation/${token}` } })`; none → `service.auth.admin.inviteUserByEmail(email, { redirectTo: `${SITE_URL}/invitation/${token}` })`. If mailing fails the invitation is revoked and the error returned. Response `201 { id }` — **never the token**.
  - `POST /provider-invitation/:id/resend` → same right (`update`), `rotate_provider_invitation_token(id, caller)` then mail as above; `200 { id }`.
  - `SITE_URL` from `Deno.env.get('SITE_URL')` (config `site_url`); `/invitation/` is added to `additional_redirect_urls` in `config.toml`.
- [ ] **Step 1: Failing tests** (`provider_invitation_test.ts`, stubs as in `user_test.ts`):
  - `Deno.test('create never returns the token')`: the stub RPC returns `{ id: 'I', token: 'T' }`; assert response body is `{ id: 'I' }` and `JSON.stringify(body)` has no `'T'`.
  - `Deno.test('an existing address gets a magic link, not an invite')`: stub user lookup returns a row; assert `signInWithOtp` called with `shouldCreateUser: false` and `emailRedirectTo` ending `/invitation/T`; `inviteUserByEmail` not called.
  - `Deno.test('a new address gets an invite e-mail')`.
  - `Deno.test('a mail failure revokes the invitation')`.
  - `Deno.test('a caller without insert is refused 403 before any RPC')`.
- [ ] **Step 2: Run** `cd supabase/functions && deno task check && deno task test` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(onboarding): provider-invitation function mails the link through Supabase Auth`.

---

### Task 6: `user` Edge Function: provider staff may join a client tenant

**Files:**
- Modify: `supabase/functions/user/index.ts`, `supabase/functions/_shared/company.ts`, `supabase/migrations/071_provider_invitation.sql` (section 3)
- Test: `supabase/functions/tests/user_test.ts`, `supabase/tests/database/071_provider_invitation.test.sql` (+1 → `plan(25)`)

**Interfaces:**
- Produces: `public.is_provider_staff(p_client UUID, p_user UUID) RETURNS BOOLEAN` SECURITY DEFINER, `service_role` only: `p_user` is a member of a tenant that has an `active` relationship with the company root of `p_client`. In `createUser`, an existing account is linked when `belongsToCompany(reach, company) || await isProviderStaff(tenantId, user.id)`; otherwise still `409 user_exists_elsewhere`. The relationship grants no read by itself: only this membership does (spec "Calls made").
- [ ] **Step 1: Failing tests:** `Deno.test('a provider staff account may be added to a client tenant')` (stub `is_provider_staff` → true; expect 201 and the `tenant_user` insert); `Deno.test('a stranger account is still refused with user_exists_elsewhere')`. pgTAP: `SELECT ok(public.is_provider_staff(:'client', :'koordinator') AND NOT public.is_provider_staff(:'client', :'ayse'), 'provider staff recognised, others not');`
- [ ] **Step 2–4: Run → FAIL; implement; run → PASS.**
- [ ] **Step 5: Commit** `feat(onboarding): client owners can add their provider's staff`.

---

### Task 7: HTTP attack tests for the invitation entry point

**Files:**
- Create: `supabase/functions/http-tests/invitation_http_test.ts`
- Modify: `supabase/functions/http-tests/helpers.ts` (`invitationSetup()`: creates invitations through `admin('/rpc/create_provider_invitation', …)` with the service role, which is the only way a test gets a plaintext token; users via the admin API)

- [ ] **Step 1: Write the tests:**
  - `'anon cannot call preview, accept or revoke'`: with the anon key only, `POST /rpc/invitation_preview`, `/rpc/accept_provider_invitation`, `/rpc/revoke_provider_invitation` → 401 or 404, never 200.
  - `'authenticated cannot mint or rotate tokens'`: `POST /rpc/create_provider_invitation`, `/rpc/rotate_provider_invitation_token` as `baris` → 404 (not exposed) or 403.
  - `'the provider app never sees a token'`: `POST /functions/v1/provider-invitation` as `baris` → 201 body keys exactly `['id']`; `GET /provider_invitation?select=*` → `token_hash` null.
  - `'a wrong account cannot accept and is counted'`: valid token, signed in as another user → 403 `invitation_email_mismatch`; admin read shows `failed_attempts = 1`.
  - `'used, revoked, expired and unknown tokens are indistinguishable'`: four requests → identical status 404 and identical body.
  - `'the accepting user cannot choose model, staff, roles or owner'`: payloads adding `procurement_model`, `staff`, `roles`, `tenant_id`, `owner_id`, `client_code` → 400 `invitation_payload_invalid`; admin read shows no tenant created.
  - `'acceptance creates tenant, accepted relationship and stored staff roles'`: then as the new owner `GET /provider_relationship` → one row, `procurement_model` as invited; as a staff member with `x-tenant-ids` = new tenant → membership works.
  - `'concurrent acceptance creates one tenant'`: two parallel accepts → statuses `{200, 404}`; admin count of tenants with that name = 1.
  - `'brute force is throttled'`: 31 previews with random tokens within the window → the 31st is 429 `invitation_throttled`; 11 accepts → 429.
  - `'ten failed attempts lock the invitation until rotated'`.
  - `'open signup is closed by default'`: `POST /functions/v1/create-account` → 403 `signup_closed`, and no auth user with that e-mail exists afterwards (admin API).
  - `'error bodies carry no token, hash or staff identity'`: the bodies of every failing request above do not contain the token, `\\x`-hex of the hash, or a staff e-mail.
- [ ] **Step 2: Run** `cd supabase/functions && deno task test:http` → PASS (a failure is a defect in Tasks 3–6).
- [ ] **Step 3: Commit** `test(http): attack suite for invitation onboarding`.

---

### Task 8: App: invitations page

**Files:**
- Create: `app/src/api/invitation/index.ts`, `app/src/views/pages/ops/client/invitations/Index.vue`, `InvitationCreate.vue`
- Modify: `app/src/router/routes/ops.ts` (`ops-client-invitations`, `ops-client-invitation-create`), menu, locales, `app/src/lib/form/postgrestErrors.ts`
- Test: `app/tests/api/invitation.test.ts`

**Interfaces:**
- Produces: `invitationResource = defineResource('provider_invitation')`; `invitationSchema` (zod: `email` lower-cased, `company_name` min 3, `client_code` `/^[A-Z]{3}$/`, `procurement_model` enum, contract terms, `recommended_plan_id` nullable, `staff: z.array(z.object({ user_id: z.string().uuid(), role_name: z.enum(['management','coordinator','viewer']) })).max(20)`); `createInvitation(values)` → `functions.invoke('provider-invitation', { body })`; `resendInvitation(id)`; `revokeInvitation(id)` → `rpc('revoke_provider_invitation')`; `invitationState(row, now): 'pending' | 'expired' | 'accepted' | 'revoked'`. The list shows state, e-mail, company, model, expiry, staff count; actions resend and revoke on pending/expired rows. Error codes mapped: `invitation_forbidden`, `invitation_payload_invalid`, `invitation_staff_invalid`, `invitation_throttled`, `invitation_invalid`, `client_code_taken`.
- [ ] **Step 1: Failing tests:** `it('invitationState reports expired from expires_at')`, `it('the create payload never carries a token or tenant_id')`, `it('staff entries are limited to the three roles')`.
- [ ] **Step 2–4: Run `cd app && pnpm test` → FAIL; implement; → PASS.**
- [ ] **Step 5: Commit** `feat(app): provider invitations page`.

---

### Task 9: App: relationships page

**Files:**
- Create: `app/src/views/pages/ops/client/Index.vue`, `Manage.vue`
- Modify: `app/src/api/relationship/index.ts` (Plan 1), router (`ops-client`, `ops-client-manage`), menu, locales
- Test: `app/tests/api/relationship.test.ts`

**Interfaces:**
- Produces: one page, two lists: "Clients" (rows where `tenant_id` is the active tenant: client name, code, model, status, contract terms, notes and Drive link for those who can read them; edit contract terms and procurement model; End) and "Providers" (rows where `client_tenant_id` is the active tenant: provider name, model, status, contract terms read-only; End for the owner). `relationshipSide(row, activeTenantId): 'provider' | 'client'`; `endRelationship(id)` → `rpc('end_provider_relationship')` with a confirm dialog that says what ending does (no new shared orders; history stays; staff memberships unchanged).
- [ ] **Step 1: Failing tests:** `it('relationshipSide is provider when the active tenant owns the row')`, `it('the client side offers no edit of contract terms')` (component test on `Manage.vue`: inputs disabled when side is `client`).
- [ ] **Step 2–4: Run → FAIL; implement; → PASS.**
- [ ] **Step 5: Commit** `feat(app): provider relationships page for both sides`.

---

### Task 10: App: invitation acceptance and plan comparison

**Files:**
- Create: `app/src/views/pages/auth/invitation/Index.vue`, `steps/AccountStep.vue`, `steps/CompanyStep.vue`, `steps/PlanStep.vue`, `app/src/components/service-components/plan-compare/PlanCompare.vue`, `app/src/lib/planDiff.ts`
- Modify: `app/src/router/routes/auth.ts` (public route `/invitation/:token`, name `auth-invitation`, no tenant required), locales
- Test: `app/tests/lib/planDiff.test.ts`, `app/tests/components/PlanCompare.test.ts`, `app/tests/views/invitation.test.ts`

**Interfaces:**
- Produces:
  - `planDiff(from: PlanSummary, to: PlanSummary): { modulesGained: string[]; modulesLost: string[]; limits: { key: string; from: number | null; to: number | null }[] }` (null = unlimited); `PlanSummary` is an element of `invitation_preview().plans`.
  - `PlanCompare.vue` props `{ plans: PlanSummary[]; recommendedId: string | null; seats: number; modelValue: string | null }`: one column per plan with modules (localised module names), limits, `audience`, price and trial; a "Recommended by <provider_name>" badge; for the selected plan, the changes to every other plan from `planDiff` ("Upgrading to X adds …", "Downgrading to Y removes … and limits users to N"); a plan whose `max_users` < `seats` is disabled with the reason.
  - Flow: the page reads the session set by the e-mail link; without a session it explains to open the link from the e-mail. Step 1 sets a password when `needs_password` (`supabase.auth.updateUser({ password })`); step 2 company details (zod: the `private.create_company` keys); step 3 plan; confirm calls `rpc('accept_provider_invitation')`, then switches to the new tenant (`auth.changeCurrentTenant`) and opens the dashboard. Errors: `invitation_invalid` → "This link is no longer valid; ask your provider for a new one."; `invitation_email_mismatch` → "You are signed in as <email>; this invitation is for another address." with sign-out.
- [ ] **Step 1: Failing tests:**
  - `planDiff.test.ts`: `it('lists modules gained and lost')`, `it('treats a missing limit as unlimited')`.
  - `PlanCompare.test.ts`: `it('marks the recommended plan')`, `it('disables a plan whose user limit is below the invitation\'s seats')` (seats 3, `max_users` 2 → disabled with text containing `3`), `it('explains a downgrade')`.
  - `invitation.test.ts`: `it('accept sends only company and plan, never model or staff')` (spy on `rpc`: argument keys exactly `['token','company','plan_id']`).
- [ ] **Step 2–4: Run → FAIL; implement; → PASS; `pnpm typecheck && pnpm lint`.**
- [ ] **Step 5: Commit** `feat(app): invitation acceptance with a side-by-side plan step`.

---

### Task 11: App: register page and platform setting

**Files:**
- Modify: `app/src/views/pages/auth/register/Index.vue`, `app/src/views/pages/auth/Login.vue` (hide the sign-up link when closed), `app/src/views/pages/admin/plans/*` (the `audience` field)
- Create: `app/src/api/platform/index.ts`, `app/src/views/pages/admin/platform/Index.vue`; router `admin-platform`
- Test: `app/tests/api/platform.test.ts`, `app/tests/views/register.test.ts`

**Interfaces:**
- Produces: `useSignupOpen()` → `functions.invoke('create-account', { method: 'GET' })` → `{ open }`; the register page shows "Sign-up is by invitation" when closed; `usePlatformSettings()`/`setPlatformSetting(key, value)` (super admin page with the `open_signup` toggle).
- [ ] **Step 1: Failing tests:** `it('register shows the invitation notice when signup is closed')`, `it('setPlatformSetting calls the RPC with key and value')`.
- [ ] **Step 2–4: Run → FAIL; implement; → PASS.**
- [ ] **Step 5: Commit** `feat(app): sign-up by invitation unless the platform opens it`.

---

### Task 12: Tenant transfer: registry, rehearsal and the rights gate

**Files:**
- Create: `supabase/migrations/072_transfer_core.sql` (ported from `git show 055b03b:supabase/migrations/040_transfer_core.sql` and `042_transfer_rehearsal.sql`, reshaped)
- Test: `supabase/tests/database/072_transfer_core.test.sql` (ported from `040_transfer_core.test.sql` and `042_transfer_rehearsal.test.sql` at 055b03b, reshaped)

**Interfaces:**
- Reuse decision: keep M21's registry-driven engine, its product-only path, dry-run report with conflicts and decisions, id map, revert guard and file list; drop the customer root, projects, orders, shipments, incidents, change requests and listing submissions from the registry (they stay where they were created, decision 13), drop the cheap path (044) and code renumbering. Rationale: the product-only path already copied "products and their linked records" between tenants and is tested; the rest existed only for the customer package.
- Produces:
  - `public.transfer` (as at 055b03b without `customer_id`, `target_customer_id`, `path`): `id, tenant_id` (target), `source_tenant_id, product_ids UUID[] NOT NULL, mode public.transfer_mode ('copy','move'), started_by, report, decisions, id_map, files, files_status, missing_files, audit_transaction_ids, xact_id, created_at, updated_at`. Module `transfer` re-added; permissions select and insert on `public.transfer`.
  - `private.transfer_registry` rows, in order: `supplier` (copy_only), `supplier_contact` (copy_only), `product`, `sourcing` (the source tenant's own rows, `client_tenant_id IS NULL`, for the package products), `market_cell` (listing columns reset to NULL: `listing_state, listing_checked_at, listing_match`), `media` (copy_only), `media_link` (entity), `document` (entity). `root` CHECK becomes `('product', 'supplier')`.
  - `private.transfer_refusal(p_source UUID, p_target UUID, p_mode TEXT) RETURNS TEXT`, the gate, in this order (first failure returned; NULL = allowed):

```text
1 mode not in (copy, move)                                                  → 'transfer_mode_invalid'
2 p_source = p_target                                                       → 'transfer_same_tenant'
3 caller not a member or owner of both (private.allowed_tenant())          → 'transfer_forbidden'      -- no super-admin bypass
4 target read-only (subscription locked/expired) or plan lacks module product → 'transfer_target_unavailable'
5 table rights: public.transfer insert in both; for every registry table T: select in p_source,
  insert in p_target (copy_only tables: insert in p_target only when T has an insert permission row);
  move: delete in p_source for every non-copy_only T                       → 'transfer_permissions_required'
6 field rights, from the catalog: for every registry table T and every field F of 'public.'||T classified sensitive:
  read in p_source and write in p_target, and for move also write in p_source
  (private.field_tenants(uid, ARRAY[x], 'public.'||T, F, write) = ARRAY[x]) → 'transfer_field_rights_required'
7 move out of a read-only source                                            → 'transfer_source_read_only'
8 an earlier transfer into p_target whose files are not all copied         → 'transfer_files_pending'
```
    Rule 6 is M21's S3 gate generalised to the direction of the data; a table or sensitive field added to the registry or the catalog is covered without a code change.
  - `private.transfer_collect(p_source UUID, p_product_ids UUID[])` and `private.transfer_report(...)` as at 055b03b for the product-only path; the report adds `left_behind_links`: rows of other tenants that reference a package product through a client link (`sourcing`, `purchase_order_line` with `product_tenant_id = p_source`), counted per table, so a move warns that those rows keep only their snapshot.
  - `public.transfer_options(source_tenant UUID) RETURNS JSONB` and `public.transfer_products(source_tenant UUID, target_tenant UUID, product_ids UUID[], mode TEXT, decisions JSONB DEFAULT NULL, rehearse BOOLEAN DEFAULT TRUE) RETURNS JSONB` (rehearse → the report; else the transfer row as `api.transfer` JSON), both SECURITY DEFINER, `authenticated`, added to the 064 allowlist.
- [ ] **Step 1: Port and reshape the tests.** Keep every M21 assertion that applies to the product-only path; delete the customer, project, order, shipment, incident and change-request cases; add (and set the file's `plan(n)` to the final count):

```sql
SELECT is(private.transfer_refusal_as(:'akif', :'P', :'C', 'copy'), NULL, 'rights in both tenants allow a copy');
SELECT is(private.transfer_refusal_as(:'koordinator_no_cost_in_C', :'P', :'C', 'copy'), 'transfer_field_rights_required', 'missing cost write in the target refuses');
SELECT is(private.transfer_refusal_as(:'akif_no_delete', :'C', :'P', 'move'), 'transfer_permissions_required', 'a move needs delete in the source');
SELECT is(private.transfer_refusal_as(:'thomas', :'C', :'K', 'copy'), 'transfer_forbidden', 'a tenant the caller is not in');
SELECT is(private.transfer_refusal_as(:'admin', :'C', :'P', 'copy'), 'transfer_forbidden', 'no super-admin bypass');
SELECT ok((public.transfer_products(:'C', :'P', ARRAY[:'client_product']::UUID[], 'move', NULL, TRUE) -> 'left_behind_links' ->> 'purchase_order_line')::INT >= 1, 'report lists cross-tenant links left behind');
```
  (`private.transfer_refusal_as(user, source, target, mode)` is a test helper in `private.create_test_helpers()` that impersonates `user` and calls `transfer_refusal`; the report assertion runs as `akif` with C and P in scope.)
- [ ] **Step 2: Run** `cd supabase && supabase db reset && supabase test db --file tests/database/072_transfer_core.test.sql` → FAIL.
- [ ] **Step 3: Implement** `072_transfer_core.sql`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(transfer): general tenant-to-tenant product transfer, rehearsal and rights gate`.

---

### Task 13: Tenant transfer: copy, move and files

**Files:**
- Create: `supabase/migrations/073_transfer_copy.sql` (from `041_transfer_triggers.sql` and `043_transfer_copy.sql` at 055b03b), `074_transfer_files.sql` (from `045_transfer_files.sql`)
- Test: `supabase/tests/database/073_transfer_copy.test.sql`, `074_transfer_files.test.sql` (ported)

**Interfaces:**
- Produces: `private.transferring()` and the rules bypass as at 055b03b; `private.transfer_build_map`, `private.transfer_write`, `private.transfer_apply_copy`, `private.transfer_apply` (move = copy then `private.transfer_delete_source` of non-copy_only rows); `public.transfer_check_files(transfer_id UUID) RETURNS api.transfer`. Copied product SKU clashes are decided by the report's decisions (`rename` with a suffix, or `skip`), as M21's code conflicts were. Copied rows get the target's `tenant_id`; a client link of a copied `sourcing` row is never created (copied sourcing has `client_tenant_id` NULL). `api.transfer` is enabled with `private.enable_field_security('transfer', TRUE)`.
- [ ] **Step 1: Port the tests**; add `SELECT results_eq($$ SELECT tenant_id, client_tenant_id FROM public.sourcing WHERE product_id = :'copied_product' $$, $$ VALUES (:'P'::UUID, NULL::UUID) $$, 'copied sourcing lands in the target without a client link');` and `SELECT ok(NOT EXISTS (SELECT 1 FROM public.product WHERE id = :'moved_product'), 'a move removes the source product');` with `SELECT is((SELECT product_sku FROM public.purchase_order_line WHERE id = :'provider_line'), 'THO-MOP', 'the provider line keeps its snapshot after the move');`.
- [ ] **Step 2–4: Run → FAIL; implement; run `cd app && pnpm test:db` → PASS, `api_view_drift()` empty.**
- [ ] **Step 5: Commit** `feat(transfer): copy and move products with their files between tenants`.

---

### Task 14: HTTP attack tests for the transfer

**Files:**
- Create: `supabase/functions/http-tests/transfer_http_test.ts`

- [ ] **Step 1: Write the tests:**
  - `'a transfer needs field rights in both tenants'`: a user with every table right but no `cost` write in the target → `POST /rpc/transfer_products` 403/409 body `transfer_field_rights_required`; nothing written (admin count unchanged).
  - `'a transfer into a tenant the caller is not in is refused without detail'`: body `transfer_forbidden`, no tenant name in the body.
  - `'the report shows masked values only'`: a rehearsal by a user without `cost` read in the source → the report holds no `purchase_price` value (body does not contain the seeded `987654.32`).
  - `'a client owner cannot transfer a provider sourcing row'`: `product_ids` of the client's product, source = provider tenant → `transfer_forbidden`.
- [ ] **Step 2: Run** `cd supabase/functions && deno task test:http` → PASS.
- [ ] **Step 3: Commit** `test(http): transfer rights gate over HTTP`.

---

### Task 15: App: transfer wizard

**Files:**
- Restore and reshape from 055b03b: `app/src/views/pages/ops/transfer/` (`Transfer.vue`, `TargetStep.vue`, `ReportStep.vue`, `ConflictDecision.vue`, `ResultStep.vue`, `useTransferWizard.ts`), `app/src/api/transfer/index.ts`, `app/tests/api/transfer.test.ts`, `app/tests/components/TransferFilesNotice.test.ts`
- Modify: router (`ops-transfer`), menu, locales

**Interfaces:**
- Produces: the wizard starts from the product list (selection → "Copy or move to another company"); steps: target (from `transfer_options(source)`, each target with its refusal reason), report (counts, SKU conflicts with decisions, `left_behind_links` warning), result (files progress via `transfer_check_files`). `useTransferWizard()` keeps M21's shape without `customerId`/`targetCustomerId`.
- [ ] **Step 1: Failing tests:** `it('transferProducts sends source, target, product ids and mode only')`, `it('shows the left-behind warning when the report has links')`.
- [ ] **Step 2–4: Run → FAIL; implement; → PASS.**
- [ ] **Step 5: Commit** `feat(app): product transfer wizard between companies`.

---

### Task 16: Story seed: an invitation-born tenant and a transfer step

**Files:**
- Modify: `supabase/seed_story.sql`, `supabase/seed_story.check.sql`, `supabase/seed.sql` (`private.platform_setting` row stays `false`)

**Interfaces:**
- Produces: step 02 creates LEA (Leafline Garten GmbH) through the real path: `public.create_provider_invitation` (as service role, actor `baris@`) then `public.accept_provider_invitation` as `owner.lea@moesa-panel.test` with plan Pro, so the story exercises acceptance; the other story clients keep direct inserts. Step 10 is new: `akif@` (management in THO and MOESA Europe) copies THO's 6 mm filter into MOESA Europe with `public.transfer_products(..., rehearse => FALSE)`. Checks: `onboarding.lea_by_invitation` (invitation `accepted`, relationship `active`, koordinator is a LEA coordinator), `transfer.copy_done` (the copy exists in MOESA Europe with the source's SKU, `files_status` `done`).
- [ ] **Step 1: Write the steps and checks.**
- [ ] **Step 2: Run** `cd supabase && supabase db reset && cd ../app && pnpm dev:seed-story` → exit 0, the new checks `ok`.
- [ ] **Step 3: Commit** `feat(seed): story onboards a client by invitation and copies a product`.

---

### Task 17: Browser walk and final verification

**Files:** none new (fixes only).

- [ ] **Step 1: Run** `cd app && pnpm test:db && pnpm test && pnpm typecheck && pnpm lint && pnpm build` → all exit 0.
- [ ] **Step 2: Run** `cd supabase/functions && deno task check && deno task test && deno task test:http` → all pass (field security, shared rows, invitation, transfer suites).
- [ ] **Step 3: Run** `cd app && pnpm perf:fields` → within R10 (reads max(+15%, +5 ms) internal, max(+40%, +10 ms) restricted; writes +15 ms).
- [ ] **Step 4: Browser walk** after `cd supabase && supabase db reset && cd ../app && pnpm dev:seed-story && pnpm dev`, password `Demo1234!`, one screenshot per bullet saved under `docs/superpowers/research/customer-as-tenant/walk/`:
  - `koordinator@` (provider staff): picks MOESA LTD + THOMETZKI in the tenant picker; a THO product shows MOESA LTD's sourcing (cost, supplier, sell price) beside it; a THO order shows PI figures; the relationships page lists THO, KRN and LEA; creates an invitation (the success toast shows no link); KRN's orders are visible only with KRN in scope.
  - `thomas@` (THO owner, provider-procured): the orders list shows MOESA LTD's orders for THO tagged "From MOESA LTD", read-only, with status, dates, quantities, products, sell price per line, shipment ETA and tracking, and no purchase price, supplier, payments, deposit or notes; the role editor's "Shared by a provider" section offers only client-visible fields; the Providers list shows the contract terms and no Drive link.
  - `portal@` (THO viewer): the same orders without the sell price; no edit actions anywhere on shared rows.
  - `kerstin@` (KRN owner, client-procures): her own orders show cost, supplier and payments; no provider order is listed.
- [ ] **Step 5: Run** `grep -rn "MOESA" supabase/migrations supabase/functions app/src` → matches only inside `private.field_test_fixtures` in `050_field_rights.sql` (test support naming seed tenants); anything else is a hard-coded operator name in schema or copy and is removed (spec anti-goal).
- [ ] **Step 6: Commit** fixes as `chore(tenancy): final verification fixes`; the walk screenshots as `docs(tenancy): browser walk evidence`.
