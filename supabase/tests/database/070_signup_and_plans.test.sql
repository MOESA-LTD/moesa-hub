CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Onboarding (Plan 3): open self-signup is a platform setting, off by default and changed by the
-- super admin only (decision 17); plans say who they suit (plan.audience).
-- Sections: platform setting and audience (Task 1); company creation and standard roles (Task 2);
-- verify-first self-signup: complete_signup and signup_throttle (Task 11, task-5-review I1).
BEGIN;

SELECT plan(24);

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

-- Section 2: one company-creation path (private.create_company) with the standard roles.
-- Fixtures: an inactive plan and a company owned by ayse, created by the service-only path.
INSERT INTO public.plan (id, display_name, is_active) VALUES ('00000000-0000-4000-8000-000000070201', 'Retired 070', FALSE);

SELECT throws_ok(
    $$ SELECT private.create_company((SELECT id FROM auth.users WHERE email = 'ayse@moesa-panel.test'),
                                     '{"display_name": "Injected 070", "tenant_id": "00000000-0000-4000-8000-000000000001"}', NULL) $$,
    'P0001', 'company_payload_invalid', 'a key outside the company allowlist is refused');

SELECT throws_ok(
    $$ SELECT private.create_company((SELECT id FROM auth.users WHERE email = 'ayse@moesa-panel.test'),
                                     '{"display_name": "Retired plan 070", "email": "retired070@example.test"}',
                                     '00000000-0000-4000-8000-000000070201') $$,
    'P0001', 'plan_inactive', 'an inactive plan is refused');

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
-- proven (email_confirmed_at), by the service role, while signup is open, and once per account.
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
SELECT '00000000-0000-0000-0000-000000000000', v.id::UUID, 'authenticated', 'authenticated', v.email, '', v.confirmed, now(), now(), '', '', '', ''
FROM (VALUES ('00000000-0000-4000-8000-000000070301', 'proven070@signup.test', now()),
             ('00000000-0000-4000-8000-000000070302', 'unproven070@signup.test', NULL::TIMESTAMPTZ)) AS v (id, email, confirmed);

SELECT ok(NOT has_function_privilege('authenticated', 'public.complete_signup(uuid, jsonb, uuid)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.complete_signup(uuid, jsonb, uuid)', 'EXECUTE')
          AND has_function_privilege('service_role', 'public.complete_signup(uuid, jsonb, uuid)', 'EXECUTE'),
          'only the service role completes a signup');

SELECT ok(NOT has_function_privilege('authenticated', 'public.signup_throttle(text, text)', 'EXECUTE')
          AND NOT has_function_privilege('anon', 'public.signup_throttle(text, text)', 'EXECUTE')
          AND has_function_privilege('service_role', 'public.signup_throttle(text, text)', 'EXECUTE'),
          'only the service role counts sign-ups');

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
    $$ SELECT public.complete_signup('00000000-0000-4000-8000-000000070301', '{"display_name": "Retired 070 co"}',
                                     '00000000-0000-4000-8000-000000070201') $$,
    'P0001', 'plan_inactive', 'the plan must be active');

SELECT is((SELECT count(*)::INT FROM public.tenant_owner WHERE user_id = '00000000-0000-4000-8000-000000070301'), 0,
          'the refusals created nothing');

CREATE TEMP TABLE signup_070 (id UUID) ON COMMIT DROP;
GRANT ALL ON signup_070 TO service_role;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SET LOCAL ROLE service_role;
INSERT INTO signup_070
SELECT (public.complete_signup('00000000-0000-4000-8000-000000070301',
                               '{"display_name": "Signed up 070", "email": "signedup070@example.test", "city": "Bursa"}',
                               (SELECT id FROM public.plan WHERE display_name = 'Pro' AND is_active))).id;
RESET ROLE;
SELECT set_config('request.jwt.claims', '', TRUE);

SELECT ok(EXISTS (SELECT 1 FROM public.tenant t JOIN signup_070 s ON s.id = t.id
                  WHERE t.display_name = 'Signed up 070' AND t.city = 'Bursa'),
          'the proven account gets its company');

SELECT is((SELECT p.display_name FROM public.subscription s JOIN public.plan p ON p.id = s.plan_id
           WHERE s.tenant_id = (SELECT id FROM signup_070)), 'Pro', 'on the chosen plan');

SELECT throws_ok(
    $$ SELECT public.complete_signup('00000000-0000-4000-8000-000000070301', '{"display_name": "Second 070"}', NULL) $$,
    'P0001', 'signup_completed', 'a second completion is refused');

SELECT is((SELECT count(*)::INT FROM public.tenant_owner WHERE user_id = '00000000-0000-4000-8000-000000070301'), 1,
          'exactly one company');

-- Five sign-ups an hour per address; the sixth is throttled, another address is not.
SELECT is(ARRAY(SELECT public.signup_throttle('Throttled070@signup.test', '203.0.113.70') FROM generate_series(1, 6)),
          ARRAY[TRUE, TRUE, TRUE, TRUE, TRUE, FALSE], 'five sign-ups an hour per address');

SELECT * FROM finish();

ROLLBACK;
