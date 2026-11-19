-- Onboarding and transfer (Plan 3), section 1: the provider invitation (decision 16). The provider
-- invites a customer by e-mail with the terms of the relationship to come and the staff who will work
-- in the customer's tenant; the customer accepts through a link carrying a one-time token (section 2).
--
--   public.provider_invitation        the invitation, in the provider's tenant. Read-only through
--                                     api (F3): created and resent by the service role (the
--                                     provider-invitation Edge Function), revoked by an RPC.
--   public.provider_invitation_staff  the provider staff the customer's tenant will get, with a role.
--   private.provider_invitation_token the token's SHA-256 hash, one per invitation. No API role reads
--                                     it, the owner included (F3): the token is returned once, to the
--                                     service-role caller, and never stored or audited in plain text.
--   private.provider_invitation_issue each token issued (creation or resend): the cap counts them,
--                                     50 per tenant per 24 hours (F21).
--
--   public.create_provider_invitation(tenant, actor, invitation, staff) → (id, token)   service role
--   public.rotate_provider_invitation_token(invitation, actor) → token                  service role
--   public.revoke_provider_invitation(invitation_id)                                    authenticated
--
-- Refusals: invitation_forbidden (42501: the actor lacks the right, or the invitation is unknown),
-- invitation_payload_invalid and invitation_staff_invalid (23514), client_code_taken and
-- invitation_pending_exists (23505), invitation_throttled and invitation_invalid (P0001: not pending).
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TYPE public.invitation_status AS ENUM('pending', 'accepted', 'revoked');

CREATE TABLE public.provider_invitation (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   -- The provider.
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   email TEXT NOT NULL CHECK (email = lower(email) AND email ~ '^[^@\s]+@[^@\s]+$' AND length(email) <= 320),
   company_name TEXT NOT NULL CHECK (length(company_name) BETWEEN 3 AND 200),
   client_code TEXT NOT NULL CHECK (client_code ~ '^[A-Z]{3}$'),
   procurement_model public.procurement_model NOT NULL,
   -- The contract terms the relationship starts with (as on provider_relationship).
   commercial_model public.commercial_model,
   packages TEXT[] NOT NULL DEFAULT '{}' CHECK (packages <@ ARRAY['A0', 'A1', 'A2', 'B', 'C', 'D', 'E']::TEXT[]),
   contract_status public.contract_status NOT NULL DEFAULT 'onboarding',
   start_on DATE,
   deposit_rate NUMERIC(5, 2) CHECK (deposit_rate BETWEEN 0 AND 100),
   extra_cost_rule TEXT CHECK (length(extra_cost_rule) <= 2000),
   eu_responsible_person TEXT CHECK (length(eu_responsible_person) <= 500),
   recommended_plan_id UUID REFERENCES public.plan (id) ON DELETE SET NULL,
   -- Expired is expires_at <= now(), not a status.
   expires_at TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '14 days',
   status public.invitation_status NOT NULL DEFAULT 'pending',
   failed_attempts INT NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
   accepted_at TIMESTAMPTZ,
   accepted_by UUID,
   client_tenant_id UUID REFERENCES public.tenant (id) ON DELETE SET NULL,
   revoked_at TIMESTAMPTZ,
   -- No foreign key to public.user: who invited stays known after the user is deleted.
   created_by UUID NOT NULL,
   created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
   updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
   CONSTRAINT provider_invitation_id_tenant_id_key UNIQUE (id, tenant_id)
);

CREATE INDEX idx_provider_invitation_tenant ON public.provider_invitation (tenant_id, created_at DESC);

-- One pending invitation per e-mail, and a pending invitation holds its client code (F15).
CREATE UNIQUE INDEX provider_invitation_one_pending ON public.provider_invitation (tenant_id, email)
WHERE
   status = 'pending';

CREATE UNIQUE INDEX provider_invitation_pending_code ON public.provider_invitation (tenant_id, client_code)
WHERE
   status = 'pending';

CREATE OR REPLACE TRIGGER set_updated_at BEFORE
UPDATE ON public.provider_invitation FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at ();

CREATE TABLE public.provider_invitation_staff (
   invitation_id UUID NOT NULL,
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   user_id UUID NOT NULL REFERENCES public.user (id) ON DELETE CASCADE,
   role_name TEXT NOT NULL CHECK (role_name IN ('management', 'coordinator', 'viewer')),
   PRIMARY KEY (invitation_id, user_id),
   CONSTRAINT provider_invitation_staff_invitation_fkey FOREIGN KEY (invitation_id, tenant_id) REFERENCES public.provider_invitation (id, tenant_id) ON DELETE CASCADE
);

CREATE INDEX idx_provider_invitation_staff_tenant ON public.provider_invitation_staff (tenant_id);

-- The hashes and the issue log: postgres only (the definers below).
CREATE TABLE private.provider_invitation_token (
   invitation_id UUID PRIMARY KEY,
   tenant_id UUID NOT NULL,
   token_hash BYTEA NOT NULL UNIQUE CHECK (length(token_hash) = 32),
   CONSTRAINT provider_invitation_token_invitation_fkey FOREIGN KEY (invitation_id, tenant_id) REFERENCES public.provider_invitation (id, tenant_id) ON DELETE CASCADE
);

CREATE TABLE private.provider_invitation_issue (
   id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   invitation_id UUID,
   issued_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_provider_invitation_issue_tenant ON private.provider_invitation_issue (tenant_id, issued_at);

ALTER TABLE private.provider_invitation_token OWNER TO postgres;

ALTER TABLE private.provider_invitation_issue OWNER TO postgres;

ALTER TABLE private.provider_invitation_token ENABLE ROW LEVEL SECURITY;

ALTER TABLE private.provider_invitation_issue ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE private.provider_invitation_token, private.provider_invitation_issue FROM PUBLIC, anon, authenticated, service_role, api_owner;

-- RLS, audit, permissions (module client).
SELECT
   private.enable_tenant_level_security (t_name)
FROM
   unnest(ARRAY['provider_invitation', 'provider_invitation_staff']) AS t_name;

SELECT
   private.audit_enable ('public.provider_invitation'::REGCLASS);

SELECT
   private.audit_enable ('public.provider_invitation_staff'::REGCLASS);

-- Inserting a permission creates its RLS policies (private.manage_policies). Insert is checked by
-- create_provider_invitation and update by rotate and revoke (F7); the rows themselves are written
-- by those definers only, as the api views are read-only.
INSERT INTO
   public.permission (resource_name, group_name, command, kind, bypass, throws_error, resource_condition)
VALUES
   ('public.provider_invitation', 'client', 'select', 'read', FALSE, FALSE, NULL),
   ('public.provider_invitation', 'client', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.provider_invitation', 'client', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.provider_invitation_staff', 'client', 'select', 'read', FALSE, FALSE, NULL)
ON CONFLICT ON CONSTRAINT unique_permission_resource_command DO NOTHING;

-- The built-in owner role has every permission (008). A role that may change relationships (the
-- client update right) may also invite: management and coordinator roles made before this migration.
INSERT INTO
   public.role_permission (role_id, permission_id)
SELECT
   r.id,
   p.id
FROM
   public.role r,
   public.permission p
WHERE
   p.resource_name IN ('public.provider_invitation', 'public.provider_invitation_staff')
   AND (
      (r.display_name = 'owner' AND r.tenant_id IS NULL)
      OR (
         r.tenant_id IS NOT NULL
         AND EXISTS (
            SELECT 1
            FROM public.role_permission rp
            JOIN public.permission q ON q.id = rp.permission_id
            WHERE rp.role_id = r.id AND q.resource_name = 'public.provider_relationship' AND q.command = 'update'
         )
      )
   )
ON CONFLICT DO NOTHING;

-- Classification (F13: in the owning migration). Like the relationship it becomes: the contract terms
-- are `contract`, the invited person's e-mail `personal_data`; failed_attempts is open.
INSERT INTO
   public.field_class (resource_name, field, class, group_name)
VALUES
   ('public.provider_invitation', 'id', 'system', NULL),
   ('public.provider_invitation', 'tenant_id', 'system', NULL),
   ('public.provider_invitation', 'email', 'sensitive', 'personal_data'),
   ('public.provider_invitation', 'company_name', 'open', NULL),
   ('public.provider_invitation', 'client_code', 'open', NULL),
   ('public.provider_invitation', 'procurement_model', 'open', NULL),
   ('public.provider_invitation', 'commercial_model', 'open', NULL),
   ('public.provider_invitation', 'packages', 'open', NULL),
   ('public.provider_invitation', 'contract_status', 'open', NULL),
   ('public.provider_invitation', 'start_on', 'sensitive', 'contract'),
   ('public.provider_invitation', 'deposit_rate', 'sensitive', 'contract'),
   ('public.provider_invitation', 'extra_cost_rule', 'sensitive', 'contract'),
   ('public.provider_invitation', 'eu_responsible_person', 'open', NULL),
   ('public.provider_invitation', 'recommended_plan_id', 'system', NULL),
   ('public.provider_invitation', 'expires_at', 'open', NULL),
   ('public.provider_invitation', 'status', 'open', NULL),
   ('public.provider_invitation', 'failed_attempts', 'open', NULL),
   ('public.provider_invitation', 'accepted_at', 'open', NULL),
   ('public.provider_invitation', 'accepted_by', 'system', NULL),
   ('public.provider_invitation', 'client_tenant_id', 'system', NULL),
   ('public.provider_invitation', 'revoked_at', 'open', NULL),
   ('public.provider_invitation', 'created_by', 'system', NULL),
   ('public.provider_invitation', 'created_at', 'system', NULL),
   ('public.provider_invitation', 'updated_at', 'system', NULL),
   ('public.provider_invitation_staff', 'invitation_id', 'system', NULL),
   ('public.provider_invitation_staff', 'tenant_id', 'system', NULL),
   ('public.provider_invitation_staff', 'user_id', 'system', NULL),
   ('public.provider_invitation_staff', 'role_name', 'open', NULL)
ON CONFLICT DO NOTHING;

-- R1 (049): no role loses what it had. The built-in profiles get their defaults for the new
-- sensitive fields (private.field_default); any other tenant role reads them as far as it reads
-- invitations (with select; it writes none, the view being read-only).
INSERT INTO
   public.role_field_permission (role_id, resource_name, field, can_read, can_write)
SELECT
   r.id,
   f.resource_name,
   f.field,
   d.can_read,
   d.can_write
FROM
   public.role r
   JOIN private.field_default d ON d.profile = r.display_name
   JOIN public.field_class f ON f.resource_name = 'public.provider_invitation'
   AND f.class = 'sensitive'
   AND f.group_name = d.group_name
WHERE
   r.tenant_id IS NOT NULL
ON CONFLICT (role_id, resource_name, field) DO NOTHING;

INSERT INTO
   public.role_field_permission (role_id, resource_name, field, can_read, can_write)
SELECT
   r.id,
   f.resource_name,
   f.field,
   TRUE,
   FALSE
FROM
   public.role r
   JOIN public.field_class f ON f.resource_name = 'public.provider_invitation'
   AND f.class = 'sensitive'
WHERE
   r.tenant_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM private.field_default d WHERE d.profile = r.display_name)
   AND EXISTS (
      SELECT 1
      FROM public.role_permission rp
      JOIN public.permission p ON p.id = rp.permission_id
      WHERE rp.role_id = r.id AND p.resource_name = 'public.provider_invitation' AND p.command = 'select'
   )
ON CONFLICT (role_id, resource_name, field) DO NOTHING;

-- The api views, read-only (F3): no column holds the token or its hash. A new view changes owner to
-- api_owner, which needs api_owner's CREATE on the schema for that moment (as in 057).
GRANT CREATE ON SCHEMA api TO api_owner;

SELECT private.enable_field_security ('provider_invitation', TRUE);

SELECT private.enable_field_security ('provider_invitation_staff', TRUE);

REVOKE CREATE ON SCHEMA api FROM api_owner;

-- A fresh token: 32 random bytes, base64url without padding (43 characters).
CREATE OR REPLACE FUNCTION private.invitation_new_token () RETURNS TEXT LANGUAGE sql VOLATILE
SET
   search_path = '' AS $$
    SELECT rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), E'+/\n', '-_'), '=');
$$;

REVOKE ALL ON FUNCTION private.invitation_new_token () FROM PUBLIC, anon, authenticated, service_role;

-- Records one token issued for the tenant, refusing it past 50 in 24 hours (creations and resends
-- alike, F21). Serialised per tenant, so concurrent calls cannot both take the last place.
CREATE OR REPLACE FUNCTION private.invitation_issue (p_tenant UUID, p_invitation UUID) RETURNS VOID LANGUAGE plpgsql
SET
   search_path = '' AS $$
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('provider_invitation_issue:' || p_tenant::TEXT, 0));
    DELETE FROM private.provider_invitation_issue i WHERE i.tenant_id = p_tenant AND i.issued_at <= now() - INTERVAL '24 hours';
    IF (SELECT count(*) FROM private.provider_invitation_issue i WHERE i.tenant_id = p_tenant) >= 50 THEN
        RAISE EXCEPTION 'invitation_throttled';
    END IF;
    INSERT INTO private.provider_invitation_issue (tenant_id, invitation_id) VALUES (p_tenant, p_invitation);
END;
$$;

REVOKE ALL ON FUNCTION private.invitation_issue (UUID, UUID) FROM PUBLIC, anon, authenticated, service_role;

-- One lock per (tenant, client code), taken by invitation creation and by a relationship taking a
-- code, so a pending invitation and a relationship never end up with the same code.
CREATE OR REPLACE FUNCTION private.client_code_lock (p_tenant UUID, p_code TEXT) RETURNS VOID LANGUAGE sql
SET
   search_path = '' AS $$
    SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('client_code:' || p_tenant::TEXT || ':' || lower(coalesce(p_code, '')), 0));
$$;

REVOKE ALL ON FUNCTION private.client_code_lock (UUID, TEXT) FROM PUBLIC, anon, authenticated, service_role;

-- A pending invitation holds its client code (F15): no relationship of the tenant may take it, on
-- insert or by a rename. Only pending invitations count, so acceptance (Task 4) marks the invitation
-- accepted before it inserts the relationship under the same code. SECURITY DEFINER: the inserting
-- caller need not read invitations. Named to fire after provider_relationship_guard (client code
-- immutability) and before relationship_contract_guard.
CREATE OR REPLACE FUNCTION private.provider_relationship_reserved_code () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.client_code IS NOT DISTINCT FROM OLD.client_code THEN
        RETURN NEW;
    END IF;
    PERFORM private.client_code_lock(NEW.tenant_id, NEW.client_code);
    IF EXISTS (SELECT 1 FROM public.provider_invitation i
               WHERE i.tenant_id = NEW.tenant_id AND i.client_code = NEW.client_code AND i.status = 'pending') THEN
        RAISE EXCEPTION 'client_code_taken' USING ERRCODE = 'unique_violation';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.provider_relationship_reserved_code () FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE TRIGGER provider_relationship_reserved_code BEFORE INSERT
OR
UPDATE OF client_code ON public.provider_relationship FOR EACH ROW
EXECUTE FUNCTION private.provider_relationship_reserved_code ();

-- Creates an invitation for the provider tenant p_tenant in the name of p_actor, who must hold the
-- insert right on invitations there. Returns the token once; only its hash is kept.
CREATE OR REPLACE FUNCTION public.create_provider_invitation (p_tenant UUID, p_actor UUID, p_invitation JSONB, p_staff JSONB DEFAULT '[]') RETURNS TABLE (id UUID, token TEXT) LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    allowed CONSTANT TEXT[] := ARRAY['email', 'company_name', 'client_code', 'procurement_model', 'commercial_model', 'packages',
                                     'contract_status', 'start_on', 'deposit_rate', 'extra_cost_rule', 'eu_responsible_person',
                                     'recommended_plan_id'];
    staff JSONB := coalesce(p_staff, '[]'::JSONB);
    v_id UUID;
    v_token TEXT;
    v_code TEXT;
    v_constraint TEXT;
BEGIN
    IF p_tenant IS NULL OR p_actor IS NULL
       OR coalesce(cardinality(private.tenants_permitting(p_actor, ARRAY[p_tenant], 'public.provider_invitation', 'insert')), 0) = 0 THEN
        RAISE EXCEPTION 'invitation_forbidden' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF jsonb_typeof(p_invitation) IS DISTINCT FROM 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_invitation) AS k WHERE k <> ALL (allowed)) THEN
        RAISE EXCEPTION 'invitation_payload_invalid' USING ERRCODE = 'check_violation';
    END IF;

    -- Staff: at most 20 distinct members of the provider, each with one of the standard roles.
    IF jsonb_typeof(staff) IS DISTINCT FROM 'array'
       OR jsonb_array_length(staff) > 20
       OR EXISTS (
           SELECT 1 FROM jsonb_array_elements(staff) AS s
           WHERE jsonb_typeof(s) IS DISTINCT FROM 'object'
              OR EXISTS (SELECT 1 FROM jsonb_object_keys(s) AS k WHERE k NOT IN ('user_id', 'role_name'))
              OR coalesce(s ->> 'role_name', '') NOT IN ('management', 'coordinator', 'viewer')
              OR coalesce(s ->> 'user_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              OR NOT EXISTS (SELECT 1 FROM public.tenant_user tu WHERE tu.tenant_id = p_tenant AND tu.user_id = (s ->> 'user_id')::UUID)
       )
       OR (SELECT count(DISTINCT s ->> 'user_id') FROM jsonb_array_elements(staff) AS s) <> jsonb_array_length(staff) THEN
        RAISE EXCEPTION 'invitation_staff_invalid' USING ERRCODE = 'check_violation';
    END IF;

    v_code := p_invitation ->> 'client_code';
    -- The same lock as a relationship taking a code (provider_relationship_reserved_code), so the two
    -- cannot both pass their checks.
    PERFORM private.client_code_lock(p_tenant, v_code);
    IF EXISTS (SELECT 1 FROM public.provider_relationship r WHERE r.tenant_id = p_tenant AND r.client_code = v_code) THEN
        RAISE EXCEPTION 'client_code_taken' USING ERRCODE = 'unique_violation';
    END IF;

    -- A recommended plan must be one the customer can pick: active (the plan step lists active plans).
    IF p_invitation ? 'recommended_plan_id' AND p_invitation ->> 'recommended_plan_id' IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.plan pl
                       WHERE pl.id::TEXT = lower(p_invitation ->> 'recommended_plan_id') AND pl.is_active) THEN
        RAISE EXCEPTION 'plan_inactive' USING ERRCODE = 'check_violation';
    END IF;

    BEGIN
        INSERT INTO public.provider_invitation (
            tenant_id, email, company_name, client_code, procurement_model, commercial_model, packages, contract_status,
            start_on, deposit_rate, extra_cost_rule, eu_responsible_person, recommended_plan_id, created_by
        )
        VALUES (
            p_tenant,
            lower(btrim(p_invitation ->> 'email')),
            btrim(p_invitation ->> 'company_name'),
            v_code,
            (p_invitation ->> 'procurement_model')::public.procurement_model,
            (p_invitation ->> 'commercial_model')::public.commercial_model,
            coalesce(ARRAY(SELECT jsonb_array_elements_text(p_invitation -> 'packages')), '{}'),
            coalesce((p_invitation ->> 'contract_status')::public.contract_status, 'onboarding'),
            (p_invitation ->> 'start_on')::DATE,
            (p_invitation ->> 'deposit_rate')::NUMERIC,
            nullif(p_invitation ->> 'extra_cost_rule', ''),
            nullif(p_invitation ->> 'eu_responsible_person', ''),
            (p_invitation ->> 'recommended_plan_id')::UUID,
            p_actor
        )
        RETURNING provider_invitation.id INTO v_id;
    EXCEPTION
        WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
            IF v_constraint = 'provider_invitation_pending_code' THEN
                RAISE EXCEPTION 'client_code_taken' USING ERRCODE = 'unique_violation';
            ELSIF v_constraint = 'provider_invitation_one_pending' THEN
                RAISE EXCEPTION 'invitation_pending_exists' USING ERRCODE = 'unique_violation';
            END IF;
            RAISE;
        WHEN not_null_violation OR check_violation OR foreign_key_violation OR invalid_text_representation
             OR invalid_parameter_value OR invalid_datetime_format OR datetime_field_overflow
             OR numeric_value_out_of_range OR invalid_binary_representation OR cannot_coerce THEN
            RAISE EXCEPTION 'invitation_payload_invalid' USING ERRCODE = 'check_violation', DETAIL = SQLERRM;
    END;

    INSERT INTO public.provider_invitation_staff (invitation_id, tenant_id, user_id, role_name)
    SELECT v_id, p_tenant, (s ->> 'user_id')::UUID, s ->> 'role_name'
    FROM jsonb_array_elements(staff) AS s;

    -- Last of the checks, so a refused payload does not use up the day's places.
    PERFORM private.invitation_issue(p_tenant, v_id);

    v_token := private.invitation_new_token();
    INSERT INTO private.provider_invitation_token (invitation_id, tenant_id, token_hash)
    VALUES (v_id, p_tenant, extensions.digest(v_token, 'sha256'));

    id := v_id;
    token := v_token;
    RETURN NEXT;
END;
$$;

-- Resends a pending invitation (expired or not): a new token replaces the old one's hash, the 14
-- days start again and the failed attempts are forgotten. p_actor needs the update right in the
-- invitation's tenant; an unknown invitation is refused like a forbidden one.
CREATE OR REPLACE FUNCTION public.rotate_provider_invitation_token (p_invitation UUID, p_actor UUID) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    inv public.provider_invitation;
    v_token TEXT;
BEGIN
    SELECT * INTO inv FROM public.provider_invitation i WHERE i.id = p_invitation FOR UPDATE;

    IF inv.id IS NULL OR p_actor IS NULL
       OR coalesce(cardinality(private.tenants_permitting(p_actor, ARRAY[inv.tenant_id], 'public.provider_invitation', 'update')), 0) = 0 THEN
        RAISE EXCEPTION 'invitation_forbidden' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF inv.status <> 'pending' THEN
        RAISE EXCEPTION 'invitation_invalid';
    END IF;

    PERFORM private.invitation_issue(inv.tenant_id, inv.id);

    v_token := private.invitation_new_token();
    INSERT INTO private.provider_invitation_token AS t (invitation_id, tenant_id, token_hash)
    VALUES (inv.id, inv.tenant_id, extensions.digest(v_token, 'sha256'))
    ON CONFLICT (invitation_id) DO UPDATE SET token_hash = EXCLUDED.token_hash;

    UPDATE public.provider_invitation i
    SET expires_at = now() + INTERVAL '14 days', failed_attempts = 0
    WHERE i.id = inv.id;

    RETURN v_token;
END;
$$;

-- Revokes a pending invitation: the caller holds the update right in the invitation's tenant. The
-- hash goes with it, so no token matches the invitation any more. An unknown invitation is refused
-- like a forbidden one, so ids cannot be probed.
CREATE OR REPLACE FUNCTION public.revoke_provider_invitation (invitation_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    v_tenant UUID;
    v_status public.invitation_status;
BEGIN
    -- Authorise on an unlocked read: a caller without the right never locks another tenant's row.
    SELECT i.tenant_id INTO v_tenant FROM public.provider_invitation i WHERE i.id = revoke_provider_invitation.invitation_id;

    IF v_tenant IS NULL OR auth.uid() IS NULL
       OR coalesce(cardinality(private.tenants_permitting(auth.uid(), ARRAY[v_tenant], 'public.provider_invitation', 'update')), 0) = 0 THEN
        RAISE EXCEPTION 'invitation_forbidden' USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Then lock and re-read the status (a concurrent accept or revoke may have moved it).
    SELECT i.status INTO v_status FROM public.provider_invitation i
    WHERE i.id = revoke_provider_invitation.invitation_id AND i.tenant_id = v_tenant
    FOR UPDATE;

    IF v_status IS DISTINCT FROM 'pending' THEN
        RAISE EXCEPTION 'invitation_invalid';
    END IF;

    UPDATE public.provider_invitation i
    SET status = 'revoked', revoked_at = now()
    WHERE i.id = revoke_provider_invitation.invitation_id;

    DELETE FROM private.provider_invitation_token t WHERE t.invitation_id = revoke_provider_invitation.invitation_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_provider_invitation (UUID, UUID, JSONB, JSONB) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.rotate_provider_invitation_token (UUID, UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.revoke_provider_invitation (UUID) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_provider_invitation (UUID, UUID, JSONB, JSONB) TO service_role;

GRANT EXECUTE ON FUNCTION public.rotate_provider_invitation_token (UUID, UUID) TO service_role;

GRANT EXECUTE ON FUNCTION public.revoke_provider_invitation (UUID) TO authenticated;

-- 046's audit_service_actor plus the provider-invitation label (F27): the Edge Function's writes are
-- audited under its name and, through x-audit-actor, the user it acts for.
CREATE OR REPLACE FUNCTION private.audit_service_actor () RETURNS TRIGGER LANGUAGE plpgsql
SET
   search_path = '' AS $$
DECLARE
    v_headers JSONB;
    v_actor TEXT;
BEGIN
    IF NEW.actor_id IS NOT NULL OR NEW.actor_role IS DISTINCT FROM 'service_role' THEN
        RETURN NEW;
    END IF;

    v_headers := nullif(current_setting('request.headers', TRUE), '')::JSONB;
    IF NOT coalesce(v_headers ->> 'x-audit-role' = ANY (ARRAY['amazon-auth', 'amazon-listing', 'amazon-schema', 'amazon-poll', 'amazon-schema-refresh',
                                                          'provider-invitation']), FALSE) THEN
        RETURN NEW;
    END IF;

    NEW.actor_role := v_headers ->> 'x-audit-role';
    v_actor := v_headers ->> 'x-audit-actor';
    IF v_actor ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        NEW.actor_id := v_actor::UUID;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.audit_service_actor () FROM PUBLIC, anon, authenticated;
