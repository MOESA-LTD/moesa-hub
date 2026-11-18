CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- 066: the client-visible field set. A shared table carries client_tenant_id under the
-- (tenant_id, client_tenant_id) link to provider_relationship; only its client_visible fields reach
-- the client tenant. Raw purchase_order.status stays provider-only (Q1: the client sees a derived
-- client_status); sourcing.manufacturer_art_no is client-visible (Q3).
BEGIN;

SELECT plan(10);

SELECT set_eq($$ SELECT c.relname::TEXT FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r' AND private.is_shared_table(c.relname) $$,
   ARRAY['provider_relationship','sourcing','purchase_order','purchase_order_line','shipment','shipment_event','shipment_line','shipment_purchase_order'], 'the shared tables');
SELECT is_empty($$ SELECT resource_name, field FROM public.field_class WHERE client_visible AND NOT private.is_shared_table(split_part(resource_name, '.', 2)) $$, 'client_visible only on shared tables');
SELECT set_eq($$ SELECT field FROM public.field_class WHERE resource_name = 'public.purchase_order' AND client_visible $$,
   ARRAY['id','tenant_id','client_tenant_id','code','project_id','project_tenant_id','project_code','ready_on','created_at','updated_at','client_status'], 'purchase_order client-visible set: raw status provider-only, the derived client_status client-visible (Q1, 067)');
SELECT set_eq($$ SELECT field FROM public.field_class WHERE resource_name = 'public.purchase_order_line' AND client_visible $$,
   ARRAY['id','tenant_id','client_tenant_id','purchase_order_id','position','product_id','product_tenant_id','product_sku','product_name','quantity','sell_price_eur','created_at','updated_at'], 'line client-visible set');
SELECT is_empty($$ SELECT field FROM public.field_class WHERE client_visible AND group_name IN ('cost','supplier_identity','supplier_contact','supplier_terms','finance','internal_note')
   AND (resource_name, field) <> ('public.sourcing', 'manufacturer_art_no') $$, 'no cost, supplier, finance or internal note is client-visible (bar manufacturer_art_no, Q3)');
SELECT is_empty($$ SELECT 1 FROM public.field_class WHERE resource_name IN ('public.purchase_order_payment','public.purchase_order_update','public.supplier','public.supplier_contact') AND client_visible $$, 'payments, updates and suppliers are never shared');

SELECT set_eq($$ SELECT resource_name || '.' || field FROM public.field_class WHERE client_visible
   AND resource_name IN ('public.provider_relationship','public.sourcing','public.shipment','public.shipment_event') $$,
   ARRAY(SELECT 'public.provider_relationship.' || f FROM unnest(ARRAY['id','tenant_id','client_tenant_id','client_code','client_name','provider_name','procurement_model','status','accepted_at','ended_at','commercial_model','packages','contract_status','contract_accepted_on','start_on','deposit_rate','extra_cost_rule','eu_responsible_person','created_at','updated_at']) f
   UNION ALL SELECT 'public.sourcing.' || f FROM unnest(ARRAY['id','tenant_id','client_tenant_id','product_tenant_id','product_id','product_sku','product_name','sell_price_eur','price_list_version','manufacturer_art_no','created_at','updated_at']) f
   UNION ALL SELECT 'public.shipment.' || f FROM unnest(ARRAY['id','tenant_id','client_tenant_id','code','status','mode','carrier','container_no','seal_no','delivery_warehouse_id','warehouse_tenant_id','delivery_address','ready_on','booking_confirmed_on','etd','eta','customs_cleared_on','planned_delivery_on','delivered_at','carton_count','pallet_count','volume_m3','gross_kg','accepted_on','quantity_matches','has_damage','dispute_deadline_at','created_at','updated_at']) f
   UNION ALL SELECT 'public.shipment_event.' || f FROM unnest(ARRAY['id','tenant_id','client_tenant_id','shipment_id','happened_at','step','created_at','updated_at']) f),
   'relationship, sourcing, shipment and event client-visible sets');
SELECT is_empty($$ SELECT resource_name, field FROM public.field_class WHERE resource_name IN ('public.shipment_line','public.shipment_purchase_order') AND NOT client_visible $$,
   'every shipment_line and shipment_purchase_order column is client-visible');
SELECT results_eq($$ SELECT resource_name, field, rights_column FROM public.field_class WHERE rights_column IS NOT NULL ORDER BY 1, 2 $$,
   $$ VALUES ('public.change_request', 'cost_impact', 'guard_tenant_id'), ('public.change_request', 'cost_payer', 'guard_tenant_id'),
             ('public.incident_log', 'cost_amount', 'guard_tenant_id'), ('public.incident_log', 'cost_currency', 'guard_tenant_id'),
             ('public.incident_log', 'cost_payer', 'guard_tenant_id') $$,
   'the rights columns: the change request and incident log cost (068, Task 6)');
SELECT is_empty($$ SELECT unnest(ARRAY['client_visible','rights_column']) EXCEPT
   SELECT column_name::TEXT FROM information_schema.columns WHERE table_schema = 'api' AND table_name = 'field_class' $$,
   'api.field_class exposes client_visible and rights_column');

SELECT * FROM finish();
ROLLBACK;
