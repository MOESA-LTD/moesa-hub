-- Onboarding and transfer (Plan 3), section 1: the platform setting that gates open self-signup
-- (decision 17) and the plan audience ("who it suits") shown by the plan step.
--
--   private.platform_setting      key/value platform switches; only the definers below read it.
--   public.platform_settings()    the settings, super admin only (42501 super_admin_required).
--   public.set_platform_setting   changes an existing key, super admin only (platform_setting_unknown).
--   public.open_signup_enabled()  the create-account Edge Function asks (service role only).
--   public.plan.audience          editable in the admin plan editor; save_plan carries it.
--   public.tenant email           unique whatever its case (cleanup concern 1): 003's exact key
--                                 tenant_email_key gives way to the unique index
--                                 tenant_email_lower_key on lower(email); NULLs may repeat, as
--                                 before. Its violation is still company_email_exists to the
--                                 callers (create-account, acceptance, the app), by the new name.
--   public.plan.target            whom the plan is offered to (decision 21): client, provider or
--                                 all (the default). Invitations and self-signup offer and accept
--                                 only active plans for client or all (plan_not_for_clients);
--                                 audience stays the description shown with it. save_plan carries
--                                 it and keeps the stored one when the payload leaves it out.

CREATE TABLE private.platform_setting (
    key TEXT PRIMARY KEY,
    value JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID
);

ALTER TABLE private.platform_setting OWNER TO postgres;

ALTER TABLE private.platform_setting ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE private.platform_setting FROM PUBLIC, anon, authenticated, service_role, api_owner;

INSERT INTO private.platform_setting (key, value) VALUES ('open_signup', 'false'::JSONB);

CREATE OR REPLACE FUNCTION public.platform_settings () RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER STABLE
SET
    search_path = '' AS $$
BEGIN
    IF NOT private.check_super_admin() THEN
        RAISE EXCEPTION 'super_admin_required' USING ERRCODE = '42501';
    END IF;
    RETURN coalesce((SELECT jsonb_object_agg(s.key, s.value) FROM private.platform_setting s), '{}'::JSONB);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_platform_setting (key TEXT, value JSONB) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET
    search_path = '' AS $$
BEGIN
    IF NOT private.check_super_admin() THEN
        RAISE EXCEPTION 'super_admin_required' USING ERRCODE = '42501';
    END IF;
    IF set_platform_setting.value IS NULL THEN
        RAISE EXCEPTION 'platform_setting_invalid';
    END IF;
    UPDATE private.platform_setting s
    SET value = set_platform_setting.value, updated_at = now(), updated_by = auth.uid()
    WHERE s.key = set_platform_setting.key;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'platform_setting_unknown';
    END IF;
    RETURN public.platform_settings();
END;
$$;

CREATE OR REPLACE FUNCTION public.open_signup_enabled () RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE
SET
    search_path = '' AS $$
    SELECT coalesce((SELECT s.value = 'true'::JSONB FROM private.platform_setting s WHERE s.key = 'open_signup'), FALSE)
$$;

REVOKE ALL ON FUNCTION public.platform_settings () FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.set_platform_setting (TEXT, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.open_signup_enabled () FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.platform_settings () TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_platform_setting (TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.open_signup_enabled () TO service_role;

-- Cleanup concern 1: a case variant of a registered company e-mail is the same address.
ALTER TABLE public.tenant DROP CONSTRAINT tenant_email_key;

CREATE UNIQUE INDEX tenant_email_lower_key ON public.tenant (lower(email));

-- Plan audience, and the plan's target (decision 21).
CREATE TYPE public.plan_target AS ENUM ('client', 'provider', 'all');

ALTER TABLE public.plan
ADD COLUMN audience TEXT,
ADD COLUMN target public.plan_target NOT NULL DEFAULT 'all';

INSERT INTO public.field_class (resource_name, field, class)
VALUES ('public.plan', 'audience', 'open'), ('public.plan', 'target', 'open')
ON CONFLICT DO NOTHING;

SELECT private.enable_field_security ('plan');

-- 013's save_plan, now carrying audience and target (decision 21). CREATE OR REPLACE keeps SECURITY DEFINER and the owner
-- api_owner (058); both are restated below.
CREATE OR REPLACE FUNCTION public.save_plan (plan_data JSONB, module_ids TEXT[] DEFAULT '{}', limits JSONB DEFAULT '{}') RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    saved_id UUID := (plan_data ->> 'id')::UUID;
    make_default BOOLEAN := coalesce((plan_data ->> 'is_default')::BOOLEAN, FALSE);
    make_active BOOLEAN := coalesce((plan_data ->> 'is_active')::BOOLEAN, TRUE);
BEGIN
    IF make_default AND NOT make_active THEN
        RAISE SQLSTATE 'PGRST' USING
            MESSAGE = json_build_object('code', 'P0001', 'message', 'plan_default_inactive')::TEXT,
            DETAIL = json_build_object('status', 422, 'headers', json_build_object())::TEXT;
    END IF;

    IF NOT make_default AND saved_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.plan p WHERE p.id = saved_id AND p.is_default) THEN
        RAISE SQLSTATE 'PGRST' USING
            MESSAGE = json_build_object('code', 'P0001', 'message', 'plan_default_required')::TEXT,
            DETAIL = json_build_object('status', 422, 'headers', json_build_object())::TEXT;
    END IF;

    IF make_default THEN
        UPDATE public.plan p SET is_default = FALSE WHERE p.is_default AND p.id IS DISTINCT FROM saved_id;
    END IF;

    IF saved_id IS NULL THEN
        INSERT INTO public.plan (display_name, description, audience, target, price, currency, billing_period, trial_days, is_default, is_active, position)
        VALUES (
            plan_data ->> 'display_name',
            plan_data ->> 'description',
            plan_data ->> 'audience',
            coalesce((plan_data ->> 'target')::public.plan_target, 'all'),
            (plan_data ->> 'price')::NUMERIC,
            plan_data ->> 'currency',
            plan_data ->> 'billing_period',
            coalesce((plan_data ->> 'trial_days')::INT, 0),
            make_default,
            make_active,
            coalesce((plan_data ->> 'position')::INT, 0)
        )
        RETURNING id INTO saved_id;
    ELSE
        UPDATE public.plan p SET
            display_name = plan_data ->> 'display_name',
            description = plan_data ->> 'description',
            audience = plan_data ->> 'audience',
            target = coalesce((plan_data ->> 'target')::public.plan_target, p.target),
            price = (plan_data ->> 'price')::NUMERIC,
            currency = plan_data ->> 'currency',
            billing_period = plan_data ->> 'billing_period',
            trial_days = coalesce((plan_data ->> 'trial_days')::INT, 0),
            is_default = make_default,
            is_active = make_active,
            position = coalesce((plan_data ->> 'position')::INT, 0)
        WHERE p.id = saved_id;

        IF NOT FOUND THEN
            RAISE SQLSTATE 'PGRST' USING
                MESSAGE = json_build_object('code', 'P0002', 'message', 'plan_not_found')::TEXT,
                DETAIL = json_build_object('status', 404, 'headers', json_build_object())::TEXT;
        END IF;
    END IF;

    DELETE FROM public.plan_module pm WHERE pm.plan_id = saved_id AND NOT (pm.module_id = ANY (module_ids));
    INSERT INTO public.plan_module (plan_id, module_id)
    SELECT saved_id, item.id FROM unnest(module_ids) AS item (id)
    ON CONFLICT DO NOTHING;

    DELETE FROM public.plan_limit pl
    WHERE pl.plan_id = saved_id AND (limits -> pl.limit_key IS NULL OR jsonb_typeof(limits -> pl.limit_key) = 'null');
    INSERT INTO public.plan_limit (plan_id, limit_key, value)
    SELECT saved_id, item.key, item.value::INT
    FROM jsonb_each_text(limits) AS item
    WHERE item.value IS NOT NULL
    ON CONFLICT (plan_id, limit_key) DO UPDATE SET value = EXCLUDED.value;

    RETURN saved_id;
END;
$$;

REVOKE ALL ON FUNCTION public.save_plan (JSONB, TEXT[], JSONB) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.save_plan (JSONB, TEXT[], JSONB) TO authenticated, service_role;

-- Section 2: one company-creation path, shared by self-signup (register_tenant) and the provider
-- invitation's acceptance (Plan 3 Task 4), with the standard roles (spec §7, preflight F8).
--
--   private.create_standard_role(tenant, name)    one standard role with its permissions and the
--                                                 field defaults of its profile; seed.sql builds its
--                                                 demo roles with it.
--   private.create_standard_roles(tenant)         management, coordinator and viewer.
--   private.create_company(owner, company, plan)  the company from an allowlisted payload
--                                                 (company_payload_invalid), its owner and member,
--                                                 the standard roles and the subscription
--                                                 (plan_inactive; plan_not_for_clients, decision
--                                                 21: a chosen plan targets client or all). Not
--                                                 executable by any API role.
--   public.register_tenant                        keeps its signature and delegates (restates 009).

-- The viewer profile: of the sensitive fields only the sell price, contract and personal data, read
-- only (apply_field_defaults leaves public.user out for any profile but management and coordinator).
INSERT INTO private.field_default (profile, group_name, can_read, can_write)
VALUES
   ('viewer', 'sell_price', TRUE, FALSE),
   ('viewer', 'contract', TRUE, FALSE),
   ('viewer', 'personal_data', TRUE, FALSE)
ON CONFLICT DO NOTHING;

-- management: every permission of every module, core and optional (F8). coordinator: the same,
-- without changing the settings, the users, the roles or the company and its branches, and without
-- deleting media (spec M19). viewer: reads products, projects, purchase orders, shipments, market
-- cells, media, documents and the provider relationship, and writes nothing. INVOKER: its callers,
-- create_company (a definer) and the seed, run as the table owner, where the S7 trigger on
-- role_field_permission lets apply_field_defaults through (field_guard_bypassed: the seed's session
-- user, or the service role's request).
CREATE OR REPLACE FUNCTION private.create_standard_role (p_tenant UUID, p_role TEXT) RETURNS UUID LANGUAGE plpgsql
SET
   search_path = '' AS $$
DECLARE
    role_id UUID;
BEGIN
    IF p_role NOT IN ('management', 'coordinator', 'viewer') THEN
        RAISE EXCEPTION 'standard_role_unknown';
    END IF;

    INSERT INTO public.role (display_name, tenant_id)
    VALUES (p_role, p_tenant)
    RETURNING id INTO role_id;

    INSERT INTO public.role_permission (role_id, permission_id)
    SELECT role_id, p.id
    FROM public.permission p
    WHERE p.group_name IN (SELECT m.id FROM public.module m)
      AND CASE p_role
              WHEN 'management' THEN TRUE
              WHEN 'coordinator' THEN NOT (p.group_name = 'ops_setting' AND p.command = 'update'
                                           OR p.group_name IN ('role', 'user') AND p.command <> 'select'
                                           OR p.resource_name = 'public.tenant' AND p.command <> 'select'
                                           OR p.resource_name = 'public.media' AND p.command = 'delete')
              ELSE p.command = 'select'
                   AND (p.group_name IN ('product', 'project', 'purchase_order', 'shipment', 'market_matrix',
                                         'media', 'document')
                        OR p.resource_name = 'public.provider_relationship')
          END;

    PERFORM private.apply_field_defaults(role_id, p_role);
    RETURN role_id;
END;
$$;

CREATE OR REPLACE FUNCTION private.create_standard_roles (p_tenant UUID) RETURNS VOID LANGUAGE plpgsql
SET
   search_path = '' AS $$
BEGIN
    PERFORM private.create_standard_role(p_tenant, 'management');
    PERFORM private.create_standard_role(p_tenant, 'coordinator');
    PERFORM private.create_standard_role(p_tenant, 'viewer');
END;
$$;

-- The subscription comes from private.subscribe_new_company (the default plan); a chosen plan
-- replaces it, with that plan's trial computed as the default subscription does.
CREATE OR REPLACE FUNCTION private.create_company (p_owner UUID, p_company JSONB, p_plan_id UUID DEFAULT NULL) RETURNS public.tenant LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    created public.tenant;
    chosen public.plan;
BEGIN
    IF p_company IS NULL OR jsonb_typeof(p_company) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_company) AS k (key)
                  WHERE k.key NOT IN ('display_name', 'legal_name', 'email', 'phone', 'website', 'country', 'city',
                                      'district', 'address', 'tax_office', 'tax_number')) THEN
        RAISE EXCEPTION 'company_payload_invalid';
    END IF;

    IF p_plan_id IS NOT NULL THEN
        SELECT * INTO chosen FROM public.plan p WHERE p.id = p_plan_id;
        IF NOT FOUND OR NOT chosen.is_active THEN
            RAISE EXCEPTION 'plan_inactive';
        END IF;
        -- Decision 21: both callers (self-signup, invitation acceptance) make a client company.
        IF chosen.target NOT IN ('client', 'all') THEN
            RAISE EXCEPTION 'plan_not_for_clients';
        END IF;
    END IF;

    INSERT INTO public.tenant (display_name, legal_name, email, phone, website, country, city, district, address,
                               tax_office, tax_number)
    VALUES (
        p_company ->> 'display_name',
        NULLIF(p_company ->> 'legal_name', ''),
        NULLIF(p_company ->> 'email', ''),
        NULLIF(p_company ->> 'phone', ''),
        NULLIF(p_company ->> 'website', ''),
        NULLIF(p_company ->> 'country', ''),
        NULLIF(p_company ->> 'city', ''),
        NULLIF(p_company ->> 'district', ''),
        NULLIF(p_company ->> 'address', ''),
        NULLIF(p_company ->> 'tax_office', ''),
        NULLIF(p_company ->> 'tax_number', '')
    )
    RETURNING * INTO created;

    INSERT INTO public.tenant_owner (tenant_id, user_id) VALUES (created.id, p_owner);
    INSERT INTO public.tenant_user (tenant_id, user_id) VALUES (created.id, p_owner);

    PERFORM private.create_standard_roles(created.id);

    IF p_plan_id IS NOT NULL THEN
        UPDATE public.subscription s
        SET plan_id = chosen.id,
            is_trial = chosen.trial_days > 0,
            ends_at = CASE WHEN chosen.trial_days > 0 THEN now() + make_interval(days => chosen.trial_days) END
        WHERE s.tenant_id = created.id;
    END IF;

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION private.create_standard_role (UUID, TEXT) FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION private.create_standard_roles (UUID) FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION private.create_company (UUID, JSONB, UUID) FROM PUBLIC, anon, authenticated, service_role;

-- 009's register_tenant, now delegating. SECURITY DEFINER (was INVOKER): the service role has no
-- USAGE on schema private, so the body reaches create_company as its owner. Still service role
-- only, so the 064 allowlist (definers executable by authenticated) does not list it.
CREATE OR REPLACE FUNCTION public.register_tenant (owner_id UUID, company JSONB) RETURNS public.tenant LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    RETURN private.create_company(register_tenant.owner_id, register_tenant.company, NULL);
END;
$$;

REVOKE ALL ON FUNCTION public.register_tenant (UUID, JSONB) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.register_tenant (UUID, JSONB) TO service_role;

-- Section 3: verify-first self-signup (Task 11, task-5-review I1). An open sign-up no longer
-- creates a confirmed account with the caller's password: create-account invites the address
-- (GoTrue mails a link; no password exists), keeps the company it asked for in
-- private.pending_signup and creates no tenant. Only once the inbox is proven (the link was
-- followed, email_confirmed_at) does create-account/complete create the company through
-- complete_signup. So nobody can pre-register someone else's address with a password they know.
--
--   private.pending_signup                       the company (and plan) a sign-up asked for, one row
--                                                per account, removed with the account (cascade), on
--                                                completion and on a provider invitation's acceptance
--                                                (071). Server side only: no API role reaches it and
--                                                nothing of it is put into the account's token.
--   public.save_pending_signup(user, company, plan)  writes it (create-account).
--   public.pending_signup(user)                  reads it: {company, plan_id, created_at} or NULL.
--   public.complete_signup(user, company, plan)  the company of a proven account: refused while
--                                                signup is closed (signup_closed, also for a signup
--                                                started while it was open), for an unproven or
--                                                unknown account (signup_unconfirmed), once the
--                                                account owns a company (signup_completed) and
--                                                without a pending sign-up (signup_not_pending).
--                                                `company` is what the owner confirmed or edited on
--                                                the completion page (the pending row is only its
--                                                default); create_company checks its allowlist. The
--                                                pending row goes in the same transaction.
--                                                Serialised per user.
--   public.release_abandoned_signup(user)        deletes the account if it is a squat (M4): not
--                                                confirmed, created over a day ago (auth.users, so a
--                                                repeated sign-up cannot keep it young), owning no
--                                                company, member of none, with a pending sign-up. One
--                                                statement: the conditions are checked under the
--                                                row's lock, so an account confirmed meanwhile is
--                                                kept. Returns whether it was deleted (its identities
--                                                and pending sign-up go with it, cascade). The staff
--                                                and provider invitations then proceed as for a new
--                                                address.
--   public.signup_throttle(email, ip)            five sign-ups an hour per address and thirty per
--                                                client address; only a call both allow counts toward
--                                                two hundred in all (so one caller refused by its own
--                                                limits cannot spend everyone's budget). The endpoint
--                                                can neither mail-bomb an inbox nor drain the
--                                                project's mail quota. The counter is 071's
--                                                private.invitation_throttle (resolved when called;
--                                                the migrations are applied together).
-- All are granted to the service role alone (not in the 064 allowlist).
CREATE TABLE private.pending_signup (
    user_id UUID PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
    company JSONB NOT NULL,
    plan_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE private.pending_signup OWNER TO postgres;

ALTER TABLE private.pending_signup ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE private.pending_signup FROM PUBLIC, anon, authenticated, service_role, api_owner;

-- A new request replaces the company and plan of the earlier one; the row keeps its first date.
CREATE OR REPLACE FUNCTION public.save_pending_signup (p_user UUID, p_company JSONB, p_plan_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF p_user IS NULL OR p_company IS NULL OR jsonb_typeof(p_company) <> 'object' THEN
        RAISE EXCEPTION 'signup_payload_invalid';
    END IF;
    INSERT INTO private.pending_signup AS p (user_id, company, plan_id)
    VALUES (p_user, p_company, p_plan_id)
    ON CONFLICT (user_id) DO UPDATE SET company = EXCLUDED.company, plan_id = EXCLUDED.plan_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.pending_signup (p_user UUID) RETURNS JSONB LANGUAGE sql SECURITY DEFINER STABLE
SET
   search_path = '' AS $$
    SELECT jsonb_build_object('company', p.company, 'plan_id', p.plan_id, 'created_at', p.created_at)
    FROM private.pending_signup p
    WHERE p.user_id = p_user
$$;

CREATE OR REPLACE FUNCTION public.complete_signup (p_user UUID, p_company JSONB, p_plan_id UUID) RETURNS public.tenant LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF NOT public.open_signup_enabled() THEN
        RAISE EXCEPTION 'signup_closed';
    END IF;

    IF p_user IS NULL
       OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user AND u.email_confirmed_at IS NOT NULL) THEN
        RAISE EXCEPTION 'signup_unconfirmed';
    END IF;

    -- Two completions of one account at once: the second waits here, then finds the company.
    PERFORM pg_advisory_xact_lock(hashtextextended('complete_signup:' || p_user::TEXT, 0));
    IF EXISTS (SELECT 1 FROM public.tenant_owner o WHERE o.user_id = p_user) THEN
        RAISE EXCEPTION 'signup_completed';
    END IF;

    DELETE FROM private.pending_signup p WHERE p.user_id = p_user;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'signup_not_pending';
    END IF;

    RETURN private.create_company(p_user, p_company, p_plan_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.release_abandoned_signup (p_user UUID) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    DELETE FROM auth.users u
    WHERE u.id = p_user
      AND u.email_confirmed_at IS NULL
      AND u.created_at < now() - INTERVAL '24 hours'
      AND EXISTS (SELECT 1 FROM private.pending_signup p WHERE p.user_id = u.id)
      AND NOT EXISTS (SELECT 1 FROM public.tenant_owner o WHERE o.user_id = u.id)
      AND NOT EXISTS (SELECT 1 FROM public.tenant_user tu WHERE tu.user_id = u.id);
    RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.signup_throttle (p_email TEXT, p_ip TEXT) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    by_email BOOLEAN := private.invitation_throttle('signup:email:' || lower(trim(coalesce(p_email, ''))), 5, INTERVAL '1 hour');
    by_ip BOOLEAN := private.invitation_throttle('signup:ip:' || coalesce(nullif(trim(p_ip), ''), 'unknown'), 30, INTERVAL '1 hour');
BEGIN
    -- Refused by its own limits: it never reaches the global budget.
    IF NOT (by_email AND by_ip) THEN
        RETURN FALSE;
    END IF;
    RETURN private.invitation_throttle('signup:all', 200, INTERVAL '1 hour');
END;
$$;

REVOKE ALL ON FUNCTION public.save_pending_signup (UUID, JSONB, UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.pending_signup (UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.complete_signup (UUID, JSONB, UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.release_abandoned_signup (UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.signup_throttle (TEXT, TEXT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.save_pending_signup (UUID, JSONB, UUID) TO service_role;

GRANT EXECUTE ON FUNCTION public.pending_signup (UUID) TO service_role;

GRANT EXECUTE ON FUNCTION public.complete_signup (UUID, JSONB, UUID) TO service_role;

GRANT EXECUTE ON FUNCTION public.release_abandoned_signup (UUID) TO service_role;

GRANT EXECUTE ON FUNCTION public.signup_throttle (TEXT, TEXT) TO service_role;
