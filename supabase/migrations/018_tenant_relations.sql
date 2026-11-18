-- Tenant relations: every company the panel serves is a tenant of its own. A tenant that works for
-- another one (the provider) is linked to it (the client) by a provider relationship; the client's
-- own records (brands, contacts, warehouses, platform accounts) belong to the client's tenant like
-- any other tenant's.
--
-- tenant.code            A short code for the tenant (two to six capital letters or digits), filled
--                        on insert from the display name (private.default_tenant_code). It numbers
--                        the tenant's own business codes. It need not be unique across tenants.
-- provider_relationship  Lives in the provider's tenant (tenant_id) and names the client tenant
--                        (client_tenant_id). It records:
--                          - client_code (three capital letters, unique per provider): the code the
--                            provider numbers its records for this client under, fixed once a code
--                            was drawn under it (public.code_sequence);
--                          - client_name: the provider's label for the client, since provider staff
--                            cannot read the client's tenant row without an invitation;
--                          - provider_name: the provider's display name when the relationship was
--                            made, so the client can name its provider without reading the
--                            provider's tenant row (filled on insert; a sent value is ignored);
--                          - the procurement model: the client procures, or the provider does;
--                          - status: active, then ended for good (ended_at);
--                          - the contract terms (commercial model, packages, contract status,
--                            dates and document, deposit rate, extra-cost rule, EU responsible
--                            person); they, the procurement model, client_name and the Drive
--                            link are changed only by those who may change the provider's
--                            settings (private.relationship_contract_guard);
--                          - provider-internal fields: notes and the restricted Drive link.
--                        Rows come from accepting an invitation (or the seed): no insert permission.
--                        The provider side, or the client company's owner, ends a relationship
--                        (public.end_provider_relationship). Ending moves no row and touches no
--                        membership.
-- brand                  The tenant's brands and their registration status.
-- contact                The tenant's people, and who of them may approve.
-- warehouse              Where the tenant's goods are delivered: its own, a third party's or FBA. At
--                        most one is the default.
-- platform_account       The marketplaces (public.platform) the tenant sells on, and whether it has
--                        an authorized user there. No passwords or tokens are kept. Its permissions
--                        come with the listing module (046_amazon_listing_core.sql).
--
-- Each rule is a check_violation whose message is the rule's code, or a 42501 for a right:
--   relationship_immutable            the provider, the client or accepted_at changed
--   relationship_ended_final          an ended relationship made active again
--   client_code_immutable             a client_code changed after a code was drawn under it
--   relationship_contract_restricted  the procurement model, client_name or a contract term
--                                     changed by a caller without the update permission on
--                                     settings in the provider's tenant
--   relationship_end_forbidden        (42501) ending by a caller who is neither the provider side
--                                     with the update right nor the client company's owner
--
-- Project rule for every child→parent reference between tenant-scoped tables: the foreign key
-- includes tenant_id (parent UNIQUE (id, tenant_id), child FOREIGN KEY (parent_id, tenant_id)).
-- Referential checks bypass RLS, so a plain FK on the id alone would let a row point at another
-- tenant's parent (and probe which ids exist there), and that tenant's deletes would cascade into
-- this tenant's rows. Documents are never deleted, so provider_relationship.contract_document_id is
-- ON DELETE RESTRICT: ON DELETE SET NULL on a composite key would null tenant_id as well. The one
-- cross-tenant reference here, client_tenant_id, is what the relationship is about; a client tenant
-- is not deleted while a relationship names it.

CREATE TYPE public.commercial_model AS ENUM ('trading_partner', 'commercial_representative', 'operations_partner');

CREATE TYPE public.contract_status AS ENUM ('lead', 'onboarding', 'active', 'paused', 'closed');

CREATE TYPE public.procurement_model AS ENUM ('client', 'provider');

CREATE TYPE public.relationship_status AS ENUM ('active', 'ended');

CREATE TYPE public.warehouse_type AS ENUM ('own', 'third_party', 'fba');

CREATE TYPE public.platform_access AS ENUM ('authorized_user', 'none');

-- Target of provider_relationship.contract_document_id.
ALTER TABLE public.document
ADD CONSTRAINT document_id_tenant_id_key UNIQUE (id, tenant_id);

-- The tenant code
-- The default code of a tenant named `p_name`: its letters and digits, Turkish letters folded to
-- ASCII, the first three, padded with X to three.
CREATE OR REPLACE FUNCTION private.default_tenant_code (p_name TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE
SET
   search_path = '' AS $$
    SELECT rpad(left(regexp_replace(translate(upper(p_name), 'ÇĞİIÖŞÜÂÎÛ', 'CGIIOSUAIU'), '[^A-Z0-9]', '', 'g'), 3), 3, 'X');
$$;

REVOKE ALL ON FUNCTION private.default_tenant_code (TEXT) FROM PUBLIC, anon, authenticated;

ALTER TABLE public.tenant
ADD COLUMN IF NOT EXISTS code TEXT CONSTRAINT tenant_code_format CHECK (code ~ '^[A-Z0-9]{2,6}$');

UPDATE public.tenant
SET
   code = private.default_tenant_code (display_name)
WHERE
   code IS NULL;

ALTER TABLE public.tenant
ALTER COLUMN code SET NOT NULL;

CREATE OR REPLACE FUNCTION private.tenant_default_code () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF NEW.code IS NULL THEN
        NEW.code := private.default_tenant_code(NEW.display_name);
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tenant_default_code BEFORE INSERT ON public.tenant FOR EACH ROW
EXECUTE FUNCTION private.tenant_default_code ();

REVOKE ALL ON FUNCTION private.tenant_default_code () FROM PUBLIC, anon, authenticated;

-- Whether the user owns the company at the root of the tenant's tree. A super admin is not an
-- owner here; the callers check that apart.
CREATE OR REPLACE FUNCTION private.owns_company (user_id UUID, tenant_id UUID) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT EXISTS (
        SELECT 1
        FROM private.entitlements(ARRAY[owns_company.tenant_id]) e
        JOIN public.tenant_owner o ON o.tenant_id = e.company_id
        WHERE o.user_id = owns_company.user_id
    );
$$;

REVOKE ALL ON FUNCTION private.owns_company (UUID, UUID) FROM PUBLIC, anon, authenticated;

-- Provider relationships
CREATE TABLE IF NOT EXISTS public.provider_relationship (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   -- The provider.
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   client_tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE RESTRICT,
   client_code TEXT NOT NULL CHECK (client_code ~ '^[A-Z]{3}$'),
   client_name TEXT NOT NULL,
   provider_name TEXT NOT NULL,
   procurement_model public.procurement_model NOT NULL,
   status public.relationship_status NOT NULL DEFAULT 'active',
   accepted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   ended_at TIMESTAMPTZ,
   -- Contract terms.
   commercial_model public.commercial_model,
   packages TEXT[] NOT NULL DEFAULT '{}' CHECK (packages <@ ARRAY['A0', 'A1', 'A2', 'B', 'C', 'D', 'E']::TEXT[]),
   contract_status public.contract_status NOT NULL DEFAULT 'lead',
   contract_accepted_on DATE,
   contract_document_id UUID,
   start_on DATE,
   deposit_rate NUMERIC(5, 2) CHECK (deposit_rate BETWEEN 0 AND 100),
   extra_cost_rule TEXT,
   eu_responsible_person TEXT,
   -- Provider-internal.
   restricted_drive_url TEXT,
   notes TEXT,
   created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
   CONSTRAINT provider_relationship_id_tenant_id_key UNIQUE (id, tenant_id),
   -- Target of the provider rows that name their client (tenant_id, client_tenant_id).
   CONSTRAINT provider_relationship_pair_key UNIQUE (tenant_id, client_tenant_id),
   CONSTRAINT provider_relationship_client_code_key UNIQUE (tenant_id, client_code),
   CONSTRAINT provider_relationship_not_self CHECK (tenant_id <> client_tenant_id),
   CONSTRAINT provider_relationship_ended_at CHECK ((status = 'ended') = (ended_at IS NOT NULL)),
   CONSTRAINT provider_relationship_contract_document_fkey FOREIGN KEY (contract_document_id, tenant_id) REFERENCES public.document (id, tenant_id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_provider_relationship_client ON public.provider_relationship (client_tenant_id);

CREATE OR REPLACE TRIGGER set_updated_at BEFORE
UPDATE ON public.provider_relationship FOR EACH ROW
EXECUTE FUNCTION private.set_updated_at ();

-- provider_name is the provider's display name at creation, whatever was sent. SECURITY DEFINER:
-- the tenant row may not be readable to the inserting caller.
CREATE OR REPLACE FUNCTION private.provider_relationship_provider_name () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    NEW.provider_name := (SELECT t.display_name FROM public.tenant t WHERE t.id = NEW.tenant_id);
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER provider_relationship_provider_name BEFORE INSERT ON public.provider_relationship FOR EACH ROW
EXECUTE FUNCTION private.provider_relationship_provider_name ();

REVOKE ALL ON FUNCTION private.provider_relationship_provider_name () FROM PUBLIC, anon, authenticated;

-- Who the relationship joins and when it was accepted never change; an ended relationship stays
-- ended (ending sets ended_at); a client_code is fixed once a code was drawn under it. SECURITY
-- DEFINER for code_sequence, which callers cannot read.
CREATE OR REPLACE FUNCTION private.provider_relationship_guard () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.client_tenant_id IS DISTINCT FROM OLD.client_tenant_id
       OR NEW.accepted_at IS DISTINCT FROM OLD.accepted_at THEN
        RAISE EXCEPTION 'relationship_immutable' USING ERRCODE = 'check_violation';
    END IF;

    IF OLD.status = 'ended' THEN
        IF NEW.status IS DISTINCT FROM 'ended' THEN
            RAISE EXCEPTION 'relationship_ended_final' USING ERRCODE = 'check_violation';
        END IF;
        NEW.ended_at := OLD.ended_at;
    ELSIF NEW.status = 'ended' THEN
        NEW.ended_at := now();
    END IF;

    IF NEW.client_code IS DISTINCT FROM OLD.client_code
       AND EXISTS (SELECT 1 FROM public.code_sequence s WHERE s.tenant_id = OLD.tenant_id AND s.scope = OLD.client_code) THEN
        RAISE EXCEPTION 'client_code_immutable' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER provider_relationship_guard BEFORE
UPDATE ON public.provider_relationship FOR EACH ROW
EXECUTE FUNCTION private.provider_relationship_guard ();

REVOKE ALL ON FUNCTION private.provider_relationship_guard () FROM PUBLIC, anon, authenticated;

-- The terms of the relationship are management's: the procurement model (it decides what is
-- shared with the client), the client's name, and the contract terms. A caller changes them only
-- while holding the update permission on settings in the provider's tenant; the update right on
-- relationships alone covers the rest (notes). SECURITY DEFINER for the permission lookup
-- (private.tenants_permitting reads roles the caller may not read). A request without a user
-- (migrations, seed, service role) is not limited.
--
-- Whoever writes it, an existing relationship never moves from 'client' to 'provider' procurement
-- (procurement_model_widen_forbidden): that would start sharing the provider's procurement into a
-- client that never accepted it. Only a new relationship (the invitation flow) starts as
-- 'provider'. Moving to 'client' (decision 13, less sharing) stays under the rule above.
CREATE OR REPLACE FUNCTION private.relationship_contract_guard () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
BEGIN
    IF OLD.procurement_model = 'client' AND NEW.procurement_model = 'provider' THEN
        RAISE EXCEPTION 'procurement_model_widen_forbidden' USING ERRCODE = 'check_violation';
    END IF;

    IF (NEW.procurement_model IS DISTINCT FROM OLD.procurement_model
        OR NEW.client_name IS DISTINCT FROM OLD.client_name
        OR NEW.commercial_model IS DISTINCT FROM OLD.commercial_model
        OR NEW.packages IS DISTINCT FROM OLD.packages
        OR NEW.contract_status IS DISTINCT FROM OLD.contract_status
        OR NEW.eu_responsible_person IS DISTINCT FROM OLD.eu_responsible_person
        OR NEW.contract_accepted_on IS DISTINCT FROM OLD.contract_accepted_on
        OR NEW.contract_document_id IS DISTINCT FROM OLD.contract_document_id
        OR NEW.start_on IS DISTINCT FROM OLD.start_on
        OR NEW.deposit_rate IS DISTINCT FROM OLD.deposit_rate
        OR NEW.extra_cost_rule IS DISTINCT FROM OLD.extra_cost_rule
        OR NEW.restricted_drive_url IS DISTINCT FROM OLD.restricted_drive_url)
       AND auth.uid() IS NOT NULL
       AND cardinality(private.tenants_permitting(auth.uid(), ARRAY[NEW.tenant_id], 'public.setting', 'update')) = 0 THEN
        RAISE EXCEPTION 'relationship_contract_restricted' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER relationship_contract_guard BEFORE
UPDATE ON public.provider_relationship FOR EACH ROW
EXECUTE FUNCTION private.relationship_contract_guard ();

REVOKE ALL ON FUNCTION private.relationship_contract_guard () FROM PUBLIC, anon, authenticated;

-- Whether the provider may name the client on a row: always without a client; with one, the pair
-- must have a relationship, and a new link (p_new) needs it active with the provider procuring.
-- Existing rows (history) only need the relationship to exist.
CREATE OR REPLACE FUNCTION private.relationship_allows (p_provider UUID, p_client UUID, p_new BOOLEAN) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT p_client IS NULL OR EXISTS (
        SELECT 1
        FROM public.provider_relationship r
        WHERE r.tenant_id = p_provider
          AND r.client_tenant_id = p_client
          AND (NOT coalesce(p_new, TRUE) OR (r.status = 'active' AND r.procurement_model = 'provider'))
    );
$$;

REVOKE ALL ON FUNCTION private.relationship_allows (UUID, UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- The status of the pair's relationship; NULL when there is none.
CREATE OR REPLACE FUNCTION private.relationship_status (p_provider UUID, p_client UUID) RETURNS public.relationship_status LANGUAGE sql STABLE SECURITY DEFINER
SET
   search_path = '' AS $$
    SELECT r.status
    FROM public.provider_relationship r
    WHERE r.tenant_id = p_provider AND r.client_tenant_id = p_client;
$$;

REVOKE ALL ON FUNCTION private.relationship_status (UUID, UUID) FROM PUBLIC, anon, authenticated;

-- Ends a relationship: allowed to the provider side holding the update right on relationships, or
-- to the owner of the client company. An unknown id is refused like a forbidden one, so ids cannot
-- be probed. Ending an ended relationship changes nothing. Returns nothing: the row holds
-- provider-internal fields the client owner may not read.
CREATE OR REPLACE FUNCTION public.end_provider_relationship (relationship_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    v_provider UUID;
    v_client UUID;
BEGIN
    SELECT r.tenant_id, r.client_tenant_id INTO v_provider, v_client
    FROM public.provider_relationship r
    WHERE r.id = end_provider_relationship.relationship_id;

    IF v_provider IS NULL
       OR auth.uid() IS NULL
       OR NOT (
           coalesce(cardinality(private.tenants_permitting(auth.uid(), ARRAY[v_provider], 'public.provider_relationship', 'update')), 0) > 0
           OR coalesce(private.owns_company(auth.uid(), v_client), FALSE)
       ) THEN
        RAISE EXCEPTION 'relationship_end_forbidden' USING ERRCODE = 'insufficient_privilege';
    END IF;

    UPDATE public.provider_relationship r
    SET status = 'ended'
    WHERE r.id = end_provider_relationship.relationship_id AND r.status = 'active';
END;
$$;

REVOKE ALL ON FUNCTION public.end_provider_relationship (UUID) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.end_provider_relationship (UUID) TO authenticated;

-- The tenant's own records
CREATE TABLE IF NOT EXISTS public.contact (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   name TEXT NOT NULL,
   role TEXT,
   email TEXT,
   phone TEXT,
   can_approve BOOLEAN NOT NULL DEFAULT FALSE,
   CONSTRAINT contact_id_tenant_id_key UNIQUE (id, tenant_id)
);

CREATE INDEX IF NOT EXISTS idx_contact_tenant ON public.contact (tenant_id);

CREATE TABLE IF NOT EXISTS public.warehouse (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   display_name TEXT NOT NULL,
   type public.warehouse_type NOT NULL DEFAULT 'own',
   country TEXT,
   city TEXT,
   address TEXT,
   postal_code TEXT,
   dock_hours TEXT,
   appointment_rule TEXT,
   pallet_standard TEXT,
   receiving_person TEXT,
   is_default BOOLEAN NOT NULL DEFAULT FALSE,
   CONSTRAINT warehouse_id_tenant_id_key UNIQUE (id, tenant_id)
);

CREATE INDEX IF NOT EXISTS idx_warehouse_tenant ON public.warehouse (tenant_id);

-- At most one default warehouse per tenant.
CREATE UNIQUE INDEX IF NOT EXISTS warehouse_one_default ON public.warehouse (tenant_id)
WHERE
   is_default;

CREATE TABLE IF NOT EXISTS public.platform_account (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   -- Global reference data (no tenant_id), so a plain foreign key.
   platform_id TEXT NOT NULL REFERENCES public.platform (id),
   -- ISO 3166-1 alpha-2 codes of the platform's countries the tenant sells in.
   countries TEXT[] NOT NULL DEFAULT '{}',
   account_holder TEXT,
   access public.platform_access NOT NULL DEFAULT 'none',
   notes TEXT,
   CONSTRAINT platform_account_tenant_platform_key UNIQUE (tenant_id, platform_id),
   CONSTRAINT platform_account_id_tenant_id_key UNIQUE (id, tenant_id)
);

CREATE TABLE IF NOT EXISTS public.brand (
   id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
   tenant_id UUID NOT NULL REFERENCES public.tenant (id) ON DELETE CASCADE,
   name TEXT NOT NULL,
   registration_status TEXT,
   brand_program_status TEXT,
   gs1_prefix_owner TEXT,
   CONSTRAINT brand_id_tenant_id_key UNIQUE (id, tenant_id)
);

CREATE INDEX IF NOT EXISTS idx_brand_tenant ON public.brand (tenant_id);

SELECT
   private.enable_tenant_level_security (t_name)
FROM
   unnest(ARRAY['provider_relationship', 'brand', 'contact', 'warehouse', 'platform_account']) AS t_name;

SELECT
   private.audit_enable ('public.provider_relationship'::REGCLASS);

SELECT
   private.audit_enable ('public.brand'::REGCLASS);

SELECT
   private.audit_enable ('public.contact'::REGCLASS);

SELECT
   private.audit_enable ('public.warehouse'::REGCLASS);

SELECT
   private.audit_enable ('public.platform_account'::REGCLASS);

-- Module row (from 015_ops_core.sql), kept here should this migration run alone.
INSERT INTO
   public.module (id, is_core, position)
VALUES
   ('client', TRUE, 130)
ON CONFLICT (id) DO NOTHING;

-- Permissions. Inserting a permission creates its RLS policies (see private.manage_policies).
-- Relationships are neither inserted (an accepted invitation makes them) nor deleted by users; they
-- are ended (public.end_provider_relationship).
INSERT INTO
   public.permission (resource_name, group_name, command, kind, bypass, throws_error, resource_condition)
VALUES
   ('public.provider_relationship', 'client', 'select', 'read', FALSE, FALSE, NULL),
   ('public.provider_relationship', 'client', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.brand', 'ops_setting', 'select', 'read', FALSE, FALSE, NULL),
   ('public.brand', 'ops_setting', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.brand', 'ops_setting', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.brand', 'ops_setting', 'delete', 'modify', FALSE, TRUE, NULL),
   ('public.contact', 'ops_setting', 'select', 'read', FALSE, FALSE, NULL),
   ('public.contact', 'ops_setting', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.contact', 'ops_setting', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.contact', 'ops_setting', 'delete', 'modify', FALSE, TRUE, NULL),
   ('public.warehouse', 'ops_setting', 'select', 'read', FALSE, FALSE, NULL),
   ('public.warehouse', 'ops_setting', 'insert', 'create', FALSE, TRUE, NULL),
   ('public.warehouse', 'ops_setting', 'update', 'modify', FALSE, TRUE, NULL),
   ('public.warehouse', 'ops_setting', 'delete', 'modify', FALSE, TRUE, NULL)
ON CONFLICT ON CONSTRAINT unique_permission_resource_command DO NOTHING;

-- The built-in owner role has every permission (see 008_init_reference_data.sql).
INSERT INTO
   public.role_permission (role_id, permission_id)
SELECT
   r.id,
   p.id
FROM
   public.role r,
   public.permission p
WHERE
   r.display_name = 'owner'
   AND r.tenant_id IS NULL
   AND p.resource_name IN ('public.provider_relationship', 'public.brand', 'public.contact', 'public.warehouse')
ON CONFLICT DO NOTHING;
