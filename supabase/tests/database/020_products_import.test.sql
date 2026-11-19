CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

BEGIN;

SELECT plan(11);

-- Fixture, built here as postgres (the seed is not on the new model yet):
--   tenant   00000000-0000-4000-8000-000000002001  the importing company, owner 2011
--   other    00000000-0000-4000-8000-000000002002  another company
--   supplier 00000000-0000-4000-8000-000000002021  code CN1, in the importing company
-- A plan is made first, so each new company is subscribed (a company without one is read-only).
INSERT INTO public.plan (display_name, is_active) VALUES ('Import test plan', TRUE);

INSERT INTO public.tenant (id, display_name) VALUES
   ('00000000-0000-4000-8000-000000002001', 'Import Trading'),
   ('00000000-0000-4000-8000-000000002002', 'Other Trading');

INSERT INTO public.user (id, email) VALUES ('00000000-0000-4000-8000-000000002011', 'owner@products-import.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000002011', '00000000-0000-4000-8000-000000002001');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000002011', '00000000-0000-4000-8000-000000002001');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country)
VALUES ('00000000-0000-4000-8000-000000002021', '00000000-0000-4000-8000-000000002001', 'CN1', 'Ningbo Mops', 'CN');

-- The other company's product of the same SKU: SKUs are unique per tenant only.
INSERT INTO public.product (tenant_id, sku, display_name)
VALUES ('00000000-0000-4000-8000-000000002002', 'IMP-001', 'Not ours');

-- The relation users read: the api view once the api views exist (the base tables are closed to
-- users then), the base table before.
CREATE FUNCTION pg_temp.rel (p_name TEXT) RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT coalesce(to_regclass('api.' || p_name), to_regclass('public.' || p_name))::TEXT;
$$;

-- The rest runs as the importing company's owner.
SELECT private.impersonate('00000000-0000-4000-8000-000000002011', '00000000-0000-4000-8000-000000002001');

-- An active product holding a GTIN the import must not take.
SELECT public.import_products($$[
    {"sku": "OTH-001", "display_name": "Held GTIN", "gtin": "4260696025855"}
]$$::JSONB);

SELECT is(
    public.import_products($$[
        {"sku": "IMP-001", "display_name": "Mop 40 cm", "gtin": "4260696025817", "supplier_code": "CN1", "purchase_price": 1.9, "sell_price_eur": 4.25},
        {"sku": "IMP-002", "display_name": "Mop 60 cm", "gtin": "4260696025824"}
    ]$$::JSONB),
    '{"ok": true, "inserted": 2, "updated": 0}'::JSONB,
    'two new rows are inserted'
);

SELECT is(
    public.import_products($$[
        {"sku": "IMP-001", "display_name": "Mop 40 cm", "gtin": "4260696025817", "purchase_price": 1.9},
        {"sku": "IMP-002", "display_name": "Mop 60 cm", "gtin": "4260696025824"}
    ]$$::JSONB),
    '{"ok": true, "inserted": 0, "updated": 2}'::JSONB,
    'the same file again updates the two rows'
);

-- The sourcing columns go to the active tenant's own sourcing row of the product (no client).
SELECT results_eq(
    format($$
        SELECT s.client_tenant_id, s.product_sku, s.supplier_id, s.purchase_price, s.sell_price_eur
        FROM %s s
        WHERE s.tenant_id = '00000000-0000-4000-8000-000000002001'
        ORDER BY s.product_sku
    $$, pg_temp.rel('sourcing')),
    $$ VALUES (NULL::UUID, 'IMP-001', '00000000-0000-4000-8000-000000002021'::UUID, 1.9::NUMERIC(12, 4), 4.25::NUMERIC(12, 2)) $$,
    'sourcing columns land in the active tenant''s sourcing row, product columns on the product'
);

SELECT set_config('test.gtin_clash', public.import_products($$[
    {"sku": "IMP-003", "display_name": "Bucket", "gtin": "4260696025862"},
    {"sku": "IMP-004", "display_name": "Clash", "gtin": "4260696025855"}
]$$::JSONB)::TEXT, TRUE);

SELECT is(
    current_setting('test.gtin_clash')::JSONB ->> 'ok',
    'false',
    'a GTIN held by another active product fails the import'
);

SELECT is(
    current_setting('test.gtin_clash')::JSONB -> 'errors' -> 0,
    '{"row": 2, "field": "gtin", "code": "gtin_in_use", "sku": "OTH-001"}'::JSONB,
    'the error names the row and the product holding the GTIN'
);

SELECT results_eq(
    format($$ SELECT count(*)::INT FROM %s p WHERE p.sku LIKE 'IMP-%%' $$, pg_temp.rel('product')),
    $$ VALUES (2) $$,
    'a failed import writes nothing, not even its valid rows'
);

SELECT is(
    public.import_products($$[
        {"sku": "IMP-010", "display_name": "First"},
        {"sku": "IMP-010", "display_name": "Again"}
    ]$$::JSONB) -> 'errors' -> 0,
    '{"row": 2, "field": "sku", "code": "sku_duplicate"}'::JSONB,
    'a SKU twice in the file is reported on its second row'
);

SELECT is(
    public.import_products($$[
        {"sku": "IMP-012", "display_name": "Bad check digit", "gtin": "4260696025801"}
    ]$$::JSONB) -> 'errors' -> 0,
    '{"row": 1, "field": "gtin", "code": "gtin_invalid"}'::JSONB,
    'a GTIN with a wrong check digit is reported'
);

SELECT is(
    public.import_products($$[
        {"sku": "IMP-011", "display_name": "Odd", "status": "bogus", "unit_net_g": "abc", "purchase_currency": "euro"}
    ]$$::JSONB) -> 'errors',
    '[{"row": 1, "field": "status", "code": "invalid_value"}, {"row": 1, "field": "unit_net_g", "code": "invalid_value"}, {"row": 1, "field": "purchase_currency", "code": "invalid_value"}]'::JSONB,
    'values the columns cannot hold are reported per field'
);

SELECT is(
    public.import_products($$[
        {"sku": "IMP-020-S", "display_name": "Mop small", "parent_sku": "IMP-020"},
        {"sku": "IMP-020", "display_name": "Mop"}
    ]$$::JSONB) ->> 'ok',
    'true',
    'a variant may name a parent that comes later in the file'
);

SELECT results_eq(
    format($$
        SELECT c.parent_id = p.id
        FROM %1$s c, %1$s p
        WHERE c.sku = 'IMP-020-S' AND p.sku = 'IMP-020'
    $$, pg_temp.rel('product')),
    $$ VALUES (TRUE) $$,
    'the variant points at its parent'
);

SELECT * FROM finish();

ROLLBACK;
