CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Incidents (035): the code from the family and the tenant's code, the customer notice time of S1
-- and S2 (business days), the deadlines the incident calculates, the overview's linked record and
-- next deadline, the Y10 card of the incident's family, the fixed family, the linked record of the
-- incident's own tenant (not another tenant's, not a provider's order for the tenant, not an
-- unknown id), the management notice before an S1 leaves open, what closing needs and that
-- management closes an S1, a closed incident's log, the final closed status, a cost with its
-- currency and payer, no deleting, no customer column, and another tenant that sees none of them.
-- What it writes is rolled back.
BEGIN;

SELECT plan(31);

-- Fixture, built here as postgres (the seed is not on the new model yet):
--   tenant   ...3501  Thor Trading (THO): owner 3511 (management), coordinator 3512 (role 3531:
--                     incidents, products, projects; no right to change the company); supplier
--                     3581; product 3521, project pilot 3524, own order 3541
--   other    ...3502  Other Company (OTH), owned by 3513; project 3526, product 3527
--   provider ...3503  Provider Trading (PRV), owned by 3514; procures for THO (relationship 3561);
--                     supplier 3582; order 3542 for THO
INSERT INTO public.plan (display_name, is_active) VALUES ('Incident test plan', TRUE);

INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000003501', 'Thor Trading', 'THO'),
   ('00000000-0000-4000-8000-000000003502', 'Other Company', 'OTH'),
   ('00000000-0000-4000-8000-000000003503', 'Provider Trading', 'PRV');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000003511', 'owner@incident.test'),
   ('00000000-0000-4000-8000-000000003512', 'coordinator@incident.test'),
   ('00000000-0000-4000-8000-000000003513', 'other@incident.test'),
   ('00000000-0000-4000-8000-000000003514', 'provider@incident.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003511', '00000000-0000-4000-8000-000000003501'),
   ('00000000-0000-4000-8000-000000003513', '00000000-0000-4000-8000-000000003502'),
   ('00000000-0000-4000-8000-000000003514', '00000000-0000-4000-8000-000000003503');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003511', '00000000-0000-4000-8000-000000003501'),
   ('00000000-0000-4000-8000-000000003512', '00000000-0000-4000-8000-000000003501'),
   ('00000000-0000-4000-8000-000000003513', '00000000-0000-4000-8000-000000003502'),
   ('00000000-0000-4000-8000-000000003514', '00000000-0000-4000-8000-000000003503');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000003531', '00000000-0000-4000-8000-000000003501', 'Coordinator');
INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000003531', p.id FROM public.permission p
WHERE p.group_name IN ('incident', 'product', 'project');
INSERT INTO public.user_role (user_id, role_id) VALUES
   ('00000000-0000-4000-8000-000000003512', '00000000-0000-4000-8000-000000003531');

INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, procurement_model) VALUES
   ('00000000-0000-4000-8000-000000003561', '00000000-0000-4000-8000-000000003503', '00000000-0000-4000-8000-000000003501',
    'THO', 'Thor Trading', 'provider');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, default_incoterm, status) VALUES
   ('00000000-0000-4000-8000-000000003581', '00000000-0000-4000-8000-000000003501', 'TR1', 'Bir', 'Türkiye', 'EXW', 'approved'),
   ('00000000-0000-4000-8000-000000003582', '00000000-0000-4000-8000-000000003503', 'TR1', 'Bir', 'Türkiye', 'EXW', 'approved');

SELECT private.impersonate('00000000-0000-4000-8000-000000003514', '00000000-0000-4000-8000-000000003503');
INSERT INTO api.purchase_order (id, tenant_id, client_tenant_id, supplier_id, currency)
VALUES ('00000000-0000-4000-8000-000000003542', '00000000-0000-4000-8000-000000003503', '00000000-0000-4000-8000-000000003501',
        '00000000-0000-4000-8000-000000003582', 'USD');
RESET ROLE;

SELECT private.impersonate('00000000-0000-4000-8000-000000003513', '00000000-0000-4000-8000-000000003502');
INSERT INTO api.project (id, tenant_id, display_name, type, path, packages)
VALUES ('00000000-0000-4000-8000-000000003526', '00000000-0000-4000-8000-000000003502', 'Other lamp', 'npi', 'a_sourcing', ARRAY['A1']);
INSERT INTO api.product (id, tenant_id, sku, display_name)
VALUES ('00000000-0000-4000-8000-000000003527', '00000000-0000-4000-8000-000000003502', 'OTH-LAMP', 'Other lamp');
RESET ROLE;

SELECT private.impersonate('00000000-0000-4000-8000-000000003511', '00000000-0000-4000-8000-000000003501');
INSERT INTO api.product (id, tenant_id, sku, display_name)
VALUES ('00000000-0000-4000-8000-000000003521', '00000000-0000-4000-8000-000000003501', 'THO-MOP40-2P', 'Mop 40 cm, 2 pack');
INSERT INTO api.project (id, tenant_id, display_name, type, path, packages)
VALUES ('00000000-0000-4000-8000-000000003524', '00000000-0000-4000-8000-000000003501', 'Mop pilot', 'npi', 'a_sourcing', ARRAY['A1']);
INSERT INTO api.purchase_order (id, tenant_id, supplier_id, currency)
VALUES ('00000000-0000-4000-8000-000000003541', '00000000-0000-4000-8000-000000003501', '00000000-0000-4000-8000-000000003581', 'USD');
RESET ROLE;

-- The rest runs as the coordinator, management where it says so.
SELECT private.impersonate('00000000-0000-4000-8000-000000003512', '00000000-0000-4000-8000-000000003501');

-- An S1 on Friday morning about the pilot, an S2 on Saturday about a document request.
INSERT INTO api.incident (id, tenant_id, code, family, severity, title, what_happened, entity_type, entity_id, opened_at)
VALUES ('00000000-0000-4000-8000-000000035011', '00000000-0000-4000-8000-000000003501', 'X', 'ol', 's1', 'Pallets short at Rosbach',
        'Two pallets fewer than the packing list.', 'project', '00000000-0000-4000-8000-000000003524', '2026-11-06 09:00+00'),
       ('00000000-0000-4000-8000-000000035012', '00000000-0000-4000-8000-000000003501', NULL, 'oa', 's2', 'GPSR document request',
        'Amazon DE asks for the GPSR safety information.', NULL, NULL, '2026-11-07 10:00+00');
INSERT INTO api.incident_deadline (id, tenant_id, incident_id, kind)
VALUES ('00000000-0000-4000-8000-000000035021', '00000000-0000-4000-8000-000000003501', '00000000-0000-4000-8000-000000035012', 'document_request'),
       ('00000000-0000-4000-8000-000000035022', '00000000-0000-4000-8000-000000003501', '00000000-0000-4000-8000-000000035011', 'supplier_damage');

SELECT hasnt_column('public', 'incident', 'customer_id', 'an incident names no customer');
SELECT hasnt_column('public', 'incident_overview', 'customer_code', 'the overview names no customer');
SELECT is((SELECT code || ':' || status FROM api.incident WHERE id = '00000000-0000-4000-8000-000000035011'),
          'OL-THO-' || extract(year FROM now())::INT || '-001:open', 'the code is the family, the tenant''s code, the year and the number');
SELECT is((SELECT customer_notice_due_at FROM api.incident WHERE id = '00000000-0000-4000-8000-000000035011'),
          '2026-11-06 13:00+00'::TIMESTAMPTZ, 'S1: the customer within four hours');
SELECT is((SELECT customer_notice_due_at FROM api.incident WHERE id = '00000000-0000-4000-8000-000000035012'),
          '2026-11-09 23:59:59+00'::TIMESTAMPTZ, 'S2 on a Saturday: by the end of Monday');
SELECT is(public.add_business_days('2026-11-06', 5), '2026-11-13'::DATE, 'five business days from a Friday');
SELECT is(public.add_business_days('2026-11-07', 0), '2026-11-09'::DATE, 'a weekend day rolls to Monday');
SELECT is((SELECT due_at FROM api.incident_deadline WHERE id = '00000000-0000-4000-8000-000000035021'),
          '2026-11-13 23:59:59+00'::TIMESTAMPTZ, 'a document request: five business days');
SELECT is((SELECT due_at FROM api.incident_deadline WHERE id = '00000000-0000-4000-8000-000000035022'),
          '2026-11-08 09:00+00'::TIMESTAMPTZ, 'the supplier damage notice: 48 hours');
SELECT throws_ok($$ INSERT INTO api.incident_deadline (tenant_id, incident_id, kind) VALUES ('00000000-0000-4000-8000-000000003501', '00000000-0000-4000-8000-000000035011', 'other') $$,
                 '23502', NULL, 'another deadline needs its date');
SELECT is((SELECT entity_label FROM api.incident_overview WHERE id = '00000000-0000-4000-8000-000000035011'),
          'THO-' || extract(year FROM now())::INT || '-001', 'the overview names the linked record');
SELECT is((SELECT next_deadline_at FROM api.incident_overview WHERE id = '00000000-0000-4000-8000-000000035012'),
          '2026-11-13 23:59:59+00'::TIMESTAMPTZ, 'the next deadline');
SELECT throws_ok($$ UPDATE api.incident SET incident_type = 'OA-02' WHERE id = '00000000-0000-4000-8000-000000035011' $$,
                 '23514', 'incident_type_family', 'the Y10 card is of the incident''s family');
SELECT throws_ok($$ UPDATE api.incident SET incident_type = 'OL-1' WHERE id = '00000000-0000-4000-8000-000000035011' $$,
                 '23514', NULL, 'a Y10 card code');
SELECT throws_ok($$ UPDATE api.incident SET family = 'om' WHERE id = '00000000-0000-4000-8000-000000035011' $$,
                 '23514', 'incident_immutable_field', 'the family is fixed with the code');
SELECT throws_ok($$ UPDATE api.incident SET entity_id = '00000000-0000-4000-8000-000000003526' WHERE id = '00000000-0000-4000-8000-000000035011' $$,
                 '23514', 'incident_entity_invalid', 'not another tenant''s project');
SELECT throws_ok($$ INSERT INTO api.incident (tenant_id, family, severity, title, what_happened, entity_type, entity_id)
                    VALUES ('00000000-0000-4000-8000-000000003501', 'ou', 's3', 'Label', 'Wrong label.', 'product', '00000000-0000-4000-8000-000000003527') $$,
                 '23514', 'incident_entity_invalid', 'not another tenant''s product');
SELECT throws_ok($$ UPDATE api.incident SET entity_type = 'purchase_order', entity_id = '00000000-0000-4000-8000-000000003542' WHERE id = '00000000-0000-4000-8000-000000035012' $$,
                 '23514', 'incident_entity_invalid', 'not the provider''s order for the tenant (linked in a later sharing step)');
SELECT throws_ok($$ UPDATE api.incident SET entity_type = 'purchase_order', entity_id = '00000000-0000-4000-8000-000000035999' WHERE id = '00000000-0000-4000-8000-000000035012' $$,
                 '23514', 'incident_entity_invalid', 'an unknown record gets the same refusal');
SELECT lives_ok($$ UPDATE api.incident SET entity_type = 'purchase_order', entity_id = '00000000-0000-4000-8000-000000003541' WHERE id = '00000000-0000-4000-8000-000000035012' $$,
                'the tenant''s own order is linked');
SELECT throws_ok($$ UPDATE api.incident SET status = 'contained' WHERE id = '00000000-0000-4000-8000-000000035011' $$,
                 '23514', 'incident_management_notice_required', 'S1 leaves open only once management is told');

SELECT throws_ok($$ UPDATE api.incident SET severity = 's3', status = 'contained' WHERE id = '00000000-0000-4000-8000-000000035011' $$,
                 '42501', 'incident_severity_downgrade_requires_management', 'only management lowers an S1 or S2');

UPDATE api.incident SET management_notified_at = '2026-11-06 09:30+00', status = 'contained' WHERE id = '00000000-0000-4000-8000-000000035011';

SELECT throws_ok($$ UPDATE api.incident SET status = 'closed' WHERE id = '00000000-0000-4000-8000-000000035011' $$,
                 '23514', 'incident_closure_incomplete', 'closing needs the outcome, root cause and preventive action');
SELECT throws_ok($$ UPDATE api.incident SET status = 'closed', outcome = 'partial_recovery', root_cause = 'carrier', preventive_action = 'Y07 §4.3: count pallets at loading (v1.2)'
                    WHERE id = '00000000-0000-4000-8000-000000035011' $$,
                 '42501', 'incident_close_management', 'management closes an S1');

RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000003511', '00000000-0000-4000-8000-000000003501');
UPDATE api.incident SET status = 'closed', outcome = 'partial_recovery', root_cause = 'carrier', preventive_action = 'Y07 §4.3: count pallets at loading (v1.2)'
WHERE id = '00000000-0000-4000-8000-000000035011';

SELECT is((SELECT status || ':' || (closed_on = current_date) FROM api.incident WHERE id = '00000000-0000-4000-8000-000000035011'),
          'closed:true', 'closing dates it');
SELECT lives_ok($$ UPDATE api.incident SET severity = 's3' WHERE id = '00000000-0000-4000-8000-000000035012' $$,
                'management lowers an S2');
SELECT throws_ok($$ INSERT INTO api.incident_log (tenant_id, incident_id, note) VALUES ('00000000-0000-4000-8000-000000003501', '00000000-0000-4000-8000-000000035011', 'late note') $$,
                 '23514', 'incident_closed', 'a closed incident''s log no longer changes');
SELECT throws_ok($$ UPDATE api.incident SET status = 'open' WHERE id = '00000000-0000-4000-8000-000000035011' $$,
                 '23514', 'incident_status_order', 'closed is final');
SELECT throws_ok($$ INSERT INTO api.incident_log (tenant_id, incident_id, note, cost_amount) VALUES ('00000000-0000-4000-8000-000000003501', '00000000-0000-4000-8000-000000035012', 'storage fee', 100) $$,
                 '23514', NULL, 'a cost names its currency and payer');
SELECT throws_ok($$ DELETE FROM api.incident WHERE id = '00000000-0000-4000-8000-000000035012' $$,
                 '42501', NULL, 'incidents are not deleted');

RESET ROLE;
SELECT private.impersonate('00000000-0000-4000-8000-000000003513', '00000000-0000-4000-8000-000000003502');
SELECT is((SELECT count(*)::INT FROM api.incident), 0, 'another tenant sees none');

SELECT * FROM finish();

ROLLBACK;
