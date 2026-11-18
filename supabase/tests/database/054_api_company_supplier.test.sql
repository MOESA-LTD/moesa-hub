CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- 054: the company tables (provider relationship, contact, warehouse, platform account) and the
-- supplier tables behind the masked api views, as the client's viewer, a coordinator and a
-- restricted user; sourcing (055) brings the supplier relationships (R4).
BEGIN;

SELECT plan(25);

SELECT private.field_test_fixtures();
SELECT private.create_test_helpers();
SELECT is_empty($$ SELECT * FROM private.api_view_drift() $$, 'api_view_drift() is empty');

-- As portal, THO's viewer, in THO: the provider's rows stay in the provider's tenant (Plan 1).
SELECT private.impersonate(current_setting('test.portal')::UUID, current_setting('test.tho')::UUID);
SELECT is((SELECT count(*)::INT FROM api.provider_relationship), 0, 'the client reads no relationship row of its provider');
SELECT is((SELECT count(*)::INT FROM api.contact WHERE id = current_setting('test.tho_contact')::UUID), 0, 'nor the provider''s contacts');
SELECT is((SELECT count(*)::INT FROM api.supplier), 0, 'portal has no supplier table access');

-- As koordinator in moesa.
RESET ROLE;
SELECT private.impersonate(current_setting('test.koordinator')::UUID, current_setting('test.moesa')::UUID);
SELECT is((SELECT deposit_rate FROM api.supplier WHERE id = current_setting('test.tsp')::UUID), 0.3::NUMERIC, 'coordinator reads supplier terms');
SELECT throws_ok($$ UPDATE api.supplier SET payment_terms = 'net 60' WHERE id = current_setting('test.tsp')::UUID $$, '42501', 'field_write_forbidden', 'coordinator cannot change supplier terms');
SELECT lives_ok($$ UPDATE api.supplier SET payment_terms = 'net 30', city = 'Shanghai' WHERE id = current_setting('test.tsp')::UUID $$, 'S1: sending the visible value unchanged is not a write');
SELECT is(t.peek('supplier', 'city', current_setting('test.tsp')::UUID), 'Shanghai', '… and the open change is forwarded');
SELECT results_eq($$ SELECT deposit_rate, restricted_drive_url, notes FROM api.provider_relationship WHERE id = current_setting('test.rel')::UUID $$,
   $$ VALUES (0.4::NUMERIC, 'https://drive.example/THO'::TEXT, 'relationship secret'::TEXT) $$, 'coordinator reads the contract terms and internal notes');
SELECT is((SELECT email FROM api.contact WHERE id = current_setting('test.tho_contact')::UUID), 'buyer@tho.example', 'coordinator reads contact personal data');
SELECT throws_ok($$ UPDATE api.provider_relationship SET deposit_rate = 0.2 WHERE id = current_setting('test.rel')::UUID $$, '42501', 'field_write_forbidden', 'contract stays guarded through the view');
SELECT lives_ok($$ UPDATE api.supplier_contact SET phone = '+86 101' WHERE id = current_setting('test.tsp_contact')::UUID $$, 'coordinator writes supplier contacts');
SELECT lives_ok($$ INSERT INTO api.warehouse (tenant_id, display_name) VALUES (current_setting('test.moesa')::UUID, 'W-T') $$, 'insert through the view');
SELECT lives_ok($$ DELETE FROM api.warehouse WHERE display_name = 'W-T' $$, 'delete through the view');
SELECT throws_ok($$ UPDATE api.platform_account SET api_connection = 'connected' WHERE id = current_setting('test.acct')::UUID $$, '23514', 'platform_account_api_server_only', 'R6 holds through api');
SELECT is((SELECT s.code FROM api.sourcing p, api.supplier(p) s WHERE p.id = current_setting('test.secret_sourcing')::UUID), 'TS1', 'R4: the supplier embed works with the right');

-- As elif in moesa (t_restricted: the company and supplier tables, no field rows).
RESET ROLE;
SELECT private.impersonate(current_setting('test.elif')::UUID, current_setting('test.moesa')::UUID);
SELECT is((SELECT count(*)::INT FROM api.provider_relationship WHERE restricted_drive_url LIKE '%THO%'), 0, 'drive URL filter oracle closed');
SELECT is((SELECT notes FROM api.platform_account WHERE id = current_setting('test.acct')::UUID), NULL, 'platform account notes masked');
SELECT is((SELECT account_holder FROM api.platform_account WHERE id = current_setting('test.acct')::UUID), NULL, 'account holder masked (personal_data)');
SELECT throws_ok($$ UPDATE api.supplier SET deposit_rate = 0.3 WHERE id = current_setting('test.tsp')::UUID $$, '42501', 'field_write_forbidden', 'S1: a correct guess on a supplier term is refused');
SELECT throws_ok($$ UPDATE api.supplier SET deposit_rate = 0.9 WHERE id = current_setting('test.tsp')::UUID $$, '42501', 'field_write_forbidden', 'S1: a wrong guess is refused the same way');
SELECT is((SELECT count(*)::INT FROM api.sourcing p, api.supplier(p) s WHERE p.id = current_setting('test.secret_sourcing')::UUID), 0, 'R4: a hidden supplier link embeds nothing');
SELECT is((SELECT count(*)::INT FROM api.supplier s, api.sourcing_by_supplier(s) p WHERE s.id = current_setting('test.tsp')::UUID), 0, 'R4: the reverse embed from supplier is empty');
SELECT lives_ok($$ UPDATE api.provider_relationship SET eu_responsible_person = notes WHERE id = current_setting('test.rel')::UUID $$, 'T6d copying a masked column …');
SELECT isnt(t.peek('provider_relationship', 'eu_responsible_person', current_setting('test.rel')::UUID), 'relationship secret', '… never copies the secret');

SELECT * FROM finish();
ROLLBACK;
