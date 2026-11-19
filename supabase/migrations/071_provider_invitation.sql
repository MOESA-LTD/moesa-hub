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
   -- An id like every audited table: the audit diffs an update's old and new rows by it.
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   invitation_id UUID NOT NULL,
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   user_id UUID NOT NULL REFERENCES public.user (id) ON DELETE CASCADE,
   role_name TEXT NOT NULL CHECK (role_name IN ('management', 'coordinator', 'viewer')),
   CONSTRAINT provider_invitation_staff_invitation_user_key UNIQUE (invitation_id, user_id),
   CONSTRAINT provider_invitation_staff_invitation_fkey FOREIGN KEY (invitation_id, tenant_id) REFERENCES public.provider_invitation (id, tenant_id) ON DELETE CASCADE
);

CREATE INDEX idx_provider_invitation_staff_tenant ON public.provider_invitation_staff (tenant_id);

-- The hashes and the issue log: postgres only (the definers below).
CREATE TABLE private.provider_invitation_token (
   invitation_id UUID PRIMARY KEY,
   tenant_id UUID NOT NULL,
   token_hash BYTEA NOT NULL UNIQUE CHECK (length(token_hash) = 32),
   -- When this token was issued (creation or the latest resend): revoke_unsent_provider_invitation
   -- acts only on a token that has just been issued.
   issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
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
   ('public.provider_invitation_staff', 'id', 'system', NULL),
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
    ON CONFLICT (invitation_id) DO UPDATE SET token_hash = EXCLUDED.token_hash, issued_at = now();

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

-- The provider-invitation Edge Function's undo when the invitation e-mail could not be sent (Task 5):
-- nobody holds the token, so the invitation is revoked and its e-mail and code are free again. The
-- service role has no auth.uid(), so revoke_provider_invitation cannot serve it. Only the creator,
-- still holding the insert right, discards a pending invitation, and only while it is "unsent": created
-- and its current token issued within the last 10 minutes (a mailed, older invitation is never taken by
-- a wrong id). Anything else is invitation_forbidden (an unknown id included). The issue stays logged,
-- so failed mails still count toward the cap.
CREATE OR REPLACE FUNCTION public.revoke_unsent_provider_invitation (p_invitation UUID, p_actor UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    inv public.provider_invitation;
    v_status public.invitation_status;
BEGIN
    -- Authorise on an unlocked read (as revoke_provider_invitation), then lock and re-read the status.
    SELECT * INTO inv FROM public.provider_invitation i WHERE i.id = p_invitation;

    IF inv.id IS NULL OR p_actor IS NULL OR inv.created_by IS DISTINCT FROM p_actor
       OR inv.created_at < now() - INTERVAL '10 minutes'
       OR NOT EXISTS (SELECT 1 FROM private.provider_invitation_token t
                      WHERE t.invitation_id = inv.id AND t.issued_at >= now() - INTERVAL '10 minutes')
       OR coalesce(cardinality(private.tenants_permitting(p_actor, ARRAY[inv.tenant_id], 'public.provider_invitation', 'insert')), 0) = 0 THEN
        RAISE EXCEPTION 'invitation_forbidden' USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT i.status INTO v_status FROM public.provider_invitation i WHERE i.id = inv.id AND i.tenant_id = inv.tenant_id FOR UPDATE;

    IF v_status IS DISTINCT FROM 'pending' THEN
        RAISE EXCEPTION 'invitation_invalid';
    END IF;

    UPDATE public.provider_invitation i SET status = 'revoked', revoked_at = now() WHERE i.id = inv.id;
    DELETE FROM private.provider_invitation_token t WHERE t.invitation_id = inv.id;
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_unsent_provider_invitation (UUID, UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.revoke_unsent_provider_invitation (UUID, UUID) TO service_role;

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

-- Section 2: preview and one-step acceptance (decision 16). The customer opens the link, signed in
-- with the invited e-mail, sees the terms and the plans, and accepts: their own tenant (they own it,
-- on the plan they chose), the relationship with the provider, and the provider staff named on the
-- invitation in their roles, in one transaction.
--
--   private.invitation_attempt                 attempts per key in a window (the throttles).
--   private.invitation_throttle(key, limit, w) counts one attempt; TRUE while within the limit.
--   private.invitation_open(user, token, count) finds (and, to count, locks) the invitation behind
--                                              a token and checks it for the user (shared by both
--                                              below; only acceptance counts a mismatch).
--   private.invitation_staff_slots(inv, user) the invitation's staff as the user sees them: every
--                                              staff row but the user's own, numbered from 0 in the
--                                              row order (the rows never change after creation, so a
--                                              number names the same person in the preview and at
--                                              acceptance), and whether they are still with the
--                                              provider.
--   public.invitation_preview(token) → JSONB   authenticated (auth.uid()); consumes nothing.
--   public.accept_provider_invitation(p_user, p_token, p_company, p_plan_id, p_staff) → JSONB
--                                              service role only (F1): the provider-invitation Edge
--                                              Function, p_user from the verified JWT.
--
-- Final review I2 (informed consent, decision 16): the preview names each staff member who would
-- join ({index, display_name, role_name}: the display name, never an e-mail or a user id) and the
-- accepter may keep only some of them (p_staff, the preview's indexes; NULL keeps every one).
--
-- Refusals before the first write return {"error": code} and do not raise (F2), so the attempt
-- counts and failed_attempts they wrote commit: invitation_throttled (preview:<uid> 30 per 10
-- minutes, accept:<uid> 10 per hour), invitation_invalid (unknown, used, revoked, expired, or locked
-- by 10 failed acceptances until a resend), invitation_email_mismatch (the user's confirmed e-mail
-- is not the invited one; counted by acceptance only, so a preview never locks an invitation),
-- invitation_payload_invalid (also a p_staff that is not an array of the preview's indexes),
-- plan_inactive, company_email_exists, company_phone_exists. A failure
-- after the first write raises and leaves nothing: company_email_exists, company_phone_exists
-- (23505, a concurrent registration), invitation_payload_invalid (23514), invitation_staff_invalid
-- (23514), plan_limit_users.
CREATE TABLE private.invitation_attempt (
   key TEXT PRIMARY KEY,
   window_start TIMESTAMPTZ NOT NULL,
   count INT NOT NULL
);

ALTER TABLE private.invitation_attempt OWNER TO postgres;

ALTER TABLE private.invitation_attempt ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_invitation_attempt_window ON private.invitation_attempt (window_start);

REVOKE ALL ON TABLE private.invitation_attempt FROM PUBLIC, anon, authenticated, service_role, api_owner;

-- One attempt under p_key: a window of p_window opens with the first attempt; within it at most
-- p_limit attempts pass. The count stops at p_limit + 1, so a refused caller cannot overflow it.
-- Each call also prunes up to 100 rows whose window started over a day ago (no throttle window is
-- longer), skipping rows another call holds, so the table stays small at a bounded cost.
CREATE OR REPLACE FUNCTION private.invitation_throttle (p_key TEXT, p_limit INT, p_window INTERVAL) RETURNS BOOLEAN LANGUAGE plpgsql
SET
   search_path = '' AS $$
DECLARE
    v_count INT;
BEGIN
    DELETE FROM private.invitation_attempt a
    WHERE a.key IN (SELECT o.key FROM private.invitation_attempt o
                    WHERE o.window_start < now() - INTERVAL '1 day' AND o.key <> p_key
                    LIMIT 100 FOR UPDATE SKIP LOCKED);

    INSERT INTO private.invitation_attempt AS a (key, window_start, count)
    VALUES (p_key, now(), 1)
    ON CONFLICT (key) DO UPDATE
    SET window_start = CASE WHEN a.window_start <= now() - p_window THEN now() ELSE a.window_start END,
        count = CASE WHEN a.window_start <= now() - p_window THEN 1 ELSE least(a.count + 1, p_limit + 1) END
    RETURNING a.count INTO v_count;
    RETURN v_count <= p_limit;
END;
$$;

REVOKE ALL ON FUNCTION private.invitation_throttle (TEXT, INT, INTERVAL) FROM PUBLIC, anon, authenticated, service_role;

-- The invitation behind p_token, for p_user: its id, or the refusal. Looks the hash up, then locks
-- the invitation (FOR UPDATE, so concurrent accepts, resends and revokes are serialised) and checks
-- the hash again under the lock, as a resend or revoke may have replaced it meanwhile. One answer,
-- invitation_invalid, for unknown, accepted, revoked, expired and locked. The e-mail is proven by
-- auth.users (F1): the user's address, confirmed, is the invited one; else invitation_email_mismatch
-- (the caller returns it without raising, F2). With p_count (acceptance) the invitation is locked
-- and the mismatch counted toward the lock-out; preview passes FALSE: it neither locks nor counts,
-- so whoever holds the link cannot lock the invited user out by previewing.
CREATE OR REPLACE FUNCTION private.invitation_open (p_user UUID, p_token TEXT, p_count BOOLEAN, OUT invitation_id UUID, OUT error TEXT) LANGUAGE plpgsql
SET
   search_path = '' AS $$
DECLARE
    v_hash BYTEA;
    v_id UUID;
    inv public.provider_invitation;
    v_email TEXT;
    v_confirmed TIMESTAMPTZ;
BEGIN
    IF p_user IS NULL OR p_token IS NULL OR length(p_token) > 256 THEN
        error := 'invitation_invalid';
        RETURN;
    END IF;

    v_hash := extensions.digest(p_token, 'sha256');
    SELECT t.invitation_id INTO v_id FROM private.provider_invitation_token t WHERE t.token_hash = v_hash;
    IF v_id IS NOT NULL THEN
        IF p_count THEN
            SELECT * INTO inv FROM public.provider_invitation i WHERE i.id = v_id FOR UPDATE;
        ELSE
            SELECT * INTO inv FROM public.provider_invitation i WHERE i.id = v_id;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM private.provider_invitation_token t WHERE t.invitation_id = v_id AND t.token_hash = v_hash) THEN
            inv := NULL;
        END IF;
    END IF;

    IF inv.id IS NULL OR inv.status <> 'pending' OR inv.expires_at <= now() OR inv.failed_attempts >= 10 THEN
        error := 'invitation_invalid';
        RETURN;
    END IF;

    SELECT lower(u.email), u.email_confirmed_at INTO v_email, v_confirmed FROM auth.users u WHERE u.id = p_user;
    IF v_confirmed IS NULL OR v_email IS DISTINCT FROM inv.email THEN
        IF p_count THEN
            UPDATE public.provider_invitation i SET failed_attempts = i.failed_attempts + 1 WHERE i.id = inv.id;
        END IF;
        error := 'invitation_email_mismatch';
        RETURN;
    END IF;

    invitation_id := inv.id;
END;
$$;

REVOKE ALL ON FUNCTION private.invitation_open (UUID, TEXT, BOOLEAN) FROM PUBLIC, anon, authenticated, service_role;

-- The invitation's staff for a user (see the section header): (idx, user_id, role_name, present).
CREATE OR REPLACE FUNCTION private.invitation_staff_slots (p_invitation UUID, p_user UUID) RETURNS TABLE (
   idx INT,
   user_id UUID,
   role_name TEXT,
   present BOOLEAN
) LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT (row_number() OVER (ORDER BY s.id) - 1)::INT, s.user_id, s.role_name,
           EXISTS (SELECT 1 FROM public.tenant_user tu WHERE tu.tenant_id = s.tenant_id AND tu.user_id = s.user_id)
    FROM public.provider_invitation_staff s
    WHERE s.invitation_id = p_invitation AND s.user_id IS DISTINCT FROM p_user;
$$;

REVOKE ALL ON FUNCTION private.invitation_staff_slots (UUID, UUID) FROM PUBLIC, anon, authenticated, service_role;

-- What the invited user sees before accepting: the invitation's terms, the seats it needs (the owner
-- and the staff still with the provider, the viewer aside), those staff by display name and role
-- (I2: {index, display_name, role_name}; the accepter's choice names them by index) and the active
-- plans. Same validity and e-mail rules as acceptance, but consumes and counts nothing. Staff user
-- ids and e-mails, the token and its hash are never returned. needs_password: the user has no
-- password of their own yet (none, or Auth's temporary one of an invited account), so the page asks
-- for one.
CREATE OR REPLACE FUNCTION public.invitation_preview (token TEXT) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    uid UUID := auth.uid();
    v_id UUID;
    v_error TEXT;
    inv public.provider_invitation;
BEGIN
    IF uid IS NULL THEN
        RETURN jsonb_build_object('error', 'invitation_invalid');
    END IF;
    IF NOT private.invitation_throttle('preview:' || uid::TEXT, 30, INTERVAL '10 minutes') THEN
        RETURN jsonb_build_object('error', 'invitation_throttled');
    END IF;

    SELECT o.invitation_id, o.error INTO v_id, v_error FROM private.invitation_open(uid, invitation_preview.token, FALSE) o;
    IF v_error IS NOT NULL THEN
        RETURN jsonb_build_object('error', v_error);
    END IF;
    SELECT * INTO inv FROM public.provider_invitation i WHERE i.id = v_id;

    RETURN jsonb_build_object(
        'company_name', inv.company_name,
        'email', inv.email,
        'provider_name', (SELECT t.display_name FROM public.tenant t WHERE t.id = inv.tenant_id),
        'procurement_model', inv.procurement_model,
        'contract', jsonb_build_object('commercial_model', inv.commercial_model, 'packages', to_jsonb(inv.packages),
                                       'start_on', inv.start_on, 'deposit_rate', inv.deposit_rate),
        'recommended_plan_id', inv.recommended_plan_id,
        'expires_at', inv.expires_at,
        'seats', 1 + (SELECT count(*) FROM private.invitation_staff_slots(inv.id, uid) s WHERE s.present),
        -- I2: who joins, and in which role; a staff member who left the provider joins no more.
        'staff', coalesce((
            SELECT jsonb_agg(jsonb_build_object('index', s.idx, 'display_name', u.user_metadata ->> 'display_name',
                                                'role_name', s.role_name) ORDER BY s.idx)
            FROM private.invitation_staff_slots(inv.id, uid) s
            JOIN public.user u ON u.id = s.user_id
            WHERE s.present
        ), '[]'::JSONB),
        -- No password, or only the temporary one Auth gives an invited account when its link is
        -- followed: the acceptance page sets one, marking user_metadata.password_set true with it.
        'needs_password', (SELECT coalesce(u.encrypted_password, '') = ''
                                  OR (u.invited_at IS NOT NULL AND (u.raw_user_meta_data -> 'password_set') IS DISTINCT FROM 'true'::JSONB)
                           FROM auth.users u WHERE u.id = uid),
        'plans', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', p.id, 'display_name', p.display_name, 'description', p.description, 'audience', p.audience,
                       'price', p.price, 'currency', p.currency, 'billing_period', p.billing_period, 'trial_days', p.trial_days,
                       'position', p.position,
                       'modules', coalesce((SELECT jsonb_agg(pm.module_id ORDER BY pm.module_id) FROM public.plan_module pm WHERE pm.plan_id = p.id), '[]'::JSONB),
                       'limits', coalesce((SELECT jsonb_object_agg(pl.limit_key, pl.value) FROM public.plan_limit pl WHERE pl.plan_id = p.id), '{}'::JSONB)
                   ) ORDER BY p.position, p.display_name)
            FROM public.plan p
            WHERE p.is_active
        ), '[]'::JSONB)
    );
END;
$$;

-- Accepts the invitation behind p_token for p_user (F1: the service role, with p_user from the
-- verified JWT). p_company is the new company: the keys of private.create_company, text values; its
-- e-mail defaults to the invited one (F15). p_staff (I2): the staff the accepter keeps, as the
-- preview's indexes (a JSON array of integers; NULL keeps every one, [] none). Returns {tenant_id,
-- skipped_staff}: kept staff who are no longer members of the provider are skipped.
CREATE OR REPLACE FUNCTION public.accept_provider_invitation (
   p_user UUID,
   p_token TEXT,
   p_company JSONB,
   p_plan_id UUID,
   p_staff JSONB DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    allowed CONSTANT TEXT[] := ARRAY['display_name', 'legal_name', 'email', 'phone', 'website', 'country', 'city', 'district',
                                     'address', 'tax_office', 'tax_number'];
    v_id UUID;
    v_error TEXT;
    inv public.provider_invitation;
    company JSONB;
    created public.tenant;
    v_constraint TEXT;
    s RECORD;
    skipped UUID[] := '{}';
    kept INT[];
    v_headers TEXT := current_setting('request.headers', TRUE);
    v_result JSONB;
BEGIN
    IF p_user IS NULL OR NOT EXISTS (SELECT 1 FROM public.user u WHERE u.id = p_user) THEN
        RETURN jsonb_build_object('error', 'invitation_invalid');
    END IF;

    -- Every write below is audited as the provider-invitation function acting for p_user (F27),
    -- whatever actor the caller's header names. The caller's headers are restored on return.
    PERFORM set_config('request.headers',
                       (coalesce(nullif(v_headers, '')::JSONB, '{}'::JSONB)
                        || jsonb_build_object('x-audit-role', 'provider-invitation', 'x-audit-actor', p_user))::TEXT,
                       TRUE);

    <<body>>
    BEGIN
    IF NOT private.invitation_throttle('accept:' || p_user::TEXT, 10, INTERVAL '1 hour') THEN
        v_result := jsonb_build_object('error', 'invitation_throttled');
        EXIT body;
    END IF;

    SELECT o.invitation_id, o.error INTO v_id, v_error FROM private.invitation_open(p_user, p_token, TRUE) o;
    IF v_error IS NOT NULL THEN
        v_result := jsonb_build_object('error', v_error);
        EXIT body;
    END IF;
    SELECT * INTO inv FROM public.provider_invitation i WHERE i.id = v_id;

    -- The accepter names their company only: not the model, the staff, the tenant or the owner.
    IF jsonb_typeof(p_company) IS DISTINCT FROM 'object'
       OR EXISTS (SELECT 1 FROM jsonb_each(p_company) AS e WHERE e.key <> ALL (allowed) OR jsonb_typeof(e.value) NOT IN ('string', 'null'))
       OR length(btrim(coalesce(p_company ->> 'display_name', ''))) NOT BETWEEN 3 AND 200 THEN
        v_result := jsonb_build_object('error', 'invitation_payload_invalid');
        EXIT body;
    END IF;
    IF p_plan_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.plan p WHERE p.id = p_plan_id AND p.is_active) THEN
        v_result := jsonb_build_object('error', 'plan_inactive');
        EXIT body;
    END IF;

    -- I2: the staff the accepter keeps, by the preview's indexes.
    IF p_staff IS NOT NULL AND jsonb_typeof(p_staff) <> 'null' THEN
        IF jsonb_typeof(p_staff) <> 'array'
           OR jsonb_array_length(p_staff) > 100
           OR EXISTS (
               SELECT 1 FROM jsonb_array_elements(p_staff) AS e (v)
               WHERE jsonb_typeof(e.v) <> 'number'
                  OR (e.v #>> '{}')::NUMERIC <> trunc((e.v #>> '{}')::NUMERIC)
                  OR NOT EXISTS (SELECT 1 FROM private.invitation_staff_slots(inv.id, p_user) x WHERE x.idx = (e.v #>> '{}')::NUMERIC)
           ) THEN
            v_result := jsonb_build_object('error', 'invitation_payload_invalid');
            EXIT body;
        END IF;
        kept := ARRAY(SELECT DISTINCT (e.v #>> '{}')::INT FROM jsonb_array_elements(p_staff) AS e (v));
    END IF;

    company := p_company || jsonb_build_object('display_name', btrim(p_company ->> 'display_name'));
    IF nullif(btrim(coalesce(company ->> 'email', '')), '') IS NULL THEN
        company := company || jsonb_build_object('email', inv.email);
    END IF;

    -- The company's unique e-mail and phone, checked before the first write so the refusal keeps
    -- the throttle count (F2); the unique keys below still catch a concurrent registration.
    IF EXISTS (SELECT 1 FROM public.tenant t WHERE t.email = nullif(company ->> 'email', '')) THEN
        v_result := jsonb_build_object('error', 'company_email_exists');
        EXIT body;
    END IF;
    IF EXISTS (SELECT 1 FROM public.tenant t WHERE t.phone = nullif(company ->> 'phone', '')) THEN
        v_result := jsonb_build_object('error', 'company_phone_exists');
        EXIT body;
    END IF;

    -- From here a failure raises: the whole acceptance is undone.
    BEGIN
        created := private.create_company(p_user, company, p_plan_id);
    EXCEPTION
        WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
            IF v_constraint = 'tenant_email_key' THEN
                RAISE EXCEPTION 'company_email_exists' USING ERRCODE = 'unique_violation';
            ELSIF v_constraint = 'tenant_phone_key' THEN
                RAISE EXCEPTION 'company_phone_exists' USING ERRCODE = 'unique_violation';
            END IF;
            RAISE;
        WHEN check_violation OR not_null_violation OR string_data_right_truncation THEN
            RAISE EXCEPTION 'invitation_payload_invalid' USING ERRCODE = 'check_violation', DETAIL = SQLERRM;
    END;

    UPDATE public.tenant t SET code = inv.client_code WHERE t.id = created.id;

    -- The invitation is used up before the relationship takes its code: a pending invitation holds
    -- the code (provider_relationship_reserved_code).
    UPDATE public.provider_invitation i
    SET status = 'accepted', accepted_at = now(), accepted_by = p_user, client_tenant_id = created.id
    WHERE i.id = inv.id;
    DELETE FROM private.provider_invitation_token t WHERE t.invitation_id = inv.id;

    -- Every field written explicitly, as agreed on the invitation.
    INSERT INTO public.provider_relationship (
        tenant_id, client_tenant_id, client_code, client_name, provider_name, procurement_model, status, accepted_at,
        commercial_model, packages, contract_status, start_on, deposit_rate, extra_cost_rule, eu_responsible_person
    )
    VALUES (
        inv.tenant_id, created.id, inv.client_code, inv.company_name,
        (SELECT t.display_name FROM public.tenant t WHERE t.id = inv.tenant_id),
        inv.procurement_model, 'active', now(),
        inv.commercial_model, inv.packages, inv.contract_status, inv.start_on, inv.deposit_rate, inv.extra_cost_rule,
        inv.eu_responsible_person
    );

    -- The provider's staff the accepter kept (I2; all without a choice), in their roles; the accepter
    -- is never one of them. One who left the provider is skipped; the plan's user limit may refuse
    -- one, which fails the whole call.
    FOR s IN
        SELECT st.user_id, st.role_name FROM private.invitation_staff_slots(inv.id, p_user) st
        WHERE kept IS NULL OR st.idx = ANY (kept)
        ORDER BY st.user_id
    LOOP
        IF NOT EXISTS (SELECT 1 FROM public.tenant_user tu WHERE tu.tenant_id = inv.tenant_id AND tu.user_id = s.user_id) THEN
            skipped := skipped || s.user_id;
            CONTINUE;
        END IF;
        INSERT INTO public.tenant_user (tenant_id, user_id) VALUES (created.id, s.user_id);
        INSERT INTO public.user_role (user_id, role_id)
        SELECT s.user_id, r.id FROM public.role r WHERE r.tenant_id = created.id AND r.display_name = s.role_name;
        -- Never a member without a role.
        IF NOT FOUND THEN
            RAISE EXCEPTION 'invitation_staff_invalid' USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;

    -- A self-signup pending on this account (070, private.pending_signup) may be someone else's
    -- request for this address: acceptance never reads it, and the account now owns this company.
    DELETE FROM private.pending_signup p WHERE p.user_id = p_user;

    v_result := jsonb_build_object('tenant_id', created.id, 'skipped_staff', to_jsonb(skipped));
    END;

    PERFORM set_config('request.headers', coalesce(v_headers, ''), TRUE);
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.invitation_preview (TEXT) FROM PUBLIC, anon;

REVOKE ALL ON FUNCTION public.accept_provider_invitation (UUID, TEXT, JSONB, UUID, JSONB) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.invitation_preview (TEXT) TO authenticated;

GRANT EXECUTE ON FUNCTION public.accept_provider_invitation (UUID, TEXT, JSONB, UUID, JSONB) TO service_role;

-- A client tenant is not deleted while a relationship names it (F14): the relationship's RESTRICT
-- foreign key, with a code the app can name. The provider ends the relationship first.
CREATE OR REPLACE FUNCTION private.tenant_has_provider_relationship () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.provider_relationship r WHERE r.client_tenant_id = OLD.id) THEN
        RAISE EXCEPTION 'tenant_has_provider_relationship' USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN OLD;
END;
$$;

REVOKE ALL ON FUNCTION private.tenant_has_provider_relationship () FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE TRIGGER tenant_has_provider_relationship BEFORE DELETE ON public.tenant FOR EACH ROW
EXECUTE FUNCTION private.tenant_has_provider_relationship ();

-- ---------------------------------------------------------------------------------------------
-- Section 3: provider staff may join a client tenant (Task 6). Whether p_user is staff of a
-- provider of p_client's company: a member of the tenant of an active relationship whose client is
-- the company root of p_client. The user Edge Function asks it (service role) before linking an
-- existing account of another company; the relationship reads nothing, and the membership it
-- allows has no role until the client owner assigns one.
CREATE OR REPLACE FUNCTION public.is_provider_staff (p_client UUID, p_user UUID) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT EXISTS (
        SELECT 1
        FROM private.entitlements(ARRAY[p_client]) e
        JOIN public.provider_relationship r ON r.client_tenant_id = e.company_id AND r.status = 'active'
        JOIN public.tenant_user m ON m.tenant_id = r.tenant_id AND m.user_id = p_user
    );
$$;

REVOKE ALL ON FUNCTION public.is_provider_staff (UUID, UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.is_provider_staff (UUID, UUID) TO service_role;
