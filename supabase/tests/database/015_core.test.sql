CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

BEGIN;

SELECT plan(11);

SELECT has_table('public', 'setting', 'setting table');

SELECT has_table('public', 'code_sequence', 'code_sequence table');

SELECT has_function('public', 'next_code', ARRAY['text', 'text'], 'next_code');

-- A new company (root tenant) gets the default settings; inserted as the migration role, before
-- impersonating, since signed-in users do not create companies.
INSERT INTO public.tenant (display_name) VALUES ('pgTAP Root Tenant');

SELECT is(
    (
        SELECT count(*)::INT
        FROM public.setting s
        JOIN public.tenant t ON t.id = s.tenant_id
        WHERE t.display_name = 'pgTAP Root Tenant'
    ),
    (SELECT count(*)::INT FROM private.default_settings()),
    'a new root tenant gets the default settings'
);

SELECT is((SELECT count(*)::INT FROM public.platform), 10, 'platform has the 10 marketplaces');

-- The code scope: a tenant's own rows under its code, a client's rows under the client_code of the
-- pair's relationship, and nothing for a pair without one.
INSERT INTO public.tenant (id, display_name) VALUES
    ('00000000-0000-4000-8000-000000001501', 'Zed Provider'),
    ('00000000-0000-4000-8000-000000001502', 'Thor Trading'),
    ('00000000-0000-4000-8000-000000001503', 'Loki Wares');

INSERT INTO public.provider_relationship (tenant_id, client_tenant_id, client_code, client_name, procurement_model)
VALUES ('00000000-0000-4000-8000-000000001501', '00000000-0000-4000-8000-000000001502', 'THO', 'Thor Trading',
        'provider');

SELECT is(
    private.code_scope('00000000-0000-4000-8000-000000001501', NULL),
    (SELECT t.code FROM public.tenant t WHERE t.id = '00000000-0000-4000-8000-000000001501'),
    'code scope of a tenant''s own row is the tenant code'
);

SELECT is(
    private.code_scope('00000000-0000-4000-8000-000000001501', '00000000-0000-4000-8000-000000001502'),
    'THO',
    'code scope of a client row is its client_code'
);

SELECT is(
    private.code_scope('00000000-0000-4000-8000-000000001501', '00000000-0000-4000-8000-000000001503'),
    NULL,
    'code scope of a pair without a relationship is NULL'
);

-- The rest runs as a signed-in owner of a company (fixture, built here as postgres).
INSERT INTO public.user (id, email) VALUES ('00000000-0000-4000-8000-000000001504', 'owner@core.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000001504', '00000000-0000-4000-8000-000000001501');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000001504', '00000000-0000-4000-8000-000000001501');

SELECT private.impersonate('00000000-0000-4000-8000-000000001504', '00000000-0000-4000-8000-000000001501');

-- Counter: consecutive within one customer and year, independent across customers.
SELECT is(public.next_code('project', 'THO'), 'THO-' || extract(year FROM now())::INT || '-001');

SELECT is(public.next_code('project', 'THO'), 'THO-' || extract(year FROM now())::INT || '-002');

SELECT is(public.next_code('po', 'ABC'), 'PO-ABC-' || extract(year FROM now())::INT || '-001');

SELECT * FROM finish();

ROLLBACK;
