CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

BEGIN;

SELECT plan(16);

-- Fixture, built here as postgres (the seed is not on the new model yet). One provider with two
-- provider-procures clients and one client-procures client, plus a tenant with no relationship.
--   provider     00000000-0000-4000-8000-000000001801
--   client       00000000-0000-4000-8000-000000001802  (provider procures; relationship rel)
--   client2      00000000-0000-4000-8000-000000001803  (provider procures; relationship rel2)
--   client_proc  00000000-0000-4000-8000-000000001804  (client procures)
--   stranger     00000000-0000-4000-8000-000000001805  (no relationship)
--   rel          00000000-0000-4000-8000-000000001821
--   rel2         00000000-0000-4000-8000-000000001822
--   owner of client          00000000-0000-4000-8000-000000001811
--   plain member of client2  00000000-0000-4000-8000-000000001812
INSERT INTO public.tenant (id, display_name) VALUES
   ('00000000-0000-4000-8000-000000001801', 'Provider Trading'),
   ('00000000-0000-4000-8000-000000001802', 'Thor Trading'),
   ('00000000-0000-4000-8000-000000001803', 'Odin Goods'),
   ('00000000-0000-4000-8000-000000001804', 'Freya Home'),
   ('00000000-0000-4000-8000-000000001805', 'Stranger Co');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000001811', 'client-owner@tenant-relations.test'),
   ('00000000-0000-4000-8000-000000001812', 'client2-member@tenant-relations.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000001811', '00000000-0000-4000-8000-000000001802');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000001811', '00000000-0000-4000-8000-000000001802'),
   ('00000000-0000-4000-8000-000000001812', '00000000-0000-4000-8000-000000001803');

INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, procurement_model) VALUES
   ('00000000-0000-4000-8000-000000001821', '00000000-0000-4000-8000-000000001801', '00000000-0000-4000-8000-000000001802',
    'THO', 'Thor Trading', 'provider'),
   ('00000000-0000-4000-8000-000000001822', '00000000-0000-4000-8000-000000001801', '00000000-0000-4000-8000-000000001803',
    'ODN', 'Odin Goods', 'provider'),
   ('00000000-0000-4000-8000-000000001823', '00000000-0000-4000-8000-000000001801', '00000000-0000-4000-8000-000000001804',
    'FRY', 'Freya Home', 'client');

SELECT has_table('public', 'provider_relationship', 'provider_relationship exists');

SELECT hasnt_table('public', 'customer', 'customer is gone');

SELECT is_empty(
   $$ SELECT table_name FROM information_schema.columns WHERE column_name = 'customer_id' AND table_schema IN ('public','api','private') $$,
   'no customer_id anywhere'
);

SELECT is(private.default_tenant_code('Çağ Ödül Ltd'), 'CAG', 'default code folds Turkish letters');

SELECT is(private.default_tenant_code('1 2'), '12X', 'default code keeps digits and pads');

SELECT is(private.default_tenant_code('— —'), 'XXX', 'default code of no letters');

SELECT ok(
   (SELECT code FROM public.tenant WHERE id = '00000000-0000-4000-8000-000000001801') ~ '^[A-Z0-9]{2,6}$',
   'a tenant gets a code on insert'
);

-- The stranger has no relationship yet, so only the (provider, client_code) key can refuse this.
SELECT throws_ok(
   $$ INSERT INTO public.provider_relationship (tenant_id, client_tenant_id, client_code, client_name, procurement_model)
      VALUES ('00000000-0000-4000-8000-000000001801', '00000000-0000-4000-8000-000000001805', 'THO', 'Dup', 'provider') $$,
   '23505',
   'duplicate key value violates unique constraint "provider_relationship_client_code_key"',
   'client_code unique per provider'
);

SELECT throws_ok(
   $$ INSERT INTO public.provider_relationship (tenant_id, client_tenant_id, client_code, client_name, procurement_model)
      VALUES ('00000000-0000-4000-8000-000000001801', '00000000-0000-4000-8000-000000001801', 'SLF', 'Self', 'provider') $$,
   '23514',
   NULL,
   'no relationship with oneself'
);

SELECT ok(
   private.relationship_allows('00000000-0000-4000-8000-000000001801', '00000000-0000-4000-8000-000000001802', TRUE),
   'active provider-procures allows new links'
);

SELECT ok(
   NOT private.relationship_allows('00000000-0000-4000-8000-000000001801', '00000000-0000-4000-8000-000000001804', TRUE),
   'client-procures allows no new provider links'
);

SELECT ok(
   private.relationship_allows('00000000-0000-4000-8000-000000001801', '00000000-0000-4000-8000-000000001804', FALSE),
   'client-procures still allows history'
);

SELECT throws_ok(
   $$ UPDATE public.provider_relationship SET client_tenant_id = '00000000-0000-4000-8000-000000001803'
      WHERE id = '00000000-0000-4000-8000-000000001821' $$,
   '23514',
   'relationship_immutable',
   'pair immutable'
);

-- As the client owner.
SELECT private.impersonate('00000000-0000-4000-8000-000000001811', '00000000-0000-4000-8000-000000001802');

SELECT lives_ok(
   $$ SELECT public.end_provider_relationship('00000000-0000-4000-8000-000000001821') $$,
   'client owner may end'
);

-- The base table is closed to users, so the rule is checked as postgres.
RESET ROLE;

SELECT throws_ok(
   $$ UPDATE public.provider_relationship SET status = 'active', ended_at = NULL WHERE id = '00000000-0000-4000-8000-000000001821' $$,
   '23514',
   'relationship_ended_final',
   'ended is final'
);

-- As a client member without ownership.
SELECT private.impersonate('00000000-0000-4000-8000-000000001812', '00000000-0000-4000-8000-000000001803');

SELECT throws_ok(
   $$ SELECT public.end_provider_relationship('00000000-0000-4000-8000-000000001822') $$,
   '42501',
   NULL,
   'a plain client member may not end'
);

RESET ROLE;

SELECT * FROM finish();

ROLLBACK;
