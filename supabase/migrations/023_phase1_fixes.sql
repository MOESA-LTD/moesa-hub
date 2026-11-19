-- Phase 1 fixes (final review): rules the business tables still lacked.
--
-- document               An approved spec sheet needs the signature, stamp, official e-mail and
--                        date a signed document does (private.document_signed_requires), so an
--                        unsigned spec sheet no longer counts as product evidence; other approved
--                        documents (a gate approval is an e-mail or e-signature record) do not. A superseded document stays superseded, and
--                        what a document is (its record, type, version and tenant) never changes
--                        (private.document_transition).
-- product_with_evidence  The product list: every product column plus its evidence
--                        (public.product_evidence), so the list can filter on a signed spec sheet.
--
-- Each rule is a check_violation whose message is the rule's code:
--   document_signed_incomplete    a signed document, or an approved spec sheet, lacks signature,
--                                 stamp, official e-mail or date
--   document_superseded_sticky    a superseded document cannot get another status
--   document_identity_immutable   a document's entity_type, entity_id, type, version or tenant
--                                 changed
-- (The contract-terms rule moved to the provider relationship: private.relationship_contract_guard,
-- 018_tenant_relations.sql.)

-- Signed means signed, stamped, sent from the official e-mail and dated; so does an approved spec
-- sheet, the product's evidence.
CREATE OR REPLACE FUNCTION private.document_signed_requires () RETURNS TRIGGER LANGUAGE plpgsql
SET
   search_path = '' AS $$
BEGIN
    IF (NEW.status = 'signed' OR (NEW.status = 'approved' AND NEW.type = 'spec_sheet'))
       AND NOT (NEW.is_signed AND NEW.is_stamped AND NEW.sent_from_official_email AND NEW.issued_on IS NOT NULL) THEN
        RAISE EXCEPTION 'document_signed_incomplete' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- A superseded document stays superseded, and a document never moves to another record, type,
-- version or tenant: a new version is a new row.
CREATE OR REPLACE FUNCTION private.document_transition () RETURNS TRIGGER LANGUAGE plpgsql
SET
   search_path = '' AS $$
BEGIN
    IF OLD.status = 'superseded' AND NEW.status <> 'superseded' THEN
        RAISE EXCEPTION 'document_superseded_sticky' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.entity_type IS DISTINCT FROM OLD.entity_type
       OR NEW.entity_id IS DISTINCT FROM OLD.entity_id
       OR NEW.type IS DISTINCT FROM OLD.type
       OR NEW.version IS DISTINCT FROM OLD.version
       OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
        RAISE EXCEPTION 'document_identity_immutable' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER document_transition BEFORE
UPDATE ON public.document FOR EACH ROW
EXECUTE FUNCTION private.document_transition ();

REVOKE ALL ON FUNCTION private.document_transition () FROM PUBLIC, anon, authenticated;

-- The product list: the product and its evidence, as the caller may read them.
CREATE OR REPLACE VIEW public.product_with_evidence
WITH
   (security_invoker = TRUE) AS
SELECT
   p.*,
   e.has_signed_spec,
   e.spec_version,
   e.compliance_complete
FROM
   public.product p
   LEFT JOIN public.product_evidence e ON e.product_id = p.id;

COMMENT ON VIEW public.product_with_evidence IS 'Every product column plus its evidence (public.product_evidence): whether it has a signed or approved spec sheet, the highest such version, and whether its compliance is complete. Read by the product list, which filters on has_signed_spec.';

GRANT SELECT ON public.product_with_evidence TO authenticated;
