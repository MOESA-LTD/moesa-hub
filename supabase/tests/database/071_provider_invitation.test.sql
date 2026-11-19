CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Provider invitations (Plan 3, decision 16): the provider invites a customer by e-mail; the link
-- carries a token whose SHA-256 hash alone is kept, in private.provider_invitation_token, which no
-- API role reads (F3).
-- Sections: the invitation, its token, create / rotate / revoke (Task 3); preview and acceptance (Task 4).
BEGIN;

SELECT plan(116);

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
             ('00000000-0000-4000-8000-000000071207', 'lockee@client.test')) AS v (id, email);
SELECT set_config('test.newbie', '00000000-0000-4000-8000-000000071201', TRUE);
SELECT set_config('test.other', '00000000-0000-4000-8000-000000071202', TRUE);
SELECT set_config('test.third', '00000000-0000-4000-8000-000000071203', TRUE);
SELECT set_config('test.departed', '00000000-0000-4000-8000-000000071204', TRUE);
SELECT set_config('test.late', '00000000-0000-4000-8000-000000071205', TRUE);
SELECT set_config('test.small', '00000000-0000-4000-8000-000000071206', TRUE);
SELECT set_config('test.lockee', '00000000-0000-4000-8000-000000071207', TRUE);
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
SELECT ok(NOT has_function_privilege('authenticated', 'public.accept_provider_invitation(uuid,text,jsonb,uuid)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.accept_provider_invitation(uuid,text,jsonb,uuid)', 'EXECUTE')
          AND has_function_privilege('service_role', 'public.accept_provider_invitation(uuid,text,jsonb,uuid)', 'EXECUTE'),
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
RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);

UPDATE public.provider_invitation SET expires_at = now() - interval '1 second' WHERE id = (SELECT id FROM inv_071 WHERE label = 'expired');
DELETE FROM public.tenant_user WHERE user_id = current_setting('test.departed')::UUID AND tenant_id = current_setting('test.p')::UUID;
SELECT is((SELECT count(*)::INT FROM inv_071 WHERE label IN ('inv1', 'inv2', 'inv3', 'expired', 'seats', 'lock')), 6, 'the fixture invitations are made');

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
         'needs_password', 'plans'],
   'the preview carries exactly the documented keys');
SELECT ok((SELECT result::TEXT NOT LIKE ALL (ARRAY['%' || current_setting('test.koordinator') || '%', '%' || current_setting('test.akif') || '%',
                                                   '%koordinator@%', '%akif@%', '%' || i.token || '%',
                                                   '%' || encode(extensions.digest(i.token, 'sha256'), 'hex') || '%',
                                                   '%' || encode(extensions.digest(i.token, 'sha256'), 'base64') || '%'])
           FROM acc_071 a, inv_071 i WHERE a.label = 'preview1' AND i.label = 'inv1'),
          'no staff identity, token or hash in the preview');
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
SELECT results_eq($$ SELECT i.status::TEXT, i.failed_attempts, EXISTS (SELECT 1 FROM private.provider_invitation_token h WHERE h.invitation_id = i.id)
   FROM public.provider_invitation i WHERE i.id = (SELECT id FROM inv_071 WHERE label = 'inv1') $$,
   $$ VALUES ('pending', 1, TRUE) $$, 'previewing consumes nothing; the other account''s attempt is counted');

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
SELECT is((SELECT failed_attempts FROM public.provider_invitation WHERE id = (SELECT id FROM inv_071 WHERE label = 'inv1')), 2,
          'the mismatch is counted, and the count survives the refusal');
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
SELECT set_config('audit.transaction_id', '', TRUE);
SET LOCAL ROLE service_role;

SELECT lives_ok($$ INSERT INTO acc_071 SELECT 'inv1', public.accept_provider_invitation(current_setting('test.newbie')::UUID,
   (SELECT token FROM inv_071 WHERE label = 'inv1'), '{"display_name": "New Client GmbH", "country": "Germany"}', current_setting('test.pro_plan')::UUID) $$,
   'the invited user accepts');
SELECT set_config('test.tx_accept', current_setting('audit.transaction_id', TRUE), TRUE);
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

SELECT * FROM finish();
ROLLBACK;
