CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Plan module tiers (075): the business modules outside the core are given to the plans by tier,
-- and a plan never holds a module without one it requires.
BEGIN;

SELECT plan(19);

-- The tiers.
SELECT set_eq($$ SELECT id FROM public.module WHERE is_core $$,
              ARRAY['branch', 'user', 'role', 'ops_setting', 'document', 'media', 'supplier', 'client', 'product', 'transfer'],
              'the core modules are what every other module points at, and the copy tool');

SELECT set_eq($$ SELECT pm.module_id FROM public.plan_module pm JOIN public.plan p ON p.id = pm.plan_id WHERE p.display_name = 'Basic' $$,
              ARRAY['purchase_order', 'shipment', 'incident', 'change_request'],
              'Basic: the orders and shipments shared with a client, with their incidents and change requests');

SELECT set_eq($$ SELECT pm.module_id FROM public.plan_module pm JOIN public.plan p ON p.id = pm.plan_id WHERE p.display_name = 'Pro' $$,
              $$ SELECT id FROM public.module WHERE NOT is_core $$,
              'Pro: every module outside the core');

SELECT set_eq($$ SELECT pm.module_id FROM public.plan_module pm JOIN public.plan p ON p.id = pm.plan_id WHERE p.display_name = 'Enterprise' $$,
              $$ SELECT id FROM public.module WHERE NOT is_core $$,
              'Enterprise: every module outside the core');

SELECT is((SELECT requires FROM public.module WHERE id = 'shipment'), ARRAY['purchase_order'], 'a shipment requires orders');

SELECT is((SELECT requires FROM public.module WHERE id = 'listing'), ARRAY['market_matrix'], 'a listing requires the market matrix');

-- What a company on Basic may use (Nova Yazılım in the seed).
SELECT ok(NOT ARRAY['project'] <@ (SELECT e.modules FROM private.entitlements(ARRAY[(SELECT id FROM public.tenant WHERE display_name = 'Nova Yazılım')]) e),
          'a Basic company has no projects');

SELECT ok(ARRAY['purchase_order', 'shipment', 'product'] <@ (SELECT e.modules FROM private.entitlements(ARRAY[(SELECT id FROM public.tenant WHERE display_name = 'Nova Yazılım')]) e),
          'but has orders, shipments and the core');

SELECT is(cardinality(private.tenants_entitled(ARRAY[(SELECT id FROM public.tenant WHERE display_name = 'Nova Yazılım')], 'public.project', 'select')), 0,
          'so project rows are not entitled to it');

SELECT is(private.subscription_summary((SELECT id FROM public.tenant WHERE display_name = 'Nova Yazılım')) -> 'locked' ->> 'project', 'project',
          'and the app shows its project pages as locked');

-- The guard, as the super admin through save_plan.
RESET ROLE;
SELECT private.impersonate_scope((SELECT id FROM auth.users WHERE email = 'admin@moesa-panel.test'), NULL, NULL);

SELECT throws_like($$ SELECT public.save_plan('{"display_name": "Ship only"}', ARRAY['shipment']) $$, '%plan_module_requires%',
                   'a plan with shipments but no orders is refused');

SELECT lives_ok($$ SELECT public.save_plan('{"display_name": "Ship and order"}', ARRAY['shipment', 'purchase_order']) $$,
                'with the orders it is saved');

SELECT throws_like($$ SELECT public.save_plan(
                         (SELECT jsonb_build_object('id', p.id, 'display_name', p.display_name) FROM api.plan p WHERE p.display_name = 'Ship and order'),
                         ARRAY['shipment']) $$, '%plan_module_requires%',
                   'dropping the orders and keeping the shipments is refused');

SELECT lives_ok($$ SELECT public.save_plan(
                       (SELECT jsonb_build_object('id', p.id, 'display_name', p.display_name) FROM api.plan p WHERE p.display_name = 'Ship and order'),
                       ARRAY[]::TEXT[]) $$,
                'dropping both is saved');

RESET ROLE;
SELECT private.unimpersonate();

-- What the role would grant outside the plan: the app shows those pages locked, the rest hidden.
SELECT set_config('test.nova', (SELECT id::TEXT FROM public.tenant WHERE display_name = 'Nova Yazılım'), TRUE);
SELECT private.impersonate_scope((SELECT id FROM auth.users WHERE email = 'ali@moesa-panel.test'), NULL, NULL);

SELECT ok(public.my_access(current_setting('test.nova')::UUID) -> 'locked_permissions'
          @> '[{"resource_name": "public.project", "command": "select"}]',
          'the owner of a Basic company would read projects: they are shown locked');

SELECT ok(NOT jsonb_path_exists(public.my_access(current_setting('test.nova')::UUID) -> 'locked_permissions',
                                '$[*] ? (@.resource_name == "public.purchase_order" || @.resource_name == "public.product")'),
          'what the plan holds is not among them');

RESET ROLE;
SELECT private.unimpersonate();

SELECT private.impersonate_scope((SELECT id FROM auth.users WHERE email = 'admin@moesa-panel.test'), NULL, NULL);

SELECT is(jsonb_array_length(public.my_access(current_setting('test.nova')::UUID) -> 'locked_permissions'), 0,
          'nothing is locked for the super admin');

RESET ROLE;
SELECT private.unimpersonate();

-- Directly, and through the module.
SELECT throws_like($$ DELETE FROM public.plan_module pm USING public.plan p
                      WHERE p.id = pm.plan_id AND p.display_name = 'Pro' AND pm.module_id = 'market_matrix' $$,
                   '%plan_module_requires%', 'a direct write is checked too');

SELECT throws_like($$ UPDATE public.module SET requires = ARRAY['project'] WHERE id = 'incident' $$,
                   '%plan_module_requires%', 'so is a new requirement a plan does not meet (Basic has incidents, no projects)');

SELECT * FROM finish();

ROLLBACK;
