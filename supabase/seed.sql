-- enable explain
ALTER ROLE authenticator
SET
    pgrst.db_plan_enabled TO 'true';

-- reload the config
NOTIFY pgrst,
'reload config';

-- Reference data (permissions, audit config, owner role, plans) lives in the migrations; this file
-- only adds demo data: companies on each kind of subscription with their branches, roles and
-- members, and a provider with a client tenant it procures for.
--
-- Demo accounts (local only), all with the password Demo1234!, and what each one sees:
--   admin@moesa-panel.test    super admin: manages plans and subscriptions, no company
--   ayse@moesa-panel.test     owner of Atlas Danışmanlık (Pro, branch limit reached: 3/3): all of it
--   mehmet@moesa-panel.test   branch manager, Atlas Avcılar: that branch
--   zeynep@moesa-panel.test   staff, Atlas Kadıköy and Atlas Moda (two memberships): reads the
--                             branches, users and roles there
--   can@moesa-panel.test      auditor, Atlas Danışmanlık: the change history, reads the rest
--   ali@moesa-panel.test      owner of Nova Yazılım (Basic trial ending in 5 days)
--   elif@moesa-panel.test     staff, Nova Yazılım
--   deniz@moesa-panel.test    owner of Kuzey Holding (Enterprise, branches two levels deep)
--   burak@moesa-panel.test    branch manager, Kuzey Ankara and the branch under it
--   selin@moesa-panel.test    owner of Eski Ticaret (Pro, expired: read-only)
--   baris@moesa-panel.test    owner of MOESA LTD (Enterprise; the provider of the business demo)
--                             and of MOESA Trading GmbH; sees none of THO's own rows
--   akif@moesa-panel.test     management in MOESA LTD and MOESA Europe, and in THO (invited):
--                             everything in each, sensitive fields included
--   koordinator@moesa-panel.test  coordinator in MOESA LTD (settings, users, roles and the company
--                             read-only, no media deletes), and management in THO (invited)
--   thomas@moesa-panel.test   owner of THOMETZKI ONLINE HANDEL (THO): all of THO, nothing of MOESA LTD
--   portal@moesa-panel.test   viewer in THO: reads THO's products, projects, market cells, media and
--                             documents; of the sensitive fields only the sell price, contract and
--                             personal data; writes nothing; sees nothing of MOESA LTD
--
-- MOESA LTD and its branch MOESA Europe have the two Phase 1 roles (spec §7), built by
-- private.seed_ops_roles:
--   management   every permission of the business modules (ops_setting, document, supplier, client,
--                product, project, purchase_order, shipment, market_matrix, incident,
--                change_request, media, listing) and of branch, user, role and audit_log
--   coordinator  the same, but the settings, the users, the roles and the company and its branches
--                read-only, and no deleting media (spec M19: management only)
-- MOESA Trading GmbH, a second company of baris with the same roles, stays for the copy-tool demo.
--
-- THOMETZKI ONLINE HANDEL (THO, Germany, its own Pro subscription) is a client tenant of MOESA LTD,
-- which procures for it (provider_relationship, client code THO). Its roles come from
-- private.seed_client_roles: management (as above) and viewer. THO owns its warehouse, Amazon
-- account, brand, contact, three products on sale (THO-MOP40-2P with a signed spec sheet) and the
-- "Mop ailesi çok ülke pilotu" project, its gates all pending (it waits on G1). MOESA LTD owns the
-- five approved suppliers and the sourcing of THO's products (cost and supplier), each sourcing row
-- naming THO as its client.

-- Demo helpers, dropped at the end.

-- A confirmed account that signs in with Demo1234! (public.user follows through handle_new_user).
CREATE OR REPLACE FUNCTION private.seed_user (email TEXT, display_name TEXT, is_super_admin BOOLEAN DEFAULT FALSE) RETURNS UUID LANGUAGE plpgsql
SET
    search_path = '' AS $$
DECLARE
    id UUID := gen_random_uuid();
BEGIN
    -- GoTrue reads the token columns as strings: they must be '' rather than NULL.
    INSERT INTO auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, is_super_admin, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new, email_change,
        email_change_token_current, phone_change, phone_change_token, reauthentication_token
    ) VALUES (
        '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', seed_user.email,
        extensions.crypt('Demo1234!', extensions.gen_salt('bf')), NOW(),
        '{"provider": "email", "providers": ["email"]}', jsonb_build_object('display_name', seed_user.display_name),
        seed_user.is_super_admin, NOW(), NOW(),
        '', '', '', '', '', '', '', ''
    );
    INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    VALUES (
        id::TEXT, id, jsonb_build_object('sub', id::TEXT, 'email', seed_user.email, 'email_verified', TRUE),
        'email', NOW(), NOW(), NOW()
    );
    RETURN id;
END;
$$;

-- A tenant (a company without `parent_id`, else a branch) with its roles.
CREATE OR REPLACE FUNCTION private.seed_tenant (display_name TEXT, parent_id UUID DEFAULT NULL, email TEXT DEFAULT NULL) RETURNS UUID LANGUAGE plpgsql
SET
    search_path = '' AS $$
DECLARE
    id UUID;
BEGIN
    INSERT INTO public.tenant (display_name, parent_id, email)
    VALUES (seed_tenant.display_name, seed_tenant.parent_id, seed_tenant.email)
    RETURNING public.tenant.id INTO id;

    PERFORM private.seed_roles(id);
    RETURN id;
END;
$$;

-- The roles of a tenant: a manager (everything), staff (reading the branch, users and roles) and
-- an auditor (the change history, reading the rest).
CREATE OR REPLACE FUNCTION private.seed_roles (tenant_id UUID) RETURNS VOID LANGUAGE plpgsql
SET
    search_path = '' AS $$
BEGIN
    INSERT INTO public.role (display_name, tenant_id)
    SELECT name, seed_roles.tenant_id
    FROM unnest(ARRAY['Branch manager', 'Staff', 'Auditor']) AS name;

    INSERT INTO public.role_permission (role_id, permission_id)
    SELECT r.id, p.id
    FROM public.role r
    JOIN public.permission p ON CASE r.display_name
        WHEN 'Branch manager' THEN TRUE
        WHEN 'Staff' THEN p.group_name IN ('branch', 'user', 'role') AND p.command = 'select'
        ELSE p.group_name = 'audit_log' OR p.command = 'select'
    END
    WHERE r.tenant_id = seed_roles.tenant_id;

    -- Every field of the tables a role holds rights on (as the migration's backfill does).
    PERFORM private.grant_all_fields(r.id) FROM public.role r WHERE r.tenant_id = seed_roles.tenant_id;
END;
$$;

-- A business role of a tenant: management (every permission of the business and core modules) or
-- coordinator (the same, without changing the settings, the users, the roles or the company and its
-- branches, and without deleting media), with the field defaults of its profile.
CREATE OR REPLACE FUNCTION private.seed_business_role (tenant_id UUID, role_name TEXT) RETURNS VOID LANGUAGE plpgsql
SET
    search_path = '' AS $$
DECLARE
    role_id UUID;
BEGIN
    INSERT INTO public.role (display_name, tenant_id)
    VALUES (seed_business_role.role_name, seed_business_role.tenant_id)
    RETURNING id INTO role_id;

    INSERT INTO public.role_permission (role_id, permission_id)
    SELECT role_id, p.id
    FROM public.permission p
    WHERE p.group_name IN ('ops_setting', 'document', 'supplier', 'client', 'product', 'project',
                           'purchase_order', 'shipment', 'market_matrix', 'incident', 'change_request',
                           'media', 'listing', 'branch', 'user', 'role', 'audit_log')
      AND (seed_business_role.role_name = 'management'
           OR NOT (p.group_name = 'ops_setting' AND p.command = 'update'
                   OR p.group_name IN ('role', 'user') AND p.command <> 'select'
                   OR p.resource_name = 'public.tenant' AND p.command <> 'select'
                   OR p.resource_name = 'public.media' AND p.command = 'delete'));

    PERFORM private.apply_field_defaults(role_id, seed_business_role.role_name);
END;
$$;

-- The two Phase 1 roles of a provider (spec §7): management and coordinator.
CREATE OR REPLACE FUNCTION private.seed_ops_roles (tenant_id UUID) RETURNS VOID LANGUAGE plpgsql
SET
    search_path = '' AS $$
BEGIN
    PERFORM private.seed_business_role(seed_ops_roles.tenant_id, 'management');
    PERFORM private.seed_business_role(seed_ops_roles.tenant_id, 'coordinator');
END;
$$;

-- The roles of a client tenant: management, and viewer, which reads the tenant's products, projects,
-- market cells, media and documents, and of the sensitive fields only the sell price, contract and
-- personal data (written directly: the viewer profile of private.field_default comes later).
CREATE OR REPLACE FUNCTION private.seed_client_roles (tenant_id UUID) RETURNS VOID LANGUAGE plpgsql
SET
    search_path = '' AS $$
DECLARE
    viewer UUID;
BEGIN
    PERFORM private.seed_business_role(seed_client_roles.tenant_id, 'management');

    INSERT INTO public.role (display_name, tenant_id)
    VALUES ('viewer', seed_client_roles.tenant_id)
    RETURNING id INTO viewer;

    INSERT INTO public.role_permission (role_id, permission_id)
    SELECT viewer, p.id
    FROM public.permission p
    WHERE p.command = 'select' AND p.group_name IN ('product', 'project', 'market_matrix', 'media', 'document');

    -- As private.apply_field_defaults does for a profile other than management and coordinator: no
    -- field of public.user.
    INSERT INTO public.role_field_permission (role_id, resource_name, field, can_read, can_write)
    SELECT viewer, f.resource_name, f.field, TRUE, FALSE
    FROM public.field_class f
    WHERE f.class = 'sensitive'
      AND f.group_name IN ('sell_price', 'contract', 'personal_data')
      AND f.resource_name <> 'public.user';
END;
$$;

-- A member of a tenant, with one of its roles.
CREATE OR REPLACE FUNCTION private.seed_member (tenant_id UUID, user_id UUID, role_name TEXT) RETURNS VOID LANGUAGE plpgsql
SET
    search_path = '' AS $$
BEGIN
    INSERT INTO public.tenant_user (tenant_id, user_id) VALUES (seed_member.tenant_id, seed_member.user_id);
    INSERT INTO public.user_role (user_id, role_id)
    SELECT seed_member.user_id, r.id FROM public.role r
    WHERE r.tenant_id = seed_member.tenant_id AND r.display_name = seed_member.role_name;
END;
$$;

-- An owner of a company, who is also a member of it.
CREATE OR REPLACE FUNCTION private.seed_owner (tenant_id UUID, user_id UUID) RETURNS VOID LANGUAGE plpgsql
SET
    search_path = '' AS $$
BEGIN
    INSERT INTO public.tenant_owner (tenant_id, user_id) VALUES (seed_owner.tenant_id, seed_owner.user_id);
    INSERT INTO public.tenant_user (tenant_id, user_id) VALUES (seed_owner.tenant_id, seed_owner.user_id);
END;
$$;

-- The demo companies. Each starts on the default plan's trial (subscribe_new_company); the
-- subscriptions are set last, so the branches and members go in while the plan allows them.
DO $$
DECLARE
    admin_id UUID := private.seed_user('admin@moesa-panel.test', 'System Admin', TRUE);
    ayse UUID := private.seed_user('ayse@moesa-panel.test', 'Ayşe Yılmaz');
    mehmet UUID := private.seed_user('mehmet@moesa-panel.test', 'Mehmet Avcı');
    zeynep UUID := private.seed_user('zeynep@moesa-panel.test', 'Zeynep Kaya');
    can UUID := private.seed_user('can@moesa-panel.test', 'Can Demir');
    ali UUID := private.seed_user('ali@moesa-panel.test', 'Ali Şahin');
    elif UUID := private.seed_user('elif@moesa-panel.test', 'Elif Çelik');
    deniz UUID := private.seed_user('deniz@moesa-panel.test', 'Deniz Arslan');
    burak UUID := private.seed_user('burak@moesa-panel.test', 'Burak Doğan');
    selin UUID := private.seed_user('selin@moesa-panel.test', 'Selin Aydın');
    baris UUID := private.seed_user('baris@moesa-panel.test', 'Barış Ayçiçek');
    akif UUID := private.seed_user('akif@moesa-panel.test', 'Akif Ayçiçek');
    koordinator UUID := private.seed_user('koordinator@moesa-panel.test', 'Koordinatör');
    portal UUID := private.seed_user('portal@moesa-panel.test', 'Müşteri Portalı');
    thomas UUID := private.seed_user('thomas@moesa-panel.test', 'Thomas Thometzki');
    atlas UUID;
    kadikoy UUID;
    nova UUID;
    kuzey UUID;
    ankara UUID;
    eski UUID;
    moesa UUID;
    tho UUID;
    europe UUID;
    trading UUID;
BEGIN
    -- Atlas Danışmanlık: Pro, every branch the plan allows.
    atlas := private.seed_tenant('Atlas Danışmanlık', NULL, 'info@atlas.test');
    PERFORM private.seed_owner(atlas, ayse);
    PERFORM private.seed_member(atlas, can, 'Auditor');
    PERFORM private.seed_member(private.seed_tenant('Atlas Avcılar', atlas), mehmet, 'Branch manager');
    kadikoy := private.seed_tenant('Atlas Kadıköy', atlas);
    PERFORM private.seed_member(kadikoy, zeynep, 'Staff');
    PERFORM private.seed_member(private.seed_tenant('Atlas Moda', kadikoy), zeynep, 'Staff');

    -- Nova Yazılım: Basic, its trial ending soon.
    nova := private.seed_tenant('Nova Yazılım', NULL, 'info@nova.test');
    PERFORM private.seed_owner(nova, ali);
    PERFORM private.seed_member(nova, elif, 'Staff');

    -- Kuzey Holding: Enterprise, branches two levels deep.
    kuzey := private.seed_tenant('Kuzey Holding', NULL, 'info@kuzey.test');
    PERFORM private.seed_owner(kuzey, deniz);
    ankara := private.seed_tenant('Kuzey Ankara', kuzey);
    PERFORM private.seed_member(ankara, burak, 'Branch manager');
    PERFORM private.seed_tenant('Kuzey Çankaya', ankara);
    PERFORM private.seed_tenant('Kuzey İzmir', kuzey);

    -- Eski Ticaret: Pro, expired, so read-only.
    eski := private.seed_tenant('Eski Ticaret', NULL, 'info@eski.test');
    PERFORM private.seed_owner(eski, selin);

    -- MOESA LTD: Enterprise, with the Phase 1 roles; its business data follows below.
    moesa := private.seed_tenant('MOESA LTD', NULL, 'info@moesaltd.test');
    PERFORM private.seed_ops_roles(moesa);
    PERFORM private.seed_owner(moesa, baris);
    PERFORM private.seed_member(moesa, akif, 'management');
    PERFORM private.seed_member(moesa, koordinator, 'coordinator');

    -- THOMETZKI ONLINE HANDEL: a client tenant of MOESA LTD (the relationship follows below), Pro.
    -- akif and koordinator joined it by invitation, as management.
    tho := private.seed_tenant('THOMETZKI ONLINE HANDEL', NULL, 'info@thometzki.test');
    UPDATE public.tenant SET code = 'THO', country = 'Germany' WHERE id = tho;
    PERFORM private.seed_client_roles(tho);
    PERFORM private.seed_owner(tho, thomas);
    PERFORM private.seed_member(tho, portal, 'viewer');
    PERFORM private.seed_member(tho, akif, 'management');
    PERFORM private.seed_member(tho, koordinator, 'management');

    -- MOESA Europe (a branch of MOESA LTD) and MOESA Trading GmbH (a company of baris): the
    -- copy-tool demo.
    europe := private.seed_tenant('MOESA Europe', moesa);
    PERFORM private.seed_ops_roles(europe);
    PERFORM private.seed_member(europe, akif, 'management');
    trading := private.seed_tenant('MOESA Trading GmbH', NULL, 'info@moesatrading.test');
    PERFORM private.seed_ops_roles(trading);
    PERFORM private.seed_owner(trading, baris);

    UPDATE public.subscription s
    SET
        plan_id = p.id,
        is_trial = setting.is_trial,
        starts_at = NOW() + setting.starts,
        ends_at = NOW() + setting.ends,
        note = 'Demo',
        created_by = admin_id
    FROM (
        VALUES
            (atlas, 'Pro', FALSE, INTERVAL '-8 months', NULL::INTERVAL),
            (nova, 'Basic', TRUE, INTERVAL '-9 days', INTERVAL '5 days'),
            (kuzey, 'Enterprise', FALSE, INTERVAL '-2 months', INTERVAL '10 months'),
            (eski, 'Pro', FALSE, INTERVAL '-13 months', INTERVAL '-10 days'),
            (moesa, 'Enterprise', FALSE, INTERVAL '-1 month', INTERVAL '11 months'),
            (tho, 'Pro', FALSE, INTERVAL '-1 month', INTERVAL '11 months'),
            (trading, 'Enterprise', FALSE, INTERVAL '-1 month', INTERVAL '11 months')
    ) AS setting (tenant_id, plan_name, is_trial, starts, ends)
    JOIN public.plan p ON p.display_name = setting.plan_name
    WHERE s.tenant_id = setting.tenant_id;
END;
$$;

-- THO's own data, entered as its owner working in THO: the project code comes from public.next_code,
-- which needs the active tenant of a request.
DO $$
DECLARE
    tho UUID := (SELECT t.id FROM public.tenant t WHERE t.code = 'THO');
    thomas UUID := (SELECT u.id FROM public.user u WHERE u.email = 'thomas@moesa-panel.test');
    koordinator UUID := (SELECT u.id FROM public.user u WHERE u.email = 'koordinator@moesa-panel.test');
    mop UUID;
    pilot UUID;
    gtin TEXT;
BEGIN
    -- A typo in a GTIN fails the reset here, loudly.
    FOREACH gtin IN ARRAY ARRAY['4260696025800', '4260696025831', '4260696025848'] LOOP
        IF NOT private.gtin_valid(gtin) THEN
            RAISE EXCEPTION 'seed: invalid GTIN %', gtin;
        END IF;
    END LOOP;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', thomas, 'role', 'authenticated')::TEXT, TRUE);
    PERFORM set_config('request.headers', json_build_object('x-tenant-id', tho, 'x-tenant-ids', tho)::TEXT, TRUE);

    -- Its warehouse, Amazon account, brand and buyer.
    INSERT INTO public.warehouse (tenant_id, display_name, type, country, city, is_default)
    VALUES (tho, 'Rosbach', 'own', 'Germany', 'Rosbach', TRUE);

    INSERT INTO public.platform_account (tenant_id, platform_id, countries, access)
    VALUES (tho, 'amazon', ARRAY['DE', 'FR', 'IT', 'ES', 'NL'], 'authorized_user');

    INSERT INTO public.brand (tenant_id, name, registration_status)
    VALUES (tho, 'OKAEI', 'registered');

    INSERT INTO public.contact (tenant_id, name, role, email, can_approve)
    VALUES (tho, 'Thometzki Einkauf', 'Einkauf', 'einkauf@thometzki.test', TRUE);

    -- Three products on sale (their sourcing is MOESA LTD's, below).
    INSERT INTO public.product (tenant_id, sku, display_name, brand, gtin, status, compliance_status, pack_qty)
    VALUES (tho, 'THO-MOP40-2P', 'Pamuk mop bezi 40 cm, 2''li', 'OKAEI', '4260696025800', 'on_sale', 'partial', 2)
    RETURNING id INTO mop;

    INSERT INTO public.product (tenant_id, sku, display_name, brand, gtin, status, compliance_status)
    SELECT tho, item.sku, item.display_name, 'OKAEI', item.gtin, 'on_sale', item.compliance::public.compliance_status
    FROM (
        VALUES
            ('THO-TIPS-6-50', 'Aktif karbon filtre 6 mm, 50''li', '4260696025831', 'complete'),
            ('THO-CONES-100', 'Cones 100''lü', '4260696025848', 'partial')
    ) AS item (sku, display_name, gtin, compliance);

    -- The mop's spec sheet: signed, stamped, sent from the official e-mail and dated.
    INSERT INTO public.document (tenant_id, entity_type, entity_id, type, version, status, url, file_name,
                                 is_signed, is_stamped, sent_from_official_email, issued_on)
    VALUES (tho, 'product', mop, 'spec_sheet', 2, 'signed',
            'https://drive.google.com/example/spec-THO-MOP40-2P-v02', 'THO-MOP40-2P_SPEC_v02_20261015_imzali', TRUE, TRUE,
            TRUE, '2026-10-15');

    -- The mop family's pilot; its code and gates come from the triggers, every gate pending.
    INSERT INTO public.project (tenant_id, display_name, type, path, packages, target_live_on, coordinator_id)
    VALUES (tho, 'Mop ailesi çok ülke pilotu', 'npi', 'a_sourcing', ARRAY['A1', 'B', 'C'], '2027-02-15', koordinator)
    RETURNING id INTO pilot;

    INSERT INTO public.project_product (project_id, product_id, tenant_id) VALUES (pilot, mop, tho);

    PERFORM set_config('request.jwt.claims', '', TRUE);
    PERFORM set_config('request.headers', '', TRUE);
END;
$$;

-- MOESA LTD's business data, entered as its owner working in MOESA LTD: the relationship to THO, the
-- five suppliers and the sourcing of THO's products.
DO $$
DECLARE
    moesa UUID := (SELECT t.id FROM public.tenant t WHERE t.display_name = 'MOESA LTD');
    tho UUID := (SELECT t.id FROM public.tenant t WHERE t.code = 'THO');
    baris UUID := (SELECT u.id FROM public.user u WHERE u.email = 'baris@moesa-panel.test');
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', baris, 'role', 'authenticated')::TEXT, TRUE);
    PERFORM set_config('request.headers', json_build_object('x-tenant-id', moesa, 'x-tenant-ids', moesa)::TEXT, TRUE);

    -- MOESA LTD procures for THOMETZKI, under the contract terms THOMETZKI had as a customer.
    INSERT INTO public.provider_relationship (tenant_id, client_tenant_id, client_code, client_name, procurement_model,
                                              commercial_model, packages, contract_status, start_on, deposit_rate)
    VALUES (moesa, tho, 'THO', 'THOMETZKI ONLINE HANDEL', 'provider', 'trading_partner', ARRAY['A1', 'B', 'C', 'E'],
            'active', '2025-01-01', 30);

    -- The five suppliers.
    INSERT INTO public.supplier (tenant_id, code, display_name, country, default_incoterm, deposit_rate,
                                 damage_notice_hours, status)
    VALUES (moesa, 'TR1', 'Kutlu', 'Türkiye', 'EXW', 30, NULL, 'approved'),
           (moesa, 'TR2', 'TEKIS', 'Türkiye', 'EXW', 30, NULL, 'approved'),
           (moesa, 'CN1', 'BTE', 'China', 'FOB', 30, 48, 'approved'),
           (moesa, 'CN2', 'Cixi Fujing', 'China', 'FOB', 30, NULL, 'approved'),
           (moesa, 'ID1', 'PT Kertas Energi Mulia', 'Indonesia', 'FOB', 30, NULL, 'approved');

    -- The sourcing of THO's products: cost and supplier, each row naming THO as its client. baris
    -- reads none of THO's products (he was not invited), so these client links are written under the
    -- seed bypass (private.rules_bypassed), for these rows only.
    PERFORM set_config('moesa.rules_bypass', '1', TRUE);

    INSERT INTO public.sourcing (tenant_id, client_tenant_id, product_id, supplier_id, purchase_price, purchase_currency,
                                 purchase_incoterm, landed_cost_eur, target_price_eur)
    SELECT moesa, tho, p.id, s.id, 1.90, 'USD', 'FOB', 2.65, 12.99
    FROM public.product p
    JOIN public.supplier s ON s.tenant_id = moesa AND s.code = 'TR1'
    WHERE p.tenant_id = tho AND p.sku = 'THO-MOP40-2P';

    INSERT INTO public.sourcing (tenant_id, client_tenant_id, product_id, supplier_id)
    SELECT moesa, tho, p.id, s.id
    FROM (VALUES ('THO-TIPS-6-50', 'CN1'), ('THO-CONES-100', 'ID1')) AS item (sku, supplier_code)
    JOIN public.product p ON p.tenant_id = tho AND p.sku = item.sku
    JOIN public.supplier s ON s.tenant_id = moesa AND s.code = item.supplier_code;

    PERFORM set_config('moesa.rules_bypass', '', TRUE);
    PERFORM set_config('request.jwt.claims', '', TRUE);
    PERFORM set_config('request.headers', '', TRUE);
END;
$$;

DROP FUNCTION private.seed_user (TEXT, TEXT, BOOLEAN),
private.seed_tenant (TEXT, UUID, TEXT),
private.seed_roles (UUID),
private.seed_business_role (UUID, TEXT),
private.seed_ops_roles (UUID),
private.seed_client_roles (UUID),
private.seed_member (UUID, UUID, TEXT),
private.seed_owner (UUID, UUID);
