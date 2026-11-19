-- 075: plan module tiers. Until now every business module was core (015, decision 2 of the modules
-- spec: the panel was MOESA's own tool, so plans were left alone). With customers as tenants
-- (2026-11-18) a plan has to mean something, so the business modules are split into tiers:
--
--   core (every plan)  branch, user, role, ops_setting, document, media, supplier, client,
--                      product, transfer: what every other module points at (a product, a
--                      supplier, a document, the provider relationship), and the copy tool,
--                      whose record lives in the target tenant.
--   Basic (client)     + purchase_order, shipment, incident, change_request: a client follows the
--                      orders and shipments its provider shares with it (a shared row is read
--                      through the client's own plan, 067), and raises incidents and change
--                      requests on them (068).
--   Pro                + project, market_matrix, listing, audit_log.
--   Enterprise         every module, without limits.
--
-- public.module.requires  The modules a module cannot work without, besides the core ones: a
--                         shipment carries order lines (shipment_line → purchase_order_line, NOT
--                         NULL) and a listing is published from a market cell
--                         (listing_submission → market_cell, NOT NULL). Nullable links (a cell's
--                         or a request's project, an order's project) are not requirements: the
--                         module works without the other and the link stays empty.
-- private.check_plan_requirements()
--                         Raises plan_module_requires (422) when a plan holds a module without one
--                         it requires (core modules always count as held). Statement-level, after
--                         every write to plan_module and to module's is_core/requires; save_plan
--                         deletes the dropped modules before inserting the new ones, and the rows
--                         left between the two are valid whenever the old and the new set are.
--
-- Downgrading keeps the data: a module outside the plan is read-locked by RLS (entitlements, 013)
-- and its pages show as locked; moving back up shows it again. A transfer does not put data where
-- it would be locked: public.transfer_products (073) refuses a package with rows of a module the
-- target's plan lacks (transfer_target_plan_lacks_module), in the rehearsal and in the run.

-- 1. Requirements.
ALTER TABLE public.module
ADD COLUMN requires TEXT[] NOT NULL DEFAULT '{}';

INSERT INTO public.field_class (resource_name, field, class)
VALUES ('public.module', 'requires', 'open')
ON CONFLICT DO NOTHING;

SELECT private.enable_field_security ('module');

-- 2. The tiers. Re-runnable: the flags are set, the plan rows inserted only when missing.
UPDATE public.module
SET is_core = (id IN ('branch', 'user', 'role', 'ops_setting', 'document', 'media', 'supplier', 'client', 'product', 'transfer'));

UPDATE public.module SET requires = ARRAY['purchase_order'] WHERE id = 'shipment';

UPDATE public.module SET requires = ARRAY['market_matrix'] WHERE id = 'listing';

UPDATE public.plan
SET description = CASE display_name
        WHEN 'Basic' THEN 'Products, suppliers and documents, with the orders and shipments procured for you, their incidents and change requests. A single location.'
        WHEN 'Pro' THEN 'Basic with projects and gates, the market matrix, listings and the change history, for a few branches.'
        WHEN 'Enterprise' THEN 'Every module, without limits.'
    END
WHERE display_name IN ('Basic', 'Pro', 'Enterprise');

INSERT INTO public.plan_module (plan_id, module_id)
SELECT p.id, m.id
FROM public.plan p
JOIN public.module m ON NOT m.is_core
WHERE p.display_name IN ('Pro', 'Enterprise')
   OR (p.display_name = 'Basic' AND m.id IN ('purchase_order', 'shipment', 'incident', 'change_request'))
ON CONFLICT DO NOTHING;

-- 3. The guard.
CREATE OR REPLACE FUNCTION private.check_plan_requirements () RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET
   search_path = '' AS $$
DECLARE
    missing RECORD;
BEGIN
    SELECT p.display_name AS plan_name, pm.module_id, r.required_id INTO missing
    FROM public.plan_module pm
    JOIN public.plan p ON p.id = pm.plan_id
    JOIN public.module m ON m.id = pm.module_id
    CROSS JOIN LATERAL unnest(m.requires) AS r (required_id)
    WHERE NOT EXISTS (SELECT 1 FROM public.module c WHERE c.id = r.required_id AND c.is_core)
      AND NOT EXISTS (SELECT 1 FROM public.plan_module o WHERE o.plan_id = pm.plan_id AND o.module_id = r.required_id)
    ORDER BY p.position, pm.module_id
    LIMIT 1;

    IF FOUND THEN
        RAISE SQLSTATE 'PGRST' USING
            MESSAGE = json_build_object(
                'code', 'P0001',
                'message', 'plan_module_requires',
                'details', json_build_object('plan', missing.plan_name, 'module', missing.module_id, 'requires', missing.required_id)
            )::TEXT,
            DETAIL = json_build_object('status', 422, 'headers', json_build_object())::TEXT;
    END IF;
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION private.check_plan_requirements () FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER check_plan_requirements
AFTER INSERT OR UPDATE OR DELETE ON public.plan_module FOR EACH STATEMENT
EXECUTE FUNCTION private.check_plan_requirements ();

CREATE OR REPLACE TRIGGER check_plan_requirements
AFTER UPDATE OF is_core, requires ON public.module FOR EACH STATEMENT
EXECUTE FUNCTION private.check_plan_requirements ();
