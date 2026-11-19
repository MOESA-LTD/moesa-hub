CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Gate evidence from orders and shipments (032): another project's PI is not evidence, G3 needs the
-- PI of one of the project's orders whose PI is approved, that PI passes G3, a shipment's delivery
-- receipt is G5 evidence, and the project still advances as before. A client's project may also be
-- served by a provider order (in the provider's tenant): it counts for G3 once its PI is approved,
-- without citing the provider's PI, which is not the client's document. What it writes is rolled
-- back.
BEGIN;

SELECT plan(8);

-- Fixture, built here as postgres (the seed is not on the new model yet):
--   client    ...3201  code THO, owned by ...3211; product THO-HOSE ...3221 with its signed spec
--                      sheet ...3222; projects pilot ...3231 and second ...3232 (both with the hose)
--   provider  ...3202  code PRV, owned by staff ...3212, who is invited into the client with role
--                      ...3213 (read projects); provider procures (relationship ...3214, THO)
INSERT INTO public.plan (display_name, is_active) VALUES ('Gate links test plan', TRUE);

INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000003201', 'Thor Trading', 'THO'),
   ('00000000-0000-4000-8000-000000003202', 'Provider Trading', 'PRV');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000003211', 'owner@gates.test'),
   ('00000000-0000-4000-8000-000000003212', 'staff@gates.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003211', '00000000-0000-4000-8000-000000003201'),
   ('00000000-0000-4000-8000-000000003212', '00000000-0000-4000-8000-000000003202');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003211', '00000000-0000-4000-8000-000000003201'),
   ('00000000-0000-4000-8000-000000003212', '00000000-0000-4000-8000-000000003202'),
   ('00000000-0000-4000-8000-000000003212', '00000000-0000-4000-8000-000000003201');

INSERT INTO public.role (id, tenant_id, display_name) VALUES
   ('00000000-0000-4000-8000-000000003213', '00000000-0000-4000-8000-000000003201', 'Provider staff');

INSERT INTO public.role_permission (role_id, permission_id)
SELECT '00000000-0000-4000-8000-000000003213', p.id FROM public.permission p
WHERE p.resource_name = 'public.project' AND p.command = 'select';

INSERT INTO public.user_role (user_id, role_id) VALUES ('00000000-0000-4000-8000-000000003212', '00000000-0000-4000-8000-000000003213');

INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, procurement_model) VALUES
   ('00000000-0000-4000-8000-000000003214', '00000000-0000-4000-8000-000000003202', '00000000-0000-4000-8000-000000003201',
    'THO', 'Thor Trading', 'provider');

INSERT INTO public.product (id, tenant_id, sku, display_name) VALUES
   ('00000000-0000-4000-8000-000000003221', '00000000-0000-4000-8000-000000003201', 'THO-HOSE', 'Garden hose');

INSERT INTO public.document (id, tenant_id, entity_type, entity_id, type, version, status, issued_on, is_signed, is_stamped,
                             sent_from_official_email, url)
VALUES ('00000000-0000-4000-8000-000000003222', '00000000-0000-4000-8000-000000003201', 'product', '00000000-0000-4000-8000-000000003221',
        'spec_sheet', 1, 'signed', '2026-11-01', TRUE, TRUE, TRUE, 'https://example.test/spec-hose.pdf');

INSERT INTO public.supplier (id, tenant_id, code, display_name, country, default_incoterm, status) VALUES
   ('00000000-0000-4000-8000-000000003251', '00000000-0000-4000-8000-000000003201', 'TR1', 'Bir', 'Türkiye', 'EXW', 'approved'),
   ('00000000-0000-4000-8000-000000003252', '00000000-0000-4000-8000-000000003202', 'CN1', 'Yi', 'China', 'FOB', 'approved');

INSERT INTO public.warehouse (id, tenant_id, display_name, city) VALUES
   ('00000000-0000-4000-8000-000000003261', '00000000-0000-4000-8000-000000003201', 'Rosbach', 'Rosbach');

SELECT set_config('test.' || x.k, x.v, TRUE)
FROM (VALUES
    ('client', '00000000-0000-4000-8000-000000003201'),
    ('provider', '00000000-0000-4000-8000-000000003202'),
    ('owner', '00000000-0000-4000-8000-000000003211'),
    ('staff', '00000000-0000-4000-8000-000000003212'),
    ('hose', '00000000-0000-4000-8000-000000003221'),
    ('pilot', '00000000-0000-4000-8000-000000003231'),
    ('second', '00000000-0000-4000-8000-000000003232')
) AS x (k, v);

-- The client's projects, made by its owner.
SELECT private.impersonate(current_setting('test.owner')::UUID, current_setting('test.client')::UUID);
INSERT INTO api.project (id, tenant_id, display_name, type, path, packages)
VALUES (current_setting('test.pilot')::UUID, current_setting('test.client')::UUID, 'Hose pilot', 'npi', 'a_sourcing', ARRAY['A1', 'C']),
       (current_setting('test.second')::UUID, current_setting('test.client')::UUID, 'Hose second', 'npi', 'a_sourcing', ARRAY['A1']);
INSERT INTO api.project_product (project_id, product_id, tenant_id)
VALUES (current_setting('test.pilot')::UUID, current_setting('test.hose')::UUID, current_setting('test.client')::UUID),
       (current_setting('test.second')::UUID, current_setting('test.hose')::UUID, current_setting('test.client')::UUID);
SELECT set_config('test.' || x.name, (SELECT g.id FROM api.project_gate g WHERE g.project_id = x.project_id AND g.code = x.code)::TEXT, TRUE)
FROM (VALUES ('p_g1', current_setting('test.pilot')::UUID, 'G1'::public.gate_code), ('p_g2', current_setting('test.pilot')::UUID, 'G2'),
             ('p_g3', current_setting('test.pilot')::UUID, 'G3'), ('p_g4', current_setting('test.pilot')::UUID, 'G4'),
             ('p_g5', current_setting('test.pilot')::UUID, 'G5'), ('s_g1', current_setting('test.second')::UUID, 'G1'),
             ('s_g2', current_setting('test.second')::UUID, 'G2'), ('g3_client', current_setting('test.second')::UUID, 'G3')) AS x (name, project_id, code);

-- Gate approvals (G1, G2, G3, G5 of the pilot; G1, G2, G3 of the second), and G1 and G2 passed the real way.
INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, status, url)
SELECT x.id, current_setting('test.client')::UUID, 'project_gate', current_setting('test.' || x.gate)::UUID,
       'gate_approval', 'approved', 'https://example.test/' || x.gate || '.pdf'
FROM (VALUES ('00000000-0000-4000-8000-000000032011'::UUID, 'p_g1'), ('00000000-0000-4000-8000-000000032012', 'p_g2'),
             ('00000000-0000-4000-8000-000000032013', 'p_g3'), ('00000000-0000-4000-8000-000000032015', 'p_g5'),
             ('00000000-0000-4000-8000-000000032016', 's_g1'), ('00000000-0000-4000-8000-000000032017', 's_g2'),
             ('00000000-0000-4000-8000-000000032018', 'g3_client')) AS x (id, gate);
UPDATE api.project_task SET status = 'done' WHERE tenant_id = current_setting('test.client')::UUID;
SELECT public.pass_gate(current_setting('test.p_g1')::UUID, 'brief ok', current_date, '00000000-0000-4000-8000-000000032011');
SELECT public.pass_gate(current_setting('test.s_g1')::UUID, 'brief ok', current_date, '00000000-0000-4000-8000-000000032016');
UPDATE api.project_task SET status = 'done' WHERE tenant_id = current_setting('test.client')::UUID;
SELECT public.pass_gate(current_setting('test.p_g2')::UUID, 'spec ok', current_date, '00000000-0000-4000-8000-000000032012');
SELECT public.pass_gate(current_setting('test.s_g2')::UUID, 'spec ok', current_date, '00000000-0000-4000-8000-000000032017');

-- The client's own orders: P (the pilot's, PI approved), P2 (the pilot's, only sent), Q (no project);
-- a shipment of P.
INSERT INTO api.purchase_order (id, tenant_id, supplier_id, project_id, currency)
VALUES ('00000000-0000-4000-8000-000000032021', current_setting('test.client')::UUID, '00000000-0000-4000-8000-000000003251', current_setting('test.pilot')::UUID, 'USD'),
       ('00000000-0000-4000-8000-000000032022', current_setting('test.client')::UUID, '00000000-0000-4000-8000-000000003251', current_setting('test.pilot')::UUID, 'USD'),
       ('00000000-0000-4000-8000-000000032023', current_setting('test.client')::UUID, '00000000-0000-4000-8000-000000003251', NULL, 'USD');
INSERT INTO api.purchase_order_line (tenant_id, purchase_order_id, product_id, quantity, unit_price)
SELECT current_setting('test.client')::UUID, x.id, current_setting('test.hose')::UUID, 10, 1
FROM (VALUES ('00000000-0000-4000-8000-000000032021'::UUID), ('00000000-0000-4000-8000-000000032022'), ('00000000-0000-4000-8000-000000032023')) AS x (id);
INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, url)
VALUES ('00000000-0000-4000-8000-000000032031', current_setting('test.client')::UUID, 'purchase_order', '00000000-0000-4000-8000-000000032021', 'pi', 'https://example.test/pi-p.pdf'),
       ('00000000-0000-4000-8000-000000032032', current_setting('test.client')::UUID, 'purchase_order', '00000000-0000-4000-8000-000000032022', 'pi', 'https://example.test/pi-p2.pdf'),
       ('00000000-0000-4000-8000-000000032033', current_setting('test.client')::UUID, 'purchase_order', '00000000-0000-4000-8000-000000032023', 'pi', 'https://example.test/pi-q.pdf');
INSERT INTO api.shipment (id, tenant_id, mode, delivery_warehouse_id)
VALUES ('00000000-0000-4000-8000-000000032041', current_setting('test.client')::UUID, 'road', '00000000-0000-4000-8000-000000003261');
INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, status, url)
VALUES ('00000000-0000-4000-8000-000000032042', current_setting('test.client')::UUID, 'shipment', '00000000-0000-4000-8000-000000032041', 'delivery_receipt', 'approved', 'https://example.test/receipt.pdf');
RESET ROLE;

-- A provider order for the client's second project, with the provider's PI (sent for now).
SELECT private.impersonate(current_setting('test.staff')::UUID, current_setting('test.provider')::UUID);
INSERT INTO api.purchase_order (id, tenant_id, client_tenant_id, supplier_id, project_id, currency)
VALUES ('00000000-0000-4000-8000-000000032051', current_setting('test.provider')::UUID, current_setting('test.client')::UUID,
        '00000000-0000-4000-8000-000000003252', current_setting('test.second')::UUID, 'USD');
INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, url)
VALUES ('00000000-0000-4000-8000-000000032052', current_setting('test.provider')::UUID, 'purchase_order', '00000000-0000-4000-8000-000000032051', 'pi', 'https://example.test/pi-provider.pdf');
RESET ROLE;

SELECT set_config('moesa.rules_bypass', '1', TRUE);
UPDATE public.purchase_order SET pi_document_id = '00000000-0000-4000-8000-000000032031', status = 'pi_approved' WHERE id = '00000000-0000-4000-8000-000000032021';
-- The shipment takes P once its PI is approved (031: only an approved, open order is shipped).
INSERT INTO public.shipment_purchase_order (shipment_id, purchase_order_id, tenant_id)
VALUES ('00000000-0000-4000-8000-000000032041', '00000000-0000-4000-8000-000000032021', current_setting('test.client')::UUID);
UPDATE public.purchase_order SET pi_document_id = '00000000-0000-4000-8000-000000032032', status = 'sent' WHERE id = '00000000-0000-4000-8000-000000032022';
UPDATE public.purchase_order SET pi_document_id = '00000000-0000-4000-8000-000000032052', status = 'sent' WHERE id = '00000000-0000-4000-8000-000000032051';
SELECT set_config('moesa.rules_bypass', '', TRUE);

SELECT private.impersonate(current_setting('test.owner')::UUID, current_setting('test.client')::UUID);
UPDATE api.project_task SET status = 'done' WHERE tenant_id = current_setting('test.client')::UUID;

SELECT throws_ok($$ SELECT public.pass_gate(current_setting('test.p_g3')::UUID, 'PI ok', current_date, '00000000-0000-4000-8000-000000032013', ARRAY['00000000-0000-4000-8000-000000032033']::UUID[]) $$,
                 '23514', 'gate_evidence_invalid', 'another project''s PI is not evidence');
SELECT throws_ok($$ SELECT public.pass_gate(current_setting('test.p_g3')::UUID, 'PI ok', current_date, '00000000-0000-4000-8000-000000032013', ARRAY['00000000-0000-4000-8000-000000032032']::UUID[]) $$,
                 '23514', 'gate_pi_required', 'G3 needs an approved PI');
SELECT lives_ok($$ SELECT public.pass_gate(current_setting('test.p_g3')::UUID, 'PI ok', current_date, '00000000-0000-4000-8000-000000032013', ARRAY['00000000-0000-4000-8000-000000032031']::UUID[]) $$,
                'the project''s approved PO PI passes G3');

UPDATE api.project_task SET status = 'done' WHERE tenant_id = current_setting('test.client')::UUID;
SELECT public.pass_gate(current_setting('test.p_g4')::UUID, 'PSI ok');
UPDATE api.project_task SET status = 'done' WHERE tenant_id = current_setting('test.client')::UUID;

SELECT lives_ok($$ SELECT public.pass_gate(current_setting('test.p_g5')::UUID, 'delivered', current_date, '00000000-0000-4000-8000-000000032015', ARRAY['00000000-0000-4000-8000-000000032042']::UUID[]) $$,
                'the shipment''s delivery receipt is G5 evidence');
SELECT is((SELECT current_phase FROM api.project WHERE id = current_setting('test.pilot')::UUID), 'L1'::public.project_phase,
          'the project still advances as before');

-- The second project: served by the provider order only.
SELECT throws_ok($$ SELECT public.pass_gate(current_setting('test.g3_client')::UUID, 'G3', current_date, '00000000-0000-4000-8000-000000032018', '{}') $$,
                 '23514', 'gate_pi_required', 'a provider order counts for G3 only once its PI is approved');

RESET ROLE;
SELECT set_config('moesa.rules_bypass', '1', TRUE);
UPDATE public.purchase_order SET status = 'pi_approved' WHERE id = '00000000-0000-4000-8000-000000032051';
SELECT set_config('moesa.rules_bypass', '', TRUE);
SELECT private.impersonate(current_setting('test.owner')::UUID, current_setting('test.client')::UUID);

SELECT throws_ok($$ SELECT public.pass_gate(current_setting('test.g3_client')::UUID, 'G3', current_date, '00000000-0000-4000-8000-000000032018', ARRAY['00000000-0000-4000-8000-000000032052']::UUID[]) $$,
                 '23514', 'gate_evidence_invalid', 'a provider document cannot be client gate evidence');
SELECT lives_ok($$ SELECT public.pass_gate(current_setting('test.g3_client')::UUID, 'G3', current_date, '00000000-0000-4000-8000-000000032018', '{}') $$,
                'G3 of a client project passes on a provider order at pi_approved without citing the PI');

SELECT * FROM finish();

ROLLBACK;
