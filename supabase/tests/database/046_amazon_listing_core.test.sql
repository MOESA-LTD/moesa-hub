CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- The Amazon listing core (046) on fixtures built in the file: the new columns and enums; the
-- definition cache is read by every user and written by none, and its property groups are an
-- ordered array; a user never writes a submission (only the service role does); listing_state and
-- the Amazon connection are server-only, and a connected account cannot move to another tenant;
-- another tenant sees no submission and no platform account of the seller; as the service role,
-- connecting an account stores its token in Vault (one secret per account) and disconnecting with
-- 'none' removes it; listing_apply_submission walks market_cell.status only through the legal
-- transitions (R2: accepted → uploaded, live only with the listing data, issues keep the status and
-- write open_issue), fills the platform product ID from the ASIN and moves the cell only for the
-- cell's latest submission; listing_begin_submission records a submission, marks the cell submitted
-- and refuses a second one while one is in flight; listing_set_state writes only over the version
-- it was given and clears an Amazon open issue when leaving issues; the parent cell is created on
-- demand and shows the worst of its own submission and its children (R7); the public bucket and the
-- coordinator's publish permission are there; called as a user, begin and parent are audited as
-- that user and refuse another tenant or a user without the permission, Amazon's outcome is the
-- service role's only (audited as its p_actor), and a service write is labelled by its
-- x-audit-role. The cells are AMZ-MOP40-2P's on amazon PL, SE, BE, GB and NL, inserted as postgres
-- and walked with UPDATEs. What it writes is rolled back.
BEGIN;

SELECT plan(100);

-- Fixture, built here as postgres (the seed is not on the new model yet): one tenant that sells on
-- Amazon with its owner, a coordinator who may publish, a second tenant with its own owner, one
-- product and the tenant's Amazon account (one per tenant and platform).
INSERT INTO public.tenant (id, display_name) VALUES
    ('00000000-0000-4000-8000-000000004601', 'Amazon Seller'),
    ('00000000-0000-4000-8000-000000004602', 'Other Seller');

INSERT INTO public.user (id, email) VALUES
    ('00000000-0000-4000-8000-000000004611', 'owner@amazon-core.test'),
    ('00000000-0000-4000-8000-000000004612', 'other-owner@amazon-core.test'),
    ('00000000-0000-4000-8000-000000004613', 'coordinator@amazon-core.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000004611', '00000000-0000-4000-8000-000000004601'),
    ('00000000-0000-4000-8000-000000004612', '00000000-0000-4000-8000-000000004602');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000004611', '00000000-0000-4000-8000-000000004601'),
    ('00000000-0000-4000-8000-000000004612', '00000000-0000-4000-8000-000000004602'),
    ('00000000-0000-4000-8000-000000004613', '00000000-0000-4000-8000-000000004601');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
    ('00000000-0000-4000-8000-000000004631', '00000000-0000-4000-8000-000000004601', 'coordinator');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000004631', p.id
FROM public.permission p
WHERE (p.resource_name = 'public.listing_submission' AND p.command IN ('select', 'insert'))
   OR (p.resource_name = 'public.platform_account' AND p.command IN ('select', 'update'));

INSERT INTO public.user_role (user_id, role_id) VALUES
    ('00000000-0000-4000-8000-000000004613', '00000000-0000-4000-8000-000000004631');

INSERT INTO public.product (tenant_id, sku, display_name)
VALUES ('00000000-0000-4000-8000-000000004601', 'AMZ-MOP40-2P', 'Mop 40');

INSERT INTO public.platform_account (tenant_id, platform_id)
VALUES ('00000000-0000-4000-8000-000000004601', 'amazon');

SELECT set_config('test.' || x.k, x.v::TEXT, TRUE)
FROM (VALUES
    ('client', '00000000-0000-4000-8000-000000004601'),
    ('other', '00000000-0000-4000-8000-000000004602'),
    ('akif', '00000000-0000-4000-8000-000000004611'),
    ('selin', '00000000-0000-4000-8000-000000004612'),
    ('koord', '00000000-0000-4000-8000-000000004613'),
    ('mop', (SELECT id FROM public.product WHERE sku = 'AMZ-MOP40-2P')),
    ('acct', (SELECT a.id FROM public.platform_account a
              WHERE a.tenant_id = '00000000-0000-4000-8000-000000004601' AND a.platform_id = 'amazon'))
) AS x (k, v);

-- The five cells, as postgres: PL preparing (later complete), SE planned, BE a candidate, GB
-- uploaded without a price, NL planned (accepted with issues).
INSERT INTO public.market_cell (tenant_id, product_id, platform_id, country)
SELECT current_setting('test.client')::UUID, current_setting('test.mop')::UUID, 'amazon', c
FROM unnest(ARRAY['PL', 'SE', 'BE', 'GB', 'NL']) AS c;

SELECT set_config('test.cell_' || lower(m.country), m.id::TEXT, TRUE)
FROM public.market_cell m
WHERE m.product_id = current_setting('test.mop')::UUID AND m.platform_id = 'amazon';

UPDATE public.market_cell SET status = 'planned' WHERE id IN (current_setting('test.cell_pl')::UUID, current_setting('test.cell_se')::UUID, current_setting('test.cell_gb')::UUID, current_setting('test.cell_nl')::UUID);
UPDATE public.market_cell SET status = 'preparing' WHERE id IN (current_setting('test.cell_pl')::UUID, current_setting('test.cell_gb')::UUID);
UPDATE public.market_cell SET status = 'uploaded', platform_sku = 'AMZ-MOP40-2P', platform_product_id = 'B07N4M94X4',
    currency = 'GBP', stock_source = 'platform', content_status = 'approved'
WHERE id = current_setting('test.cell_gb')::UUID;
UPDATE public.market_cell SET price = 12.99, currency = 'PLN', stock_source = 'platform', content_status = 'approved'
WHERE id = current_setting('test.cell_pl')::UUID;

-- The submissions the service applies, as postgres.
DO $$
DECLARE
    s RECORD;
    new_id UUID;
BEGIN
    FOR s IN SELECT * FROM (VALUES ('preparing', 'pl'), ('planned', 'se'), ('candidate', 'be'), ('no_price', 'gb'), ('issues', 'nl')) AS v (k, cell) LOOP
        INSERT INTO public.listing_submission (tenant_id, cell_id, kind, sku, marketplace_id, payload)
        VALUES (current_setting('test.client')::UUID, current_setting('test.cell_' || s.cell)::UUID, 'create', 'AMZ-MOP40-2P', 'A1C3SOZRARQ6R3', '{}')
        RETURNING id INTO new_id;
        PERFORM set_config('test.sub_' || s.k, new_id::TEXT, TRUE);
    END LOOP;
END;
$$;

-- 1–11. The columns.
SELECT has_column('public', 'product', 'amazon_product_type', 'product.amazon_product_type');
SELECT has_column('public', 'product', 'amazon_schema_version', 'product.amazon_schema_version');
SELECT has_column('public', 'product', 'listing_attributes', 'product.listing_attributes');
SELECT throws_ok(
    $$ INSERT INTO public.platform_account (tenant_id, platform_id) VALUES (current_setting('test.client')::UUID, 'amazon') $$,
    '23505',
    NULL,
    'one Amazon account per tenant and platform'
);
SELECT is(
    (SELECT count(*)::INT FROM public.permission WHERE resource_name = 'public.platform_account' AND group_name = 'listing'),
    4,
    'platform_account has its four permissions under the listing module'
);
SELECT has_column('public', 'platform_account', 'api_connection', 'platform_account.api_connection');
SELECT has_column('public', 'platform_account', 'authorized_at', 'platform_account.authorized_at');
SELECT has_column('public', 'platform_account', 'seller_id', 'platform_account.seller_id');
SELECT has_column('public', 'market_cell', 'listing_state', 'market_cell.listing_state');
SELECT has_column('public', 'market_cell', 'listing_checked_at', 'market_cell.listing_checked_at');
SELECT has_column('public', 'market_cell', 'listing_language', 'market_cell.listing_language');
SELECT has_column('public', 'market_cell', 'fulfillment_channel', 'market_cell.fulfillment_channel');
SELECT has_column('public', 'market_cell', 'listing_match', 'market_cell.listing_match');

-- 12–15. The enums.
SELECT enum_has_labels('public', 'listing_state', ARRAY['draft', 'ready', 'submitted', 'live', 'issues'], 'listing_state values');
SELECT enum_has_labels('public', 'api_connection', ARRAY['none', 'connected', 'revoked'], 'api_connection values');
SELECT enum_has_labels('public', 'listing_submission_kind', ARRAY['create', 'update', 'delete'], 'submission kinds');
SELECT enum_has_labels('public', 'listing_submission_status', ARRAY['accepted', 'invalid', 'processing', 'done', 'failed'], 'submission statuses');

-- 16–23. the owner of the seller tenant.
SELECT private.impersonate(current_setting('test.akif')::UUID, current_setting('test.client')::UUID);

SELECT lives_ok($$ SELECT * FROM api.amazon_product_type_definition $$, 'a user reads the definition cache');
SELECT throws_ok(
    $$ INSERT INTO api.amazon_product_type_definition (marketplace_id, product_type, locale, version, schema, property_groups)
       VALUES ('X', 'Y', 'en_GB', '1', '{}', '[]') $$,
    '42501',
    NULL,
    'a user cannot write the definition cache'
);

SELECT throws_ok(
    $$ INSERT INTO api.listing_submission (tenant_id, cell_id, kind, sku, marketplace_id, payload, status, amazon_submission_id)
       VALUES (current_setting('test.client')::UUID, current_setting('test.cell_se')::UUID, 'create', 'FORGED-SKU', 'A2NODRKZP88ZB9', '{}',
               'done', 'forged') $$,
    '42501',
    NULL,
    'a user cannot insert a submission'
);
SELECT throws_ok(
    $$ UPDATE api.listing_submission SET status = 'done' $$,
    '42501',
    NULL,
    'a user cannot update a submission'
);
SELECT throws_ok(
    $$ DELETE FROM api.listing_submission $$,
    '42501',
    NULL,
    'a user cannot delete a submission'
);

SELECT throws_ok(
    $$ UPDATE api.market_cell SET listing_state = 'live' WHERE id = current_setting('test.cell_pl')::UUID $$,
    '23514',
    'market_cell_listing_server_only',
    'listing_state is server-only'
);
SELECT throws_ok(
    $$ UPDATE api.platform_account SET api_connection = 'connected' WHERE id = current_setting('test.acct')::UUID $$,
    '23514',
    'platform_account_api_server_only',
    'api_connection is server-only'
);
SELECT throws_ok(
    $$ SELECT public.amazon_account_token(current_setting('test.acct')::UUID) $$,
    '42501',
    NULL,
    'a user cannot read a token'
);

RESET ROLE;

-- 24. A user of the other tenant.
SELECT private.impersonate(current_setting('test.selin')::UUID, current_setting('test.other')::UUID);
SELECT is((SELECT count(*) FROM api.listing_submission)::INT, 0, 'another tenant sees no submission');
SELECT is((SELECT count(*) FROM api.platform_account WHERE id = current_setting('test.acct')::UUID)::INT, 0,
   'another tenant sees no platform account of the seller');
RESET ROLE;

-- 25–30. The service role: connect, the token, disconnect.
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);

SELECT is(
    (public.amazon_account_connect(current_setting('test.acct')::UUID, 'Atzr|test', 'A3TEST')).api_connection,
    'connected',
    'connect sets connected'
);
SELECT is(public.amazon_account_token(current_setting('test.acct')::UUID), 'Atzr|test', 'the token round-trips through Vault');
SELECT ok(
    (SELECT seller_id = 'A3TEST' AND authorized_at IS NOT NULL FROM public.platform_account WHERE id = current_setting('test.acct')::UUID),
    'connect stores the seller id and the date'
);

RESET ROLE;
SELECT is((SELECT count(*) FROM vault.secrets WHERE name = 'amazon:' || current_setting('test.acct'))::INT, 1, 'one secret per account');

-- C1. A connected account stays with its tenant and platform: its token would publish another tenant's
-- products into this seller account.
SELECT private.impersonate(current_setting('test.akif')::UUID, current_setting('test.client')::UUID);
SELECT throws_ok(
    $$ UPDATE api.platform_account SET platform_id = 'ebay'
       WHERE id = current_setting('test.acct')::UUID $$,
    '42501',
    'platform_account_connected',
    'a connected account cannot move to another platform'
);
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);

SELECT lives_ok($$ SELECT public.amazon_account_disconnect(current_setting('test.acct')::UUID, 'none') $$, 'disconnect');
SELECT is(public.amazon_account_token(current_setting('test.acct')::UUID), NULL, 'disconnect none removes the token');

-- 31–32. Revoked: the state and the seller id stay, the token goes.
SELECT 1 FROM public.amazon_account_connect(current_setting('test.acct')::UUID, 'Atzr|again', 'A3TEST');
SELECT public.amazon_account_disconnect(current_setting('test.acct')::UUID, 'revoked');
SELECT ok(
    (SELECT api_connection = 'revoked' AND seller_id = 'A3TEST' FROM public.platform_account WHERE id = current_setting('test.acct')::UUID),
    'disconnect revoked keeps the seller id'
);
SELECT is(public.amazon_account_token(current_setting('test.acct')::UUID), NULL, 'disconnect revoked removes the token');

-- 33–34. A NULL listing state is refused.
SELECT throws_ok(
    $$ SELECT public.listing_apply_submission(current_setting('test.sub_planned')::UUID, 'accepted', NULL, '[]', NULL, NULL) $$,
    '22023',
    NULL,
    'apply refuses a NULL listing state'
);
SELECT throws_ok(
    $$ SELECT public.listing_set_state(current_setting('test.cell_se')::UUID, NULL, NULL) $$,
    '22023',
    NULL,
    'set_state refuses a NULL listing state'
);

-- 35–45. Applying submissions (R2).
SELECT is(
    (public.listing_apply_submission(current_setting('test.sub_preparing')::UUID, 'accepted', 'f1dc2914-75dd-11ea-bc55-0242ac130003', '[]', 'submitted', NULL)).status,
    'uploaded',
    'accepted moves preparing to uploaded'
);
SELECT is(
    (public.listing_apply_submission(current_setting('test.sub_planned')::UUID, 'accepted', 's2', '[]', 'submitted', NULL)).status,
    'uploaded',
    'accepted walks planned through preparing'
);
SELECT is(
    (public.listing_apply_submission(current_setting('test.sub_candidate')::UUID, 'accepted', 's3', '[]', 'submitted', NULL)).status,
    'candidate',
    'a candidate stays a candidate'
);
RESET ROLE;
WITH s AS (
    INSERT INTO public.listing_submission (tenant_id, cell_id, kind, sku, marketplace_id, payload)
    VALUES (current_setting('test.client')::UUID, current_setting('test.cell_pl')::UUID, 'create', 'AMZ-MOP40-2P', 'A1C3SOZRARQ6R3', '{}')
    RETURNING id
)
SELECT set_config('test.sub_complete', s.id::TEXT, TRUE) FROM s;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);

SELECT is(
    (public.listing_apply_submission(current_setting('test.sub_complete')::UUID, 'done', NULL, '[]', 'live', 'B07N4M94X4')).status,
    'live',
    'live with complete data goes live'
);
SELECT is((SELECT launched_on FROM public.market_cell WHERE id = current_setting('test.cell_pl')::UUID), current_date, 'going live dates the launch');

SELECT is(
    (public.listing_apply_submission(current_setting('test.sub_no_price')::UUID, 'done', NULL, '[]', 'live', 'B07N4M94X4')).status,
    'uploaded',
    'live without a price keeps uploaded'
);
SELECT is((SELECT listing_state FROM public.market_cell WHERE id = current_setting('test.cell_gb')::UUID), 'live', 'its listing_state is live anyway');
SELECT matches(
    (public.listing_apply_submission(
        current_setting('test.sub_issues')::UUID, 'accepted', 's6',
        '[{"code":"90220","message":"''size'' is required but not supplied.","severity":"ERROR","attributeNames":["size"]}]',
        'issues', NULL
    )).open_issue,
    '^Amazon: ''size'' is required',
    'issues write open_issue'
);
SELECT is((SELECT status::TEXT FROM public.market_cell WHERE id = current_setting('test.cell_nl')::UUID), 'planned', 'accepted with issues keeps the status');
SELECT is((SELECT listing_state::TEXT FROM public.market_cell WHERE id = current_setting('test.cell_nl')::UUID), 'issues', 'accepted with issues is in issues');
SELECT is((SELECT platform_product_id FROM public.market_cell WHERE id = current_setting('test.cell_pl')::UUID), 'B07N4M94X4', 'the ASIN fills the platform product id');

-- C2/C13. listing_begin_submission: GB's last submission is done, so a new one starts; BE's is
-- accepted (in flight), so a second one is refused. A user begins it: created_by is the caller.
RESET ROLE;
SELECT private.impersonate(current_setting('test.akif')::UUID, current_setting('test.client')::UUID);
SELECT set_config('test.sub_begin', (public.listing_begin_submission(
    current_setting('test.cell_gb')::UUID, 'update', '{"productType": "LUGGAGE"}'
)).id::TEXT, TRUE);
SELECT ok(
    (SELECT status = 'processing' AND created_by = current_setting('test.akif')::UUID AND issues = '[]'::JSONB
     FROM api.listing_submission WHERE id = current_setting('test.sub_begin')::UUID),
    'begin records a processing submission by the caller'
);
SELECT is((SELECT listing_state::TEXT FROM api.market_cell WHERE id = current_setting('test.cell_gb')::UUID), 'submitted', 'begin marks the cell submitted before Amazon is called');
SELECT throws_ok(
    $$ SELECT public.listing_begin_submission(current_setting('test.cell_be')::UUID, 'create', '{}') $$,
    'P0001',
    'listing_in_progress',
    'begin refuses while the last submission is in flight'
);
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);

-- C2. An older submission's answer settles that submission only: GB keeps the newer one's state.
SELECT is(
    (public.listing_apply_submission(current_setting('test.sub_no_price')::UUID, 'done', NULL,
        '[{"code":"18027","message":"late","severity":"ERROR"}]', 'issues', NULL)).listing_state::TEXT,
    'submitted',
    'a stale submission does not move the cell'
);
SELECT is(
    (SELECT issues -> 0 ->> 'message' FROM public.listing_submission WHERE id = current_setting('test.sub_no_price')::UUID),
    'late',
    'a stale submission is still settled'
);

-- C2. listing_set_state writes only over the version it read.
SELECT is(
    (public.listing_set_state(current_setting('test.cell_se')::UUID, 'ready', NULL, '2000-01-01T00:00:00Z')).listing_state::TEXT,
    'submitted',
    'set_state over a changed cell keeps the current state'
);
SELECT is(
    (public.listing_set_state(current_setting('test.cell_se')::UUID, 'ready', NULL,
        (SELECT updated_at FROM public.market_cell WHERE id = current_setting('test.cell_se')::UUID))).listing_state::TEXT,
    'ready',
    'set_state over the version it read writes'
);

-- C18. Leaving issues (a removal) clears the Amazon open issue.
SELECT is(
    (public.listing_set_state(current_setting('test.cell_nl')::UUID, 'draft', NULL)).open_issue,
    NULL,
    'leaving issues clears the Amazon open issue'
);

-- The parent case: a parent product with one child, the child's cell on amazon DE.
RESET ROLE;

WITH parent AS (
    INSERT INTO public.product (tenant_id, sku, display_name)
    VALUES (current_setting('test.client')::UUID, 'AMZ-M22-PARENT', 'M22 parent')
    RETURNING id
), child AS (
    INSERT INTO public.product (tenant_id, parent_id, sku, display_name)
    SELECT current_setting('test.client')::UUID, parent.id, 'AMZ-M22-CHILD', 'M22 child' FROM parent
    RETURNING id
), cell AS (
    INSERT INTO public.market_cell (tenant_id, product_id, platform_id, country)
    SELECT current_setting('test.client')::UUID, child.id, 'amazon', 'DE' FROM child
    RETURNING id
)
SELECT set_config('test.child_cell', cell.id::TEXT, TRUE) FROM cell;

WITH s AS (
    INSERT INTO public.listing_submission (tenant_id, cell_id, kind, sku, marketplace_id, payload)
    VALUES (current_setting('test.client')::UUID, current_setting('test.child_cell')::UUID, 'create', 'AMZ-M22-CHILD', 'A1PA6795UKMFR9', '{}')
    RETURNING id
)
SELECT set_config('test.sub_child', s.id::TEXT, TRUE) FROM s;

SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);

SELECT isnt(public.listing_parent_cell(current_setting('test.child_cell')::UUID), NULL, 'the parent cell is created');
SELECT set_config('test.parent_cell', public.listing_parent_cell(current_setting('test.child_cell')::UUID)::TEXT, TRUE);

SELECT 1 FROM public.listing_apply_submission(
    current_setting('test.sub_child')::UUID, 'done', NULL, '[{"code":"18027","message":"image","severity":"ERROR"}]', 'issues', NULL
);

SELECT is(
    (SELECT listing_state FROM public.market_cell WHERE id = public.listing_parent_cell(current_setting('test.child_cell')::UUID)),
    'issues',
    'the parent mirrors the worst child'
);

-- C6. The parent's own submission counts too: its failure is not hidden by a live child, and it
-- goes live once both are.
RESET ROLE;
INSERT INTO public.listing_submission (tenant_id, cell_id, kind, sku, marketplace_id, payload)
VALUES (current_setting('test.client')::UUID, current_setting('test.parent_cell')::UUID, 'create', 'AMZ-M22-PARENT', 'A1PA6795UKMFR9', '{}');
INSERT INTO public.listing_submission (tenant_id, cell_id, kind, sku, marketplace_id, payload)
VALUES (current_setting('test.client')::UUID, current_setting('test.child_cell')::UUID, 'update', 'AMZ-M22-CHILD', 'A1PA6795UKMFR9', '{}');
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SELECT 1 FROM public.listing_apply_submission(
    (SELECT id FROM public.listing_submission WHERE cell_id = current_setting('test.parent_cell')::UUID),
    'failed', NULL, '[{"code":"amazon_poll_timeout","message":"late","severity":"ERROR"}]', 'issues', NULL
);
SELECT 1 FROM public.listing_apply_submission(
    (SELECT id FROM public.listing_submission WHERE cell_id = current_setting('test.child_cell')::UUID AND kind = 'update'),
    'done', NULL, '[]', 'live', NULL
);
SELECT is(
    (SELECT listing_state::TEXT FROM public.market_cell WHERE id = current_setting('test.parent_cell')::UUID),
    'issues',
    'a live child does not hide the parent''s own failure'
);
RESET ROLE;
INSERT INTO public.listing_submission (tenant_id, cell_id, kind, sku, marketplace_id, payload)
VALUES (current_setting('test.client')::UUID, current_setting('test.parent_cell')::UUID, 'update', 'AMZ-M22-PARENT', 'A1PA6795UKMFR9', '{}');
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SELECT 1 FROM public.listing_apply_submission(
    (SELECT id FROM public.listing_submission WHERE cell_id = current_setting('test.parent_cell')::UUID AND kind = 'update'),
    'done', NULL, '[]', 'live', NULL
);
SELECT is(
    (SELECT listing_state::TEXT FROM public.market_cell WHERE id = current_setting('test.parent_cell')::UUID),
    'live',
    'the parent is live with its own listing and its children live'
);

RESET ROLE;

-- 48–49. The bucket, the coordinator.
SELECT ok((SELECT public FROM storage.buckets WHERE id = 'listing-images'), 'listing-images is public');
SELECT throws_ok(
    $$ INSERT INTO public.amazon_product_type_definition (marketplace_id, product_type, locale, version, schema, property_groups)
       VALUES ('X', 'Y', 'en_GB', '1', '{}', '{"g": {"title": "G", "propertyNames": []}}') $$,
    '23514',
    NULL,
    'the property groups are an ordered array'
);
SELECT ok(
    EXISTS (
        SELECT 1
        FROM public.role_permission rp
        JOIN public.role r ON r.id = rp.role_id
        JOIN public.permission p ON p.id = rp.permission_id
        WHERE r.tenant_id = current_setting('test.client')::UUID AND r.display_name = 'coordinator'
          AND p.resource_name = 'public.listing_submission' AND p.command = 'insert'
    ),
    'the coordinator may publish'
);

-- 51. Deleting the account deletes its token.
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SELECT 1 FROM public.amazon_account_connect(current_setting('test.acct')::UUID, 'Atzr|third', 'A3TEST');
RESET ROLE;
DELETE FROM public.platform_account WHERE id = current_setting('test.acct')::UUID;
SELECT is((SELECT count(*) FROM vault.secrets WHERE name = 'amazon:' || current_setting('test.acct'))::INT, 0, 'a deleted account leaves no secret');

-- The account the caller's-credentials tests below connect and disconnect: the tenant's own, again.
INSERT INTO public.platform_account (tenant_id, platform_id) VALUES (current_setting('test.client')::UUID, 'amazon');

-- The caller's credentials. What is the user's act runs as the user (the coordinator in the seller tenant, who
-- holds insert on listing_submission): beginning a submission, getting the parent cell,
-- disconnecting; the audit records that user. Amazon's outcome (apply, set_state,
-- settle_removal) only the service role may write: a user is refused EXECUTE; the service role
-- passes the triggering user as p_actor and the audit names that user, role amazon-listing. A
-- service call without an actor is labelled by its x-audit-role header (and x-audit-actor), which a
-- user cannot forge; a user of another tenant, or without the permission, is refused inside the
-- RPC; the table stays closed to direct writes. Each call starts its own audit transaction
-- (audit.transaction_id cleared).
SELECT set_config('test.zzb', (SELECT a.id FROM public.platform_account a
                               WHERE a.tenant_id = current_setting('test.client')::UUID AND a.platform_id = 'amazon')::TEXT, TRUE);

UPDATE public.market_cell SET platform_sku = ' AMZ-PL-OWN ' WHERE id = current_setting('test.cell_pl')::UUID;
SELECT private.impersonate(current_setting('test.koord')::UUID, current_setting('test.client')::UUID);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT set_config('test.sub_user', (public.listing_begin_submission(
    current_setting('test.cell_pl')::UUID, 'update', '{}'
)).id::TEXT, TRUE);
SELECT set_config('test.tx_begin', current_setting('audit.transaction_id'), TRUE);
-- A user's own x-audit-role / x-audit-actor headers are not a label.
SELECT set_config('request.headers', json_build_object(
    'x-tenant-id', current_setting('test.client'), 'x-tenant-ids', current_setting('test.client'),
    'x-audit-role', 'amazon-poll', 'x-audit-actor', current_setting('test.akif'))::TEXT, TRUE);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT set_config('test.sub_removal', (public.listing_begin_submission(
    current_setting('test.cell_se')::UUID, 'delete', '{}'
)).id::TEXT, TRUE);
SELECT set_config('test.tx_forged', current_setting('audit.transaction_id'), TRUE);
SELECT isnt(public.listing_parent_cell(current_setting('test.child_cell')::UUID), NULL, 'a user gets the parent cell');
SELECT throws_ok(
    $$ SELECT public.listing_begin_submission(current_setting('test.cell_pl')::UUID, 'update', 'FORGED-SKU', 'ATVPDKIKX0DER', '{}') $$,
    '42883',
    NULL,
    'a user cannot name the SKU or the marketplace of a submission'
);

-- Amazon's outcome is not the user's to write.
SELECT throws_ok(
    $$ SELECT public.listing_apply_submission(current_setting('test.sub_user')::UUID, 'done', NULL, '[]', 'live', NULL) $$,
    '42501',
    NULL,
    'a user cannot apply Amazon''s answer'
);
SELECT throws_ok(
    $$ SELECT public.listing_set_state(current_setting('test.cell_se')::UUID, 'live', NULL) $$,
    '42501',
    NULL,
    'a user cannot set the listing state'
);
SELECT throws_ok(
    $$ SELECT public.listing_settle_removal(current_setting('test.sub_removal')::UUID, 'done', NULL, '[]') $$,
    '42501',
    NULL,
    'a user cannot settle a removal'
);
SELECT throws_ok(
    $$ SELECT public.listing_apply_submission(current_setting('test.sub_user')::UUID, 'done', NULL, '[]', 'live', NULL, current_setting('test.akif')::UUID) $$,
    '42501',
    NULL,
    'a user cannot apply Amazon''s answer in another''s name'
);
SELECT throws_ok(
    $$ INSERT INTO api.listing_submission (tenant_id, cell_id, kind, sku, marketplace_id, payload)
       VALUES (current_setting('test.client')::UUID, current_setting('test.cell_se')::UUID, 'create', 'X', 'Y', '{}') $$,
    '42501',
    NULL,
    'a user with the permission still cannot insert a submission directly'
);
SELECT throws_ok(
    $$ UPDATE api.listing_submission SET status = 'done' WHERE id = current_setting('test.sub_user')::UUID $$,
    '42501',
    NULL,
    'a user with the permission still cannot update a submission directly'
);
SELECT throws_ok(
    $$ SELECT public.amazon_account_connect(current_setting('test.zzb')::UUID, 'Atzr|forged', 'AFORGED') $$,
    '42501',
    NULL,
    'a user cannot connect an account'
);
RESET ROLE;

-- The service role: amazon-listing writing Amazon's outcome for the coordinator, an OAuth callback for
-- the coordinator, the poll, and an unknown label.
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SELECT set_config('request.headers', json_build_object('x-audit-role', 'amazon-listing', 'x-audit-actor', current_setting('test.koord'))::TEXT, TRUE);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT 1 FROM public.listing_apply_submission(current_setting('test.sub_user')::UUID, 'accepted', 'u1',
    '[{"code":"90220","message":"size","severity":"ERROR"}]', 'issues', NULL, current_setting('test.koord')::UUID);
SELECT set_config('test.tx_apply', current_setting('audit.transaction_id'), TRUE);
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT 1 FROM public.listing_set_state(current_setting('test.cell_se')::UUID, 'draft', NULL, NULL, current_setting('test.koord')::UUID);
SELECT set_config('test.tx_state', current_setting('audit.transaction_id'), TRUE);
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT is(
    (public.listing_settle_removal(current_setting('test.sub_removal')::UUID, 'done', 'r1', '[]', current_setting('test.koord')::UUID)).status::TEXT,
    'done',
    'the service role settles a removal for the user'
);
SELECT set_config('test.tx_settle', current_setting('audit.transaction_id'), TRUE);
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SELECT throws_ok(
    $$ SELECT public.listing_settle_removal(current_setting('test.sub_user')::UUID, 'done', NULL, '[]') $$,
    '22023',
    NULL,
    'only a removal is settled without the walk'
);
SELECT throws_ok(
    $$ SELECT public.listing_set_state(current_setting('test.cell_se')::UUID, 'live', NULL, NULL, current_setting('test.selin')::UUID) $$,
    '42501',
    'listing_forbidden',
    'an actor of another tenant is refused'
);
SELECT throws_ok(
    $$ SELECT public.listing_apply_submission(current_setting('test.sub_user')::UUID, 'done', NULL, '[]', 'live', NULL, current_setting('test.selin')::UUID) $$,
    '42501',
    'listing_forbidden',
    'an outcome cannot be applied in the name of a user without the permission there'
);

SELECT set_config('request.headers', json_build_object('x-audit-role', 'amazon-auth', 'x-audit-actor', current_setting('test.koord'))::TEXT, TRUE);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT 1 FROM public.amazon_account_connect(current_setting('test.zzb')::UUID, 'Atzr|zzb', 'A3ZZB');
SELECT set_config('test.tx_connect', current_setting('audit.transaction_id'), TRUE);
SELECT set_config('request.headers', '{"x-audit-role": "amazon-poll"}', TRUE);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT 1 FROM public.listing_set_state(current_setting('test.cell_se')::UUID, 'ready', NULL);
SELECT set_config('test.tx_poll', current_setting('audit.transaction_id'), TRUE);
SELECT set_config('request.headers', '{"x-audit-role": "anything"}', TRUE);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT 1 FROM public.listing_set_state(current_setting('test.cell_se')::UUID, 'draft', NULL);
SELECT set_config('test.tx_unlabelled', current_setting('audit.transaction_id'), TRUE);
SELECT set_config('request.headers', '', TRUE);
RESET ROLE;

-- the coordinator disconnects the account (update on platform_account); revoked is the
-- server's word only.
SELECT private.impersonate(current_setting('test.koord')::UUID, current_setting('test.client')::UUID);
SELECT throws_ok(
    $$ SELECT public.amazon_account_disconnect(current_setting('test.zzb')::UUID, 'revoked') $$,
    '42501',
    NULL,
    'a user cannot mark an account revoked'
);
SELECT set_config('audit.transaction_id', '', TRUE);
SELECT lives_ok($$ SELECT public.amazon_account_disconnect(current_setting('test.zzb')::UUID, 'none') $$, 'a user disconnects the account');
SELECT set_config('test.tx_disconnect', current_setting('audit.transaction_id'), TRUE);
RESET ROLE;
SELECT ok(
    (SELECT a.api_connection = 'none' AND private.amazon_token(a.id) IS NULL FROM public.platform_account a WHERE a.id = current_setting('test.zzb')::UUID),
    'a user''s disconnect clears the connection and the token'
);

-- Another tenant's user.
SELECT private.impersonate(current_setting('test.selin')::UUID, current_setting('test.other')::UUID);
SELECT throws_ok(
    $$ SELECT public.listing_begin_submission(current_setting('test.cell_se')::UUID, 'delete', '{}') $$,
    '42501',
    'listing_forbidden',
    'another tenant cannot begin a submission'
);
SELECT throws_ok(
    $$ SELECT public.listing_parent_cell(current_setting('test.child_cell')::UUID) $$,
    '42501',
    'listing_forbidden',
    'another tenant cannot get the parent cell'
);
SELECT throws_ok(
    $$ SELECT public.amazon_account_disconnect(current_setting('test.zzb')::UUID, 'none') $$,
    '42501',
    NULL,
    'another tenant cannot disconnect the account'
);
RESET ROLE;

-- the coordinator without the permission.
DELETE FROM public.role_permission rp
USING public.role r, public.permission p
WHERE rp.role_id = r.id AND rp.permission_id = p.id
  AND r.tenant_id = current_setting('test.client')::UUID AND r.display_name = 'coordinator'
  AND p.resource_name = 'public.listing_submission' AND p.command = 'insert';
SELECT private.impersonate(current_setting('test.koord')::UUID, current_setting('test.client')::UUID);
SELECT throws_ok(
    $$ SELECT public.listing_begin_submission(current_setting('test.cell_pl')::UUID, 'delete', '{}') $$,
    '42501',
    'listing_forbidden',
    'without the permission a submission is refused'
);
SELECT throws_ok(
    $$ SELECT public.listing_parent_cell(current_setting('test.child_cell')::UUID) $$,
    '42501',
    'listing_forbidden',
    'without the permission the parent cell is refused'
);
RESET ROLE;

-- The db role authenticated with a service_role claim is a user, not the service role.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"role": "service_role"}', TRUE);
SELECT set_config('request.headers', json_build_object('x-tenant-id', current_setting('test.client'), 'x-tenant-ids', current_setting('test.client'))::TEXT, TRUE);
SELECT throws_ok(
    $$ SELECT public.listing_begin_submission(current_setting('test.cell_se')::UUID, 'delete', '{}') $$,
    '42501',
    'listing_forbidden',
    'authenticated with a service_role claim cannot begin a submission'
);
SELECT throws_ok(
    $$ SELECT public.amazon_account_disconnect(current_setting('test.zzb')::UUID, 'none') $$,
    '42501',
    'platform_account_forbidden',
    'authenticated with a service_role claim cannot disconnect'
);
RESET ROLE;

-- Who the audit names.
SELECT is(
    (SELECT created_by FROM public.listing_submission WHERE id = current_setting('test.sub_user')::UUID),
    current_setting('test.koord')::UUID,
    'created_by is the caller'
);
SELECT ok(
    (SELECT s.sku = 'AMZ-PL-OWN' AND s.marketplace_id = 'A1C3SOZRARQ6R3'
     FROM public.listing_submission s WHERE s.id = current_setting('test.sub_user')::UUID)
    AND (SELECT s.sku = 'AMZ-MOP40-2P' AND s.marketplace_id = 'A2NODRKZP88ZB9'
         FROM public.listing_submission s WHERE s.id = current_setting('test.sub_removal')::UUID),
    'begin stores the cell''s own SKU (its platform SKU, else the product''s) and its country''s marketplace'
);
SELECT ok(
    (SELECT t.actor_id = current_setting('test.koord')::UUID AND t.actor_role = 'authenticated'
     FROM public.audit_transaction t WHERE t.id = current_setting('test.tx_begin')::UUID),
    'a user''s begin is audited as the user'
);
SELECT ok(
    EXISTS (SELECT 1 FROM public.audit_log l WHERE l.transaction_id = current_setting('test.tx_begin')::UUID AND l.table_name = 'listing_submission')
    AND EXISTS (SELECT 1 FROM public.audit_log l WHERE l.transaction_id = current_setting('test.tx_begin')::UUID AND l.table_name = 'market_cell'),
    'the begin logs the submission and the cell'
);
SELECT ok(
    (SELECT t.actor_id = current_setting('test.koord')::UUID AND t.actor_role = 'amazon-listing'
     FROM public.audit_transaction t WHERE t.id = current_setting('test.tx_apply')::UUID)
    AND EXISTS (SELECT 1 FROM public.audit_log l WHERE l.transaction_id = current_setting('test.tx_apply')::UUID AND l.table_name = 'listing_submission')
    AND EXISTS (SELECT 1 FROM public.audit_log l WHERE l.transaction_id = current_setting('test.tx_apply')::UUID AND l.table_name = 'market_cell'),
    'Amazon''s answer applied for the user is audited as the user, role amazon-listing, on the submission and the cell'
);
SELECT ok(
    (SELECT t.actor_id = current_setting('test.koord')::UUID AND t.actor_role = 'amazon-listing' AND t.table_name = 'market_cell'
     FROM public.audit_transaction t WHERE t.id = current_setting('test.tx_state')::UUID),
    'a state written for the user is audited as the user, role amazon-listing'
);
SELECT ok(
    (SELECT t.actor_id = current_setting('test.koord')::UUID AND t.actor_role = 'amazon-listing'
     FROM public.audit_transaction t WHERE t.id = current_setting('test.tx_settle')::UUID),
    'a removal settled for the user is audited as the user, role amazon-listing'
);
SELECT ok(
    (SELECT t.actor_id = current_setting('test.koord')::UUID AND t.actor_role = 'authenticated'
     FROM public.audit_transaction t WHERE t.id = current_setting('test.tx_forged')::UUID),
    'a user''s audit headers change nothing'
);
SELECT ok(
    (SELECT t.actor_id = current_setting('test.koord')::UUID AND t.actor_role = 'amazon-auth'
     FROM public.audit_transaction t WHERE t.id = current_setting('test.tx_connect')::UUID),
    'the OAuth callback''s connect is audited as the user of the state, labelled amazon-auth'
);
SELECT ok(
    (SELECT t.actor_id IS NULL AND t.actor_role = 'amazon-poll'
     FROM public.audit_transaction t WHERE t.id = current_setting('test.tx_poll')::UUID),
    'a poll write (no actor) is labelled amazon-poll'
);
SELECT is(
    (SELECT t.actor_role FROM public.audit_transaction t WHERE t.id = current_setting('test.tx_unlabelled')::UUID),
    'service_role',
    'an unknown label is ignored'
);
SELECT ok(
    (SELECT t.actor_id = current_setting('test.koord')::UUID AND t.actor_role = 'authenticated'
     FROM public.audit_transaction t WHERE t.id = current_setting('test.tx_disconnect')::UUID),
    'a user''s disconnect is audited as the user'
);

SELECT * FROM finish();

ROLLBACK;
