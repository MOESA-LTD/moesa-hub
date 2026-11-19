CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Onboarding (Plan 3): open self-signup is a platform setting, off by default and changed by the
-- super admin only (decision 17); plans say who they suit (plan.audience).
-- Sections: platform setting and audience (Task 1); company creation and standard roles (Task 2);
-- verify-first self-signup: complete_signup and signup_throttle (Task 11, task-5-review I1).
BEGIN;

SELECT plan(60);

SELECT is((SELECT value FROM private.platform_setting WHERE key = 'open_signup'), 'false'::JSONB, 'open signup is off by default');

SELECT is(public.open_signup_enabled(), FALSE, 'open_signup_enabled reads it');

SELECT ok(NOT has_function_privilege('authenticated', 'public.open_signup_enabled()', 'EXECUTE'), 'only the service role asks');

-- A company owner (ayse), then the super admin (admin).
RESET ROLE;
SELECT private.impersonate_scope((SELECT id FROM auth.users WHERE email = 'ayse@moesa-panel.test'),
                                 (SELECT t.id FROM public.tenant t JOIN public.tenant_owner o ON o.tenant_id = t.id
                                  WHERE o.user_id = (SELECT id FROM auth.users WHERE email = 'ayse@moesa-panel.test') LIMIT 1),
                                 NULL);

SELECT throws_ok($$ SELECT public.set_platform_setting('open_signup', 'true') $$, '42501', NULL, 'a company owner cannot open signup');

RESET ROLE;
SELECT private.unimpersonate();
SELECT private.impersonate_scope((SELECT id FROM auth.users WHERE email = 'admin@moesa-panel.test'), NULL, NULL);

SELECT lives_ok($$ SELECT public.set_platform_setting('open_signup', 'true') $$, 'the super admin can');

RESET ROLE;
SELECT private.unimpersonate();
SELECT has_column('public', 'plan', 'audience', 'plans say who they suit');

-- Decision 21: whom a plan is offered to (plan.target); audience stays its description.
SELECT enum_has_labels('public', 'plan_target', ARRAY['client', 'provider', 'all'], 'a plan targets clients, providers or all');
SELECT col_type_is('public', 'plan', 'target', 'plan_target', 'plan.target is a plan_target');
SELECT col_not_null('public', 'plan', 'target', 'every plan has a target');
SELECT col_default_is('public', 'plan', 'target', 'all', 'a plan is offered to all unless set');
SELECT is((SELECT class FROM public.field_class WHERE resource_name = 'public.plan' AND field = 'target'), 'open',
          'plan.target is classified (open)');

-- save_plan carries it (the admin plan editor): stored, kept when left out, changed when given.
CREATE TEMP TABLE plan_070 (id UUID) ON COMMIT DROP;
GRANT ALL ON plan_070 TO authenticated;
SELECT private.impersonate_scope((SELECT id FROM auth.users WHERE email = 'admin@moesa-panel.test'), NULL, NULL);
INSERT INTO plan_070 SELECT public.save_plan('{"display_name": "Target 070", "target": "provider"}', '{}', '{}');
SELECT is((SELECT target::TEXT FROM api.plan WHERE id = (SELECT id FROM plan_070)), 'provider', 'save_plan stores the target');
SELECT public.save_plan(jsonb_build_object('id', (SELECT id FROM plan_070), 'display_name', 'Target 070 renamed'), '{}', '{}');
SELECT is((SELECT target::TEXT FROM api.plan WHERE id = (SELECT id FROM plan_070)), 'provider', 'and keeps it when the payload leaves it out');
SELECT public.save_plan(jsonb_build_object('id', (SELECT id FROM plan_070), 'display_name', 'Target 070', 'target', 'client'), '{}', '{}');
SELECT is((SELECT target::TEXT FROM api.plan WHERE id = (SELECT id FROM plan_070)), 'client', 'and changes it when given');
RESET ROLE;
SELECT private.unimpersonate();

-- Cleanup concern 1: a company e-mail is unique whatever its case (lower(email)); NULLs repeat.
SELECT is_empty($$ SELECT 1 FROM pg_constraint WHERE conrelid = 'public.tenant'::REGCLASS AND conname = 'tenant_email_key' $$,
                'the exact e-mail key is gone');
SELECT ok(EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'tenant' AND indexname = 'tenant_email_lower_key'
                  AND indexdef LIKE 'CREATE UNIQUE INDEX%(lower(email))'),
          'a unique index on lower(email) replaces it');
SELECT throws_ok($$ INSERT INTO public.tenant (display_name, email) VALUES ('Case 070', 'INFO@Atlas.test') $$,
                 '23505', 'duplicate key value violates unique constraint "tenant_email_lower_key"',
                 'a case variant of a company e-mail is refused');
SELECT lives_ok($$ INSERT INTO public.tenant (display_name) VALUES ('No mail 070 a'), ('No mail 070 b') $$,
                'companies without an e-mail may be many');

-- Section 2: one company-creation path (private.create_company) with the standard roles.
-- Fixtures: an inactive plan and a company owned by ayse, created by the service-only path.
INSERT INTO public.plan (id, display_name, is_active) VALUES ('00000000-0000-4000-8000-000000070201', 'Retired 070', FALSE);
-- An active plan for providers only (decision 21).
INSERT INTO public.plan (id, display_name, is_active, target) VALUES ('00000000-0000-4000-8000-000000070202', 'Providers 070', TRUE, 'provider');

SELECT throws_ok(
    $$ SELECT private.create_company((SELECT id FROM auth.users WHERE email = 'ayse@moesa-panel.test'),
                                     '{"display_name": "Injected 070", "tenant_id": "00000000-0000-4000-8000-000000000001"}', NULL) $$,
    'P0001', 'company_payload_invalid', 'a key outside the company allowlist is refused');

SELECT throws_ok(
    $$ SELECT private.create_company((SELECT id FROM auth.users WHERE email = 'ayse@moesa-panel.test'),
                                     '{"display_name": "Retired plan 070", "email": "retired070@example.test"}',
                                     '00000000-0000-4000-8000-000000070201') $$,
    'P0001', 'plan_inactive', 'an inactive plan is refused');

SELECT throws_ok(
    $$ SELECT private.create_company((SELECT id FROM auth.users WHERE email = 'ayse@moesa-panel.test'),
                                     '{"display_name": "Provider plan 070", "email": "providerplan070@example.test"}',
                                     '00000000-0000-4000-8000-000000070202') $$,
    'P0001', 'plan_not_for_clients', 'a plan for providers only is refused (decision 21)');

SELECT ok(NOT has_function_privilege('authenticated', 'private.create_company(uuid, jsonb, uuid)', 'EXECUTE'),
          'a signed-in user cannot create a company directly');

CREATE TEMP TABLE created_070 ON COMMIT DROP AS
SELECT (private.create_company((SELECT id FROM auth.users WHERE email = 'ayse@moesa-panel.test'),
                               '{"display_name": "Created 070", "email": "created070@example.test", "country": "Germany"}', NULL)).id;

SELECT set_eq($$ SELECT display_name FROM public.role WHERE tenant_id = (SELECT id FROM created_070) $$,
              ARRAY['management', 'coordinator', 'viewer'], 'a new company gets the three standard roles');

SELECT ok(EXISTS (SELECT 1 FROM public.tenant_owner o JOIN created_070 c ON c.id = o.tenant_id
                  WHERE o.user_id = (SELECT id FROM auth.users WHERE email = 'ayse@moesa-panel.test'))
          AND EXISTS (SELECT 1 FROM public.tenant_user u JOIN created_070 c ON c.id = u.tenant_id
                      WHERE u.user_id = (SELECT id FROM auth.users WHERE email = 'ayse@moesa-panel.test')),
          'the owner is owner and member');

-- Self-signup: register_tenant (service role) delegates to create_company.
CREATE TEMP TABLE registered_070 (id UUID) ON COMMIT DROP;
GRANT ALL ON registered_070 TO service_role;
SELECT set_config('t.owner_070', (SELECT id FROM auth.users WHERE email = 'ayse@moesa-panel.test')::TEXT, TRUE);
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SET LOCAL ROLE service_role;
INSERT INTO registered_070
SELECT (public.register_tenant(current_setting('t.owner_070')::UUID,
                               '{"display_name": "Registered 070", "email": "registered070@example.test", "phone": null}')).id;
RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);

SELECT is((SELECT count(*)::INT FROM public.role WHERE tenant_id = (SELECT id FROM registered_070)), 3,
          'self-signup creates the company through the same path');

-- Section 3: verify-first self-signup (Task 11). The company is created only once the inbox is
-- proven (email_confirmed_at), by the service role, while signup is open, once per account, from a
-- pending sign-up kept server side (private.pending_signup).
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
SELECT '00000000-0000-0000-0000-000000000000', v.id::UUID, 'authenticated', 'authenticated', v.email, '', v.confirmed, now(), now(), '', '', '', ''
FROM (VALUES ('00000000-0000-4000-8000-000000070301', 'proven070@signup.test', now()),
             ('00000000-0000-4000-8000-000000070302', 'unproven070@signup.test', NULL::TIMESTAMPTZ),
             ('00000000-0000-4000-8000-000000070303', 'nothing070@signup.test', now()),
             ('00000000-0000-4000-8000-000000070304', 'stale070@signup.test', NULL::TIMESTAMPTZ),
             ('00000000-0000-4000-8000-000000070305', 'member070@signup.test', NULL::TIMESTAMPTZ)) AS v (id, email, confirmed);

SELECT ok(NOT has_table_privilege('authenticated', 'private.pending_signup', 'SELECT')
          AND NOT has_table_privilege('anon', 'private.pending_signup', 'SELECT')
          AND NOT has_table_privilege('service_role', 'private.pending_signup', 'SELECT')
          AND NOT has_table_privilege('service_role', 'private.pending_signup', 'INSERT'),
          'no API role reaches the pending sign-ups');

SELECT ok(bool_and(NOT has_function_privilege('authenticated', f, 'EXECUTE')
                   AND NOT has_function_privilege('anon', f, 'EXECUTE')
                   AND has_function_privilege('service_role', f, 'EXECUTE')),
          'only the service role saves, reads, completes, releases and counts sign-ups')
FROM unnest(ARRAY['public.save_pending_signup(uuid, jsonb, uuid)', 'public.pending_signup(uuid)',
                  'public.complete_signup(uuid, jsonb, uuid)', 'public.release_abandoned_signup(uuid)',
                  'public.signup_throttle(text, text)']) AS f;

SELECT public.save_pending_signup('00000000-0000-4000-8000-000000070301', '{"display_name": "Asked 070"}', NULL);
SELECT public.save_pending_signup('00000000-0000-4000-8000-000000070301', '{"display_name": "Pending 070"}',
                                  (SELECT id FROM public.plan WHERE display_name = 'Pro' AND is_active));
SELECT public.save_pending_signup('00000000-0000-4000-8000-000000070302', '{"display_name": "Unproven 070"}', NULL);

SELECT is(public.pending_signup('00000000-0000-4000-8000-000000070301') -> 'company',
          '{"display_name": "Pending 070"}'::JSONB, 'a new request replaces the earlier one');
SELECT is(public.pending_signup('00000000-0000-4000-8000-000000070303'), NULL, 'no pending sign-up reads as NULL');

UPDATE private.platform_setting SET value = 'false' WHERE key = 'open_signup';
SELECT throws_ok(
    $$ SELECT public.complete_signup('00000000-0000-4000-8000-000000070301', '{"display_name": "Closed 070"}', NULL) $$,
    'P0001', 'signup_closed', 'no company once signup is closed, even for a signup already started');
UPDATE private.platform_setting SET value = 'true' WHERE key = 'open_signup';

SELECT throws_ok(
    $$ SELECT public.complete_signup('00000000-0000-4000-8000-000000070302', '{"display_name": "Unproven 070"}', NULL) $$,
    'P0001', 'signup_unconfirmed', 'an account whose inbox is not proven gets no company');

SELECT throws_ok(
    $$ SELECT public.complete_signup(NULL, '{"display_name": "Nobody 070"}', NULL) $$,
    'P0001', 'signup_unconfirmed', 'no account, no company');

SELECT throws_ok(
    $$ SELECT public.complete_signup('00000000-0000-4000-8000-000000070303', '{"display_name": "Nothing 070"}', NULL) $$,
    'P0001', 'signup_not_pending', 'a proven account without a pending sign-up gets no company');

SELECT throws_ok(
    $$ SELECT public.complete_signup('00000000-0000-4000-8000-000000070301', '{"display_name": "Retired 070 co"}',
                                     '00000000-0000-4000-8000-000000070201') $$,
    'P0001', 'plan_inactive', 'the plan must be active');

SELECT throws_ok(
    $$ SELECT public.complete_signup('00000000-0000-4000-8000-000000070301', '{"display_name": "Provider plan 070 co"}',
                                     '00000000-0000-4000-8000-000000070202') $$,
    'P0001', 'plan_not_for_clients', 'and offered to clients (decision 21)');

SELECT throws_ok(
    $$ SELECT public.complete_signup('00000000-0000-4000-8000-000000070301', '{"display_name": "Case 070 co", "email": "Info@ATLAS.test"}', NULL) $$,
    '23505', 'duplicate key value violates unique constraint "tenant_email_lower_key"',
    'a case variant of a registered company e-mail is refused at completion (create-account names it company_email_exists)');

SELECT throws_ok(
    $$ SELECT public.complete_signup('00000000-0000-4000-8000-000000070301', '{"display_name": "Injected 070", "tenant_id": "x"}', NULL) $$,
    'P0001', 'company_payload_invalid', 'an edited company passes the same allowlist');

SELECT ok((SELECT count(*) FROM public.tenant_owner WHERE user_id = '00000000-0000-4000-8000-000000070301') = 0
          AND public.pending_signup('00000000-0000-4000-8000-000000070301') IS NOT NULL,
          'the refusals created nothing and kept the pending sign-up');

CREATE TEMP TABLE signup_070 (id UUID) ON COMMIT DROP;
GRANT ALL ON signup_070 TO service_role;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SET LOCAL ROLE service_role;
INSERT INTO signup_070
SELECT (public.complete_signup('00000000-0000-4000-8000-000000070301',
                               '{"display_name": "Edited 070", "email": "signedup070@example.test", "city": "Bursa"}',
                               (SELECT id FROM public.plan WHERE display_name = 'Pro' AND is_active))).id;
RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);

SELECT ok(EXISTS (SELECT 1 FROM public.tenant t JOIN signup_070 s ON s.id = t.id
                  WHERE t.display_name = 'Edited 070' AND t.city = 'Bursa'),
          'the proven account gets the company it confirmed (the pending one is only the default)');

SELECT is((SELECT p.display_name FROM public.subscription s JOIN public.plan p ON p.id = s.plan_id
           WHERE s.tenant_id = (SELECT id FROM signup_070)), 'Pro', 'on the chosen plan');

SELECT is(public.pending_signup('00000000-0000-4000-8000-000000070301'), NULL, 'the pending sign-up is gone');

SELECT throws_ok(
    $$ SELECT public.complete_signup('00000000-0000-4000-8000-000000070301', '{"display_name": "Second 070"}', NULL) $$,
    'P0001', 'signup_completed', 'a second completion is refused');

SELECT is((SELECT count(*)::INT FROM public.tenant_owner WHERE user_id = '00000000-0000-4000-8000-000000070301'), 1,
          'exactly one company');

-- Abandoned squats (M4, N1, N3/N5): release_abandoned_signup deletes, in one statement, an account
-- that is unconfirmed, created over a day ago (auth.users), has a pending sign-up, owns nothing and
-- is a member of nothing. Each condition is tried alone.
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
SELECT '00000000-0000-0000-0000-000000000000', v.id::UUID, 'authenticated', 'authenticated', v.email, '', v.confirmed,
       now() - v.age, now(), '', '', '', ''
FROM (VALUES ('00000000-0000-4000-8000-000000070310', 'squat070@signup.test', NULL::TIMESTAMPTZ, INTERVAL '25 hours'),
             ('00000000-0000-4000-8000-000000070311', 'young070@signup.test', NULL::TIMESTAMPTZ, INTERVAL '23 hours'),
             ('00000000-0000-4000-8000-000000070312', 'confirmed070@signup.test', now(), INTERVAL '25 hours'),
             ('00000000-0000-4000-8000-000000070313', 'nopending070@signup.test', NULL::TIMESTAMPTZ, INTERVAL '25 hours'),
             ('00000000-0000-4000-8000-000000070314', 'owner070@signup.test', NULL::TIMESTAMPTZ, INTERVAL '25 hours'),
             ('00000000-0000-4000-8000-000000070315', 'member070b@signup.test', NULL::TIMESTAMPTZ, INTERVAL '25 hours'),
             ('00000000-0000-4000-8000-000000070316', 'resigned070@signup.test', NULL::TIMESTAMPTZ, INTERVAL '25 hours')) AS v (id, email, confirmed, age);
INSERT INTO private.pending_signup (user_id, company, created_at)
SELECT v.id::UUID, '{"display_name": "Squat 070"}', now() - INTERVAL '25 hours'
FROM (VALUES ('00000000-0000-4000-8000-000000070310'), ('00000000-0000-4000-8000-000000070311'),
             ('00000000-0000-4000-8000-000000070312'), ('00000000-0000-4000-8000-000000070314'),
             ('00000000-0000-4000-8000-000000070315'), ('00000000-0000-4000-8000-000000070316')) AS v (id);
INSERT INTO public.tenant_owner (tenant_id, user_id) SELECT id, '00000000-0000-4000-8000-000000070314' FROM signup_070;
INSERT INTO public.tenant_user (tenant_id, user_id) SELECT id, '00000000-0000-4000-8000-000000070315' FROM signup_070;

SELECT ok(NOT public.release_abandoned_signup('00000000-0000-4000-8000-000000070311'), 'an account younger than a day is kept');
SELECT ok(NOT public.release_abandoned_signup('00000000-0000-4000-8000-000000070312'), 'a confirmed account is kept');
SELECT ok(NOT public.release_abandoned_signup('00000000-0000-4000-8000-000000070313'), 'an account without a pending sign-up is kept');
SELECT ok(NOT public.release_abandoned_signup('00000000-0000-4000-8000-000000070314'), 'an account owning a company is kept');
SELECT ok(NOT public.release_abandoned_signup('00000000-0000-4000-8000-000000070315'), 'an account in a company is kept');
SELECT is((SELECT count(*)::INT FROM auth.users WHERE id::TEXT LIKE '00000000-0000-4000-8000-00000007031%'
                                                   AND id <> '00000000-0000-4000-8000-000000070310'
                                                   AND id <> '00000000-0000-4000-8000-000000070316'), 5,
          'the refused releases deleted nothing');

SELECT ok(public.release_abandoned_signup('00000000-0000-4000-8000-000000070310'), 'an abandoned squat is released');
SELECT ok(NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '00000000-0000-4000-8000-000000070310')
          AND public.pending_signup('00000000-0000-4000-8000-000000070310') IS NULL,
          'the account and its pending sign-up are gone');

-- N1: signing the address up again does not make the squat young again.
SELECT public.save_pending_signup('00000000-0000-4000-8000-000000070316', '{"display_name": "Again 070"}', NULL);
SELECT ok((public.pending_signup('00000000-0000-4000-8000-000000070316') ->> 'created_at')::TIMESTAMPTZ < now() - INTERVAL '24 hours'
          AND public.pending_signup('00000000-0000-4000-8000-000000070316') -> 'company' = '{"display_name": "Again 070"}',
          'a repeated sign-up replaces the company and keeps the first date');
SELECT ok(public.release_abandoned_signup('00000000-0000-4000-8000-000000070316'), 'and the account is still released');

DELETE FROM auth.users WHERE id = '00000000-0000-4000-8000-000000070302';
SELECT is(public.pending_signup('00000000-0000-4000-8000-000000070302'), NULL, 'deleting the account deletes its pending sign-up');

-- The throttle: five an hour per address, thirty per client address, two hundred in all.
DELETE FROM private.invitation_attempt WHERE key LIKE 'signup:%';
SELECT is(ARRAY(SELECT public.signup_throttle('Throttled070@signup.test', '203.0.113.70') FROM generate_series(1, 6)),
          ARRAY[TRUE, TRUE, TRUE, TRUE, TRUE, FALSE], 'five sign-ups an hour per address');
SELECT ok(public.signup_throttle('other070@signup.test', '203.0.113.70'), 'another address is not throttled');

DELETE FROM private.invitation_attempt WHERE key LIKE 'signup:%';
SELECT is((SELECT array_agg(public.signup_throttle('ip' || i || '@signup.test', '198.51.100.7') ORDER BY i) FROM generate_series(1, 31) i),
          array_fill(TRUE, ARRAY[30]) || FALSE, 'thirty sign-ups an hour per client address');
SELECT ok(public.signup_throttle('ip-other@signup.test', '198.51.100.8'), 'another client address is not throttled');

DELETE FROM private.invitation_attempt WHERE key LIKE 'signup:%';
SELECT is((SELECT count(*) FILTER (WHERE allowed)::INT
           FROM (SELECT public.signup_throttle('all' || i || '@signup.test', '192.0.2.' || (i % 250)) AS allowed
                 FROM generate_series(1, 201) i) t), 200, 'two hundred sign-ups an hour in all');

-- N2: calls refused by their own address or client limit never spend the global budget.
DELETE FROM private.invitation_attempt WHERE key LIKE 'signup:%';
SELECT count(*) FROM (SELECT public.signup_throttle('hammer' || i || '@signup.test', '198.51.100.99') FROM generate_series(1, 40) i) t;
SELECT count(*) FROM (SELECT public.signup_throttle('same070@signup.test', '192.0.2.' || i) FROM generate_series(1, 8) i) t;
SELECT is((SELECT count FROM private.invitation_attempt WHERE key = 'signup:all'), 35,
          'only the 30 + 5 calls their own limits allowed count toward the global cap');

SELECT * FROM finish();

ROLLBACK;
