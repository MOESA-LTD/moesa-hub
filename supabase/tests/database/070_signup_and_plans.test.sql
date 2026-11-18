CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Onboarding (Plan 3): open self-signup is a platform setting, off by default and changed by the
-- super admin only (decision 17); plans say who they suit (plan.audience).
-- Sections: platform setting and audience (Task 1).
BEGIN;

SELECT plan(6);

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

SELECT * FROM finish();

ROLLBACK;
