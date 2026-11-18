CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Onboarding (Plan 3): open self-signup is a platform setting, off by default and changed by the
-- super admin only (decision 17); plans say who they suit (plan.audience).
-- Sections: platform setting and audience (Task 1); company creation and standard roles (Task 2).
BEGIN;

SELECT plan(12);

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

SELECT * FROM finish();

ROLLBACK;
