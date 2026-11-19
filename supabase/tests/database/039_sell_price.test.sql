CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- The selling price (039): sourcing.sell_price_eur is in the field group sell_price, which a
-- coordinator reads but does not write and management writes. Fixture built here as postgres:
--   tenant       00000000-0000-4000-8000-000000003901
--   coordinator  user 3911, role 3931 (coordinator defaults)
--   management   user 3912, role 3932 (management defaults)
BEGIN;

SELECT plan(3);

INSERT INTO public.tenant (id, display_name) VALUES ('00000000-0000-4000-8000-000000003901', 'Sell Price Trading');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000003911', 'coordinator@sell-price.test'),
   ('00000000-0000-4000-8000-000000003912', 'management@sell-price.test');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003911', '00000000-0000-4000-8000-000000003901'),
   ('00000000-0000-4000-8000-000000003912', '00000000-0000-4000-8000-000000003901');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000003931', '00000000-0000-4000-8000-000000003901', 'coordinator'),
   ('00000000-0000-4000-8000-000000003932', '00000000-0000-4000-8000-000000003901', 'management');

SELECT private.apply_field_defaults('00000000-0000-4000-8000-000000003931', 'coordinator');
SELECT private.apply_field_defaults('00000000-0000-4000-8000-000000003932', 'management');

INSERT INTO public.user_role (user_id, role_id) VALUES
   ('00000000-0000-4000-8000-000000003911', '00000000-0000-4000-8000-000000003931'),
   ('00000000-0000-4000-8000-000000003912', '00000000-0000-4000-8000-000000003932');

SELECT is(
    (SELECT f.group_name FROM public.field_class f WHERE f.resource_name = 'public.sourcing' AND f.field = 'sell_price_eur'),
    'sell_price',
    'the selling price is in the group sell_price'
);

SELECT ok(
    private.field_tenants('00000000-0000-4000-8000-000000003911', ARRAY['00000000-0000-4000-8000-000000003901'::UUID],
                          'public.sourcing', 'sell_price_eur', FALSE) = ARRAY['00000000-0000-4000-8000-000000003901'::UUID]
    AND private.field_tenants('00000000-0000-4000-8000-000000003911', ARRAY['00000000-0000-4000-8000-000000003901'::UUID],
                              'public.sourcing', 'sell_price_eur', TRUE) = '{}'::UUID[],
    'a coordinator reads the selling price but cannot write it'
);

SELECT is(
    private.field_tenants('00000000-0000-4000-8000-000000003912', ARRAY['00000000-0000-4000-8000-000000003901'::UUID],
                          'public.sourcing', 'sell_price_eur', TRUE),
    ARRAY['00000000-0000-4000-8000-000000003901'::UUID],
    'management writes the selling price'
);

SELECT * FROM finish();

ROLLBACK;
