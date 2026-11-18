CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

BEGIN;

SELECT plan(38);

-- Fixture, built here as postgres (the seed is not on the new model yet). A provider procuring for
-- one client tenant:
--   provider         00000000-0000-4000-8000-000000001901
--   client           00000000-0000-4000-8000-000000001902  (provider procures; relationship 1921)
--   staff            00000000-0000-4000-8000-000000001911  provider owner, invited into the client
--                                                          with role 1931 (select on products)
--   uninvited staff  00000000-0000-4000-8000-000000001912  provider member with role 1932 (every
--                                                          sourcing right), not in the client
--   client owner     00000000-0000-4000-8000-000000001913
--   client_product   00000000-0000-4000-8000-000000001941  THO-MOP
--   client_product2  00000000-0000-4000-8000-000000001942  THO-BKT
--   second tenant    00000000-0000-4000-8000-000000001903  also owned by staff; no relationship
--   no-relationship  00000000-0000-4000-8000-000000001904  product 1945
--   client-procures  00000000-0000-4000-8000-000000001905  relationship 1922, product 1946
--   provider_product 00000000-0000-4000-8000-000000001944  PRV-001, in the provider
-- A plan is made first, so each new company is subscribed (a company without one is read-only).
INSERT INTO public.plan (display_name, is_active) VALUES ('Products test plan', TRUE);

INSERT INTO public.tenant (id, display_name) VALUES
   ('00000000-0000-4000-8000-000000001901', 'Provider Trading'),
   ('00000000-0000-4000-8000-000000001902', 'Thor Trading'),
   ('00000000-0000-4000-8000-000000001903', 'Provider Second'),
   ('00000000-0000-4000-8000-000000001904', 'Loki Wares'),
   ('00000000-0000-4000-8000-000000001905', 'Freya Home');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000001911', 'staff@products.test'),
   ('00000000-0000-4000-8000-000000001912', 'uninvited@products.test'),
   ('00000000-0000-4000-8000-000000001913', 'client-owner@products.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001901'),
   ('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001903'),
   ('00000000-0000-4000-8000-000000001913', '00000000-0000-4000-8000-000000001902');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001901'),
   ('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001902'),
   ('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001903'),
   ('00000000-0000-4000-8000-000000001912', '00000000-0000-4000-8000-000000001901'),
   ('00000000-0000-4000-8000-000000001913', '00000000-0000-4000-8000-000000001902');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000001931', '00000000-0000-4000-8000-000000001902', 'Provider staff'),
   ('00000000-0000-4000-8000-000000001932', '00000000-0000-4000-8000-000000001901', 'Sourcing editor');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000001931', p.id
FROM public.permission p
WHERE p.resource_name = 'public.product' AND p.command = 'select';

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000001932', p.id
FROM public.permission p
WHERE p.resource_name = 'public.sourcing';

INSERT INTO public.user_role (user_id, role_id) VALUES
   ('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001931'),
   ('00000000-0000-4000-8000-000000001912', '00000000-0000-4000-8000-000000001932');

INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, procurement_model) VALUES
   ('00000000-0000-4000-8000-000000001921', '00000000-0000-4000-8000-000000001901', '00000000-0000-4000-8000-000000001902',
    'THO', 'Thor Trading', 'provider'),
   ('00000000-0000-4000-8000-000000001922', '00000000-0000-4000-8000-000000001901', '00000000-0000-4000-8000-000000001905',
    'FRY', 'Freya Home', 'client');

INSERT INTO public.product (id, tenant_id, sku, display_name) VALUES
   ('00000000-0000-4000-8000-000000001941', '00000000-0000-4000-8000-000000001902', 'THO-MOP', 'Mop 40 cm'),
   ('00000000-0000-4000-8000-000000001942', '00000000-0000-4000-8000-000000001902', 'THO-BKT', 'Bucket 10 l'),
   ('00000000-0000-4000-8000-000000001944', '00000000-0000-4000-8000-000000001901', 'PRV-001', 'Provider own'),
   ('00000000-0000-4000-8000-000000001945', '00000000-0000-4000-8000-000000001904', 'LOK-001', 'Loki item'),
   ('00000000-0000-4000-8000-000000001946', '00000000-0000-4000-8000-000000001905', 'FRY-001', 'Freya item');

-- The relation users read and write: the api view once the api views exist (the base tables are
-- closed to users then), the base table before.
CREATE FUNCTION pg_temp.rel (p_name TEXT) RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT coalesce(to_regclass('api.' || p_name), to_regclass('public.' || p_name))::TEXT;
$$;

-- Runs a user-side statement built with pg_temp.rel.
CREATE FUNCTION pg_temp.exec (p_sql TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
END;
$$;

-- GTIN check digits (GS1 mod-10), before signing in.
SELECT is(private.gtin_valid('4260696025855'), TRUE, 'a GTIN-13 with the right check digit is valid');

SELECT is(private.gtin_valid('4260696025801'), FALSE, 'a GTIN-13 with the wrong check digit is not');

SELECT is(private.gtin_valid('12345'), FALSE, 'five digits are not a GTIN');

SELECT is(private.gtin_valid('96385074'), TRUE, 'a GTIN-8 with the right check digit is valid');

SELECT is(private.gtin_valid('10614141000415'), TRUE, 'a GTIN-14 with the right check digit is valid');

SELECT is(private.gtin_valid('10614141000416'), FALSE, 'a GTIN-14 with the wrong check digit is not');

-- The product tests run as the client company's owner, in its tenant.
SELECT private.impersonate('00000000-0000-4000-8000-000000001913', '00000000-0000-4000-8000-000000001902');

SELECT pg_temp.exec(format($$
    INSERT INTO %s (id, tenant_id, sku, display_name, gtin)
    VALUES ('00000000-0000-4000-8000-000000001943', '00000000-0000-4000-8000-000000001902', 'THO-001',
            'Garden Hose 15 m', '4260696025855')
$$, pg_temp.rel('product')));

-- Positive control: the row the negative checks below compare against is there and visible.
SELECT results_eq(
    format($$ SELECT count(*)::INT FROM %s p WHERE p.sku = 'THO-001' AND p.tenant_id = '00000000-0000-4000-8000-000000001902' $$,
           pg_temp.rel('product')),
    $$ VALUES (1) $$,
    'the owner sees its own product'
);

SELECT throws_ok(
    format($$
        INSERT INTO %s (tenant_id, sku, gtin)
        VALUES ('00000000-0000-4000-8000-000000001902', 'THO-BAD', '4260696025801')
    $$, pg_temp.rel('product')),
    '23514',
    NULL,
    'a GTIN with a wrong check digit is rejected'
);

SELECT throws_ok(
    format($$
        INSERT INTO %s (tenant_id, sku, gtin)
        VALUES ('00000000-0000-4000-8000-000000001902', 'THO-002', '4260696025855')
    $$, pg_temp.rel('product')),
    '23505',
    NULL,
    'two active products cannot share a GTIN'
);

SELECT pg_temp.exec(format($$ UPDATE %s SET status = 'archived' WHERE id = '00000000-0000-4000-8000-000000001943' $$,
                          pg_temp.rel('product')));

SELECT lives_ok(
    format($$
        INSERT INTO %s (tenant_id, sku, gtin)
        VALUES ('00000000-0000-4000-8000-000000001902', 'THO-002', '4260696025855')
    $$, pg_temp.rel('product')),
    'an archived product frees its GTIN'
);

SELECT throws_ok(
    format($$
        INSERT INTO %s (tenant_id, sku)
        VALUES ('00000000-0000-4000-8000-000000001902', 'THO-001')
    $$, pg_temp.rel('product')),
    '23505',
    NULL,
    'a SKU is unique within its tenant'
);

SELECT lives_ok(
    format($$
        UPDATE %s SET display_name = 'Garden Hose 20 m', unit_net_g = 1250
        WHERE id = '00000000-0000-4000-8000-000000001943'
    $$, pg_temp.rel('product')),
    'a product''s details can be changed'
);

-- Evidence: no signed spec sheet yet.
SELECT results_eq(
    format($$ SELECT has_signed_spec FROM %s WHERE product_id = '00000000-0000-4000-8000-000000001943' $$,
           pg_temp.rel('product_evidence')),
    $$ VALUES (FALSE) $$,
    'without a signed spec sheet the product has no spec evidence'
);

SELECT pg_temp.exec(format($$
    INSERT INTO %s (tenant_id, entity_type, entity_id, type, version, status, issued_on, is_signed, is_stamped,
                    sent_from_official_email, url)
    VALUES ('00000000-0000-4000-8000-000000001902', 'product', '00000000-0000-4000-8000-000000001943',
            'spec_sheet', 2, 'signed', '2026-11-01', TRUE, TRUE, TRUE, 'https://example.test/spec-v2.pdf')
$$, pg_temp.rel('document')));

SELECT results_eq(
    format($$ SELECT has_signed_spec FROM %s WHERE product_id = '00000000-0000-4000-8000-000000001943' $$,
           pg_temp.rel('product_evidence')),
    $$ VALUES (TRUE) $$,
    'a signed spec sheet is spec evidence'
);

SELECT results_eq(
    format($$ SELECT spec_version FROM %s WHERE product_id = '00000000-0000-4000-8000-000000001943' $$,
           pg_temp.rel('product_evidence')),
    $$ VALUES (2) $$,
    'the evidence names the signed spec sheet''s version'
);

-- Products are archived (status), not deleted.
SELECT throws_ok(
    format($$ DELETE FROM %s WHERE id = '00000000-0000-4000-8000-000000001943' $$, pg_temp.rel('product')),
    '42501',
    NULL,
    'products cannot be deleted'
);

RESET ROLE;

-- Sourcing lives in the procuring tenant, not on the product.
SELECT hasnt_column('public', 'product', 'purchase_price', 'cost left product');

SELECT hasnt_column('public', 'product', 'company_price_eur', 'sell price left product');

SELECT col_is_unique('public', 'sourcing', ARRAY['tenant_id', 'product_id'], 'one sourcing row per procuring tenant and product');

-- Provider staff invited into the client: may link and gets the snapshot.
SELECT private.impersonate('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001901');

SELECT lives_ok(
    format($$
        INSERT INTO %s (tenant_id, client_tenant_id, product_id, sell_price_eur)
        VALUES ('00000000-0000-4000-8000-000000001901', '00000000-0000-4000-8000-000000001902',
                '00000000-0000-4000-8000-000000001941', 9.90)
    $$, pg_temp.rel('sourcing')),
    'invited provider staff link a client product'
);

RESET ROLE;

SELECT is((SELECT product_sku FROM public.sourcing WHERE product_id = '00000000-0000-4000-8000-000000001941'), 'THO-MOP', 'sku snapshot');

-- The snapshot changes only with the link: an update cannot forge it.
SELECT private.impersonate('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001901');

SELECT lives_ok(
    format($$
        UPDATE %s SET product_sku = 'FORGED', product_name = 'Forged'
        WHERE product_id = '00000000-0000-4000-8000-000000001941'
    $$, pg_temp.rel('sourcing')),
    'an update naming the snapshot runs'
);

RESET ROLE;

SELECT results_eq(
    $$ SELECT product_sku, product_name FROM public.sourcing WHERE product_id = '00000000-0000-4000-8000-000000001941' $$,
    $$ VALUES ('THO-MOP', 'Mop 40 cm') $$,
    'the snapshot is not forged while the link is kept'
);

-- The snapshot follows the link: without a product a sourcing row has no SKU, whatever is sent, so
-- it is refused (product_sku is NOT NULL); nor is the product emptied while it exists.
SELECT private.impersonate('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001901');

SELECT throws_ok(
    format($$
        INSERT INTO %s (tenant_id, product_sku, product_name)
        VALUES ('00000000-0000-4000-8000-000000001901', 'FORGED', 'Forged')
    $$, pg_temp.rel('sourcing')),
    '23502',
    'null value in column "product_sku" of relation "sourcing" violates not-null constraint',
    'a snapshot sent without a link is not stored'
);

SELECT throws_ok(
    format($$
        UPDATE %s SET product_id = NULL WHERE product_id = '00000000-0000-4000-8000-000000001941'
    $$, pg_temp.rel('sourcing')),
    '23502',
    'null value in column "product_sku" of relation "sourcing" violates not-null constraint',
    'unlinking a product that still exists clears the snapshot'
);

RESET ROLE;

-- Invited staff, unknown id: refused by the existence check, with the forbidden message.
SELECT private.impersonate('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001901');

SELECT throws_ok(
    format($$
        INSERT INTO %s (tenant_id, client_tenant_id, product_id)
        VALUES ('00000000-0000-4000-8000-000000001901', '00000000-0000-4000-8000-000000001902', gen_random_uuid())
    $$, pg_temp.rel('sourcing')),
    '23514',
    'client_link_forbidden',
    'unknown id refused with the same message'
);

-- Provider staff not invited into the client.
RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000001912', '00000000-0000-4000-8000-000000001901');

SELECT throws_ok(
    format($$
        INSERT INTO %s (tenant_id, client_tenant_id, product_id)
        VALUES ('00000000-0000-4000-8000-000000001901', '00000000-0000-4000-8000-000000001902',
                '00000000-0000-4000-8000-000000001942')
    $$, pg_temp.rel('sourcing')),
    '23514',
    'client_link_forbidden',
    'uninvited staff refused'
);

-- An own-tenant link needs the read right on the product too: the snapshot would reveal it.
SELECT throws_ok(
    format($$
        INSERT INTO %s (tenant_id, product_id)
        VALUES ('00000000-0000-4000-8000-000000001901', '00000000-0000-4000-8000-000000001944')
    $$, pg_temp.rel('sourcing')),
    '23514',
    'client_link_forbidden',
    'an own-tenant link without the product read right is refused'
);

-- The relationship: a new sourcing row naming a client needs an active provider-procures one.
RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001901');

SELECT throws_ok(
    format($$
        INSERT INTO %s (tenant_id, client_tenant_id, product_id)
        VALUES ('00000000-0000-4000-8000-000000001901', '00000000-0000-4000-8000-000000001904',
                '00000000-0000-4000-8000-000000001945')
    $$, pg_temp.rel('sourcing')),
    '23514',
    'relationship_inactive',
    'no relationship, no link'
);

SELECT throws_ok(
    format($$
        INSERT INTO %s (tenant_id, client_tenant_id, product_id)
        VALUES ('00000000-0000-4000-8000-000000001901', '00000000-0000-4000-8000-000000001905',
                '00000000-0000-4000-8000-000000001946')
    $$, pg_temp.rel('sourcing')),
    '23514',
    'relationship_inactive',
    'a client-procures client gets no provider sourcing'
);

-- The client and the tenant of a row naming a client are fixed.
SELECT throws_ok(
    format($$
        UPDATE %s SET client_tenant_id = NULL WHERE product_id = '00000000-0000-4000-8000-000000001941'
    $$, pg_temp.rel('sourcing')),
    '23514',
    'client_tenant_immutable',
    'client_tenant_id cannot change'
);

-- A user working in both of its tenants cannot move the row to the one without a relationship.
SELECT set_config('request.headers', json_build_object(
    'x-tenant-id', '00000000-0000-4000-8000-000000001901',
    'x-tenant-ids', '00000000-0000-4000-8000-000000001901,00000000-0000-4000-8000-000000001903')::TEXT, TRUE);

SELECT throws_ok(
    format($$
        UPDATE %s SET tenant_id = '00000000-0000-4000-8000-000000001903'
        WHERE product_id = '00000000-0000-4000-8000-000000001941'
    $$, pg_temp.rel('sourcing')),
    '23514',
    'client_tenant_immutable',
    'a row naming a client cannot move to another tenant'
);

-- The relationship ends.
RESET ROLE;
UPDATE public.provider_relationship SET status = 'ended' WHERE id = '00000000-0000-4000-8000-000000001921';
SELECT private.impersonate('00000000-0000-4000-8000-000000001911', '00000000-0000-4000-8000-000000001901');

SELECT throws_ok(
    format($$
        INSERT INTO %s (tenant_id, client_tenant_id, product_id)
        VALUES ('00000000-0000-4000-8000-000000001901', '00000000-0000-4000-8000-000000001902',
                '00000000-0000-4000-8000-000000001942')
    $$, pg_temp.rel('sourcing')),
    '23514',
    'relationship_inactive',
    'no new row after the end'
);

SELECT throws_ok(
    format($$
        UPDATE %s SET product_id = '00000000-0000-4000-8000-000000001942'
        WHERE product_id = '00000000-0000-4000-8000-000000001941'
    $$, pg_temp.rel('sourcing')),
    '23514',
    'relationship_inactive',
    'no relink after the end'
);

SELECT lives_ok(
    format($$
        UPDATE %s SET sell_price_eur = 10.50 WHERE product_id = '00000000-0000-4000-8000-000000001941'
    $$, pg_temp.rel('sourcing')),
    'a price edit passes after the end'
);

-- The relationship is not deleted while rows name it.
RESET ROLE;

SELECT throws_ok(
    $$ DELETE FROM public.provider_relationship WHERE id = '00000000-0000-4000-8000-000000001921' $$,
    '23503',
    NULL,
    'a relationship named by sourcing cannot be deleted'
);

-- The client deletes its product after the end (product deletes are not a user action: run as
-- postgres).
SELECT lives_ok($$ DELETE FROM public.product WHERE id = '00000000-0000-4000-8000-000000001941' $$, 'client delete is not blocked');

SELECT results_eq(
    $$ SELECT product_id IS NULL, product_sku, sell_price_eur FROM public.sourcing WHERE product_sku = 'THO-MOP' $$,
    $$ VALUES (TRUE, 'THO-MOP', 10.50::NUMERIC(12, 2)) $$,
    'client product delete keeps the snapshot'
);

SELECT * FROM finish();

ROLLBACK;
