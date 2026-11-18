CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- The demo data of seed.sql: MOESA LTD (the provider) with its roles and suppliers; the THOMETZKI
-- client tenant (THO) it procures for, with three products, one with a signed spec sheet, and the
-- pilot project waiting on G1; the sourcing of those products in MOESA LTD. Reads the seed; what it
-- writes is rolled back.
BEGIN;

SELECT plan(34);

SELECT set_config('test.tenant_id', (SELECT t.id FROM public.tenant t WHERE t.display_name = 'MOESA LTD')::TEXT, TRUE);
SELECT set_config('test.tho', (SELECT t.id FROM public.tenant t WHERE t.code = 'THO')::TEXT, TRUE);

SELECT is(
    (SELECT p.display_name FROM public.subscription s JOIN public.plan p ON p.id = s.plan_id
     WHERE s.tenant_id = current_setting('test.tenant_id')::UUID),
    'Enterprise',
    'MOESA LTD is on the Enterprise plan'
);

SELECT is(
    (SELECT string_agg(u.email || ':' || coalesce(r.display_name, 'owner'), ',' ORDER BY u.email)
     FROM public.tenant_user tu
     JOIN public.user u ON u.id = tu.user_id
     -- The role in this tenant only: akif is management in MOESA Europe and THO too.
     LEFT JOIN (public.user_role ur JOIN public.role r ON r.id = ur.role_id)
         ON ur.user_id = tu.user_id AND r.tenant_id = tu.tenant_id
     WHERE tu.tenant_id = current_setting('test.tenant_id')::UUID),
    'akif@moesa-panel.test:management,baris@moesa-panel.test:owner,koordinator@moesa-panel.test:coordinator',
    'MOESA LTD has its owner, a management member and a coordinator'
);

-- THOMETZKI: a client tenant of its own, linked to MOESA LTD.
SELECT is((SELECT procurement_model::TEXT FROM public.provider_relationship r JOIN public.tenant t ON t.id = r.client_tenant_id WHERE t.display_name = 'THOMETZKI ONLINE HANDEL'), 'provider', 'THO is provider-procured');
SELECT is((SELECT count(*)::INT FROM public.product p JOIN public.tenant t ON t.id = p.tenant_id WHERE t.code = 'THO'), 3, 'THO products live in THO');
SELECT is((SELECT count(*)::INT FROM public.sourcing s JOIN public.tenant t ON t.id = s.tenant_id WHERE t.display_name = 'MOESA LTD' AND s.client_tenant_id IS NOT NULL), 3, 'their sourcing lives in the provider');
SELECT ok(EXISTS (SELECT 1 FROM public.tenant_owner o JOIN public.user u ON u.id = o.user_id JOIN public.tenant t ON t.id = o.tenant_id WHERE u.email = 'thomas@moesa-panel.test' AND t.code = 'THO'), 'thomas owns THO');
SELECT is_empty($$ SELECT 1 FROM public.role WHERE display_name = 'customer_viewer' $$, 'no customer_viewer role');

SELECT is(
    (SELECT r.tenant_id || ':' || r.client_code || ':' || r.commercial_model || ':' || r.packages::TEXT || ':'
            || r.contract_status || ':' || r.start_on || ':' || r.deposit_rate
     FROM public.provider_relationship r WHERE r.client_tenant_id = current_setting('test.tho')::UUID),
    current_setting('test.tenant_id') || ':THO:trading_partner:{A1,B,C,E}:active:2025-01-01:30.00',
    'MOESA LTD → THO carries the contract terms'
);

SELECT is(
    (SELECT p.display_name FROM public.subscription s JOIN public.plan p ON p.id = s.plan_id
     WHERE s.tenant_id = current_setting('test.tho')::UUID),
    'Pro',
    'THO has its own Pro subscription'
);

SELECT is(
    (SELECT string_agg(u.email || ':' || coalesce(r.display_name, 'owner'), ',' ORDER BY u.email)
     FROM public.tenant_user tu
     JOIN public.user u ON u.id = tu.user_id
     LEFT JOIN (public.user_role ur JOIN public.role r ON r.id = ur.role_id)
         ON ur.user_id = tu.user_id AND r.tenant_id = tu.tenant_id
     WHERE tu.tenant_id = current_setting('test.tho')::UUID),
    'akif@moesa-panel.test:management,koordinator@moesa-panel.test:management,portal@moesa-panel.test:viewer,thomas@moesa-panel.test:owner',
    'THO has its owner, two management members invited from MOESA LTD and a viewer'
);

-- THO's viewer: reads its own tenant's work, and only the sell price, contract and personal data of
-- the sensitive fields, writing none.
SELECT is(
    (SELECT string_agg(DISTINCT p.group_name || ':' || p.command, ',')
     FROM public.role r JOIN public.role_permission rp ON rp.role_id = r.id JOIN public.permission p ON p.id = rp.permission_id
     WHERE r.tenant_id = current_setting('test.tho')::UUID AND r.display_name = 'viewer'),
    'document:select,market_matrix:select,media:select,product:select,project:select',
    'the viewer only reads products, projects, market cells, media and documents'
);

SELECT is(
    (SELECT string_agg(DISTINCT f.group_name, ',') || ':' || bool_or(fp.can_write)
     FROM public.role r
     JOIN public.role_field_permission fp ON fp.role_id = r.id
     JOIN public.field_class f ON f.resource_name = fp.resource_name AND f.field = fp.field
     WHERE r.tenant_id = current_setting('test.tho')::UUID AND r.display_name = 'viewer' AND fp.can_read),
    'contract,personal_data,sell_price:false',
    'the viewer reads the sell price, contract and personal data fields and writes none'
);

-- Management in MOESA LTD: the suppliers and the sourcing of its clients' products.
SELECT private.impersonate(
    (SELECT u.id FROM public.user u WHERE u.email = 'akif@moesa-panel.test'),
    current_setting('test.tenant_id')::UUID
);

SELECT is(
    (SELECT string_agg(s.code, ',' ORDER BY s.code) FROM api.supplier s WHERE s.status = 'approved'),
    'CN1,CN2,ID1,TR1,TR2',
    'the five approved suppliers'
);

SELECT is(
    (SELECT string_agg(sup.code, ',' ORDER BY sup.code) FROM api.sourcing s
     JOIN api.supplier sup ON sup.id = s.supplier_id
     WHERE s.client_tenant_id = current_setting('test.tho')::UUID),
    'CN1,ID1,TR1',
    'management sees the sourcing of the three THOMETZKI products'
);

SELECT lives_ok(
    $$ UPDATE api.setting SET value = value WHERE key = 'management_gates' $$,
    'management may change the settings'
);

RESET ROLE;

-- Management in THO (akif joined it by invitation): its products and project.
SELECT private.impersonate(
    (SELECT u.id FROM public.user u WHERE u.email = 'akif@moesa-panel.test'),
    current_setting('test.tho')::UUID
);

SELECT is(
    (SELECT string_agg(e.sku || ':' || e.has_signed_spec, ',' ORDER BY e.sku) FROM api.product_evidence e),
    'THO-CONES-100:false,THO-MOP40-2P:true,THO-TIPS-6-50:false',
    'only THO-MOP40-2P has a signed spec sheet'
);

SELECT is(
    (SELECT string_agg(d.gate_code::TEXT, ',') FROM api.dashboard_gate_pending d
     JOIN api.project p ON p.id = d.project_id
     WHERE p.display_name = 'Mop ailesi çok ülke pilotu'),
    'G1',
    'the pilot project waits on G1 on the dashboard'
);

SELECT is(
    (SELECT d.active_sku_count || ':' || d.signed_spec_count
     FROM api.dashboard_product_evidence d WHERE d.tenant_id = current_setting('test.tho')::UUID),
    '3:1',
    'the dashboard shows THOMETZKI with 3 active SKUs, 1 with a signed spec sheet'
);

RESET ROLE;

-- Media (M19): management deletes; the coordinator uploads but does not delete.
SELECT ok(
    cardinality(private.tenants_permitting(
        (SELECT u.id FROM public.user u WHERE u.email = 'akif@moesa-panel.test'),
        ARRAY[current_setting('test.tenant_id')::UUID], 'public.media', 'delete')) = 1,
    'management may delete media'
);

SELECT ok(
    cardinality(private.tenants_permitting(
        (SELECT u.id FROM public.user u WHERE u.email = 'koordinator@moesa-panel.test'),
        ARRAY[current_setting('test.tenant_id')::UUID], 'public.media', 'delete')) = 0
    AND cardinality(private.tenants_permitting(
        (SELECT u.id FROM public.user u WHERE u.email = 'koordinator@moesa-panel.test'),
        ARRAY[current_setting('test.tenant_id')::UUID], 'public.media', 'insert')) = 1,
    'a coordinator uploads but does not delete media'
);

-- Purchase orders: the coordinator creates them.
SELECT ok(cardinality(private.tenants_permitting(
    (SELECT id FROM public.user WHERE email = 'koordinator@moesa-panel.test'),
    ARRAY[(SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD')], 'public.purchase_order', 'insert')) = 1,
    'the coordinator creates purchase orders');

-- Shipments: the coordinator creates them.
SELECT ok(cardinality(private.tenants_permitting(
    (SELECT id FROM public.user WHERE email = 'koordinator@moesa-panel.test'),
    ARRAY[(SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD')], 'public.shipment', 'insert')) = 1,
    'the coordinator creates shipments');

-- Market cells: the coordinator opens them.
SELECT ok(cardinality(private.tenants_permitting((SELECT id FROM public.user WHERE email = 'koordinator@moesa-panel.test'), ARRAY[(SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD')], 'public.market_cell', 'insert')) = 1, 'the coordinator opens market cells');
SELECT ok(cardinality(private.tenants_permitting((SELECT id FROM public.user WHERE email = 'koordinator@moesa-panel.test'), ARRAY[(SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD')], 'public.incident', 'insert')) = 1, 'the coordinator records incidents');
SELECT ok(cardinality(private.tenants_permitting((SELECT id FROM public.user WHERE email = 'koordinator@moesa-panel.test'), ARRAY[(SELECT id FROM public.tenant WHERE display_name = 'MOESA LTD')], 'public.change_request', 'insert')) = 1, 'the coordinator opens change requests');

-- Coordinator: the business modules, the settings read-only.
SELECT private.impersonate(
    (SELECT u.id FROM public.user u WHERE u.email = 'koordinator@moesa-panel.test'),
    current_setting('test.tenant_id')::UUID
);

SELECT cmp_ok(
    (SELECT count(*)::INT FROM api.setting s WHERE s.tenant_id = current_setting('test.tenant_id')::UUID),
    '>', 0,
    'the coordinator reads the settings'
);

SELECT throws_ok(
    $$ UPDATE api.setting SET value = value WHERE key = 'management_gates' $$,
    '42501',
    NULL,
    'the coordinator cannot change the settings'
);

-- Branch management is not the coordinator's: the company's details stay read-only, and a branch
-- cannot be opened by a direct insert either (branches are opened by public.create_branch, owners only).
SELECT throws_ok(
    $$ UPDATE api.tenant SET display_name = display_name WHERE id = current_setting('test.tenant_id')::UUID $$,
    '42501',
    NULL,
    'the coordinator cannot change the company or its branches'
);

SELECT throws_ok(
    format('INSERT INTO public.tenant (display_name, parent_id) VALUES (%L, %L)', 'X', current_setting('test.tenant_id')),
    '42501',
    NULL,
    'the coordinator cannot open a branch'
);

RESET ROLE;

-- The coordinator is a management member of THO, where the pilot project lives.
SELECT private.impersonate(
    (SELECT u.id FROM public.user u WHERE u.email = 'koordinator@moesa-panel.test'),
    current_setting('test.tho')::UUID
);

SELECT lives_ok(
    $$ UPDATE api.project SET notes = 'Koordinatör notu' WHERE display_name = 'Mop ailesi çok ülke pilotu' $$,
    'the coordinator writes THO''s projects'
);

SELECT is(
    (SELECT count(*)::INT FROM api.project p WHERE p.notes = 'Koordinatör notu'),
    1,
    'the coordinator''s change is there'
);

RESET ROLE;

-- THO's viewer: reads THO's products, nothing of MOESA LTD, and changes nothing.
SELECT private.impersonate(
    (SELECT u.id FROM public.user u WHERE u.email = 'portal@moesa-panel.test'),
    current_setting('test.tho')::UUID
);

SELECT is((SELECT count(*)::INT FROM api.product), 3, 'the viewer reads THO''s three products');

SELECT is_empty($$ SELECT 1 FROM api.sourcing $$, 'the viewer reads none of the provider''s sourcing');

SELECT throws_ok(
    $$ UPDATE api.product SET display_name = display_name $$,
    '42501',
    NULL,
    'the viewer cannot change a product'
);

SELECT * FROM finish();

ROLLBACK;
