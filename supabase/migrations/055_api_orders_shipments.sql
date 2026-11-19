-- 055: masked api views for sourcing, purchase orders and shipments. The sourcing and purchase_order
-- runs create api.supplier(api.sourcing), api.supplier(api.purchase_order) and their reverses because
-- api.supplier already exists (054).
SELECT private.enable_field_security (t)
FROM unnest(ARRAY['sourcing', 'purchase_order', 'purchase_order_line', 'purchase_order_payment',
                  'purchase_order_update', 'shipment', 'shipment_event', 'shipment_line',
                  'shipment_purchase_order']) AS t;
