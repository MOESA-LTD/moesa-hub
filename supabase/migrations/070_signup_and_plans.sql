-- Onboarding and transfer (Plan 3), section 1: the platform setting that gates open self-signup
-- (decision 17) and the plan audience ("who it suits") shown by the plan step.
--
--   private.platform_setting      key/value platform switches; only the definers below read it.
--   public.platform_settings()    the settings, super admin only (42501 super_admin_required).
--   public.set_platform_setting   changes an existing key, super admin only (platform_setting_unknown).
--   public.open_signup_enabled()  the create-account Edge Function asks (service role only).
--   public.plan.audience          editable in the admin plan editor; save_plan carries it.

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

-- Plan audience.
ALTER TABLE public.plan
ADD COLUMN audience TEXT;

INSERT INTO public.field_class (resource_name, field, class)
VALUES ('public.plan', 'audience', 'open')
ON CONFLICT DO NOTHING;

SELECT private.enable_field_security ('plan');

-- 013's save_plan, now carrying audience. CREATE OR REPLACE keeps SECURITY DEFINER and the owner
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
        INSERT INTO public.plan (display_name, description, audience, price, currency, billing_period, trial_days, is_default, is_active, position)
        VALUES (
            plan_data ->> 'display_name',
            plan_data ->> 'description',
            plan_data ->> 'audience',
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
