CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Change requests (037): the code from the tenant's code, the decision due date (five business
-- days, or 24 hours when urgent), at least one kind of change, the affected and resulting documents
-- of the request's own tenant (not another tenant's, not an unknown id), the status flow, the
-- customer's written approval after a passed gate that needs it, the company's approval date and
-- approver, the new version an applied request needs, the reason of a rejection, the project and
-- products of the request's own tenant, no deleting, no customer column, and another tenant that
-- sees none of them. What it writes is rolled back.
BEGIN;

SELECT plan(29);

-- Fixture, built here as postgres (the seed is not on the new model yet):
--   tenant ...3701  Thor Trading (THO): owner 3711, coordinator 3712 (role 3731: change requests,
--                   documents, products, projects); product mop 3721 with its spec sheet v2 3723,
--                   project pilot 3724 (G1 passed below)
--   other  ...3702  Other Company (OTH), owned by 3713; product 3725 with its spec sheet 3726,
--                   project 3727
INSERT INTO public.plan (display_name, is_active) VALUES ('Change request test plan', TRUE);

INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000003701', 'Thor Trading', 'THO'),
   ('00000000-0000-4000-8000-000000003702', 'Other Company', 'OTH');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000003711', 'owner@cr.test'),
   ('00000000-0000-4000-8000-000000003712', 'coordinator@cr.test'),
   ('00000000-0000-4000-8000-000000003713', 'other@cr.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003711', '00000000-0000-4000-8000-000000003701'),
   ('00000000-0000-4000-8000-000000003713', '00000000-0000-4000-8000-000000003702');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003711', '00000000-0000-4000-8000-000000003701'),
   ('00000000-0000-4000-8000-000000003712', '00000000-0000-4000-8000-000000003701'),
   ('00000000-0000-4000-8000-000000003713', '00000000-0000-4000-8000-000000003702');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000003731', '00000000-0000-4000-8000-000000003701', 'Coordinator');
INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000003731', p.id FROM public.permission p
WHERE p.group_name IN ('change_request', 'document', 'product', 'project');
INSERT INTO public.user_role (user_id, role_id) VALUES
   ('00000000-0000-4000-8000-000000003712', '00000000-0000-4000-8000-000000003731');

SELECT private.impersonate('00000000-0000-4000-8000-000000003713', '00000000-0000-4000-8000-000000003702');
INSERT INTO api.product (id, tenant_id, sku, display_name)
VALUES ('00000000-0000-4000-8000-000000003725', '00000000-0000-4000-8000-000000003702', 'OTH-LAMP', 'Other lamp');
INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, url)
VALUES ('00000000-0000-4000-8000-000000003726', '00000000-0000-4000-8000-000000003702', 'product', '00000000-0000-4000-8000-000000003725', 'spec_sheet', 'https://example.test/oth-spec.pdf');
INSERT INTO api.project (id, tenant_id, display_name, type, path, packages)
VALUES ('00000000-0000-4000-8000-000000003727', '00000000-0000-4000-8000-000000003702', 'Other lamp', 'npi', 'a_sourcing', ARRAY['A1']);
RESET ROLE;

-- The owner sets up the product and passes the pilot's G1 (it needs the customer's approval).
SELECT private.impersonate('00000000-0000-4000-8000-000000003711', '00000000-0000-4000-8000-000000003701');
INSERT INTO api.product (id, tenant_id, sku, display_name)
VALUES ('00000000-0000-4000-8000-000000003721', '00000000-0000-4000-8000-000000003701', 'THO-MOP40-2P', 'Mop 40 cm, 2 pack');
INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, version, url)
VALUES ('00000000-0000-4000-8000-000000003723', '00000000-0000-4000-8000-000000003701', 'product', '00000000-0000-4000-8000-000000003721', 'spec_sheet', 2, 'https://example.test/spec-v02.pdf');
INSERT INTO api.project (id, tenant_id, display_name, type, path, packages)
VALUES ('00000000-0000-4000-8000-000000003724', '00000000-0000-4000-8000-000000003701', 'Mop pilot', 'npi', 'a_sourcing', ARRAY['A1']);
INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, status, url)
VALUES ('00000000-0000-4000-8000-000000037001', '00000000-0000-4000-8000-000000003701', 'project_gate',
        (SELECT id FROM api.project_gate WHERE project_id = '00000000-0000-4000-8000-000000003724' AND code = 'G1'), 'gate_approval', 'approved', 'https://example.test/G1.pdf');
UPDATE api.project_task SET status = 'done' WHERE project_id = '00000000-0000-4000-8000-000000003724';
SELECT public.pass_gate((SELECT id FROM api.project_gate WHERE project_id = '00000000-0000-4000-8000-000000003724' AND code = 'G1'), 'brief ok', current_date, '00000000-0000-4000-8000-000000037001');
RESET ROLE;

-- The rest runs as the coordinator.
SELECT private.impersonate('00000000-0000-4000-8000-000000003712', '00000000-0000-4000-8000-000000003701');

INSERT INTO api.change_request (id, tenant_id, code, project_id, title, source, change_kinds, current_value, requested_value, reason, affected_gate_code, affected_document_id)
VALUES ('00000000-0000-4000-8000-000000037011', '00000000-0000-4000-8000-000000003701', 'X', '00000000-0000-4000-8000-000000003724', 'Tolerance 3 mm', 'supplier',
        ARRAY['spec']::public.change_kind[], 'Tolerance ± 5 mm', 'Tolerance ± 3 mm', 'Sample T02 edge deviation.', 'G1', '00000000-0000-4000-8000-000000003723');
INSERT INTO api.change_request (id, tenant_id, title, source, urgency, change_kinds, current_value, requested_value, reason)
VALUES ('00000000-0000-4000-8000-000000037012', '00000000-0000-4000-8000-000000003701', 'Ready date +7 days', 'customer', 'urgent',
        ARRAY['deadline']::public.change_kind[], 'Ready 2027-01-10', 'Ready 2027-01-17', 'The customer moved the launch.');

SELECT hasnt_column('public', 'change_request', 'customer_id', 'a request names no customer');
SELECT hasnt_column('public', 'change_request_product', 'customer_id', 'nor do its products');
SELECT is((SELECT code || ':' || status FROM api.change_request WHERE id = '00000000-0000-4000-8000-000000037011'),
          'CR-THO-' || extract(year FROM now())::INT || '-001:open', 'CR-<tenant code>-<year>-<number> (K5, S08)');
SELECT is((SELECT decision_due_on FROM api.change_request WHERE id = '00000000-0000-4000-8000-000000037011'),
          public.add_business_days((now() AT TIME ZONE 'UTC')::DATE, 5), 'a normal request is decided in five business days');
SELECT is((SELECT decision_due_on FROM api.change_request WHERE id = '00000000-0000-4000-8000-000000037012'),
          (now() AT TIME ZONE 'UTC')::DATE + 1, 'an urgent one in 24 hours');
SELECT throws_ok($$ INSERT INTO api.change_request (tenant_id, title, source, change_kinds, current_value, requested_value, reason)
                    VALUES ('00000000-0000-4000-8000-000000003701', 'Nothing', 'company', ARRAY[]::public.change_kind[], 'a', 'b', 'c') $$,
                 '23514', NULL, 'at least one kind of change');
SELECT throws_ok($$ UPDATE api.change_request SET affected_document_id = '00000000-0000-4000-8000-000000003726' WHERE id = '00000000-0000-4000-8000-000000037011' $$,
                 '23514', 'change_request_document_invalid', 'not another tenant''s document');
SELECT throws_ok($$ UPDATE api.change_request SET affected_document_id = '00000000-0000-4000-8000-000000037999' WHERE id = '00000000-0000-4000-8000-000000037011' $$,
                 '23514', 'change_request_document_invalid', 'an unknown document gets the same refusal');
SELECT throws_ok($$ UPDATE api.change_request SET project_id = '00000000-0000-4000-8000-000000003727' WHERE id = '00000000-0000-4000-8000-000000037012' $$,
                 '23503', 'insert or update on table "change_request" violates foreign key constraint "change_request_project_fkey"',
                 'not another tenant''s project');
SELECT throws_ok($$ UPDATE api.change_request SET status = 'applied' WHERE id = '00000000-0000-4000-8000-000000037011' $$,
                 '23514', 'change_request_status_order', 'approved before applied');
SELECT throws_ok($$ UPDATE api.change_request SET status = 'approved' WHERE id = '00000000-0000-4000-8000-000000037011' $$,
                 '23514', 'change_request_customer_approval_required', 'a passed (M) gate needs the customer''s written approval');
SELECT throws_ok($$ UPDATE api.change_request SET customer_approval_document_id = '00000000-0000-4000-8000-000000003723' WHERE id = '00000000-0000-4000-8000-000000037011' $$,
                 '23514', 'change_request_approval_document_invalid', 'the approval is a document of the request');

INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, status, url)
VALUES ('00000000-0000-4000-8000-000000037021', '00000000-0000-4000-8000-000000003701', 'change_request', '00000000-0000-4000-8000-000000037011',
        'change_request', 'approved', 'https://example.test/cr-approval.pdf');
UPDATE api.change_request SET customer_approved_on = current_date, customer_approval_document_id = '00000000-0000-4000-8000-000000037021', status = 'approved'
WHERE id = '00000000-0000-4000-8000-000000037011';

SELECT is((SELECT company_approved_on = (now() AT TIME ZONE 'UTC')::DATE AND company_approved_by = '00000000-0000-4000-8000-000000003712' FROM api.change_request WHERE id = '00000000-0000-4000-8000-000000037011'),
          TRUE, 'approval records the company''s date and approver');
SELECT throws_ok($$ UPDATE api.change_request SET status = 'applied' WHERE id = '00000000-0000-4000-8000-000000037011' $$,
                 '23514', 'change_request_new_version_required', 'applied needs the new version');

INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, url)
VALUES ('00000000-0000-4000-8000-000000037031', '00000000-0000-4000-8000-000000003701', 'product', '00000000-0000-4000-8000-000000003721', 'label_artwork', 'https://example.test/label.pdf');

SELECT throws_ok($$ UPDATE api.change_request SET result_document_id = '00000000-0000-4000-8000-000000037031', status = 'applied' WHERE id = '00000000-0000-4000-8000-000000037011' $$,
                 '23514', 'change_request_new_version_required', 'the new version is of the same document');

INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, version, url)
VALUES ('00000000-0000-4000-8000-000000037032', '00000000-0000-4000-8000-000000003701', 'product', '00000000-0000-4000-8000-000000003721', 'spec_sheet', 3, 'https://example.test/spec-v03.pdf');
UPDATE api.change_request SET result_document_id = '00000000-0000-4000-8000-000000037032', status = 'applied' WHERE id = '00000000-0000-4000-8000-000000037011';

SELECT is((SELECT status || ':' || (closed_on = (now() AT TIME ZONE 'UTC')::DATE) FROM api.change_request WHERE id = '00000000-0000-4000-8000-000000037011'),
          'applied:true', 'the spec''s new version applies the request');
SELECT throws_ok($$ UPDATE api.change_request SET result_document_id = NULL WHERE id = '00000000-0000-4000-8000-000000037011' $$,
                 '23514', 'change_request_immutable_field', 'an applied request keeps its new version');
SELECT throws_ok($$ UPDATE api.change_request SET affected_document_id = NULL WHERE id = '00000000-0000-4000-8000-000000037011' $$,
                 '23514', 'change_request_immutable_field', 'nor does its affected document change');
SELECT throws_ok($$ UPDATE api.change_request SET status = 'rejected' WHERE id = '00000000-0000-4000-8000-000000037012' $$,
                 '23514', 'change_request_decision_note_required', 'a rejection says why');
SELECT throws_ok($$ INSERT INTO api.change_request_product (change_request_id, product_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000037012', '00000000-0000-4000-8000-000000003725', '00000000-0000-4000-8000-000000003701') $$,
                 '23503', 'insert or update on table "change_request_product" violates foreign key constraint "change_request_product_product_fkey"',
                 'not another tenant''s product');
SELECT lives_ok($$ INSERT INTO api.change_request_product (change_request_id, product_id, tenant_id) VALUES ('00000000-0000-4000-8000-000000037012', '00000000-0000-4000-8000-000000003721', '00000000-0000-4000-8000-000000003701') $$,
                'the tenant''s own product is touched');
SELECT throws_ok($$ DELETE FROM api.change_request WHERE id = '00000000-0000-4000-8000-000000037012' $$,
                 '42501', NULL, 'change requests are not deleted');

-- The approver, the approval date and the closing date are the server's, whatever the client sends.
UPDATE api.change_request SET status = 'approved', company_approved_by = '00000000-0000-4000-8000-000000003711', company_approved_on = '2020-01-01', closed_on = '2020-01-01'
WHERE id = '00000000-0000-4000-8000-000000037012';

SELECT is((SELECT company_approved_by = '00000000-0000-4000-8000-000000003712' AND company_approved_on = (now() AT TIME ZONE 'UTC')::DATE AND closed_on IS NULL
           FROM api.change_request WHERE id = '00000000-0000-4000-8000-000000037012'),
          TRUE, 'the approver, approval date and closing date are not the client''s');
SELECT throws_ok($$ UPDATE api.change_request SET result_document_id = '00000000-0000-4000-8000-000000003726' WHERE id = '00000000-0000-4000-8000-000000037012' $$,
                 '23514', 'change_request_document_invalid', 'the resulting document is the tenant''s, even without an affected document');
SELECT throws_ok($$ UPDATE api.change_request SET customer_approval_document_id = NULL, customer_approved_on = NULL WHERE id = '00000000-0000-4000-8000-000000037011' $$,
                 '23514', 'change_request_immutable_field', 'the customer''s approval stays once the request is approved');
SELECT throws_ok($$ UPDATE api.change_request SET created_at = now() - INTERVAL '10 days' WHERE id = '00000000-0000-4000-8000-000000037012' $$,
                 '23514', 'change_request_immutable_field', 'when the request was made does not change');

-- The customer's approval may be entered after the company approves (the current version 2); an
-- entered one stays.
INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, status, version, url)
VALUES ('00000000-0000-4000-8000-000000037041', '00000000-0000-4000-8000-000000003701', 'change_request', '00000000-0000-4000-8000-000000037012',
        'change_request', 'approved', 1, 'https://example.test/cr-012-approval.pdf'),
       ('00000000-0000-4000-8000-000000037042', '00000000-0000-4000-8000-000000003701', 'change_request', '00000000-0000-4000-8000-000000037012',
        'change_request', 'approved', 2, 'https://example.test/cr-012-approval-2.pdf');

SELECT lives_ok($$ UPDATE api.change_request SET customer_approved_on = current_date, customer_approval_document_id = '00000000-0000-4000-8000-000000037042'
                   WHERE id = '00000000-0000-4000-8000-000000037012' $$,
                'the customer''s approval is entered after the company approves');
SELECT throws_ok($$ UPDATE api.change_request SET customer_approval_document_id = '00000000-0000-4000-8000-000000037041' WHERE id = '00000000-0000-4000-8000-000000037012' $$,
                 '23514', 'change_request_immutable_field', 'an entered approval is not swapped');

RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000003713', '00000000-0000-4000-8000-000000003702');
SELECT is((SELECT count(*)::INT FROM api.change_request), 0, 'another tenant sees none');

SELECT * FROM finish();

ROLLBACK;
