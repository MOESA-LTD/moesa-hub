CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- A gate rolls back only through an incident (036): the pilot's G1 is passed, then a rollback
-- without an incident, with another tenant's incident and with a closed one are refused, and one
-- with an open incident of the project's tenant rolls it back and is remembered on the gate. What
-- it writes is rolled back.
BEGIN;

SELECT plan(10);

-- Fixture, built here as postgres (the seed is not on the new model yet): the client company
-- ...3601 (code THO, owner ...3611) with its project pilot ...3631, and another company ...3602
-- (owner ...3612) with an incident of its own.
INSERT INTO public.plan (display_name, is_active) VALUES ('Gate rollback test plan', TRUE);

INSERT INTO public.tenant (id, display_name, code) VALUES
   ('00000000-0000-4000-8000-000000003601', 'Thor Trading', 'THO'),
   ('00000000-0000-4000-8000-000000003602', 'Zed Trading', 'ZED');

INSERT INTO public.user (id, email) VALUES
   ('00000000-0000-4000-8000-000000003611', 'owner@rollback.test'),
   ('00000000-0000-4000-8000-000000003612', 'other@rollback.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003611', '00000000-0000-4000-8000-000000003601'),
   ('00000000-0000-4000-8000-000000003612', '00000000-0000-4000-8000-000000003602');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
   ('00000000-0000-4000-8000-000000003611', '00000000-0000-4000-8000-000000003601'),
   ('00000000-0000-4000-8000-000000003612', '00000000-0000-4000-8000-000000003602');

SELECT set_config('test.' || x.k, x.v, TRUE)
FROM (VALUES
    ('client', '00000000-0000-4000-8000-000000003601'),
    ('other', '00000000-0000-4000-8000-000000003602'),
    ('owner', '00000000-0000-4000-8000-000000003611'),
    ('other_owner', '00000000-0000-4000-8000-000000003612'),
    ('pilot', '00000000-0000-4000-8000-000000003631')
) AS x (k, v);

-- Another company's incident, made by its owner.
SELECT private.impersonate(current_setting('test.other_owner')::UUID, current_setting('test.other')::UUID);
INSERT INTO api.incident (id, tenant_id, family, severity, title, what_happened)
VALUES ('00000000-0000-4000-8000-000000036022', current_setting('test.other')::UUID, 'om', 's3', 'Zed brief', 'Another company''s incident.');
RESET ROLE;

SELECT private.impersonate(current_setting('test.owner')::UUID, current_setting('test.client')::UUID);
INSERT INTO api.project (id, tenant_id, display_name, type, path, packages)
VALUES (current_setting('test.pilot')::UUID, current_setting('test.client')::UUID, 'Mop pilot', 'npi', 'a_sourcing', ARRAY['A1']);

-- G1 of the pilot passed the real way (032 pattern).
INSERT INTO api.document (id, tenant_id, entity_type, entity_id, type, status, url)
VALUES ('00000000-0000-4000-8000-000000036011', current_setting('test.client')::UUID, 'project_gate',
        (SELECT id FROM api.project_gate WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1'), 'gate_approval', 'approved', 'https://example.test/G1.pdf');
UPDATE api.project_task SET status = 'done' WHERE project_id = current_setting('test.pilot')::UUID;
SELECT public.pass_gate((SELECT id FROM api.project_gate WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1'), 'brief ok', current_date, '00000000-0000-4000-8000-000000036011');
INSERT INTO api.incident (id, tenant_id, family, severity, title, what_happened)
VALUES ('00000000-0000-4000-8000-000000036021', current_setting('test.client')::UUID, 'om', 's3', 'Brief changed', 'The brief changed after G1.'),
       ('00000000-0000-4000-8000-000000036023', current_setting('test.client')::UUID, 'om', 's3', 'Old issue', 'Closed long ago.');
RESET ROLE;
SELECT set_config('moesa.rules_bypass', '1', TRUE);
UPDATE public.incident SET status = 'closed' WHERE id = '00000000-0000-4000-8000-000000036023';
SELECT set_config('moesa.rules_bypass', '', TRUE);
SELECT private.impersonate(current_setting('test.owner')::UUID, current_setting('test.client')::UUID);

SELECT throws_ok($$ SELECT public.rollback_gate((SELECT id FROM api.project_gate WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1'), 'brief changed') $$,
                 '23514', 'gate_rollback_incident_required', 'a rollback names its incident (K3)');
SELECT throws_ok($$ SELECT public.rollback_gate((SELECT id FROM api.project_gate WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1'), 'brief changed', '00000000-0000-4000-8000-000000036022') $$,
                 '23514', 'gate_incident_invalid', 'not another tenant''s incident');
SELECT throws_ok($$ SELECT public.rollback_gate((SELECT id FROM api.project_gate WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1'), 'brief changed', '00000000-0000-4000-8000-000000036023') $$,
                 '23514', 'gate_incident_invalid', 'not a closed incident');
SELECT lives_ok($$ SELECT public.rollback_gate((SELECT id FROM api.project_gate WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1'), 'brief changed', '00000000-0000-4000-8000-000000036021') $$,
                'an open incident of the project''s tenant rolls the gate back');
SELECT is((SELECT status || ':' || rolled_back_incident_id FROM api.project_gate WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1'),
          'rolled_back:00000000-0000-4000-8000-000000036021', 'the gate remembers the incident');
SELECT is((SELECT count(*)::INT FROM api.project_gate WHERE rolled_back_incident_id = '00000000-0000-4000-8000-000000036021'), 1,
          'the incident lists the gate it rolled back');

-- Passed again, G1 drops its last rollback: a direct rollback names its own incident.
SELECT public.pass_gate((SELECT id FROM api.project_gate WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1'), 'brief ok again', current_date, '00000000-0000-4000-8000-000000036011');
SELECT throws_ok($$ UPDATE api.project_gate SET status = 'rolled_back', rolled_back_reason = 'brief changed again'
                    WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1' $$,
                 '23514', 'gate_rollback_incident_required', 'a re-passed gate does not keep its old incident');
SELECT lives_ok($$ SELECT public.rollback_gate((SELECT id FROM api.project_gate WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1'), 'brief changed again', '00000000-0000-4000-8000-000000036021') $$,
                'naming an open incident rolls it back again');

-- A rolled-back gate keeps its rollback's incident and reason until it is passed again.
SELECT throws_ok($$ UPDATE api.project_gate SET rolled_back_incident_id = NULL
                    WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1' $$,
                 '23514', 'gate_rollback_immutable', 'a rolled-back gate''s incident is not cleared');
SELECT throws_ok($$ UPDATE api.project_gate SET rolled_back_reason = 'something else'
                    WHERE project_id = current_setting('test.pilot')::UUID AND code = 'G1' $$,
                 '23514', 'gate_rollback_immutable', 'nor its reason changed');

SELECT * FROM finish();

ROLLBACK;
