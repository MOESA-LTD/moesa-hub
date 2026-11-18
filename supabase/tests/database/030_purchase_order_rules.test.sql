CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Purchase order rules (030): the status flow (one step at a time, no deposit step at 0 %, cancelled
-- and closed final, the code trigger's draft on insert), the spec sheet rule before and from
-- spec_sheet_required_from (also for a client order's line, whose product is in the client's
-- tenant), the PI document, checklist and S09 arithmetic, the locks from pi_approved, the payment
-- gates, the closed order's children, the overview's figures and hints, and the rules_bypass flag a
-- user cannot use. What it writes is rolled back.
BEGIN;

SELECT plan(38);

-- Fixture, built here as postgres (the seed is not on the new model yet):
--   provider  ...3001  code PRV; owned by staff ...3002 (the order clerk of every test below)
--   client    ...3003  provider procures (relationship ...3004, client_code THO); staff is invited
--                      with role ...3005 (read products)
--   suppliers TR1 ...3006 (EXW, 30 %), CN1 ...3007
--   products  provider: mop ...3008, tips ...3009, cones ...3010 (on sale); client: ...3011 (new)
--   spec_mop  ...3012, the mop's signed spec sheet
INSERT INTO public.plan (display_name, is_active) VALUES ('Purchase order rules test plan', TRUE);

INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000003001', 'Provider Trading', 'PRV'),
   ('00000000-0000-4000-8000-000000003003', 'Thor Trading', 'THO');

INSERT INTO public.user (id, email) VALUES ('00000000-0000-4000-8000-000000003002', 'staff@po-rules.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000003002', '00000000-0000-4000-8000-000000003001');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003002', '00000000-0000-4000-8000-000000003001'),
   ('00000000-0000-4000-8000-000000003002', '00000000-0000-4000-8000-000000003003');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000003005', '00000000-0000-4000-8000-000000003003', 'Provider staff');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000003005', p.id FROM public.permission p
WHERE p.resource_name = 'public.product' AND p.command = 'select';

INSERT INTO public.user_role (user_id, role_id) VALUES ('00000000-0000-4000-8000-000000003002', '00000000-0000-4000-8000-000000003005');

INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, procurement_model) VALUES
   ('00000000-0000-4000-8000-000000003004', '00000000-0000-4000-8000-000000003001', '00000000-0000-4000-8000-000000003003',
    'THO', 'Thor Trading', 'provider');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, default_incoterm, deposit_rate, status) VALUES
   ('00000000-0000-4000-8000-000000003006', '00000000-0000-4000-8000-000000003001', 'TR1', 'Bir', 'Türkiye', 'EXW', 30, 'approved'),
   ('00000000-0000-4000-8000-000000003007', '00000000-0000-4000-8000-000000003001', 'CN1', 'Yi', 'China', 'FOB', 30, 'approved');

INSERT INTO public.product (id, tenant_id, sku, display_name, status) VALUES
   ('00000000-0000-4000-8000-000000003008', '00000000-0000-4000-8000-000000003001', 'PRV-MOP', 'Mop', 'on_sale'),
   ('00000000-0000-4000-8000-000000003009', '00000000-0000-4000-8000-000000003001', 'PRV-TIPS', 'Tips', 'on_sale'),
   ('00000000-0000-4000-8000-000000003010', '00000000-0000-4000-8000-000000003001', 'PRV-CONES', 'Cones', 'on_sale'),
   ('00000000-0000-4000-8000-000000003011', '00000000-0000-4000-8000-000000003003', 'THO-NEW-2', 'New client mop', 'development');

INSERT INTO public.document (id, tenant_id, entity_type, entity_id, type, version, status, issued_on, is_signed, is_stamped,
                             sent_from_official_email, url)
VALUES ('00000000-0000-4000-8000-000000003012', '00000000-0000-4000-8000-000000003001', 'product', '00000000-0000-4000-8000-000000003008',
        'spec_sheet', 1, 'signed', '2026-11-01', TRUE, TRUE, TRUE, 'https://example.test/spec-mop.pdf');

-- The names the tests below use.
SELECT set_config('test.' || x.k, x.v, TRUE)
FROM (VALUES
    ('provider', '00000000-0000-4000-8000-000000003001'),
    ('staff', '00000000-0000-4000-8000-000000003002'),
    ('client', '00000000-0000-4000-8000-000000003003'),
    ('tr1', '00000000-0000-4000-8000-000000003006'),
    ('cn1', '00000000-0000-4000-8000-000000003007'),
    ('mop', '00000000-0000-4000-8000-000000003008'),
    ('tips', '00000000-0000-4000-8000-000000003009'),
    ('cones', '00000000-0000-4000-8000-000000003010'),
    ('spec_mop', '00000000-0000-4000-8000-000000003012')
) AS x (k, v);
SELECT private.impersonate(current_setting('test.staff')::UUID, current_setting('test.provider')::UUID);

-- Fixtures, as the provider's owner. Every own order is TR1 / USD (EXW and 30 % from TR1); f has no
-- deposit; g (...30018) is an order for the client, with a line on the client's new SKU.
INSERT INTO api.product (id, tenant_id, sku, display_name, status)
VALUES ('00000000-0000-4000-8000-000000030001', current_setting('test.provider')::UUID, 'PRV-NEW-1', 'New mop', 'development');
INSERT INTO api.purchase_order (id, tenant_id, supplier_id, currency, deposit_rate)
VALUES ('00000000-0000-4000-8000-000000030011', current_setting('test.provider')::UUID, current_setting('test.tr1')::UUID, 'USD', NULL), ('00000000-0000-4000-8000-000000030012', current_setting('test.provider')::UUID, current_setting('test.tr1')::UUID, 'USD', NULL),
       ('00000000-0000-4000-8000-000000030013', current_setting('test.provider')::UUID, current_setting('test.tr1')::UUID, 'USD', NULL), ('00000000-0000-4000-8000-000000030014', current_setting('test.provider')::UUID, current_setting('test.tr1')::UUID, 'USD', NULL),
       ('00000000-0000-4000-8000-000000030015', current_setting('test.provider')::UUID, current_setting('test.tr1')::UUID, 'USD', NULL), ('00000000-0000-4000-8000-000000030016', current_setting('test.provider')::UUID, current_setting('test.tr1')::UUID, 'USD', 0);
INSERT INTO api.purchase_order (id, tenant_id, client_tenant_id, supplier_id, currency)
VALUES ('00000000-0000-4000-8000-000000030018', current_setting('test.provider')::UUID, current_setting('test.client')::UUID, current_setting('test.tr1')::UUID, 'USD');
INSERT INTO api.purchase_order_line (id, tenant_id, purchase_order_id, product_id, quantity, unit_price, spec_document_id)
VALUES ('00000000-0000-4000-8000-000000030021', current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030011', current_setting('test.mop')::UUID, 1000, 2, NULL), ('00000000-0000-4000-8000-000000030022', current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030011', current_setting('test.tips')::UUID, 10, 1, NULL),
       ('00000000-0000-4000-8000-000000030023', current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030013', '00000000-0000-4000-8000-000000030001', 5, 1, NULL), ('00000000-0000-4000-8000-000000030024', current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030014', current_setting('test.tips')::UUID, 5, 1, NULL),
       ('00000000-0000-4000-8000-000000030025', current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030015', current_setting('test.mop')::UUID, 5, 1, current_setting('test.spec_mop')::UUID), ('00000000-0000-4000-8000-000000030026', current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030016', current_setting('test.mop')::UUID, 1, 1, NULL),
       ('00000000-0000-4000-8000-000000030027', current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030018', '00000000-0000-4000-8000-000000003011', 5, 1, NULL);
INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, url)
VALUES ('00000000-0000-4000-8000-000000030031', current_setting('test.provider')::UUID, 'purchase_order', '00000000-0000-4000-8000-000000030011', 'pi', 'https://example.test/pi-a.pdf'),
       ('00000000-0000-4000-8000-000000030032', current_setting('test.provider')::UUID, 'purchase_order', '00000000-0000-4000-8000-000000030012', 'pi', 'https://example.test/pi-b.pdf');

-- The status guard runs after the code trigger: a client-sent status is replaced by draft, not refused.
SELECT lives_ok($$ INSERT INTO api.purchase_order (id, tenant_id, supplier_id, currency, status)
                   VALUES ('00000000-0000-4000-8000-000000030017', current_setting('test.provider')::UUID,
                           current_setting('test.tr1')::UUID, 'USD', 'balance_paid') $$,
                'an insert with a client-sent status passes the guard');
SELECT is((SELECT status::TEXT FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000030017'), 'draft',
          'and the order starts as a draft');
SELECT throws_ok($$ UPDATE api.purchase_order_line SET purchase_order_id = '00000000-0000-4000-8000-000000030012' WHERE id = '00000000-0000-4000-8000-000000030024' $$,
                 '23514', 'po_line_identity_immutable', 'a line stays on its order');

RESET ROLE;
UPDATE public.setting SET value = to_jsonb((current_date + 1)::TEXT) WHERE tenant_id = current_setting('test.provider')::UUID AND key = 'spec_sheet_required_from';
SELECT private.impersonate(current_setting('test.staff')::UUID, current_setting('test.provider')::UUID);

SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'pi_approved' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                 '23514', 'po_status_order', 'no skipping statuses');
SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'sent' WHERE id = '00000000-0000-4000-8000-000000030012' $$,
                 '23514', 'po_lines_required', 'an order needs lines');
SELECT lives_ok($$ UPDATE api.purchase_order SET status = 'sent' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                'before the date, SKUs on sale go without a spec reference');
SELECT is((SELECT cardinality(spec_missing_line_ids) FROM api.purchase_order_overview WHERE id = '00000000-0000-4000-8000-000000030011'), 0,
          'no missing-spec hint before the date for SKUs on sale');
SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'sent' WHERE id = '00000000-0000-4000-8000-000000030013' $$,
                 '23514', 'po_spec_sheet_required', 'a new SKU needs its spec sheet');
SELECT is((SELECT spec_missing_line_ids FROM api.purchase_order_overview WHERE id = '00000000-0000-4000-8000-000000030013'),
          ARRAY['00000000-0000-4000-8000-000000030023']::UUID[], 'the overview names the new SKU''s line');
SELECT is((SELECT spec_missing_line_ids FROM api.purchase_order_overview WHERE id = '00000000-0000-4000-8000-000000030018'),
          ARRAY['00000000-0000-4000-8000-000000030027']::UUID[], 'a client order''s line on the client''s new SKU is named too');
SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'draft' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                 '23514', 'po_status_order', 'no going back');

RESET ROLE;
UPDATE public.setting SET value = to_jsonb((current_date)::TEXT) WHERE tenant_id = current_setting('test.provider')::UUID AND key = 'spec_sheet_required_from';
SELECT private.impersonate(current_setting('test.staff')::UUID, current_setting('test.provider')::UUID);

SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'sent' WHERE id = '00000000-0000-4000-8000-000000030014' $$,
                 '23514', 'po_spec_sheet_required', 'from the date on, every SKU');
SELECT throws_ok($$ UPDATE api.purchase_order_line SET spec_document_id = current_setting('test.spec_mop')::UUID WHERE id = '00000000-0000-4000-8000-000000030024' $$,
                 '23514', 'po_line_spec_invalid', 'another product''s spec sheet does not count');
SELECT lives_ok($$ UPDATE api.purchase_order SET status = 'sent' WHERE id = '00000000-0000-4000-8000-000000030015' $$,
                'a referenced signed spec sheet passes');

-- The guards share-lock the order, so a concurrent status change waits for the line or child write
-- (the foreign key alone takes FOR KEY SHARE, which a status update does not wait for). pgrowlocks
-- names a share lock 'For Share', or 'Share' inside a multixact.
UPDATE api.purchase_order_line SET notes = 'checked' WHERE id = '00000000-0000-4000-8000-000000030025';
INSERT INTO api.purchase_order_update (tenant_id, purchase_order_id, note)
VALUES (current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030012', 'chased the supplier');
RESET ROLE;
CREATE EXTENSION IF NOT EXISTS pgrowlocks WITH SCHEMA extensions;
SELECT ok((SELECT r.modes && ARRAY['For Share', 'Share'] FROM extensions.pgrowlocks('public.purchase_order') r JOIN public.purchase_order po ON po.ctid = r.locked_row
           WHERE po.id = '00000000-0000-4000-8000-000000030015'), 'a line write share-locks its order');
SELECT ok((SELECT r.modes && ARRAY['For Share', 'Share'] FROM extensions.pgrowlocks('public.purchase_order') r JOIN public.purchase_order po ON po.ctid = r.locked_row
           WHERE po.id = '00000000-0000-4000-8000-000000030012'), 'a production update share-locks its order');
SELECT private.impersonate(current_setting('test.staff')::UUID, current_setting('test.provider')::UUID);
SELECT throws_ok($$ INSERT INTO api.purchase_order_line (tenant_id, purchase_order_id, product_id, quantity, unit_price)
                    VALUES (current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030015', current_setting('test.tips')::UUID, 1, 1) $$,
                 '23514', 'po_spec_sheet_required', 'a sent order takes no line without a spec sheet');
SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'pi_received' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                 '23514', 'po_pi_required', 'PI document and total first');
SELECT throws_ok($$ UPDATE api.purchase_order SET pi_document_id = '00000000-0000-4000-8000-000000030032' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                 '23514', 'po_pi_document_invalid', 'only this order''s PI');

UPDATE api.purchase_order SET pi_document_id = '00000000-0000-4000-8000-000000030031', pi_total = 2600, status = 'pi_received' WHERE id = '00000000-0000-4000-8000-000000030011';

SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'pi_approved' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                 '23514', 'po_pi_checklist_incomplete', 'all 30 S09 items must be OK');

UPDATE api.purchase_order SET pi_check = (SELECT jsonb_object_agg(i::TEXT, 'ok') FROM generate_series(1, 30) AS i) WHERE id = '00000000-0000-4000-8000-000000030011';

SELECT throws_ok($$ UPDATE api.purchase_order
                    SET pi_subtotal = 2510, pi_extra_amount = 150, pi_discount_amount = 50, pi_total = 2610,
                        pi_deposit_amount = 783, pi_balance_amount = 1827, status = 'pi_approved'
                    WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                 '23514', 'po_pi_mismatch', 'a PI that does not add up is not approved');
SELECT lives_ok($$ UPDATE api.purchase_order
                   SET pi_subtotal = 2010, pi_extra_amount = 150, pi_discount_amount = 50, pi_total = 2110,
                       pi_deposit_amount = 633, pi_balance_amount = 1477, status = 'pi_approved'
                   WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                'exact figures approve the PI');
SELECT is((SELECT pi_checked_by FROM api.purchase_order WHERE id = '00000000-0000-4000-8000-000000030011'), current_setting('test.staff')::UUID, 'the checker is recorded');
SELECT is((SELECT system_subtotal || ':' || system_total || ':' || system_deposit || ':' || system_balance
           FROM api.purchase_order_overview WHERE id = '00000000-0000-4000-8000-000000030011'),
          '2010.00:2110.00:633.00:1477.00', 'the overview recalculates the PI');
SELECT throws_ok($$ UPDATE api.purchase_order_line SET quantity = 999 WHERE id = '00000000-0000-4000-8000-000000030021' $$,
                 '23514', 'po_locked', 'lines are fixed after PI approval');
SELECT throws_ok($$ UPDATE api.purchase_order SET currency = 'EUR' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                 '23514', 'po_locked', 'terms are fixed after PI approval');
SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'deposit_paid' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                 '23514', 'po_deposit_unpaid', 'a paid deposit first');

-- Payments, as the provider's owner.
RESET ROLE;
SELECT private.impersonate(current_setting('test.staff')::UUID, current_setting('test.provider')::UUID);
INSERT INTO api.purchase_order_payment (id, tenant_id, purchase_order_id, kind, amount, currency, paid_on)
VALUES ('00000000-0000-4000-8000-000000030041', current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030011', 'deposit', 633, 'USD', current_date);
RESET ROLE;
SELECT private.impersonate(current_setting('test.staff')::UUID, current_setting('test.provider')::UUID);
UPDATE api.purchase_order SET status = 'deposit_paid' WHERE id = '00000000-0000-4000-8000-000000030011';
UPDATE api.purchase_order SET status = 'in_production' WHERE id = '00000000-0000-4000-8000-000000030011';
UPDATE api.purchase_order SET status = 'ready' WHERE id = '00000000-0000-4000-8000-000000030011';

SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'balance_paid' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                 '23514', 'po_balance_unpaid', 'a paid balance first');

-- Payments, as the provider's owner.
RESET ROLE;
SELECT private.impersonate(current_setting('test.staff')::UUID, current_setting('test.provider')::UUID);
INSERT INTO api.purchase_order_payment (id, tenant_id, purchase_order_id, kind, amount, currency, paid_on)
VALUES ('00000000-0000-4000-8000-000000030042', current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030011', 'balance', 1477, 'USD', current_date);
RESET ROLE;
SELECT private.impersonate(current_setting('test.staff')::UUID, current_setting('test.provider')::UUID);

SELECT lives_ok($$ UPDATE api.purchase_order SET status = 'balance_paid' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                'a paid balance lets the order move on');
SELECT lives_ok($$ UPDATE api.purchase_order SET status = 'closed' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                'and close');
SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'cancelled' WHERE id = '00000000-0000-4000-8000-000000030011' $$,
                 '23514', 'po_status_order', 'closed is final');
SELECT throws_ok($$ UPDATE api.purchase_order_payment SET notes = 'late' WHERE id = '00000000-0000-4000-8000-000000030042' $$,
                 '23514', 'po_closed', 'a closed order''s payments no longer change');

RESET ROLE;
SELECT set_config('moesa.rules_bypass', '1', TRUE);
UPDATE public.purchase_order SET status = 'pi_approved' WHERE id = '00000000-0000-4000-8000-000000030016';
SELECT set_config('moesa.rules_bypass', '', TRUE);
SELECT private.impersonate(current_setting('test.staff')::UUID, current_setting('test.provider')::UUID);

SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'deposit_paid' WHERE id = '00000000-0000-4000-8000-000000030016' $$,
                 '23514', 'po_status_order', 'no deposit step at 0 %');
SELECT lives_ok($$ UPDATE api.purchase_order SET status = 'in_production' WHERE id = '00000000-0000-4000-8000-000000030016' $$,
                'no deposit, straight to production');

UPDATE api.purchase_order SET status = 'cancelled' WHERE id = '00000000-0000-4000-8000-000000030013';

SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'draft' WHERE id = '00000000-0000-4000-8000-000000030013' $$,
                 '23514', 'po_status_order', 'cancelled is final');
SELECT throws_ok($$ INSERT INTO api.purchase_order_update (tenant_id, purchase_order_id, note)
                    VALUES (current_setting('test.provider')::UUID, '00000000-0000-4000-8000-000000030013', 'late note') $$,
                 '23514', 'po_closed', 'a cancelled order takes no more notes');

-- The bypass is not honoured for a user (role authenticated), even with the flag set.
SELECT set_config('moesa.rules_bypass', '1', TRUE);
SELECT throws_ok($$ UPDATE api.purchase_order SET status = 'pi_approved' WHERE id = '00000000-0000-4000-8000-000000030012' $$,
                 '23514', 'po_status_order', 'an impersonated user cannot use the bypass flag');
SELECT set_config('moesa.rules_bypass', '', TRUE);

-- The figures run as the caller: the overview reads the order and lines the user may read.
RESET ROLE;
SELECT is((SELECT prosecdef FROM pg_proc WHERE oid = 'private.purchase_order_figures(uuid,uuid,numeric,numeric,numeric)'::REGPROCEDURE), FALSE,
          'purchase_order_figures is SECURITY INVOKER');

SELECT * FROM finish();

ROLLBACK;
