CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Provider invitations (Plan 3, decision 16): the provider invites a customer by e-mail; the link
-- carries a token whose SHA-256 hash alone is kept, in private.provider_invitation_token, which no
-- API role reads (F3).
-- Sections: the invitation, its token, create / rotate / revoke (Task 3).
BEGIN;

SELECT plan(60);

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

SELECT * FROM finish();
ROLLBACK;
