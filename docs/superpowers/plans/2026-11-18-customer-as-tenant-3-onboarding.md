# Customer = Tenant, Plan 3: Onboarding by Invitation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A provider invites a customer with a single-use, expiring, revocable link. Accepting it creates the customer's tenant, the accepted relationship, the staff memberships and the chosen plan in one step. Open self-signup sits behind a platform setting that is off by default. Both entry points explain the plans side by side.

**Architecture:**
- **Data.** Invitations are rows in the provider tenant: `public.client_invitation` plus `public.client_invitation_staff`.
  - Each token is 32 random bytes shown once; only its SHA-256 is kept, in `private.client_invitation_token`, which no API role can read.
  - Users create and revoke invitations through two definer RPCs.
- **The public entry point.** It is the new Edge Function `client-invitation`.
  - It validates a strict body, throttles by IP and by token, and creates the auth account with the invitation's e-mail (never one from the body), or requires sign-in when the account exists.
  - It then calls one service-only database function, `public.accept_client_invitation`. That function locks the invitation and does tenant, relationship, roles, staff and plan in one transaction.
  - Staff, roles, procurement model and terms come only from the stored invitation.
- **Plans.** They gain an `audience` text. `public.signup_plans()` gives the chooser the modules and limits. Self-signup reads `public.self_signup_enabled()`.

**Tech Stack:** Supabase (Postgres 15, pgcrypto in `extensions`, PostgREST, Auth admin API), Deno Edge Functions (zod), Vue 3.5 + PrimeVue 4 (Stepper) + TanStack Query 5, vitest 3.

**Spec:** `docs/superpowers/specs/2026-11-18-customer-as-tenant-design.md`, section "Onboarding" (owner decisions 16–18), plus "Calls made": "The relationship needs both sides… Sharing starts only after acceptance."

**Series:** Plan 3 of 4. It requires Plans 1 and 2: `private.create_ops_roles`, `private.create_provider_relationship`, `public.provider_relationship` and the `provider` module.

## Global Constraints

- Decision 16: the invitation records "the customer's e-mail and company name; the procurement model; the contract terms; the provider staff who will work in the new tenant, with their roles." The customer "sets a password, completes the company details and picks a plan".
- Decision 16, acceptance: "That single step does four things: creates the customer's tenant, with the customer as owner; creates the provider relationship, already accepted; adds the chosen provider staff with their roles; starts sharing if the provider procures."
- Decision 16, the token: "Invitations expire, are single-use and can be revoked by the provider." And: "The invited e-mail must match the account that accepts the invitation. If the address already has an account, they sign in instead of signing up."
- Decision 17: "Open self-signup is closed by default. It sits behind a platform setting… With the setting on, it is today's flow: a standalone tenant with no relationship."
- Decision 18: "The plan step shows each plan side by side: its modules, its limits, who it suits, and what changes later if they upgrade or downgrade." "The provider may mark a recommended plan… The customer can still choose another." "Payment collection is out of scope."
- Calls made in this plan (owner may overrule):
  1. **The link is shown once to the provider to copy and send.** The panel sends no e-mail of its own, because it has no mail service besides Auth's.
  2. **The token travels in the URL fragment** (`/auth/invitation#t=<token>`), so it never reaches server logs or `Referer` headers. The page strips it from the address bar at once.
  3. **"Roles" of invited staff are the built-in profiles** `management` and `coordinator`. The client tenant does not exist yet, so it has no roles to pick. `private.create_ops_roles` creates them at acceptance.
  4. **Attach an existing company.** A signed-in invitee who already owns a root company may attach it instead of creating one (`p_tenant`). The plan then stays as it is. This is the "client owner accepts" path for existing tenants.
  5. **Default validity** is 14 days, allowed between 1 and 30. After 5 e-mail mismatches the invitation is dead.
  6. **Throttle:** 30 requests per 10 minutes per client IP and 10 per 10 minutes per token, answering 429. Tokens are 256-bit, so the throttle limits abuse of account creation and lookups, not guessing.
- Migrations: `073_platform_setting.sql` and `074_client_invitation.sql` are new. Edge Function: `supabase/functions/client-invitation/`, with `verify_jwt = true` in `supabase/config.toml` (the app calls it with the anon key, and a signed-in invitee with their token).
- Error codes:

  | code | status |
  |---|---|
  | `self_signup_closed` | 403 |
  | `invitation_invalid` | 404, the one answer for unknown, expired, revoked, used or locked |
  | `invitation_email_mismatch` | 403 |
  | `invitation_sign_in_required` | 409 |
  | `invitation_tenant_invalid` | 400 |
  | `invitation_invalid_input` | 400 |
  | `invitation_not_found` | 404 |
  | `plan_unavailable` | 409 |
  | `plan_user_limit` | 409 |
  | `too_many_requests` | 429 |
  | `super_admin_required` | 403 |

  Each gets `errors.<code>` in `en`/`tr` and a `NAMED_ERRORS` entry.
- pgTAP, i18n, definer, commit and command conventions as in Plans 1 and 2. `service_role`-only functions: `REVOKE ALL … FROM PUBLIC, anon, authenticated; GRANT EXECUTE … TO service_role`. `anon`-callable functions are listed in the allowlist test of `064_field_security_cutover.test.sql` with a comment.

## Review Focus

- **Two acceptances of the same link at once** (double click, two tabs). Exactly one tenant is created and the second gets `invitation_invalid`. Pinned in Tasks 4 and 6.
- **The invited e-mail typed with different case or spaces**, at creation or by the accepting account. It is matched after `lower(btrim())`, and a real mismatch is refused. Pinned in Tasks 3 and 4.
- **A staff member listed in the invitation leaves the provider before acceptance.** They are skipped and reported, and acceptance still succeeds. Pinned in Task 4.
- **The chosen plan is deactivated after lookup, or its user limit is below 1 + staff.** Acceptance is refused with nothing created, and the new auth account is deleted again. The chooser disables such plans. Pinned in Tasks 4, 5 and 7.
- **Acceptance fails after the account was created** (any DB error). The account is deleted, so the invitee can retry with the same link. Pinned in Task 5.

---

### Task 1: Platform setting and the self-signup gate

**Files:**
- Create: `supabase/migrations/073_platform_setting.sql`, `supabase/tests/database/073_platform_setting.test.sql`, `supabase/functions/create-account/handler.ts`, `supabase/functions/tests/create_account_test.ts`.
- Modify: `supabase/functions/create-account/index.ts` (it calls the handler).

**Interfaces:**
- Produces:
  - `private.platform_setting (key TEXT PRIMARY KEY CHECK (key ~ '^[a-z_]+$'), value JSONB NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_by UUID)`, seeded with `('self_signup', 'false')`.
  - `public.self_signup_enabled() RETURNS BOOLEAN`: STABLE SECURITY DEFINER, executable by `anon`, `authenticated` and `service_role`; returns `coalesce((value)::BOOLEAN, FALSE)`.
  - `public.platform_settings() RETURNS JSONB` and `public.set_platform_setting(p_key TEXT, p_value JSONB) RETURNS VOID`: super admin only, else `super_admin_required`. Known keys are `{"self_signup": boolean}`; any other key or type raises `invitation_invalid_input`.
  - `handleCreateAccount(req: Request, deps: { rpc: RpcFn; createUser: CreateUserFn; deleteUser: (id: string) => Promise<void> }): Promise<Response>` in `handler.ts`, which first checks `rpc('self_signup_enabled')`.

- [ ] **Step 1: Write the failing tests.** `073_platform_setting.test.sql` with `plan(7)`:
  - `is(public.self_signup_enabled(), FALSE)`;
  - `ok(has_function_privilege('anon', 'public.self_signup_enabled()', 'EXECUTE'))`;
  - `ok(NOT has_table_privilege('authenticated', 'private.platform_setting', 'SELECT'))`;
  - as `baris`: `throws_like(set_platform_setting('self_signup','true'), '%super_admin_required%')`;
  - as `admin@`: `lives_ok(...)`;
  - `is(public.self_signup_enabled(), TRUE)`;
  - `throws_like(set_platform_setting('self_signup','"yes"'), '%invitation_invalid_input%')`.

  `create_account_test.ts`:

```ts
Deno.test('create-account refuses when self-signup is closed', async () => {
   const calls: string[] = [];
   const res = await handleCreateAccount(req(validBody), { rpc: async (fn) => (calls.push(fn), { data: false, error: null }), createUser: () => { throw new Error('must not create'); }, deleteUser: async () => {} });
   assertEquals(res.status, 403);
   assertEquals((await res.json()).code, 'self_signup_closed');
});
```

- [ ] **Step 2: Run and confirm both fail.** `pnpm test:db` FAILS; `cd supabase/functions && deno task test` FAILS.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test:db`, `deno task check && deno task test`: PASS.
- [ ] **Step 5: Commit** with `feat(signup): open self-signup behind a platform setting, off by default`.

### Task 2: Plans that explain themselves

**Files:**
- Modify (in `073_platform_setting.sql`):
  - `public.plan` adds `audience TEXT` (its `field_class` row is open; re-run `enable_field_security('plan')`);
  - `public.save_plan` is redefined from its latest migration to write `audience`;
  - `DROP FUNCTION public.register_tenant (UUID, JSONB)` and create `public.register_tenant(owner_id UUID, company JSONB, plan_id UUID DEFAULT NULL) RETURNS public.tenant`, which still calls `private.create_ops_roles`.
- Modify: `supabase/functions/create-account/handler.ts` (optional `plan_id: z.string().uuid().optional()`), `app/src/views/pages/admin/plans/Upsert.vue`, `app/src/api/admin/*` (the plan save), `app/tests/api/admin.test.ts`.
- Test: `supabase/tests/database/073_platform_setting.test.sql` (+6), `supabase/functions/tests/create_account_test.ts` (+1).

**Interfaces:**
- Produces:
  - `public.signup_plans() RETURNS JSONB`: STABLE SECURITY DEFINER, executable by `anon` and `authenticated`. It returns active plans ordered by `position` as `[{ id, display_name, description, audience, price, currency, billing_period, trial_days, is_default, modules: [module ids by module.position], limits: { <limit_key>: value } }]`, and nothing else: no subscription or tenant data.
  - `private.set_initial_plan(p_tenant UUID, p_plan UUID) RETURNS VOID`. It raises `plan_unavailable` unless the plan exists and `is_active`. It replaces the plan of the subscription that `subscribe_new_company` created, with `is_trial = trial_days > 0` and `ends_at` set accordingly.
  - The TS type `SignupPlan`, matching the JSON, is defined in Task 7 (`planChanges.ts`) and re-exported by `app/src/api/platform/index.ts` (Task 9).

- [ ] **Step 1: Write the failing tests** (+6):
  - `ok(has_function_privilege('anon', 'public.signup_plans()', 'EXECUTE'))`;
  - `ok(jsonb_array_length(public.signup_plans()) = (SELECT count(*) FROM public.plan WHERE is_active))`;
  - `is_empty` of the keys of `public.signup_plans() -> 0` minus the eleven named keys;
  - `register_tenant` with an inactive plan → `throws_like '%plan_unavailable%'`;
  - `register_tenant` with an active non-default plan → that plan on the subscription;
  - the new tenant has the roles `management` and `coordinator`.

  Deno: `Deno.test('create-account passes plan_id to register_tenant')`.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.** The admin plan form gets an "Audience" textarea (`admin.plans.audience`, TR "Kimler için" **[owner to confirm]**).
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test:db`, `deno task test`, `pnpm test && pnpm typecheck && pnpm lint`: PASS.
- [ ] **Step 5: Commit** with `feat(plans): audience text and the signup plan list`.

### Task 3: Invitations: tables and the provider's create and revoke

**Files:**
- Create: `supabase/migrations/074_client_invitation.sql`, `supabase/tests/database/074_client_invitation.test.sql`.

**Interfaces:**
- Produces:
  - `public.client_invitation`, with:
    - `id UUID PK`, `tenant_id UUID NOT NULL` (provider);
    - `email TEXT NOT NULL CHECK (email = lower(btrim(email)) AND email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')`;
    - `company_name TEXT NOT NULL CHECK (char_length(btrim(company_name)) BETWEEN 2 AND 200)`;
    - `code CHAR(3) NOT NULL CHECK (code ~ '^[A-Z]{3}$')`, `procurement_model public.procurement_model NOT NULL`;
    - the contract-term columns of `provider_relationship` (`commercial_model`, `packages`, `start_on`, `contract_accepted_on`, `deposit_rate`, `extra_cost_rule`, `eu_responsible_person`, `restricted_drive_url`, `notes`);
    - `recommended_plan_id UUID REFERENCES public.plan ON DELETE SET NULL`;
    - `expires_at TIMESTAMPTZ NOT NULL`, `revoked_at TIMESTAMPTZ`, `accepted_at TIMESTAMPTZ`, `accepted_by UUID`;
    - `client_tenant_id UUID REFERENCES public.tenant ON DELETE SET NULL`;
    - `failed_attempts INT NOT NULL DEFAULT 0`;
    - `created_by UUID DEFAULT auth.uid()`, `created_at`, `updated_at`;
    - `UNIQUE (id, tenant_id)`;
    - partial unique indexes `(tenant_id, code)` and `(tenant_id, email)` `WHERE accepted_at IS NULL AND revoked_at IS NULL`.
  - `public.client_invitation_staff (invitation_id UUID, tenant_id UUID, user_id UUID NOT NULL REFERENCES public.user ON DELETE CASCADE, profile TEXT NOT NULL CHECK (profile IN ('management', 'coordinator')), PRIMARY KEY (invitation_id, user_id), FOREIGN KEY (invitation_id, tenant_id) REFERENCES client_invitation (id, tenant_id) ON DELETE CASCADE)`.
  - `private.client_invitation_token (invitation_id UUID PRIMARY KEY REFERENCES public.client_invitation ON DELETE CASCADE, token_hash BYTEA NOT NULL UNIQUE)`, with no grants to any API role.
  - Classification:
    - `client_invitation.email` is sensitive/`personal_data`;
    - contract terms and internal fields as on `provider_relationship`;
    - the rest open or system;
    - `client_invitation_staff` columns system or open.
  - Both tables get tenant security, audit and `enable_field_security(t, TRUE)`: read-only views; writes only through the RPCs.
  - Permissions in module `provider`: `public.client_invitation` select, insert and update, and `public.client_invitation_staff` select. Owner and management get all; coordinator gets select.
  - `public.create_client_invitation(p_invitation JSONB, p_staff JSONB DEFAULT '[]', p_valid_days INT DEFAULT 14) RETURNS JSONB` (`{ id, token, expires_at }`): SECURITY DEFINER, owner `api_owner`, executable by `authenticated`. Rules:
    - The caller holds `public.client_invitation` insert in `private.tenant_id()` (`tenants_permitting`); else 42501.
    - For each non-null sensitive term in `p_invitation`, `private.require_field_write('public.client_invitation', <field>, <tenant>)` (058) applies, so a coordinator cannot set contract terms.
    - The e-mail is normalised with `lower(btrim())`.
    - `p_valid_days` must be between 1 and 30, else `invitation_invalid_input`.
    - The code must be unused by a relationship of this provider (`relationship_code_taken`); an open but expired invitation holding the same code or e-mail is revoked first.
    - Every staff entry is `{ user_id, profile }`, with the user a `tenant_user` of the provider tenant and a valid profile; else `invitation_invalid_input`.
    - `token := encode(extensions.gen_random_bytes(32), 'hex')`; it stores `extensions.digest(token, 'sha256')`.
    - The token is returned only here.
  - `public.revoke_client_invitation(p_id UUID) RETURNS VOID`: SECURITY DEFINER, `authenticated`. The caller needs `public.client_invitation` update in the invitation's tenant, and the invitation must be open; else `invitation_not_found` (404). Sets `revoked_at = now()`.

- [ ] **Step 1: Write the failing test.** `074_client_invitation.test.sql` with `plan(12)`:
  - the table exists;
  - `hasnt_column('api', 'client_invitation', 'token_hash')`;
  - `ok(NOT has_table_privilege('authenticated', 'private.client_invitation_token', 'SELECT'))`;
  - as `baris` in MOESA LTD:
    - `create_client_invitation('{"email": " Nord@Example.TEST ", "company_name": "Nordwind", "code": "NRD", "procurement_model": "provider", "deposit_rate": 30}', '[{"user_id": <koordinator>, "profile": "coordinator"}]')` returns a 64-hex `token`;
    - `is(email, 'nord@example.test')`;
    - `is(token_hash, digest(token, 'sha256'))` read as postgres;
    - a second call with code `THO` → `relationship_code_taken`;
    - staff with `elif` (not a member) → `invitation_invalid_input`;
    - `p_valid_days = 31` → `invitation_invalid_input`;
  - as `koordinator`: with `deposit_rate` → `field_write_forbidden`;
  - as `portal` in THO → 42501;
  - `revoke_client_invitation` as `baris` sets `revoked_at`, and a second revoke → `invitation_not_found`.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS, drift empty, allowlist updated.
- [ ] **Step 5: Commit** with `feat(onboarding): client invitations with hashed single-use tokens`.

### Task 4: Lookup, acceptance and the throttle in the database

**Files:**
- Modify: `supabase/migrations/074_client_invitation.sql` (append), `supabase/tests/database/074_client_invitation.test.sql` (+19).

**Interfaces:**
- Produces:
  - `private.request_throttle (bucket TEXT, window_start TIMESTAMPTZ, hits INT NOT NULL, PRIMARY KEY (bucket, window_start))`.
  - `public.throttle_hit(p_bucket TEXT, p_limit INT, p_window_seconds INT) RETURNS BOOLEAN` (service_role). It upserts the current window's `hits + 1`, deletes the bucket's rows older than one day, and returns `hits <= p_limit`.
  - `private.open_invitation(p_token TEXT, p_lock BOOLEAN) RETURNS public.client_invitation`. It returns the row whose token hash matches and which is open: not revoked, not accepted, `expires_at > now()`, `failed_attempts < 5`. With `p_lock` it reads `FOR UPDATE`. Otherwise it raises `invitation_invalid` (404). The answer is the same for every cause.
  - `public.lookup_client_invitation(p_token TEXT) RETURNS JSONB` (service_role): `{ company_name, email, provider_name, procurement_model, recommended_plan_id, expires_at, staff_count, account_exists }`. `account_exists` means `public.user` has that e-mail.
  - `public.accept_client_invitation(p_token TEXT, p_user UUID, p_company JSONB, p_plan UUID, p_tenant UUID DEFAULT NULL) RETURNS JSONB` (service_role). **Rules** (binding, in this order, one transaction):
    1. `inv := private.open_invitation(p_token, TRUE)`.
    2. If `lower(btrim(<p_user's e-mail>)) <> inv.email`: `failed_attempts + 1` and **return** `{"error": "invitation_email_mismatch"}`. It does not raise, so the counter is kept.
    3. `p_company` keys must be a subset of `display_name, email, phone, legal_name, country, city, address, tax_office, tax_number`; else `invitation_invalid_input`. Nothing else is read from the caller. Staff, profiles, model, code and terms come from `inv` and its staff rows only.
    4. Let `n` be the number of staff rows whose user is still a `tenant_user` of `inv.tenant_id`. When `p_tenant` is NULL, the plan's `users` limit (if any) must be ≥ 1 + n, else `plan_user_limit`. Then `client := (public.register_tenant(p_user, p_company || {"display_name": coalesce(p_company->>'display_name', inv.company_name)}, p_plan)).id`, which raises `plan_unavailable` for an inactive plan.
    5. When `p_tenant` is not NULL: it must be a root tenant in `tenant_owner` for `p_user` and of another company than `inv.tenant_id`, else `invitation_tenant_invalid`. `private.create_ops_roles(p_tenant)` runs and the plan is unchanged.
    6. `rel := private.create_provider_relationship(inv.tenant_id, client, inv.code, inv.procurement_model, <inv's terms as JSONB>)`. An ended relationship for the pair is reactivated.
    7. For each staff row: when the user is still a member of the provider, insert `tenant_user (client, user)` and `user_role` with the client's role named `profile` (ON CONFLICT DO NOTHING); otherwise add the user to `skipped`.
    8. Set `accepted_at = now()`, `accepted_by = p_user`, `client_tenant_id = client`.
    9. Return `{ tenant_id: client, relationship_id: rel, skipped_staff: skipped }`.

- [ ] **Step 1: Write the failing tests** (+19: 1 + 4 + 1 + 2 + 1 + 1 + 2 + 4 + 1 + 1 + 1, in the order listed), as postgres calling the service functions:
  - `lookup` returns `staff_count = 1` and `account_exists = FALSE` for a new e-mail;
  - `lookup` with an unknown token, an expired one (`expires_at` set to the past), a revoked one and a used one → four `throws_like '%invitation_invalid%'`;
  - `accept` of a second invitation, by a user whose `auth.users` e-mail is upper-cased with spaces, passes (`lives_ok`, normalised);
  - a different user → returns `{"error":"invitation_email_mismatch"}`, and `failed_attempts` is 1;
  - after `failed_attempts = 5` → `invitation_invalid`;
  - `p_company` with `"owner_id"` → `invitation_invalid_input`;
  - a plan with `users = 1` and one staff member → `plan_user_limit`, and no tenant was created (count unchanged);
  - a successful accept creates:
    - a tenant owned by the user;
    - an active relationship with the invitation's model;
    - the staff member as a member with the `coordinator` role;
    - and `accepted_at` set (one assertion per fact, four in all);
  - removing the staff member from the provider before accept → `skipped_staff` contains them;
  - a second accept → `invitation_invalid`;
  - `throttle_hit('b', 2, 600)` returns TRUE, TRUE, FALSE (one `is` on the array of three calls).
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm it passes.** `pnpm test:db` PASS.
- [ ] **Step 5: Commit** with `feat(onboarding): accept an invitation in one transaction`.

### Task 5: Edge Function `client-invitation`

**Files:**
- Create:
  - `supabase/functions/client-invitation/index.ts` (`serve` → `handleInvitation`);
  - `supabase/functions/client-invitation/handler.ts`;
  - `supabase/functions/tests/client_invitation_test.ts`.
- Modify: `supabase/config.toml` (`[functions.client-invitation] verify_jwt = true`).

**Interfaces:**
- Produces:
  - `handleInvitation(req: Request, deps: InvitationDeps): Promise<Response>` with `type InvitationDeps = { rpc: RpcFn; createUser: (email: string, password: string) => Promise<{ id: string }>; deleteUser: (id: string) => Promise<void>; userFromToken: (jwt: string) => Promise<{ id: string; email: string } | null>; ipOf: (req: Request) => string }`.
  - The body is a zod `discriminatedUnion('action', …)`, every object `.strict()`:
    - `{ action: 'lookup', token: /^[0-9a-f]{64}$/ }`;
    - `{ action: 'accept', token, password?: string(min 8, max 72), company?: { display_name?, email?, phone?, legal_name?, country?, city?, address?, tax_office?, tax_number? }, plan_id?: uuid, tenant_id?: uuid }`.
  - Behaviour:
    - **Throttle first.** `throttle_hit('invite-ip:' + sha256(ipOf(req)), 30, 600)` and `throttle_hit('invite-token:' + sha256(token), 10, 600)`; either false → 429 `too_many_requests`.
    - **Lookup** returns the RPC JSON.
    - **Accept, account exists.** A bearer user token is required (`userFromToken`; the anon key is no user), else 409 `invitation_sign_in_required`. A password in the body → 400. The user's e-mail must match, else 403.
    - **Accept, no account.** A password is required. The account is created with `lookup.email`; the body never carries an e-mail for the account. Any failure after `createUser` calls `deleteUser`.
    - An `{"error": …}` result maps to 403.
    - Responses never echo the token.

- [ ] **Step 1: Write the failing tests** (`Deno.test` names):
  - `rejects unknown keys such as staff, roles or procurement_model` (400 for each of the three);
  - `creates the account with the invitation e-mail, never a body e-mail`;
  - `requires sign-in when the e-mail already has an account` (409);
  - `refuses a password when signed in` (400);
  - `refuses a signed-in user whose e-mail differs` (403);
  - `deletes the new account when acceptance fails` (`deleteUser` called once with the new id);
  - `returns 429 when the throttle refuses` (`createUser` not called);
  - `never echoes the token` (the response text does not include it).
- [ ] **Step 2: Run and confirm it fails.** `deno task test`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `deno task check && deno task test`: PASS.
- [ ] **Step 5: Commit** with `feat(onboarding): public invitation endpoint`.

### Task 6: HTTP attack tests for the invitation entry point

**Files:**
- Create: `supabase/functions/http-tests/invitation_http_test.ts`.
- Modify: `supabase/functions/http-tests/helpers.ts` (`invite(providerToken, body): Promise<{ id: string; token: string }>`, `callInvitation(body, bearer?)`).

- [ ] **Step 1: Write the failing tests** (`Deno.test` names and assertions):
  - `an unknown, expired, revoked or used token gives the same 404 body`: the four response bodies are deep-equal.
  - `the token is single-use under concurrency`: two parallel accepts (two distinct new-account e-mail matches are impossible, so use one new e-mail and the same password). The statuses sorted are `[200, 404]`, and admin `GET /tenant?display_name=eq.<company>` has length 1.
  - `an accepted invitation cannot be replayed`: 404.
  - `body fields cannot choose staff, roles, model or owner`: `staff`, `procurement_model`, `roles` and `owner_id` → 400. After a clean accept, the relationship's `procurement_model` equals the invitation's.
  - `a different signed-in account cannot accept`: 403, then after 5 tries the right account gets 404.
  - `the service functions are closed to anon and authenticated`: `POST /rest/v1/rpc/accept_client_invitation`, `lookup_client_invitation` and `throttle_hit` with the anon key and with a user token → 401, 403 or 404, never 200.
  - `the token hash is not readable`: `GET /client_invitation?select=*` as `baris` has no key containing `token`; `Accept-Profile: private` → 406.
  - `lookup is throttled`: 31 rapid lookups from one IP header → the last is 429.
  - `a coordinator cannot set contract terms in an invitation`: 403 `field_write_forbidden`.
  - `self-signup is closed by default`: `POST /functions/v1/create-account` → 403 `self_signup_closed`.
  - `signup_plans is public and leaks no tenant data`: anon 200, and the keys equal the eleven named keys.
- [ ] **Step 2: Run and confirm it fails.** `deno task test:http`: FAIL.
- [ ] **Step 3: Fix any finding** in the owning task's code.
- [ ] **Step 4: Run and confirm it passes.** `deno task test:http`: PASS.
- [ ] **Step 5: Commit** with `test(http): invitation entry point attack tests`.

### Task 7: App: plan chooser

**Files:**
- Create:
  - `app/src/components/service-components/plan-chooser/planChanges.ts`, `PlanChooser.vue`;
  - `app/tests/components/planChanges.test.ts`, `app/tests/components/PlanChooser.test.ts`.

**Interfaces:**
- Produces:
  - `export type SignupPlan = { id: string; display_name: string; description: string | null; audience: string | null; price: number | null; currency: string | null; billing_period: string | null; trial_days: number; is_default: boolean; modules: string[]; limits: Record<string, number> }`.
  - `planChanges(from: SignupPlan, to: SignupPlan): { addedModules: string[]; removedModules: string[]; limits: { key: string; from: number | null; to: number | null }[] }`: only changed limits, keys sorted.
  - `PlanChooser`: props `plans: SignupPlan[]`, `recommendedId?: string | null`, `minUsers?: number`; `v-model: string | null`.
    - The cards sit side by side and stack on mobile. Each shows the name, the price or trial, the `audience`, its modules (labels `modules.<id>`) and its limits.
    - A "Recommended" badge marks the recommended plan.
    - Below the selected card: "If you change later", with each other plan's `planChanges(selected, other)` as plain sentences (`plans.change.adds`, `plans.change.removes`, `plans.change.limit`).
    - A plan whose `limits.users < minUsers` is disabled with `plans.tooSmall`.

- [ ] **Step 1: Write the failing tests.**
  - `planChanges.test.ts`: `it('lists added and removed modules and changed limits only')` with Basic {modules [a,b], users 3} → Pro {modules [a,b,c], users 10, branches 5}. It expects `addedModules ['c']`, `removedModules []` and `limits [{key:'branches',from:null,to:5},{key:'users',from:3,to:10}]`.
  - `PlanChooser.test.ts`: `it('marks the recommended plan')`, `it('disables plans below minUsers')`, `it('explains a downgrade from the selected plan')` (the text contains the removed module's label).
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.** Copy is new `en` text; `tr` is **[owner to confirm]**.
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint`: PASS.
- [ ] **Step 5: Commit** with `feat(app): plan chooser that explains changes`.

### Task 8: App: invitation acceptance page

**Files:**
- Create:
  - `app/src/views/pages/auth/invitation/Index.vue`;
  - `app/src/api/invitation/index.ts`;
  - `app/tests/views/invitationAccept.test.ts`, `app/tests/api/invitation.test.ts`.
- Modify: `app/src/router/routes/auth.ts` (route `auth-invitation`, path `invitation`, public like `auth-register`), i18n.

**Interfaces:**
- Produces:
  - `lookupInvitation(token: string): Promise<InvitationLookup>`;
  - `acceptInvitation(body: AcceptBody, session?: string): Promise<{ tenant_id: string; relationship_id: string; skipped_staff: string[] }>`, both through `supabase.functions.invoke('client-invitation', …)`;
  - `createClientInvitation(invitation, staff, validDays)` and `revokeClientInvitation(id)` (RPCs);
  - `clientInvitationApi` (`api.client_invitation`, select `*, client_invitation_staff(user_id, profile)`).
- Page flow (PrimeVue Stepper):
  1. Read `#t=` from `location.hash` and call `history.replaceState` to drop the hash.
  2. Lookup, then show the company, the provider name and the e-mail (read-only).
  3. With `account_exists`, show the sign-in form (the auth store's login, e-mail fixed). Otherwise set the password twice.
  4. Company details, prefilled from `company_name`. A signed-in owner of root companies may pick "Use my existing company" instead (`tenant_id`).
  5. Plan, through `PlanChooser` with `recommendedId` and `minUsers = 1 + staff_count`. Skipped when attaching.
  6. Accept, then sign in (for a new account), set the current tenant to `tenant_id`, and route to `dashboard`.

  Every `invitation_invalid` shows one message, `auth.invitation.invalid`.

- [ ] **Step 1: Write the failing tests.**
  - `invitationAccept.test.ts`: `it('reads the token from the hash and strips it')`, `it('new account: sends password, company and plan, never an e-mail')`, `it('existing account: asks to sign in and sends no password')`, `it('shows one message for an invalid link')`, `it('sets the current tenant after acceptance')`.
  - `invitation.test.ts`: `it('createClientInvitation posts p_invitation, p_staff, p_valid_days')`.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint && pnpm build`: PASS.
- [ ] **Step 5: Commit** with `feat(app): accept a provider invitation`.

### Task 9: App: self-signup gate, plan step, platform setting

**Files:**
- Create: `app/src/api/platform/index.ts`, `app/src/views/pages/admin/settings/Index.vue`, `app/tests/views/registerGate.test.ts`, `app/tests/views/adminSettings.test.ts`.
- Modify: `app/src/views/pages/auth/Login.vue`, `app/src/views/pages/auth/register/Index.vue`, `app/src/router/routes/auth.ts` (a `beforeEnter` on `auth-register`), `app/src/router/routes/admin.ts` (`admin-settings`), i18n.

**Interfaces:**
- Produces: `selfSignupEnabled(): Promise<boolean>`, `signupPlans(): Promise<SignupPlan[]>`, `platformSettings(): Promise<{ self_signup: boolean }>`, `setPlatformSetting(key: 'self_signup', value: boolean): Promise<void>`, and a re-export of `SignupPlan` (Task 7).
  - The register route redirects to `auth-login` with `?closed=1` when self-signup is closed.
  - The login page hides the register link then.
  - The register form gains the plan step (`PlanChooser`, `minUsers = 1`) and sends `plan_id`.

- [ ] **Step 1: Write the failing tests.**
  - `registerGate.test.ts`: `it('redirects to login when self-signup is closed')`, `it('hides the register link when closed')`, `it('sends plan_id when open')`.
  - `adminSettings.test.ts`: `it('toggles self-signup through set_platform_setting')`.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint`: PASS.
- [ ] **Step 5: Commit** with `feat(app): self-signup gate and plan step`.

### Task 10: App: provider relationships page

**Files:**
- Create in `app/src/views/pages/ops/relationship/`: `Index.vue` (tabs `clients`, `invitations`), `RelationshipEdit.vue`, `InvitationCreate.vue`, `InvitationLink.vue`.
- Create: `app/tests/views/relationships.test.ts`, `app/tests/views/invitationCreate.test.ts`.
- Modify: `app/src/router/routes/ops.ts` (`ops-relationships` path `relationships/:tab?`; dialogs `ops-relationship-edit`, `ops-invitation-add`), `app/src/api/relationship/index.ts` (adds `endRelationship(id)` → `rpc('end_provider_relationship', { p_relationship })`), i18n.

**Interfaces:**
- Consumes: `relationshipApi` and `useProviderClients` (Plan 2 Task 13); `clientInvitationApi`, `createClientInvitation` and `revokeClientInvitation` (Task 8); `signupPlans` (Task 9).
- Page:
  - **Clients tab.** The relationships of the active tenant with `client_name`, code, model, status and start or end. Edit opens contract terms, model, notes and drive URL; the fields are hidden or read-only per CASL field rules. "End relationship" confirms first.
  - **Invitations tab.** Open, expired, revoked and accepted, with a revoke action.
  - **Create dialog.** E-mail, company name, code, model, terms, staff (multi-select of `api.tenant_member` with a profile select per person), recommended plan and validity days. On success, `InvitationLink` shows `${location.origin}/auth/invitation#t=<token>` with a copy button and the note `ops.relationship.linkOnce` ("This link is shown once").
  - The menu item shows when `can('read', 'provider_relationship')`.

- [ ] **Step 1: Write the failing tests.**
  - `relationships.test.ts`: `it('lists clients with their names')`, `it('ends a relationship after confirmation')`, `it('hides contract terms the role cannot read')`.
  - `invitationCreate.test.ts`: `it('sends staff with profiles and the recommended plan')`, `it('shows the link once with the token in the fragment')` (the link matches `/\/auth\/invitation#t=[0-9a-f]{64}$/`; after closing and reopening the dialog the token is gone), `it('revokes an open invitation')`.
- [ ] **Step 2: Run and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and confirm everything passes.** `pnpm test && pnpm typecheck && pnpm lint && pnpm build`: PASS.
- [ ] **Step 5: Commit** with `feat(app): provider relationships and invitations`.

### Task 11: Seeds and the final gate for Plan 3

**Files:**
- Modify:
  - `supabase/seed_story.sql`: Step 12, a pending invitation from MOESA LTD to `nordwind@moesa-panel.test` (company `Nordwind Haushalt GmbH`, code `NRD`, provider procures, `koordinator@` as coordinator, recommended plan Pro). Its token is the fixed development value `5eed0012` repeated 8 times (64 hex, written in the step's comment so the walk can open `/auth/invitation#t=<token>`), and the step stores only `extensions.digest(<token>, 'sha256')`. Plus one revoked and one expired invitation.
  - `supabase/seed_story.check.sql`: `invite.pending_open`, `invite.token_hash_only`.
  - `supabase/README.md`: the production notes:
    - deploy `client-invitation`;
    - `self_signup` stays off unless the owner turns it on in Admin → Settings;
    - the Auth site URL must allow `/auth/invitation`.
  - `supabase/CHANGELOG.md`.

- [ ] **Step 1: Add the checks.**
- [ ] **Step 2: Run and confirm they fail.**
- [ ] **Step 3: Implement the story step.**
- [ ] **Step 4: Run everything.**
  - `cd app && pnpm dev:supabase-reset && pnpm test:db && pnpm test && pnpm typecheck && pnpm lint && pnpm build && pnpm test:scripts`;
  - `cd supabase/functions && deno task check && deno task test && deno task test:http`.

  Expected: all PASS.
- [ ] **Step 5: Commit** with `chore(seed): invitations in the story; plan 3 done`.
