CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Provider invitations (Plan 3, decision 16): the provider invites a customer by e-mail; the link
-- carries a token whose SHA-256 hash alone is kept, in private.provider_invitation_token, which no
-- API role reads (F3).
-- Sections: the invitation, its token, create / rotate / revoke (Task 3); preview and acceptance (Task 4);
-- provider staff (Task 6).
BEGIN;

SELECT plan(188);

-- Fixtures: P = MOESA LTD (baris owns it, koordinator is its coordinator), C = THO (its client,
-- thomas owns it). limited (...071101) is a MOESA LTD member whose role only reads invitations (F25).
SELECT set_config('test.p', (SELECT id::TEXT FROM public.tenant WHERE display_name = 'MOESA LTD'), TRUE);
SELECT set_config('test.c', (SELECT id::TEXT FROM public.tenant WHERE code = 'THO'), TRUE);
SELECT set_config('test.baris', (SELECT id::TEXT FROM public.user WHERE email = 'baris@moesa-panel.test'), TRUE);
SELECT set_config('test.koordinator', (SELECT id::TEXT FROM public.user WHERE email = 'koordinator@moesa-panel.test'), TRUE);
SELECT set_config('test.thomas', (SELECT id::TEXT FROM public.user WHERE email = 'thomas@moesa-panel.test'), TRUE);
SELECT set_config('test.limited', '00000000-0000-4000-8000-000000071101', TRUE);

INSERT INTO public.user (id, email) VALUES ('00000000-0000-4000-8000-000000071101', 'limited@invite.test');
INSERT INTO public.tenant_user (user_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000071101', current_setting('test.p')::UUID);
INSERT INTO public.role (id, tenant_id, display_name) VALUES ('00000000-0000-4000-8000-000000071102', current_setting('test.p')::UUID, 'Invitation reader 071');
INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000071102', p.id FROM public.permission p
WHERE p.resource_name IN ('public.provider_invitation', 'public.provider_invitation_staff') AND p.command = 'select';
INSERT INTO public.user_role (user_id, role_id) VALUES ('00000000-0000-4000-8000-000000071101', '00000000-0000-4000-8000-000000071102');
-- branch.owner (...071105) owns MOESA Europe, a branch of MOESA LTD, and nothing else (decision 19).
INSERT INTO public.user (id, email) VALUES ('00000000-0000-4000-8000-000000071105', 'branch.owner@invite.test');
INSERT INTO public.tenant_owner (user_id, tenant_id)
SELECT '00000000-0000-4000-8000-000000071105', t.id FROM public.tenant t WHERE t.display_name = 'MOESA Europe';
-- A retired plan, the default (active) plan, and a client tenant for relationship fixtures (Atlas).
INSERT INTO public.plan (id, display_name, is_active) VALUES ('00000000-0000-4000-8000-000000071103', 'Retired 071', FALSE);
SELECT set_config('test.plan', (SELECT id::TEXT FROM public.plan WHERE is_active ORDER BY position LIMIT 1), TRUE);
SELECT set_config('test.atlas', (SELECT id::TEXT FROM public.tenant WHERE display_name = 'Atlas Danışmanlık'), TRUE);

-- Every token issued here, so the audit and hash checks can look for each one.
CREATE TEMP TABLE inv_071 (label TEXT, id UUID, token TEXT) ON COMMIT DROP;
GRANT ALL ON inv_071 TO service_role, authenticated;

-- ---------------------------------------------------------------------------------------------
-- Section 1: the invitation, its token, create / rotate / revoke (Task 3).

-- Who may run what.
SELECT ok(NOT has_function_privilege('authenticated', 'public.create_provider_invitation(uuid,uuid,jsonb,jsonb)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.create_provider_invitation(uuid,uuid,jsonb,jsonb)', 'EXECUTE'),
          'authenticated and anon cannot mint tokens');
SELECT ok(NOT has_function_privilege('authenticated', 'public.rotate_provider_invitation_token(uuid,uuid)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.rotate_provider_invitation_token(uuid,uuid)', 'EXECUTE'),
          'authenticated and anon cannot rotate tokens');
SELECT ok(has_function_privilege('service_role', 'public.create_provider_invitation(uuid,uuid,jsonb,jsonb)', 'EXECUTE')
          AND has_function_privilege('service_role', 'public.rotate_provider_invitation_token(uuid,uuid)', 'EXECUTE'),
          'the service role (the Edge Function) mints and rotates');
SELECT ok(has_function_privilege('authenticated', 'public.revoke_provider_invitation(uuid)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.revoke_provider_invitation(uuid)', 'EXECUTE'),
          'a signed-in user revokes through the RPC; anon cannot');

-- The hash is out of every API role's reach (F3).
SELECT ok(NOT has_table_privilege('anon', 'private.provider_invitation_token', 'SELECT')
          AND NOT has_table_privilege('authenticated', 'private.provider_invitation_token', 'SELECT')
          AND NOT has_table_privilege('service_role', 'private.provider_invitation_token', 'SELECT')
          AND NOT has_table_privilege('api_owner', 'private.provider_invitation_token', 'SELECT'),
          'no API role reads the token hashes');
SELECT is_empty($$ SELECT table_schema || '.' || table_name || '.' || column_name FROM information_schema.columns
   WHERE table_schema IN ('public', 'api') AND table_name LIKE 'provider_invitation%' AND (column_name ILIKE '%token%' OR column_name ILIKE '%hash%') $$,
   'no public or api column holds a token or its hash');
SELECT is_empty($$ SELECT format('%s.%s', n.nspname, p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public', 'api')
     AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))
     AND ('bytea'::regtype = p.prorettype OR 'bytea'::regtype = ANY (coalesce(p.proallargtypes, p.proargtypes::OID[]))) $$,
   'no RPC a user may call returns or takes a bytea');
SELECT ok(NOT private.is_shared_table('provider_invitation') AND NOT private.is_shared_table('provider_invitation_staff'),
          'invitations are never shared rows');

-- The owner invites, as the Edge Function does (service role, labelled for the audit, F27).
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SELECT set_config('request.headers', json_build_object('x-audit-role', 'provider-invitation', 'x-audit-actor', current_setting('test.baris'))::TEXT, TRUE);
SELECT set_config('audit.transaction_id', '', TRUE);
SET LOCAL ROLE service_role;

SELECT lives_ok($$ INSERT INTO inv_071 SELECT 'new', i.id, i.token FROM public.create_provider_invitation(
   current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   jsonb_build_object('email', 'new@client.test', 'company_name', 'New Client', 'client_code', 'NEW', 'procurement_model', 'provider',
                      'deposit_rate', 30, 'recommended_plan_id', current_setting('test.plan')),
   jsonb_build_array(jsonb_build_object('user_id', current_setting('test.koordinator'), 'role_name', 'coordinator'))) i $$,
   'the owner invites');
SELECT set_config('test.tx_create', current_setting('audit.transaction_id', TRUE), TRUE);
SELECT set_config('audit.transaction_id', '', TRUE);

SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.limited')::UUID,
   '{"email": "x@client.test", "company_name": "X Ltd", "client_code": "XXA", "procurement_model": "provider"}', '[]') $$,
   '42501', 'invitation_forbidden', 'a MOESA LTD member without the insert right is refused');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.thomas')::UUID,
   '{"email": "x@client.test", "company_name": "X Ltd", "client_code": "XXA", "procurement_model": "provider"}', '[]') $$,
   '42501', 'invitation_forbidden', 'a user of another tenant is refused');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   jsonb_build_object('email', 'y@client.test', 'company_name', 'Y Ltd', 'client_code', 'YYA', 'procurement_model', 'provider',
                      'tenant_id', current_setting('test.c')), '[]') $$,
   '23514', 'invitation_payload_invalid', 'unknown keys refused');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "y@client.test", "company_name": "Y Ltd", "client_code": "yya", "procurement_model": "provider"}', '[]') $$,
   '23514', 'invitation_payload_invalid', 'a malformed client code is refused');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "z@client.test", "company_name": "Z Ltd", "client_code": "ZZA", "procurement_model": "provider"}',
   jsonb_build_array(jsonb_build_object('user_id', current_setting('test.thomas'), 'role_name', 'management'))) $$,
   '23514', 'invitation_staff_invalid', 'staff must be provider members');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "z@client.test", "company_name": "Z Ltd", "client_code": "ZZA", "procurement_model": "provider"}',
   jsonb_build_array(jsonb_build_object('user_id', current_setting('test.koordinator'), 'role_name', 'owner'))) $$,
   '23514', 'invitation_staff_invalid', 'staff roles are the three standard roles');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "w@client.test", "company_name": "W Ltd", "client_code": "THO", "procurement_model": "provider"}', '[]') $$,
   '23505', 'client_code_taken', 'a client code of an existing relationship is taken');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "w@client.test", "company_name": "W Ltd", "client_code": "NEW", "procurement_model": "provider"}', '[]') $$,
   '23505', 'client_code_taken', 'a client code of a pending invitation is taken (F15)');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "new@client.test", "company_name": "New Again", "client_code": "NEA", "procurement_model": "provider"}', '[]') $$,
   '23505', 'invitation_pending_exists', 'one pending invitation per e-mail');
-- Decision 19: no invitation to an account of the provider's own company, compared lower-cased.
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": " BARIS@Moesa-Panel.test ", "company_name": "Self Ltd", "client_code": "SLF", "procurement_model": "provider"}', '[]') $$,
   '23514', 'invitation_self_invite', 'the provider owner''s own e-mail (a case variant) is refused');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "koordinator@moesa-panel.test", "company_name": "Self Ltd", "client_code": "SLF", "procurement_model": "provider"}', '[]') $$,
   '23514', 'invitation_self_invite', 'so is a member''s');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "branch.owner@invite.test", "company_name": "Self Ltd", "client_code": "SLF", "procurement_model": "provider"}', '[]') $$,
   '23514', 'invitation_self_invite', 'and the owner of a branch of the provider''s company');
SELECT is((SELECT count(*)::INT FROM public.provider_invitation WHERE client_code = 'SLF'), 0, 'none of them is stored');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "p@client.test", "company_name": "P Ltd", "client_code": "PPA", "procurement_model": "provider",
     "recommended_plan_id": "00000000-0000-4000-8000-000000071103"}', '[]') $$,
   '23514', 'plan_inactive', 'a retired plan cannot be recommended');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   jsonb_build_object('email', 'l@client.test', 'company_name', repeat('x', 201), 'client_code', 'LLA', 'procurement_model', 'provider'), '[]') $$,
   '23514', 'invitation_payload_invalid', 'a company name is at most 200 characters');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   jsonb_build_object('email', repeat('a', 310) || '@client.test', 'company_name', 'L Ltd', 'client_code', 'LLA', 'procurement_model', 'provider'), '[]') $$,
   '23514', 'invitation_payload_invalid', 'an e-mail is at most 320 characters');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   jsonb_build_object('email', 'l@client.test', 'company_name', 'L Ltd', 'client_code', 'LLA', 'procurement_model', 'provider',
                      'extra_cost_rule', repeat('x', 2001)), '[]') $$,
   '23514', 'invitation_payload_invalid', 'an extra-cost rule is at most 2000 characters');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   jsonb_build_object('email', 'l@client.test', 'company_name', 'L Ltd', 'client_code', 'LLA', 'procurement_model', 'provider',
                      'eu_responsible_person', repeat('x', 501)), '[]') $$,
   '23514', 'invitation_payload_invalid', 'an EU responsible person is at most 500 characters');

RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);
SELECT set_config('request.headers', '', TRUE);

-- What was stored.
SELECT ok((SELECT token ~ '^[A-Za-z0-9_-]{43}$' FROM inv_071 WHERE label = 'new'), 'the token is 32 random bytes, URL-safe, unpadded');
SELECT is((SELECT length(h.token_hash) FROM private.provider_invitation_token h JOIN inv_071 i ON i.id = h.invitation_id WHERE i.label = 'new'),
          32, 'only a SHA-256 hash is stored, in the private table');
SELECT ok((SELECT h.token_hash = extensions.digest(i.token, 'sha256') FROM private.provider_invitation_token h JOIN inv_071 i ON i.id = h.invitation_id WHERE i.label = 'new'),
          'the stored hash is the token''s SHA-256');
SELECT results_eq($$ SELECT status::TEXT, created_by, expires_at > now() + interval '13 days 23 hours', failed_attempts, contract_status::TEXT
   FROM public.provider_invitation WHERE email = 'new@client.test' $$,
   $$ VALUES ('pending', current_setting('test.baris')::UUID, TRUE, 0, 'onboarding') $$, 'a pending invitation for 14 days, made by the actor');
SELECT results_eq($$ SELECT user_id, role_name FROM public.provider_invitation_staff WHERE invitation_id = (SELECT id FROM inv_071 WHERE label = 'new') $$,
   $$ VALUES (current_setting('test.koordinator')::UUID, 'coordinator') $$, 'the staff and their roles are recorded');
SELECT results_eq($$ SELECT t.actor_role, t.actor_id, t.record_id FROM public.audit_transaction t WHERE t.id = nullif(current_setting('test.tx_create'), '')::UUID $$,
   $$ VALUES ('provider-invitation', current_setting('test.baris')::UUID, (SELECT id FROM inv_071 WHERE label = 'new')) $$,
   'the audit names the function and the actor (F27)');

-- The provider reads its invitations through the read-only api view; the client never does.
SELECT private.impersonate_scope(current_setting('test.koordinator')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT is((SELECT count(*)::INT FROM api.provider_invitation WHERE email = 'new@client.test'), 1, 'the provider''s coordinator reads the invitation');
SELECT is((SELECT count(*)::INT FROM api.provider_invitation_staff WHERE invitation_id = (SELECT id FROM inv_071 WHERE label = 'new')), 1, 'and its staff');
SELECT throws_ok($$ UPDATE api.provider_invitation SET expires_at = now() + interval '1 year' WHERE email = 'new@client.test' $$,
   '55000', NULL, 'the api view is read-only: expiry changes only by a resend (F3)');
SELECT is_empty($$ SELECT v.v, p.p FROM unnest(ARRAY['api.provider_invitation', 'api.provider_invitation_staff']) AS v (v),
   unnest(ARRAY['INSERT', 'UPDATE', 'DELETE']) AS p (p)
   WHERE has_table_privilege('authenticated', v.v, p.p)
      OR CASE WHEN p.p = 'DELETE' THEN FALSE ELSE has_any_column_privilege('authenticated', v.v, p.p) END
      OR has_table_privilege('anon', v.v, 'SELECT') $$,
   'no write privilege on either view, and nothing for anon');
SELECT throws_ok($$ SELECT * FROM private.provider_invitation_token $$, '42501', NULL, 'a signed-in user cannot read the hashes');

RESET ROLE;
SELECT private.unimpersonate();
SELECT private.impersonate_scope(current_setting('test.thomas')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT is((SELECT count(*)::INT FROM api.provider_invitation) + (SELECT count(*)::INT FROM api.provider_invitation_staff), 0,
          'the client tenant sees none of the provider''s invitations');
RESET ROLE;
SELECT private.unimpersonate();
SELECT private.impersonate_scope(current_setting('test.thomas')::UUID, current_setting('test.c')::UUID,
                                 ARRAY[current_setting('test.c')::UUID, current_setting('test.p')::UUID]);
SELECT is((SELECT count(*)::INT FROM api.provider_invitation) + (SELECT count(*)::INT FROM api.provider_invitation_staff), 0,
          'nor with a forged scope naming the provider');
RESET ROLE;
SELECT private.unimpersonate();

SELECT is((SELECT recommended_plan_id FROM public.provider_invitation WHERE email = 'new@client.test'), current_setting('test.plan')::UUID,
          'an active plan is recommended');

-- The pending invitation holds its code on the relationship side too (F15).
SELECT throws_ok($$ INSERT INTO public.provider_relationship (tenant_id, client_tenant_id, client_code, client_name, provider_name, procurement_model)
   VALUES (current_setting('test.p')::UUID, current_setting('test.atlas')::UUID, 'NEW', 'Atlas', 'x', 'client') $$,
   '23505', 'client_code_taken', 'a relationship cannot take a pending invitation''s code');
SELECT lives_ok($$ INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, provider_name, procurement_model)
   VALUES ('00000000-0000-4000-8000-000000071104', current_setting('test.p')::UUID, current_setting('test.atlas')::UUID, 'ZZQ', 'Atlas', 'x', 'client') $$,
   'a free code is taken as before');
SELECT throws_ok($$ UPDATE public.provider_relationship SET client_code = 'NEW' WHERE id = '00000000-0000-4000-8000-000000071104' $$,
   '23505', 'client_code_taken', 'nor can a relationship be renamed to it');

-- Rotation (the resend): the update right, a new token and hash, the expiry and counter reset.
UPDATE public.provider_invitation SET expires_at = now() - interval '1 day', failed_attempts = 4 WHERE email = 'new@client.test';

SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SET LOCAL ROLE service_role;
SELECT throws_ok($$ SELECT public.rotate_provider_invitation_token((SELECT id FROM inv_071 WHERE label = 'new'), current_setting('test.limited')::UUID) $$,
   '42501', 'invitation_forbidden', 'rotating needs the update right');
SELECT throws_ok($$ SELECT public.rotate_provider_invitation_token(gen_random_uuid(), current_setting('test.baris')::UUID) $$,
   '42501', 'invitation_forbidden', 'an unknown invitation is refused like a forbidden one');
SELECT lives_ok($$ INSERT INTO inv_071 SELECT 'rotated', (SELECT id FROM inv_071 WHERE label = 'new'),
   public.rotate_provider_invitation_token((SELECT id FROM inv_071 WHERE label = 'new'), current_setting('test.baris')::UUID) $$,
   'the owner resends an expired invitation');
RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);

SELECT ok((SELECT r.token <> n.token AND r.token ~ '^[A-Za-z0-9_-]{43}$' FROM inv_071 r, inv_071 n WHERE r.label = 'rotated' AND n.label = 'new'),
          'a new token is returned');
SELECT results_eq($$ SELECT h.token_hash = extensions.digest((SELECT token FROM inv_071 WHERE label = 'rotated'), 'sha256'),
                            h.token_hash = extensions.digest((SELECT token FROM inv_071 WHERE label = 'new'), 'sha256')
   FROM private.provider_invitation_token h WHERE h.invitation_id = (SELECT id FROM inv_071 WHERE label = 'new') $$,
   $$ VALUES (TRUE, FALSE) $$, 'the hash is replaced: the old token no longer matches');
SELECT results_eq($$ SELECT expires_at > now() + interval '13 days 23 hours', failed_attempts FROM public.provider_invitation WHERE email = 'new@client.test' $$,
   $$ VALUES (TRUE, 0) $$, 'the resend restarts the 14 days and the failure count');

-- No token, plain or hashed, reaches the audit trail.
SELECT is_empty($$ SELECT l.id FROM public.audit_log l, inv_071 i
   WHERE coalesce(l.old_data::TEXT, '') || coalesce(l.new_data::TEXT, '') LIKE ANY (ARRAY[
      '%' || i.token || '%',
      '%' || encode(extensions.digest(i.token, 'sha256'), 'hex') || '%',
      '%' || encode(extensions.digest(i.token, 'sha256'), 'base64') || '%']) $$,
   'no token or hash is written to audit_log');
SELECT is_empty($$ SELECT 1 FROM public.audit_log WHERE table_schema = 'private' $$, 'the private hash table is not audited');

-- The cap: 50 tokens per tenant per 24 hours, resends included (F21).
SELECT is((SELECT count(*)::INT FROM private.provider_invitation_issue WHERE tenant_id = current_setting('test.p')::UUID), 2,
          'the creation and the resend each count toward the cap');
INSERT INTO private.provider_invitation_issue (tenant_id, invitation_id, issued_at)
SELECT current_setting('test.p')::UUID, (SELECT id FROM inv_071 WHERE label = 'new'), now() - interval '25 hours' FROM generate_series(1, 60);
INSERT INTO private.provider_invitation_issue (tenant_id, invitation_id)
SELECT current_setting('test.p')::UUID, (SELECT id FROM inv_071 WHERE label = 'new') FROM generate_series(1, 47);

SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SET LOCAL ROLE service_role;
SELECT lives_ok($$ INSERT INTO inv_071 SELECT 'fiftieth', i.id, i.token FROM public.create_provider_invitation(
   current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "fifty@client.test", "company_name": "Fifty Ltd", "client_code": "FIF", "procurement_model": "client"}', '[]') i $$,
   'the 50th token of the day is issued (older ones no longer count)');
SELECT throws_ok($$ SELECT * FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "more@client.test", "company_name": "More Ltd", "client_code": "MOR", "procurement_model": "provider"}', '[]') $$,
   'P0001', 'invitation_throttled', 'the 51st creation is refused');
SELECT throws_ok($$ SELECT public.rotate_provider_invitation_token((SELECT id FROM inv_071 WHERE label = 'new'), current_setting('test.baris')::UUID) $$,
   'P0001', 'invitation_throttled', 'so is a resend');
RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);

-- Revocation: the update right in the invitation's tenant, pending only.
SELECT private.impersonate_scope(current_setting('test.limited')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT throws_ok($$ SELECT public.revoke_provider_invitation((SELECT id FROM inv_071 WHERE label = 'new')) $$,
   '42501', 'invitation_forbidden', 'revoking needs the update right');
RESET ROLE;
SELECT private.unimpersonate();
SELECT private.impersonate_scope(current_setting('test.thomas')::UUID, current_setting('test.c')::UUID, ARRAY[current_setting('test.c')::UUID]);
SELECT throws_ok($$ SELECT public.revoke_provider_invitation((SELECT id FROM inv_071 WHERE label = 'new')) $$,
   '42501', 'invitation_forbidden', 'the client tenant cannot revoke the provider''s invitation');
RESET ROLE;
SELECT private.unimpersonate();
SELECT private.impersonate_scope(current_setting('test.baris')::UUID, current_setting('test.p')::UUID, ARRAY[current_setting('test.p')::UUID]);
SELECT lives_ok($$ SELECT public.revoke_provider_invitation((SELECT id FROM api.provider_invitation WHERE email = 'new@client.test')) $$,
   'the provider revokes');
SELECT throws_ok($$ SELECT public.revoke_provider_invitation((SELECT id FROM inv_071 WHERE label = 'new')) $$,
   'P0001', 'invitation_invalid', 'a revoked invitation cannot be revoked again');
RESET ROLE;
SELECT private.unimpersonate();

SELECT results_eq($$ SELECT status::TEXT, revoked_at IS NOT NULL FROM public.provider_invitation WHERE email = 'new@client.test' $$,
   $$ VALUES ('revoked', TRUE) $$, 'the invitation is revoked');
SELECT is_empty($$ SELECT 1 FROM private.provider_invitation_token WHERE invitation_id = (SELECT id FROM inv_071 WHERE label = 'new') $$,
   'a revoked invitation keeps no hash: no token matches it any more');

SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SET LOCAL ROLE service_role;
SELECT throws_ok($$ SELECT public.rotate_provider_invitation_token((SELECT id FROM inv_071 WHERE label = 'new'), current_setting('test.baris')::UUID) $$,
   'P0001', 'invitation_invalid', 'a revoked invitation cannot be resent');
RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);
SELECT lives_ok($$ UPDATE public.provider_relationship SET client_code = 'NEW' WHERE id = '00000000-0000-4000-8000-000000071104' $$,
   'a revoked invitation releases its code');

-- ---------------------------------------------------------------------------------------------
-- Section 2: preview and one-step acceptance (Task 4). Acceptance runs as the service role (F1: the
-- provider-invitation Edge Function, with p_user from the verified JWT); every refusal before the
-- first write returns {"error": code} without raising, so the counters it wrote stay (F2).

-- A clean slate for this section: the day's cap and the code NEW are free again.
DELETE FROM private.provider_invitation_issue WHERE tenant_id = current_setting('test.p')::UUID;
DELETE FROM public.provider_relationship WHERE id = '00000000-0000-4000-8000-000000071104';

-- The people: newbie (new@client.test, no password yet), other (another e-mail), third, late, small
-- and lockee (each invited), and departed, a MOESA LTD member who leaves before acceptance.
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
SELECT '00000000-0000-0000-0000-000000000000', v.id::UUID, 'authenticated', 'authenticated', v.email, '', now(), now(), now(), '', '', '', ''
FROM (VALUES ('00000000-0000-4000-8000-000000071201', 'new@client.test'),
             ('00000000-0000-4000-8000-000000071202', 'other@client.test'),
             ('00000000-0000-4000-8000-000000071203', 'third@client.test'),
             ('00000000-0000-4000-8000-000000071204', 'departed@invite.test'),
             ('00000000-0000-4000-8000-000000071205', 'late@client.test'),
             ('00000000-0000-4000-8000-000000071206', 'small@client.test'),
             ('00000000-0000-4000-8000-000000071207', 'lockee@client.test'),
             ('00000000-0000-4000-8000-000000071208', 'insider@client.test'),
             ('00000000-0000-4000-8000-000000071209', 'badrole@client.test')) AS v (id, email);
SELECT set_config('test.newbie', '00000000-0000-4000-8000-000000071201', TRUE);
SELECT set_config('test.other', '00000000-0000-4000-8000-000000071202', TRUE);
SELECT set_config('test.third', '00000000-0000-4000-8000-000000071203', TRUE);
SELECT set_config('test.departed', '00000000-0000-4000-8000-000000071204', TRUE);
SELECT set_config('test.late', '00000000-0000-4000-8000-000000071205', TRUE);
SELECT set_config('test.small', '00000000-0000-4000-8000-000000071206', TRUE);
SELECT set_config('test.lockee', '00000000-0000-4000-8000-000000071207', TRUE);
SELECT set_config('test.insider', '00000000-0000-4000-8000-000000071208', TRUE);
SELECT set_config('test.badrole', '00000000-0000-4000-8000-000000071209', TRUE);
SELECT set_config('test.akif', (SELECT id::TEXT FROM public.user WHERE email = 'akif@moesa-panel.test'), TRUE);
SELECT set_config('test.ali', (SELECT id::TEXT FROM public.user WHERE email = 'ali@moesa-panel.test'), TRUE);
SELECT set_config('test.pro_plan', (SELECT id::TEXT FROM public.plan WHERE display_name = 'Pro'), TRUE);
INSERT INTO public.tenant_user (user_id, tenant_id) VALUES (current_setting('test.departed')::UUID, current_setting('test.p')::UUID);
-- A plan for two users, below the three seats of an invitation with two staff.
INSERT INTO public.plan (id, display_name, is_active, position) VALUES ('00000000-0000-4000-8000-000000071210', 'Tiny 071', TRUE, 99);
INSERT INTO public.plan_limit (plan_id, limit_key, value) VALUES ('00000000-0000-4000-8000-000000071210', 'max_users', 2);

CREATE TEMP TABLE acc_071 (label TEXT, result JSONB) ON COMMIT DROP;
GRANT ALL ON acc_071 TO service_role, authenticated;

-- Who may run what (F1).
SELECT ok(NOT has_function_privilege('authenticated', 'public.accept_provider_invitation(uuid,text,jsonb,uuid,jsonb)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.accept_provider_invitation(uuid,text,jsonb,uuid,jsonb)', 'EXECUTE')
          AND has_function_privilege('service_role', 'public.accept_provider_invitation(uuid,text,jsonb,uuid,jsonb)', 'EXECUTE'),
          'only the service role accepts (F1): a user cannot name p_user');
SELECT ok(has_function_privilege('authenticated', 'public.invitation_preview(text)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.invitation_preview(text)', 'EXECUTE'),
          'a signed-in user previews; anon cannot');
SELECT ok(NOT has_table_privilege('anon', 'private.invitation_attempt', 'SELECT,UPDATE,DELETE')
          AND NOT has_table_privilege('authenticated', 'private.invitation_attempt', 'SELECT,UPDATE,DELETE')
          AND NOT has_table_privilege('service_role', 'private.invitation_attempt', 'SELECT,UPDATE,DELETE')
          AND NOT has_function_privilege('authenticated', 'private.invitation_throttle(text,integer,interval)', 'EXECUTE')
          AND NOT has_function_privilege('service_role', 'private.invitation_throttle(text,integer,interval)', 'EXECUTE'),
          'no API role reads or resets the attempt counters');

-- The invitations, as the Edge Function makes them.
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SET LOCAL ROLE service_role;
INSERT INTO inv_071 SELECT 'inv1', i.id, i.token FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   jsonb_build_object('email', 'new@client.test', 'company_name', 'New Client', 'client_code', 'NEW', 'procurement_model', 'provider',
                      'commercial_model', 'trading_partner', 'packages', jsonb_build_array('A1', 'B'), 'start_on', '2026-12-01', 'deposit_rate', 30,
                      'extra_cost_rule', 'at cost', 'recommended_plan_id', current_setting('test.plan')),
   jsonb_build_array(jsonb_build_object('user_id', current_setting('test.koordinator'), 'role_name', 'coordinator'),
                     jsonb_build_object('user_id', current_setting('test.akif'), 'role_name', 'management'))) i;
INSERT INTO inv_071 SELECT 'inv2', i.id, i.token FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "ali@moesa-panel.test", "company_name": "Nova Ventures", "client_code": "NVV", "procurement_model": "client"}', '[]') i;
INSERT INTO inv_071 SELECT 'inv3', i.id, i.token FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "third@client.test", "company_name": "Third Co", "client_code": "TRD", "procurement_model": "provider"}',
   jsonb_build_array(jsonb_build_object('user_id', current_setting('test.departed'), 'role_name', 'viewer'),
                     jsonb_build_object('user_id', current_setting('test.koordinator'), 'role_name', 'viewer'))) i;
INSERT INTO inv_071 SELECT 'expired', i.id, i.token FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "late@client.test", "company_name": "Late Co", "client_code": "LAT", "procurement_model": "provider"}', '[]') i;
INSERT INTO inv_071 SELECT 'seats', i.id, i.token FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "small@client.test", "company_name": "Small Co", "client_code": "SML", "procurement_model": "provider"}',
   jsonb_build_array(jsonb_build_object('user_id', current_setting('test.koordinator'), 'role_name', 'coordinator'),
                     jsonb_build_object('user_id', current_setting('test.akif'), 'role_name', 'viewer'))) i;
INSERT INTO inv_071 SELECT 'lock', i.id, i.token FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "lockee@client.test", "company_name": "Lock Co", "client_code": "LCK", "procurement_model": "provider"}', '[]') i;
INSERT INTO inv_071 SELECT 'insider', i.id, i.token FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "insider@client.test", "company_name": "Insider Co", "client_code": "INS", "procurement_model": "provider"}',
   jsonb_build_array(jsonb_build_object('user_id', current_setting('test.koordinator'), 'role_name', 'coordinator'))) i;
INSERT INTO inv_071 SELECT 'badrole', i.id, i.token FROM public.create_provider_invitation(current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "badrole@client.test", "company_name": "Badrole Co", "client_code": "BDR", "procurement_model": "provider"}',
   jsonb_build_array(jsonb_build_object('user_id', current_setting('test.koordinator'), 'role_name', 'coordinator'))) i;
RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);

UPDATE public.provider_invitation SET expires_at = now() - interval '1 second' WHERE id = (SELECT id FROM inv_071 WHERE label = 'expired');
DELETE FROM public.tenant_user WHERE user_id = current_setting('test.departed')::UUID AND tenant_id = current_setting('test.p')::UUID;
-- The insider joins MOESA LTD after being invited (decision 19: preview and acceptance check again).
INSERT INTO public.tenant_user (user_id, tenant_id) VALUES (current_setting('test.insider')::UUID, current_setting('test.p')::UUID);
SELECT is((SELECT count(*)::INT FROM inv_071 WHERE label IN ('inv1', 'inv2', 'inv3', 'expired', 'seats', 'lock', 'insider', 'badrole')), 8, 'the fixture invitations are made');

-- Preview: what the customer sees before accepting, as themself (authenticated).
SELECT private.impersonate_scope(current_setting('test.newbie')::UUID, NULL, '{}'::UUID[]);
INSERT INTO acc_071 SELECT 'preview1', public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv1'));
INSERT INTO acc_071 SELECT 'preview_unknown', public.invitation_preview('not-a-token');
RESET ROLE;
SELECT private.unimpersonate();
SELECT private.impersonate_scope(current_setting('test.ali')::UUID, NULL, '{}'::UUID[]);
INSERT INTO acc_071 SELECT 'preview_ali', public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv2'));
RESET ROLE;
SELECT private.unimpersonate();
SELECT private.impersonate_scope(current_setting('test.other')::UUID, NULL, '{}'::UUID[]);
INSERT INTO acc_071 SELECT 'preview_other', public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv1'));
RESET ROLE;
SELECT private.unimpersonate();

SELECT results_eq($$ SELECT r ->> 'company_name', r ->> 'email', r ->> 'provider_name', r ->> 'procurement_model', (r ->> 'seats')::INT,
                            (r ->> 'recommended_plan_id')::UUID, (r ->> 'needs_password')::BOOLEAN
   FROM (SELECT result AS r FROM acc_071 WHERE label = 'preview1') x $$,
   $$ VALUES ('New Client', 'new@client.test', 'MOESA LTD', 'provider', 3, current_setting('test.plan')::UUID, TRUE) $$,
   'the preview shows the invitation, the seats (1 + staff) and that no password is set yet');
SELECT is((SELECT result -> 'contract' FROM acc_071 WHERE label = 'preview1'),
          '{"commercial_model": "trading_partner", "packages": ["A1", "B"], "start_on": "2026-12-01", "deposit_rate": 30.00}'::JSONB,
          'and the contract terms');
SELECT set_eq($$ SELECT jsonb_object_keys(result) FROM acc_071 WHERE label = 'preview1' $$,
   ARRAY['company_name', 'email', 'provider_name', 'procurement_model', 'contract', 'recommended_plan_id', 'expires_at', 'seats',
         'staff', 'needs_password', 'plans'],
   'the preview carries exactly the documented keys');
-- Final review I2 (ruling changed: the preview names the staff): each staff member who would join,
-- by display name and role, numbered for the accepter's choice; never a user id or an e-mail.
SELECT set_eq($$ SELECT (s ->> 'display_name') || ':' || (s ->> 'role_name') FROM acc_071, jsonb_array_elements(result -> 'staff') s
                 WHERE label = 'preview1' $$,
   ARRAY['Koordinatör:coordinator', 'Akif Ayçiçek:management'], 'the preview names each staff member and their role');
SELECT ok((SELECT bool_and(ARRAY(SELECT jsonb_object_keys(s) ORDER BY 1) = ARRAY['display_name', 'index', 'role_name'])
                  AND array_agg((s ->> 'index')::INT ORDER BY (s ->> 'index')::INT) = ARRAY[0, 1]
           FROM acc_071, jsonb_array_elements(result -> 'staff') s WHERE label = 'preview1'),
          'each as {index, display_name, role_name}, numbered from 0');
SELECT ok((SELECT result::TEXT NOT LIKE ALL (ARRAY['%' || current_setting('test.koordinator') || '%', '%' || current_setting('test.akif') || '%',
                                                   '%koordinator@%', '%akif@%', '%' || i.token || '%',
                                                   '%' || encode(extensions.digest(i.token, 'sha256'), 'hex') || '%',
                                                   '%' || encode(extensions.digest(i.token, 'sha256'), 'base64') || '%'])
           FROM acc_071 a, inv_071 i WHERE a.label = 'preview1' AND i.label = 'inv1'),
          'no staff user id or e-mail, token or hash in the preview');
SELECT is((SELECT ARRAY(SELECT p ->> 'display_name' FROM jsonb_array_elements(result -> 'plans') AS p) FROM acc_071 WHERE label = 'preview1'),
          ARRAY(SELECT display_name FROM public.plan WHERE is_active ORDER BY position, display_name),
          'the plans are the active ones, in order');
SELECT results_eq($$ SELECT (p -> 'limits' ->> 'max_users')::INT, jsonb_typeof(p -> 'modules'), p ->> 'audience' IS NOT DISTINCT FROM pl.audience
   FROM acc_071, jsonb_array_elements(result -> 'plans') AS p JOIN public.plan pl ON pl.id = (p ->> 'id')::UUID
   WHERE label = 'preview1' AND p ->> 'display_name' = 'Basic' $$,
   $$ VALUES (3, 'array', TRUE) $$, 'each plan carries its modules, limits and audience');
SELECT is((SELECT (result ->> 'needs_password')::BOOLEAN FROM acc_071 WHERE label = 'preview_ali'), FALSE, 'a user with a password needs none');
SELECT is((SELECT result FROM acc_071 WHERE label = 'preview_unknown'), '{"error": "invitation_invalid"}'::JSONB, 'an unknown token: invitation_invalid');
SELECT is((SELECT result FROM acc_071 WHERE label = 'preview_other'), '{"error": "invitation_email_mismatch"}'::JSONB,
          'another account cannot preview the invitation');

-- Auth gives an invited account a temporary password of its own when the invitation link is
-- followed (GoTrue's invite verification), so the account is not password-less by then (found by
-- the HTTP suite). Invited and no password_set mark (the acceptance page sets it with the password)
-- still needs one; a mark that is not exactly true does not count.
UPDATE auth.users SET encrypted_password = '$2a$10$temporaryinvitepasswordhashxxxxxxxxxxxxxxxxxxxxxxxxxxx', invited_at = now()
WHERE id = current_setting('test.newbie')::UUID;
SELECT private.impersonate_scope(current_setting('test.newbie')::UUID, NULL, '{}'::UUID[]);
INSERT INTO acc_071 SELECT 'preview_invited', public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv1'));
RESET ROLE;
SELECT private.unimpersonate();
UPDATE auth.users SET raw_user_meta_data = '{"password_set": "yes"}' WHERE id = current_setting('test.newbie')::UUID;
SELECT private.impersonate_scope(current_setting('test.newbie')::UUID, NULL, '{}'::UUID[]);
INSERT INTO acc_071 SELECT 'preview_invited_bad_mark', public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv1'));
RESET ROLE;
SELECT private.unimpersonate();
UPDATE auth.users SET raw_user_meta_data = '{"password_set": true}' WHERE id = current_setting('test.newbie')::UUID;
SELECT private.impersonate_scope(current_setting('test.newbie')::UUID, NULL, '{}'::UUID[]);
INSERT INTO acc_071 SELECT 'preview_invited_set', public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv1'));
RESET ROLE;
SELECT private.unimpersonate();
UPDATE auth.users SET encrypted_password = '', invited_at = NULL, raw_user_meta_data = '{}' WHERE id = current_setting('test.newbie')::UUID;
SELECT is((SELECT (result ->> 'needs_password')::BOOLEAN FROM acc_071 WHERE label = 'preview_invited'), TRUE,
          'an invited account with Auth''s temporary password still needs one');
SELECT is((SELECT (result ->> 'needs_password')::BOOLEAN FROM acc_071 WHERE label = 'preview_invited_bad_mark'), TRUE,
          'a password_set mark that is not true does not count');
SELECT is((SELECT (result ->> 'needs_password')::BOOLEAN FROM acc_071 WHERE label = 'preview_invited_set'), FALSE,
          'an invited account that set its password needs none');
SELECT results_eq($$ SELECT i.status::TEXT, i.failed_attempts, EXISTS (SELECT 1 FROM private.provider_invitation_token h WHERE h.invitation_id = i.id)
   FROM public.provider_invitation i WHERE i.id = (SELECT id FROM inv_071 WHERE label = 'inv1') $$,
   $$ VALUES ('pending', 0, TRUE) $$, 'previewing consumes and counts nothing, not even the other account''s attempt');

-- A preview never locks an invitation: ten previews by the wrong account, then the invitee still
-- previews (and accepts, below). The e-mail comes from auth.users, never the JWT: a claim naming
-- the invited address changes nothing.
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('test.other'), 'role', 'authenticated',
                                                          'email', 'new@client.test', 'email_verified', TRUE)::TEXT, TRUE);
SET LOCAL ROLE authenticated;
SELECT is(public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv1')) ->> 'error', 'invitation_email_mismatch',
          'a JWT e-mail claim naming the invited address is not proof');
SELECT is((SELECT count(*)::INT FROM generate_series(1, 10) g
           WHERE public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv1')) ->> 'error' = 'invitation_email_mismatch'), 10,
          'the wrong account previews ten times');
RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);
SELECT is((SELECT failed_attempts FROM public.provider_invitation WHERE id = (SELECT id FROM inv_071 WHERE label = 'inv1')), 0,
          'and counts nothing');
SELECT private.impersonate_scope(current_setting('test.newbie')::UUID, NULL, '{}'::UUID[]);
SELECT is(public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv1')) ->> 'company_name', 'New Client',
          'the invited user still previews: no lock-out by previews');
RESET ROLE;
SELECT private.unimpersonate();

-- Seats: the staff still with the provider, the viewer aside.
SELECT private.impersonate_scope(current_setting('test.third')::UUID, NULL, '{}'::UUID[]);
SELECT is((public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv3')) ->> 'seats')::INT, 2,
          'a departed staff member takes no seat');
SELECT is((SELECT array_agg(s ->> 'display_name') FROM jsonb_array_elements(public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv3')) -> 'staff') s),
          ARRAY['Koordinatör'], 'and is not listed');
RESET ROLE;
SELECT private.unimpersonate();
SELECT private.impersonate_scope(current_setting('test.insider')::UUID, NULL, '{}'::UUID[]);
SELECT is(public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'insider')),
          '{"error": "invitation_self_invite"}'::JSONB,
          'an invited account that joined the provider''s company since is refused at preview (decision 19)');
RESET ROLE;
SELECT private.unimpersonate();

-- The preview throttle: 30 per user per 10 minutes, and the refusal keeps its count (F2).
UPDATE private.invitation_attempt SET window_start = now(), count = 30 WHERE key = 'preview:' || current_setting('test.newbie');
SELECT private.impersonate_scope(current_setting('test.newbie')::UUID, NULL, '{}'::UUID[]);
SELECT is(public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv1')) ->> 'error', 'invitation_throttled', 'the 31st preview in 10 minutes is refused');
RESET ROLE;
SELECT private.unimpersonate();
SELECT is((SELECT count FROM private.invitation_attempt WHERE key = 'preview:' || current_setting('test.newbie')), 31, 'the refused attempt is still counted');
UPDATE private.invitation_attempt SET window_start = now() - interval '11 minutes' WHERE key = 'preview:' || current_setting('test.newbie');
SELECT private.impersonate_scope(current_setting('test.newbie')::UUID, NULL, '{}'::UUID[]);
SELECT is(public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'inv1')) ->> 'company_name', 'New Client', 'a new window opens after 10 minutes');
RESET ROLE;
SELECT private.unimpersonate();

-- Acceptance, as the Edge Function calls it. Its header names another actor: the function labels
-- the audit with p_user itself (F27).
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SELECT set_config('request.headers', json_build_object('x-audit-role', 'provider-invitation', 'x-audit-actor', current_setting('test.baris'))::TEXT, TRUE);
SET LOCAL ROLE service_role;

SELECT is(public.accept_provider_invitation(current_setting('test.other')::UUID, (SELECT token FROM inv_071 WHERE label = 'inv1'),
                                            '{"display_name": "New Client GmbH"}', NULL) ->> 'error',
          'invitation_email_mismatch', 'wrong account refused');
SELECT is((SELECT failed_attempts FROM public.provider_invitation WHERE id = (SELECT id FROM inv_071 WHERE label = 'inv1')), 1,
          'an acceptance mismatch is counted, and the count survives the refusal');
RESET ROLE;
UPDATE auth.users SET email_confirmed_at = NULL WHERE id = current_setting('test.newbie')::UUID;
SET LOCAL ROLE service_role;
SELECT is(public.accept_provider_invitation(current_setting('test.newbie')::UUID, (SELECT token FROM inv_071 WHERE label = 'inv1'),
                                            '{"display_name": "New Client GmbH"}', NULL) ->> 'error',
          'invitation_email_mismatch', 'an unconfirmed e-mail proves nothing: refused');
RESET ROLE;
UPDATE auth.users SET email_confirmed_at = now() WHERE id = current_setting('test.newbie')::UUID;
SET LOCAL ROLE service_role;
SELECT is(public.accept_provider_invitation(current_setting('test.newbie')::UUID, (SELECT token FROM inv_071 WHERE label = 'inv1'),
                                            '{"display_name": "New Client GmbH", "procurement_model": "client"}', NULL) ->> 'error',
          'invitation_payload_invalid', 'a payload naming the model is refused');
SELECT is(public.accept_provider_invitation(current_setting('test.newbie')::UUID, (SELECT token FROM inv_071 WHERE label = 'inv1'),
                                            jsonb_build_object('display_name', 'New Client GmbH', 'tenant_id', current_setting('test.p')), NULL) ->> 'error',
          'invitation_payload_invalid', 'a payload naming a tenant is refused');
SELECT is(public.accept_provider_invitation(current_setting('test.newbie')::UUID, (SELECT token FROM inv_071 WHERE label = 'inv1'),
                                            jsonb_build_object('display_name', 'New Client GmbH', 'owner', current_setting('test.ali')), NULL) ->> 'error',
          'invitation_payload_invalid', 'a payload naming an owner is refused');
SELECT is(public.accept_provider_invitation(current_setting('test.newbie')::UUID, (SELECT token FROM inv_071 WHERE label = 'inv1'),
                                            '{"display_name": {"x": 1}}', NULL) ->> 'error',
          'invitation_payload_invalid', 'a payload value must be text');
SELECT is(public.accept_provider_invitation(current_setting('test.newbie')::UUID, 'not-a-token', '{"display_name": "X Ltd"}', NULL) ->> 'error',
          'invitation_invalid', 'unknown token: invitation_invalid');
SELECT is(public.accept_provider_invitation(NULL, (SELECT token FROM inv_071 WHERE label = 'inv1'), '{"display_name": "X Ltd"}', NULL) ->> 'error',
          'invitation_invalid', 'no user: invitation_invalid');
SELECT is(public.accept_provider_invitation(current_setting('test.newbie')::UUID, (SELECT token FROM inv_071 WHERE label = 'inv1'),
                                            '{"display_name": "New Client GmbH"}', '00000000-0000-4000-8000-000000071103') ->> 'error',
          'plan_inactive', 'a retired plan cannot be chosen');
RESET ROLE;
SELECT results_eq($$ SELECT i.status::TEXT, (SELECT count(*)::INT FROM public.tenant WHERE display_name = 'New Client GmbH')
   FROM public.provider_invitation i WHERE i.id = (SELECT id FROM inv_071 WHERE label = 'inv1') $$,
   $$ VALUES ('pending', 0) $$, 'the refusals leave the invitation pending and create nothing');
-- Someone signed this address up meanwhile (070 pending_signup): acceptance does not use it, and drops it.
INSERT INTO private.pending_signup (user_id, company) VALUES (current_setting('test.newbie')::UUID, '{"display_name": "Squatter Co"}');
SELECT set_config('audit.transaction_id', '', TRUE);
SET LOCAL ROLE service_role;

SELECT lives_ok($$ INSERT INTO acc_071 SELECT 'inv1', public.accept_provider_invitation(current_setting('test.newbie')::UUID,
   (SELECT token FROM inv_071 WHERE label = 'inv1'), '{"display_name": "New Client GmbH", "country": "Germany"}', current_setting('test.pro_plan')::UUID) $$,
   'the invited user accepts');
SELECT set_config('test.tx_accept', current_setting('audit.transaction_id', TRUE), TRUE);
SELECT is(current_setting('request.headers', TRUE)::JSONB,
          jsonb_build_object('x-audit-role', 'provider-invitation', 'x-audit-actor', current_setting('test.baris')),
          'the caller''s request headers are restored when acceptance returns');
-- Serialised by the row lock: a second accept, after the first, finds the invitation used.
SELECT is(public.accept_provider_invitation(current_setting('test.newbie')::UUID, (SELECT token FROM inv_071 WHERE label = 'inv1'),
                                            '{"display_name": "Again Ltd"}', NULL) ->> 'error',
          'invitation_invalid', 'single use');
RESET ROLE;
SELECT set_config('request.headers', '', TRUE);
SELECT set_config('request.jwt.claims', '', TRUE);
SELECT set_config('test.new_tenant', (SELECT id::TEXT FROM public.tenant WHERE display_name = 'New Client GmbH'), TRUE);

SELECT is((SELECT result FROM acc_071 WHERE label = 'inv1'),
          jsonb_build_object('tenant_id', current_setting('test.new_tenant')::UUID, 'skipped_staff', '[]'::JSONB), 'it returns the new tenant');
SELECT ok(EXISTS (SELECT 1 FROM public.tenant_owner o WHERE o.user_id = current_setting('test.newbie')::UUID AND o.tenant_id = current_setting('test.new_tenant')::UUID)
          AND EXISTS (SELECT 1 FROM public.tenant_user u WHERE u.user_id = current_setting('test.newbie')::UUID AND u.tenant_id = current_setting('test.new_tenant')::UUID),
          'the customer owns the new tenant and is its member');
SELECT ok(NOT EXISTS (SELECT 1 FROM private.pending_signup WHERE user_id = current_setting('test.newbie')::UUID)
          AND NOT EXISTS (SELECT 1 FROM public.tenant WHERE display_name = 'Squatter Co'),
          'acceptance drops a pending self-signup of the account and never creates it');
SELECT results_eq($$ SELECT code, email, country FROM public.tenant WHERE id = current_setting('test.new_tenant')::UUID $$,
   $$ VALUES ('NEW', 'new@client.test', 'Germany') $$, 'the tenant takes the client code; its e-mail defaults to the invited one');
SELECT results_eq($$ SELECT procurement_model::TEXT, status::TEXT, client_code FROM public.provider_relationship WHERE client_tenant_id = current_setting('test.new_tenant')::UUID $$,
   $$ VALUES ('provider', 'active', 'NEW') $$, 'relationship from the invitation, already accepted');
SELECT results_eq($$ SELECT tenant_id, client_name, provider_name, commercial_model::TEXT, packages, contract_status::TEXT, start_on, deposit_rate,
                            extra_cost_rule, accepted_at IS NOT NULL
   FROM public.provider_relationship WHERE client_tenant_id = current_setting('test.new_tenant')::UUID $$,
   $$ VALUES (current_setting('test.p')::UUID, 'New Client', 'MOESA LTD', 'trading_partner', ARRAY['A1', 'B'], 'onboarding', '2026-12-01'::DATE, 30.00::NUMERIC(5, 2),
              'at cost', TRUE) $$,
   'the relationship carries the invitation''s terms');
SELECT set_eq($$ SELECT u.email || ':' || r.display_name FROM public.user_role ur JOIN public.role r ON r.id = ur.role_id JOIN public.user u ON u.id = ur.user_id
   WHERE r.tenant_id = current_setting('test.new_tenant')::UUID AND u.id <> current_setting('test.newbie')::UUID $$,
   ARRAY['koordinator@moesa-panel.test:coordinator', 'akif@moesa-panel.test:management'], 'staff and roles from the invitation');
SELECT set_eq($$ SELECT user_id FROM public.tenant_user WHERE tenant_id = current_setting('test.new_tenant')::UUID $$,
   ARRAY[current_setting('test.newbie')::UUID, current_setting('test.koordinator')::UUID, current_setting('test.akif')::UUID],
   'the staff are members of the new tenant');
SELECT is((SELECT p.display_name FROM public.subscription s JOIN public.plan p ON p.id = s.plan_id WHERE s.tenant_id = current_setting('test.new_tenant')::UUID),
          'Pro', 'the chosen plan is the subscription');
SELECT results_eq($$ SELECT i.status::TEXT, i.accepted_by, i.client_tenant_id, i.accepted_at IS NOT NULL,
                            EXISTS (SELECT 1 FROM private.provider_invitation_token h WHERE h.invitation_id = i.id)
   FROM public.provider_invitation i WHERE i.id = (SELECT id FROM inv_071 WHERE label = 'inv1') $$,
   $$ VALUES ('accepted', current_setting('test.newbie')::UUID, current_setting('test.new_tenant')::UUID, TRUE, FALSE) $$,
   'the invitation is accepted and its hash deleted');
SELECT results_eq($$ SELECT t.actor_role, t.actor_id FROM public.audit_transaction t WHERE t.id = nullif(current_setting('test.tx_accept'), '')::UUID $$,
   $$ VALUES ('provider-invitation', current_setting('test.newbie')::UUID) $$, 'the audit names the function and the accepting user (F27)');
-- Two locks on single use: the hash is gone, and were it found the status still refuses.
INSERT INTO private.provider_invitation_token (invitation_id, tenant_id, token_hash)
SELECT i.id, current_setting('test.p')::UUID, extensions.digest(i.token, 'sha256') FROM inv_071 i WHERE i.label = 'inv1';
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SET LOCAL ROLE service_role;
SELECT is(public.accept_provider_invitation(current_setting('test.newbie')::UUID, (SELECT token FROM inv_071 WHERE label = 'inv1'),
                                            '{"display_name": "Again Ltd"}', NULL) ->> 'error',
          'invitation_invalid', 'an accepted invitation is refused even with its hash restored');
RESET ROLE;
DELETE FROM private.provider_invitation_token WHERE invitation_id = (SELECT id FROM inv_071 WHERE label = 'inv1');

-- An existing owner accepts into a second, new tenant.
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SET LOCAL ROLE service_role;
SELECT lives_ok($$ SELECT public.accept_provider_invitation(current_setting('test.ali')::UUID, (SELECT token FROM inv_071 WHERE label = 'inv2'),
   '{"display_name": "Nova Ventures", "email": "ventures@nova.test"}', NULL) $$, 'an existing owner accepts into a new tenant');
RESET ROLE;
SELECT is((SELECT count(*)::INT FROM public.tenant_owner WHERE user_id = current_setting('test.ali')::UUID), 2, 'the first tenant is untouched');
SELECT results_eq($$ SELECT t.email, r.procurement_model::TEXT FROM public.tenant t JOIN public.provider_relationship r ON r.client_tenant_id = t.id
   WHERE t.display_name = 'Nova Ventures' $$, $$ VALUES ('ventures@nova.test', 'client') $$, 'with the e-mail it gave and the invitation''s model');

-- Staff who left the provider before acceptance are skipped; the others join.
SET LOCAL ROLE service_role;
SELECT is(public.accept_provider_invitation(current_setting('test.third')::UUID, (SELECT token FROM inv_071 WHERE label = 'inv3'), '{"display_name": "Third Co"}', NULL)
          -> 'skipped_staff', jsonb_build_array(current_setting('test.departed')), 'a departed staff member is skipped');
RESET ROLE;
SELECT set_eq($$ SELECT tu.user_id FROM public.tenant_user tu JOIN public.tenant t ON t.id = tu.tenant_id WHERE t.display_name = 'Third Co' $$,
   ARRAY[current_setting('test.third')::UUID, current_setting('test.koordinator')::UUID], 'the departed member does not join; the others do');

-- Expired, then the plan limit: a failure after the first write raises and leaves nothing.
SET LOCAL ROLE service_role;
SELECT is(public.accept_provider_invitation(current_setting('test.late')::UUID, (SELECT token FROM inv_071 WHERE label = 'expired'), '{"display_name": "Late Co"}', NULL)
          ->> 'error', 'invitation_invalid', 'an expired invitation is invalid');
SELECT throws_like($$ SELECT public.accept_provider_invitation(current_setting('test.small')::UUID, (SELECT token FROM inv_071 WHERE label = 'seats'),
   '{"display_name": "Small Co"}', '00000000-0000-4000-8000-000000071210') $$, '%plan_limit_users%', 'a plan below the seats fails (F11)');
RESET ROLE;
SELECT results_eq($$ SELECT i.status::TEXT, i.client_tenant_id, EXISTS (SELECT 1 FROM private.provider_invitation_token h WHERE h.invitation_id = i.id),
                            (SELECT count(*)::INT FROM public.tenant WHERE display_name = 'Small Co'),
                            (SELECT count(*)::INT FROM public.provider_relationship WHERE tenant_id = current_setting('test.p')::UUID AND client_code = 'SML'),
                            (SELECT count(*)::INT FROM public.tenant_owner WHERE user_id = current_setting('test.small')::UUID)
   FROM public.provider_invitation i WHERE i.id = (SELECT id FROM inv_071 WHERE label = 'seats') $$,
   $$ VALUES ('pending', NULL::UUID, TRUE, 0, 0, 0) $$, 'and creates nothing: no tenant, no relationship, the invitation still pending');

-- A company e-mail or phone another tenant holds: refused before any write, keeping the count (F2).
UPDATE public.tenant SET phone = '+49 30 071071' WHERE display_name = 'Nova Yazılım';
DELETE FROM private.invitation_attempt WHERE key = 'accept:' || current_setting('test.small');
SET LOCAL ROLE service_role;
SELECT is(public.accept_provider_invitation(current_setting('test.small')::UUID, (SELECT token FROM inv_071 WHERE label = 'seats'),
                                            '{"display_name": "Small Co", "email": "info@nova.test"}', NULL) ->> 'error',
          'company_email_exists', 'a company e-mail already registered is refused');
SELECT is(public.accept_provider_invitation(current_setting('test.small')::UUID, (SELECT token FROM inv_071 WHERE label = 'seats'),
                                            '{"display_name": "Small Co", "email": "INFO@Nova.Test"}', NULL) ->> 'error',
          'company_email_exists', 'and so is a case variant of it');
SELECT is(public.accept_provider_invitation(current_setting('test.small')::UUID, (SELECT token FROM inv_071 WHERE label = 'seats'),
                                            '{"display_name": "Small Co", "phone": "+49 30 071071"}', NULL) ->> 'error',
          'company_phone_exists', 'a company phone already registered is refused');
RESET ROLE;
SELECT results_eq($$ SELECT (SELECT count FROM private.invitation_attempt WHERE key = 'accept:' || current_setting('test.small')),
                            (SELECT count(*)::INT FROM public.tenant WHERE display_name = 'Small Co'),
                            (SELECT status::TEXT FROM public.provider_invitation WHERE id = (SELECT id FROM inv_071 WHERE label = 'seats')) $$,
   $$ VALUES (3, 0, 'pending') $$, 'every refusal is counted by the throttle and creates nothing');

-- I2: the accepter keeps only some of the staff, by the preview's indexes. The 'seats' invitation
-- brings koordinator and akif; with akif dropped it fits the two-user plan it did not fit before.
SELECT private.impersonate_scope(current_setting('test.small')::UUID, NULL, '{}'::UUID[]);
INSERT INTO acc_071 SELECT 'preview_small', public.invitation_preview((SELECT token FROM inv_071 WHERE label = 'seats'));
RESET ROLE;
SELECT private.unimpersonate();
SELECT set_config('test.koordinator_index',
                  (SELECT s ->> 'index' FROM acc_071, jsonb_array_elements(result -> 'staff') s
                   WHERE label = 'preview_small' AND s ->> 'role_name' = 'coordinator'), TRUE);
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SET LOCAL ROLE service_role;
SELECT is(public.accept_provider_invitation(current_setting('test.small')::UUID, (SELECT token FROM inv_071 WHERE label = 'seats'),
                                            '{"display_name": "Small Co"}', NULL, '[7]') ->> 'error',
          'invitation_payload_invalid', 'a staff choice must name the preview''s indexes');
SELECT is(public.accept_provider_invitation(current_setting('test.small')::UUID, (SELECT token FROM inv_071 WHERE label = 'seats'),
                                            '{"display_name": "Small Co"}', NULL, '{"0": true}') ->> 'error',
          'invitation_payload_invalid', 'as an array of integers');
SELECT is(public.accept_provider_invitation(current_setting('test.small')::UUID, (SELECT token FROM inv_071 WHERE label = 'seats'),
                                            '{"display_name": "Small Co"}', NULL, '[0.5]') ->> 'error',
          'invitation_payload_invalid', 'and nothing else');
SELECT is(public.accept_provider_invitation(current_setting('test.small')::UUID, (SELECT token FROM inv_071 WHERE label = 'seats'),
                                            '{"display_name": "Small Co"}', NULL, '[1.0]') ->> 'error',
          'invitation_payload_invalid', 'an integral float is not an integer index: refused, never a cast error');
SELECT ok(public.accept_provider_invitation(current_setting('test.small')::UUID, (SELECT token FROM inv_071 WHERE label = 'seats'),
                                            '{"display_name": "Small Co"}', '00000000-0000-4000-8000-000000071210',
                                            jsonb_build_array(current_setting('test.koordinator_index')::INT)) ? 'tenant_id',
          'the accepter keeps one of two staff, on a plan that fits the seats they chose');
RESET ROLE;
SELECT results_eq($$ SELECT u.email || ':' || r.display_name FROM public.tenant t JOIN public.tenant_user tu ON tu.tenant_id = t.id
                     JOIN public.user u ON u.id = tu.user_id
                     LEFT JOIN public.user_role ur ON ur.user_id = tu.user_id
                     LEFT JOIN public.role r ON r.id = ur.role_id AND r.tenant_id = t.id
                     WHERE t.display_name = 'Small Co' AND tu.user_id <> current_setting('test.small')::UUID AND r.id IS NOT NULL $$,
   $$ VALUES ('koordinator@moesa-panel.test:coordinator') $$, 'only the kept staff member joins, in their role');

-- The insider: invited, then a member of MOESA LTD; acceptance refuses and writes nothing (decision 19).
SET LOCAL ROLE service_role;
SELECT is(public.accept_provider_invitation(current_setting('test.insider')::UUID, (SELECT token FROM inv_071 WHERE label = 'insider'),
                                            '{"display_name": "Insider Co"}', NULL),
          '{"error": "invitation_self_invite"}'::JSONB,
          'an invited account that joined the provider''s company since is refused at acceptance');
RESET ROLE;
SELECT results_eq($$ SELECT (SELECT count(*)::INT FROM public.tenant WHERE display_name = 'Insider Co'),
                            (SELECT status::TEXT FROM public.provider_invitation WHERE id = (SELECT id FROM inv_071 WHERE label = 'insider')),
                            (SELECT failed_attempts FROM public.provider_invitation WHERE id = (SELECT id FROM inv_071 WHERE label = 'insider')) $$,
   $$ VALUES (0, 'pending', 0) $$, 'and leaves the invitation pending, no tenant made, no failed attempt counted');

-- A staff role missing in the new tenant fails the whole call: never a member without a role. Only
-- reachable past the role CHECK, so the test lifts it for one row.
ALTER TABLE public.provider_invitation_staff DROP CONSTRAINT provider_invitation_staff_role_name_check;
-- The staff row has an id, so the audit diffs its update like any other.
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT lives_ok($$ UPDATE public.provider_invitation_staff SET role_name = 'auditor'
   WHERE invitation_id = (SELECT id FROM inv_071 WHERE label = 'badrole') $$, 'a staff row update is audited without error');
SELECT ok(EXISTS (SELECT 1 FROM public.audit_log l
                  WHERE l.table_name = 'provider_invitation_staff' AND l.operation = 'UPDATE'
                    AND l.new_data ->> 'role_name' = 'auditor' AND l.old_data ->> 'role_name' = 'coordinator'),
          'and the audit log holds its old and new values');
SET LOCAL ROLE service_role;
SELECT throws_ok($$ SELECT public.accept_provider_invitation(current_setting('test.badrole')::UUID, (SELECT token FROM inv_071 WHERE label = 'badrole'),
   '{"display_name": "Badrole Co"}', NULL) $$, '23514', 'invitation_staff_invalid', 'a staff role missing in the new tenant fails the call');
RESET ROLE;
SELECT results_eq($$ SELECT (SELECT count(*)::INT FROM public.tenant WHERE display_name = 'Badrole Co'),
                            (SELECT status::TEXT FROM public.provider_invitation WHERE id = (SELECT id FROM inv_071 WHERE label = 'badrole')) $$,
   $$ VALUES (0, 'pending') $$, 'and leaves nothing behind');
DELETE FROM public.provider_invitation_staff WHERE invitation_id = (SELECT id FROM inv_071 WHERE label = 'badrole');
ALTER TABLE public.provider_invitation_staff ADD CONSTRAINT provider_invitation_staff_role_name_check
   CHECK (role_name IN ('management', 'coordinator', 'viewer'));

-- The accept throttle: 10 per user per hour, and the refusal keeps its count (F2).
INSERT INTO private.invitation_attempt (key, window_start, count) VALUES ('accept:' || current_setting('test.small'), now(), 10)
ON CONFLICT (key) DO UPDATE SET window_start = now(), count = 10;
SET LOCAL ROLE service_role;
SELECT is(public.accept_provider_invitation(current_setting('test.small')::UUID, (SELECT token FROM inv_071 WHERE label = 'seats'), '{"display_name": "Small Co"}', NULL)
          ->> 'error', 'invitation_throttled', 'the 11th acceptance in an hour is refused');
RESET ROLE;
SELECT is((SELECT count FROM private.invitation_attempt WHERE key = 'accept:' || current_setting('test.small')), 11, 'the refused attempt is still counted');

-- Ten failed attempts lock the invitation until the provider resends it.
UPDATE public.provider_invitation SET failed_attempts = 9 WHERE id = (SELECT id FROM inv_071 WHERE label = 'lock');
SET LOCAL ROLE service_role;
SELECT is(public.accept_provider_invitation(current_setting('test.third')::UUID, (SELECT token FROM inv_071 WHERE label = 'lock'), '{"display_name": "Lock Co"}', NULL)
          ->> 'error', 'invitation_email_mismatch', 'the tenth failed attempt');
SELECT is(public.accept_provider_invitation(current_setting('test.lockee')::UUID, (SELECT token FROM inv_071 WHERE label = 'lock'), '{"display_name": "Lock Co"}', NULL)
          ->> 'error', 'invitation_invalid', 'locks the invitation, even for the invited user');
INSERT INTO inv_071 SELECT 'lock2', (SELECT id FROM inv_071 WHERE label = 'lock'),
   public.rotate_provider_invitation_token((SELECT id FROM inv_071 WHERE label = 'lock'), current_setting('test.baris')::UUID);
SELECT ok(public.accept_provider_invitation(current_setting('test.lockee')::UUID, (SELECT token FROM inv_071 WHERE label = 'lock2'), '{"display_name": "Lock Co"}', NULL)
          ? 'tenant_id', 'after a resend the invited user accepts');
RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);

-- A client tenant is not deleted while a relationship names it (F14).
SELECT throws_ok($$ DELETE FROM public.tenant WHERE id = current_setting('test.new_tenant')::UUID $$,
   '23503', 'tenant_has_provider_relationship', 'a client tenant with a relationship cannot be deleted');
INSERT INTO public.tenant (id, display_name) VALUES ('00000000-0000-4000-8000-000000071211', 'Lonely 071');
SELECT lives_ok($$ DELETE FROM public.tenant WHERE id = '00000000-0000-4000-8000-000000071211' $$, 'a tenant no relationship names is deleted as before');
INSERT INTO public.tenant (id, display_name) VALUES ('00000000-0000-4000-8000-000000071212', 'Provider 071');
INSERT INTO public.provider_relationship (tenant_id, client_tenant_id, client_code, client_name, provider_name, procurement_model)
VALUES ('00000000-0000-4000-8000-000000071212', current_setting('test.atlas')::UUID, 'PRV', 'Atlas', 'Provider 071', 'client');
SELECT lives_ok($$ DELETE FROM public.tenant WHERE id = '00000000-0000-4000-8000-000000071212' $$,
   'a provider deletes its own tenant: its relationships go with it');
SELECT is_empty($$ SELECT 1 FROM public.provider_relationship WHERE tenant_id = '00000000-0000-4000-8000-000000071212' $$,
   'no relationship of the deleted provider is left');

-- The attempt counters are pruned as they go: a row whose window started over a day ago is gone
-- after the next attempt; a current one stays.
INSERT INTO private.invitation_attempt (key, window_start, count) VALUES ('preview:stale-071', now() - interval '2 days', 3),
                                                                         ('preview:fresh-071', now() - interval '1 hour', 3);
SELECT private.impersonate_scope(current_setting('test.newbie')::UUID, NULL, '{}'::UUID[]);
SELECT public.invitation_preview('not-a-token');
RESET ROLE;
SELECT private.unimpersonate();
SELECT results_eq($$ SELECT key FROM private.invitation_attempt WHERE key LIKE 'preview:%-071' $$, $$ VALUES ('preview:fresh-071') $$,
   'stale attempt rows are pruned, current ones kept');

-- ---------------------------------------------------------------------------------------------
-- Section 3: the Edge Function's undo of an invitation whose e-mail was not sent (Task 5).
SELECT ok(has_function_privilege('service_role', 'public.revoke_unsent_provider_invitation(uuid,uuid)', 'EXECUTE')
          AND NOT has_function_privilege('authenticated', 'public.revoke_unsent_provider_invitation(uuid,uuid)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.revoke_unsent_provider_invitation(uuid,uuid)', 'EXECUTE'),
          'only the service role (the Edge Function) discards an unsent invitation');

DELETE FROM private.provider_invitation_issue WHERE tenant_id = current_setting('test.p')::UUID;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SET LOCAL ROLE service_role;
INSERT INTO inv_071 SELECT 'unsent', i.id, i.token FROM public.create_provider_invitation(
   current_setting('test.p')::UUID, current_setting('test.baris')::UUID,
   '{"email": "unsent@client.test", "company_name": "Unsent Ltd", "client_code": "UNS", "procurement_model": "provider"}', '[]') i;
SELECT throws_ok($$ SELECT public.revoke_unsent_provider_invitation((SELECT id FROM inv_071 WHERE label = 'unsent'), current_setting('test.koordinator')::UUID) $$,
   '42501', 'invitation_forbidden', 'another member of the provider cannot discard it');
SELECT throws_ok($$ SELECT public.revoke_unsent_provider_invitation((SELECT id FROM inv_071 WHERE label = 'unsent'), current_setting('test.limited')::UUID) $$,
   '42501', 'invitation_forbidden', 'nor can a reader');
SELECT throws_ok($$ SELECT public.revoke_unsent_provider_invitation((SELECT id FROM inv_071 WHERE label = 'unsent'), NULL) $$,
   '42501', 'invitation_forbidden', 'nor can nobody');
-- A creator who no longer holds the insert right (the reader stands in as creator for one call).
RESET ROLE;
UPDATE public.provider_invitation SET created_by = current_setting('test.limited')::UUID WHERE id = (SELECT id FROM inv_071 WHERE label = 'unsent');
SET LOCAL ROLE service_role;
SELECT throws_ok($$ SELECT public.revoke_unsent_provider_invitation((SELECT id FROM inv_071 WHERE label = 'unsent'), current_setting('test.limited')::UUID) $$,
   '42501', 'invitation_forbidden', 'a creator without the insert right cannot discard it');
RESET ROLE;
UPDATE public.provider_invitation SET created_by = current_setting('test.baris')::UUID WHERE id = (SELECT id FROM inv_071 WHERE label = 'unsent');
-- Only a just-issued token is "unsent" (M3): an invitation whose token went out over 10 minutes
-- ago, or one created over 10 minutes ago (a resend refreshes only the token), is left alone.
UPDATE private.provider_invitation_token SET issued_at = now() - interval '11 minutes' WHERE invitation_id = (SELECT id FROM inv_071 WHERE label = 'unsent');
SET LOCAL ROLE service_role;
SELECT throws_ok($$ SELECT public.revoke_unsent_provider_invitation((SELECT id FROM inv_071 WHERE label = 'unsent'), current_setting('test.baris')::UUID) $$,
   '42501', 'invitation_forbidden', 'a token issued over 10 minutes ago is not discarded');
SELECT lives_ok($$ SELECT public.rotate_provider_invitation_token((SELECT id FROM inv_071 WHERE label = 'unsent'), current_setting('test.baris')::UUID) $$,
   'a resend issues a new token');
RESET ROLE;
SELECT is((SELECT issued_at FROM private.provider_invitation_token WHERE invitation_id = (SELECT id FROM inv_071 WHERE label = 'unsent')), now(),
          'and records when it was issued');
UPDATE public.provider_invitation SET created_at = now() - interval '11 minutes' WHERE id = (SELECT id FROM inv_071 WHERE label = 'unsent');
SET LOCAL ROLE service_role;
SELECT throws_ok($$ SELECT public.revoke_unsent_provider_invitation((SELECT id FROM inv_071 WHERE label = 'unsent'), current_setting('test.baris')::UUID) $$,
   '42501', 'invitation_forbidden', 'an invitation created over 10 minutes ago is not discarded, even with a fresh token');
RESET ROLE;
UPDATE public.provider_invitation SET created_at = now() WHERE id = (SELECT id FROM inv_071 WHERE label = 'unsent');
SET LOCAL ROLE service_role;
SELECT throws_ok($$ SELECT public.revoke_unsent_provider_invitation(gen_random_uuid(), current_setting('test.baris')::UUID) $$,
   '42501', 'invitation_forbidden', 'an unknown invitation is refused like a forbidden one');
SELECT lives_ok($$ SELECT public.revoke_unsent_provider_invitation((SELECT id FROM inv_071 WHERE label = 'unsent'), current_setting('test.baris')::UUID) $$,
   'its creator discards it');
SELECT throws_ok($$ SELECT public.revoke_unsent_provider_invitation((SELECT id FROM inv_071 WHERE label = 'unsent'), current_setting('test.baris')::UUID) $$,
   '42501', 'invitation_forbidden', 'a revoked invitation (its token is gone) cannot be discarded again');
RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);

SELECT results_eq($$ SELECT status::TEXT, revoked_at IS NOT NULL FROM public.provider_invitation WHERE id = (SELECT id FROM inv_071 WHERE label = 'unsent') $$,
   $$ VALUES ('revoked', TRUE) $$, 'the unsent invitation is revoked');
SELECT is_empty($$ SELECT 1 FROM private.provider_invitation_token WHERE invitation_id = (SELECT id FROM inv_071 WHERE label = 'unsent') $$,
   'and its hash is gone');
SELECT is((SELECT count(*)::INT FROM private.provider_invitation_issue WHERE invitation_id = (SELECT id FROM inv_071 WHERE label = 'unsent')), 2,
          'every token issued still counts toward the cap, the discarded one included');

-- ---------------------------------------------------------------------------------------------
-- Section 3: provider staff may join a client tenant (Task 6). The relationship alone reads
-- nothing; this answer only lets the client owner add the member, who has no role until assigned.

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000071301', 'stranger@staff.test'),
   ('00000000-0000-4000-8000-000000071302', 'clientmember@staff.test'),
   ('00000000-0000-4000-8000-000000071303', 'formerstaff@staff.test');
INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000071302', current_setting('test.c')::UUID);
INSERT INTO public.user (id, email) VALUES ('00000000-0000-4000-8000-000000071307', 'linked@staff.test');
INSERT INTO public.tenant_user (user_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000071307', current_setting('test.p')::UUID);
INSERT INTO public.tenant (id, display_name, parent_id) VALUES
   ('00000000-0000-4000-8000-000000071304', 'THO branch 071', current_setting('test.c')::UUID);
-- A provider whose relationship with Atlas has ended; formerstaff is its only member.
INSERT INTO public.tenant (id, display_name) VALUES ('00000000-0000-4000-8000-000000071305', 'Old provider 071');
INSERT INTO public.tenant_user (user_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000071303', '00000000-0000-4000-8000-000000071305');
INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, provider_name, procurement_model)
VALUES ('00000000-0000-4000-8000-000000071306', '00000000-0000-4000-8000-000000071305', current_setting('test.atlas')::UUID,
        'OLD', 'Atlas', 'Old provider 071', 'client');

SELECT ok(public.is_provider_staff(current_setting('test.c')::UUID, current_setting('test.koordinator')::UUID),
          'a member of the provider is provider staff of its client');
SELECT ok(public.is_provider_staff('00000000-0000-4000-8000-000000071304', current_setting('test.koordinator')::UUID),
          'also for a branch of the client company: the relationship names the company root');
SELECT ok(NOT public.is_provider_staff(current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000071301'),
          'a stranger is not provider staff');
SELECT ok(NOT public.is_provider_staff(current_setting('test.c')::UUID, current_setting('test.thomas')::UUID),
          'nor is the client owner: ownership is not provider membership');
SELECT ok(NOT public.is_provider_staff(current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000071302'),
          'the reverse direction does not count: a client member is not provider staff');
SELECT ok(NOT public.is_provider_staff(current_setting('test.p')::UUID, current_setting('test.thomas')::UUID)
          AND NOT public.is_provider_staff(current_setting('test.p')::UUID, '00000000-0000-4000-8000-000000071302'),
          'and the client is not a provider of its own provider');
SELECT ok(public.is_provider_staff(current_setting('test.atlas')::UUID, '00000000-0000-4000-8000-000000071303'),
          'while the relationship is active, its provider''s member is staff');
UPDATE public.provider_relationship SET status = 'ended' WHERE id = '00000000-0000-4000-8000-000000071306';
SELECT ok(NOT public.is_provider_staff(current_setting('test.atlas')::UUID, '00000000-0000-4000-8000-000000071303'),
          'once the relationship has ended, its provider''s member is no longer staff');
-- M3: staff of the provider's branches count, under the same active relationship.
INSERT INTO public.tenant (id, display_name, parent_id) VALUES
   ('00000000-0000-4000-8000-000000071308', 'Provider branch 071', current_setting('test.p')::UUID),
   ('00000000-0000-4000-8000-000000071309', 'Old provider branch 071', '00000000-0000-4000-8000-000000071305');
INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000071310', 'branchstaff@staff.test'),
   ('00000000-0000-4000-8000-000000071311', 'oldbranchstaff@staff.test');
INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000071310', '00000000-0000-4000-8000-000000071308'),
   ('00000000-0000-4000-8000-000000071311', '00000000-0000-4000-8000-000000071309');
SELECT ok(public.is_provider_staff(current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000071310'),
          'a member of a branch of the provider is provider staff of its client');
SELECT ok(NOT public.is_provider_staff(current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000071301')
          AND NOT public.is_provider_staff('00000000-0000-4000-8000-000000071305', '00000000-0000-4000-8000-000000071310'),
          'a stranger is not, nor is the branch member for a company the provider does not serve');
SELECT ok(NOT public.is_provider_staff(current_setting('test.atlas')::UUID, '00000000-0000-4000-8000-000000071311'),
          'a branch member of a provider whose relationship has ended is not provider staff');
-- M2 is not widened: a provider of the provider's own company, whose staff sit in the provider's
-- branch as guests, does not make them staff of the provider's clients through that branch.
INSERT INTO public.tenant (id, display_name) VALUES ('00000000-0000-4000-8000-000000071312', 'Upstream provider 071');
INSERT INTO public.user (id, email) VALUES ('00000000-0000-4000-8000-000000071313', 'upstream@staff.test');
INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000071313', '00000000-0000-4000-8000-000000071312'),
   ('00000000-0000-4000-8000-000000071313', '00000000-0000-4000-8000-000000071308');
INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, provider_name, procurement_model)
VALUES ('00000000-0000-4000-8000-000000071314', '00000000-0000-4000-8000-000000071312', current_setting('test.p')::UUID,
        'UPS', 'Provider 071', 'Upstream provider 071', 'client');
SELECT ok(NOT public.is_provider_staff(current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000071313'),
          'a guest of the provider''s branch who is staff of the provider''s own provider is not provider staff');
SELECT ok(public.is_provider_staff(current_setting('test.c')::UUID, '00000000-0000-4000-8000-000000071310'),
          'while the branch''s own staff still are');
SELECT ok(NOT has_function_privilege('authenticated', 'public.is_provider_staff(uuid,uuid)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.is_provider_staff(uuid,uuid)', 'EXECUTE')
          AND NOT has_function_privilege('public', 'public.is_provider_staff(uuid,uuid)', 'EXECUTE'),
          'authenticated and anon cannot execute it');
SELECT ok(has_function_privilege('service_role', 'public.is_provider_staff(uuid,uuid)', 'EXECUTE'),
          'the service role (the user Edge Function) can');
SELECT ok((SELECT coalesce('search_path=""' = ANY (proconfig), FALSE) AND prosecdef FROM pg_proc WHERE oid = 'public.is_provider_staff(uuid,uuid)'::REGPROCEDURE),
          'it is SECURITY DEFINER with an empty search_path');

-- A linked staff member has no role in the client tenant until its owner assigns one, and the owner
-- can then assign, replace and remove roles there, as the app's save does (set_user_roles).
SELECT set_config('test.kroles', (SELECT count(*)::TEXT FROM public.user_role ur JOIN public.role r ON r.id = ur.role_id
                                  WHERE ur.user_id = '00000000-0000-4000-8000-000000071307'::UUID AND r.tenant_id = current_setting('test.p')::UUID), TRUE);
INSERT INTO public.tenant_user (user_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000071307'::UUID, current_setting('test.c')::UUID);
SELECT is((SELECT count(*)::INT FROM public.user_role ur JOIN public.role r ON r.id = ur.role_id
           WHERE ur.user_id = '00000000-0000-4000-8000-000000071307'::UUID AND r.tenant_id = current_setting('test.c')::UUID), 0,
          'linking provider staff to the client tenant gives them no role there');
SELECT set_config('test.crole', (SELECT id::TEXT FROM public.role WHERE tenant_id = current_setting('test.c')::UUID ORDER BY created_at LIMIT 1), TRUE);
SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('test.thomas'), 'role', 'authenticated')::TEXT, TRUE);
SELECT set_config('request.headers', json_build_object('x-tenant-id', current_setting('test.c'))::TEXT, TRUE);
SET LOCAL ROLE authenticated;
SELECT lives_ok($$ SELECT public.set_user_roles('00000000-0000-4000-8000-000000071307'::UUID,
   ARRAY[current_setting('test.crole')::UUID]) $$,
   'the client owner assigns a role to the linked staff member');
RESET ROLE;
SELECT is((SELECT count(*)::INT FROM public.user_role ur JOIN public.role r ON r.id = ur.role_id
           WHERE ur.user_id = '00000000-0000-4000-8000-000000071307'::UUID AND r.tenant_id = current_setting('test.c')::UUID), 1,
          'and the role is there, in the client tenant');
SELECT is((SELECT count(*)::INT FROM public.user_role ur JOIN public.role r ON r.id = ur.role_id
           WHERE ur.user_id = '00000000-0000-4000-8000-000000071307'::UUID AND r.tenant_id = current_setting('test.p')::UUID),
          current_setting('test.kroles')::INT,
          'their provider roles are untouched');
SELECT set_config('request.jwt.claims', '', TRUE);

SELECT * FROM finish();
ROLLBACK;
