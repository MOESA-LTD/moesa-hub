-- 054: masked api views for the tenant-level company tables (the provider relationship, brand,
-- contact, warehouse and platform account of a tenant) and the supplier tables. sourcing follows in
-- 055, after api.supplier exists, so its supplier relationship across the sensitive link (R4) is
-- created with it.
SELECT private.enable_field_security (t)
FROM unnest(ARRAY['provider_relationship', 'brand', 'contact', 'warehouse', 'platform_account', 'supplier',
                  'supplier_contact']) AS t;
