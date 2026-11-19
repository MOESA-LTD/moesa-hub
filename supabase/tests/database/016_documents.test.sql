CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

BEGIN;

SELECT plan(14);

SELECT has_table('public', 'document', 'document table');

SELECT has_function('private', 'document_check_entity', 'document_check_entity');

-- The rest runs as a signed-in owner of a demo company. Its id is kept in a setting: the signed-in
-- user cannot call private functions.
-- Fixture, built here as postgres (the seed is not on the new model yet): a provider company with its
-- client company and a relationship between them, an owner of each of the two, and a third company.
INSERT INTO public.plan (display_name, is_active) VALUES ('Documents test plan', TRUE);

INSERT INTO public.tenant (id, display_name) VALUES
    ('00000000-0000-4000-8000-000000000011', 'Documents Co'),
    ('00000000-0000-4000-8000-000000000012', 'Documents Client'),
    ('00000000-0000-4000-8000-000000000013', 'Other Documents Co');

INSERT INTO public.user (id, email) VALUES
    ('00000000-0000-4000-8000-000000000014', 'owner@documents.test'),
    ('00000000-0000-4000-8000-000000000017', 'client@documents.test'),
    ('00000000-0000-4000-8000-000000000018', 'other@documents.test');

INSERT INTO public.tenant_owner (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000000014', '00000000-0000-4000-8000-000000000011'),
    ('00000000-0000-4000-8000-000000000017', '00000000-0000-4000-8000-000000000012'),
    ('00000000-0000-4000-8000-000000000018', '00000000-0000-4000-8000-000000000013');

INSERT INTO public.tenant_user (user_id, tenant_id) VALUES
    ('00000000-0000-4000-8000-000000000014', '00000000-0000-4000-8000-000000000011'),
    ('00000000-0000-4000-8000-000000000017', '00000000-0000-4000-8000-000000000012'),
    ('00000000-0000-4000-8000-000000000018', '00000000-0000-4000-8000-000000000013');

INSERT INTO public.provider_relationship (id, tenant_id, client_tenant_id, client_code, client_name, procurement_model)
VALUES ('00000000-0000-4000-8000-000000000019', '00000000-0000-4000-8000-000000000011',
        '00000000-0000-4000-8000-000000000012', 'DOC', 'Documents Client', 'provider');

SELECT set_config('test.tenant_id', '00000000-0000-4000-8000-000000000011', TRUE);

SELECT hasnt_column('public', 'document', 'customer_id', 'document has no customer');

SELECT private.impersonate('00000000-0000-4000-8000-000000000014', current_setting('test.tenant_id')::UUID);

-- The documents below belong to a product of the company.
INSERT INTO api.product (id, tenant_id, sku, display_name)
VALUES ('00000000-0000-4000-8000-000000000016', current_setting('test.tenant_id')::UUID, 'DOC-001', 'Documents product');

SELECT lives_ok(
    $$
        INSERT INTO api.document (tenant_id, entity_type, entity_id, type, version, url, file_name)
        VALUES (current_setting('test.tenant_id')::UUID, 'product', '00000000-0000-4000-8000-000000000016', 'spec_sheet', 1,
                'https://example.test/spec-v1.pdf', 'spec-v1.pdf')
    $$,
    'v1 attaches to its product'
);

INSERT INTO api.document (tenant_id, entity_type, entity_id, type, version, url, file_name)
VALUES (current_setting('test.tenant_id')::UUID, 'product', '00000000-0000-4000-8000-000000000016', 'spec_sheet', 2,
        'https://example.test/spec-v2.pdf', 'spec-v2.pdf');

SELECT is(
    (SELECT status::TEXT FROM api.document
     WHERE entity_id = '00000000-0000-4000-8000-000000000016' AND type = 'spec_sheet' AND version = 1),
    'superseded',
    'a new version supersedes the older one'
);

SELECT is(
    (SELECT status::TEXT FROM api.document
     WHERE entity_id = '00000000-0000-4000-8000-000000000016' AND type = 'spec_sheet' AND version = 2),
    'draft',
    'the new version keeps its own status'
);

SELECT throws_ok(
    $$
        INSERT INTO api.document (tenant_id, entity_type, entity_id, type, version, url, file_name, status,
                                     is_signed, is_stamped, sent_from_official_email)
        VALUES (current_setting('test.tenant_id')::UUID, 'product', '00000000-0000-4000-8000-000000000016', 'contract', 1,
                'https://example.test/contract.pdf', 'contract.pdf', 'signed', TRUE, TRUE, TRUE)
    $$,
    '23514',
    'document_signed_incomplete',
    'signed needs signature, stamp, official e-mail and issue date'
);

SELECT throws_ok(
    $$
        INSERT INTO api.document (tenant_id, entity_type, entity_id, type, version, url, file_name, status,
                                     is_signed, is_stamped, sent_from_official_email, issued_on)
        VALUES (current_setting('test.tenant_id')::UUID, 'product', '00000000-0000-4000-8000-000000000016', 'contract', 1,
                'https://example.test/contract.pdf', 'contract.pdf', 'signed', TRUE, FALSE, TRUE, '2026-11-03')
    $$,
    '23514',
    'document_signed_incomplete',
    'signed needs the stamp'
);

SELECT lives_ok(
    $$
        INSERT INTO api.document (tenant_id, entity_type, entity_id, type, version, url, file_name, status,
                                     is_signed, is_stamped, sent_from_official_email, issued_on)
        VALUES (current_setting('test.tenant_id')::UUID, 'product', '00000000-0000-4000-8000-000000000016', 'contract', 1,
                'https://example.test/contract.pdf', 'contract.pdf', 'signed', TRUE, TRUE, TRUE, '2026-11-03')
    $$,
    'signed with every requirement met'
);

SELECT throws_ok(
    $$ DELETE FROM api.document WHERE entity_id = '00000000-0000-4000-8000-000000000016' $$,
    '42501',
    NULL,
    'documents are never deleted'
);

-- A contract belongs to the provider relationship, which lives in the provider's tenant.
SELECT lives_ok(
    $$
        INSERT INTO api.document (tenant_id, entity_type, entity_id, type, version, url, file_name)
        VALUES (current_setting('test.tenant_id')::UUID, 'provider_relationship', '00000000-0000-4000-8000-000000000019',
                'contract', 7, 'https://example.test/relationship.pdf', 'relationship.pdf')
    $$,
    'a contract document attaches to the provider relationship'
);

-- As postgres, so only the entity rule can refuse it: the relationship is in the provider's tenant, not here.
RESET ROLE;

SELECT throws_ok(
    $$
        INSERT INTO public.document (tenant_id, entity_type, entity_id, type, version, url, file_name)
        VALUES ('00000000-0000-4000-8000-000000000013', 'provider_relationship', '00000000-0000-4000-8000-000000000019',
                'contract', 7, 'https://example.test/relationship.pdf', 'relationship.pdf')
    $$,
    '23503',
    'document_entity_missing',
    'another tenant cannot attach to the relationship'
);

RESET ROLE;

-- Another company's owner sees none of them.
RESET ROLE;

SELECT private.impersonate('00000000-0000-4000-8000-000000000018', '00000000-0000-4000-8000-000000000013');

SELECT is(
    (SELECT count(*)::INT FROM api.document WHERE entity_id = '00000000-0000-4000-8000-000000000016'),
    0,
    'another tenant does not see the documents'
);

-- Its own version of the same entity, type and a higher version supersedes nothing of Atlas's. No
-- product of the other company has that id, so the entity check is switched off for this insert (as postgres,
-- rolled back with the test).
RESET ROLE;

ALTER TABLE public.document DISABLE TRIGGER document_check_entity;

SELECT private.impersonate('00000000-0000-4000-8000-000000000018', '00000000-0000-4000-8000-000000000013');

INSERT INTO api.document (tenant_id, entity_type, entity_id, type, version, url, file_name)
VALUES ('00000000-0000-4000-8000-000000000013', 'product',
        '00000000-0000-4000-8000-000000000016', 'spec_sheet', 999, 'https://example.test/nova.pdf', 'nova.pdf');

RESET ROLE;

SELECT private.impersonate('00000000-0000-4000-8000-000000000014', current_setting('test.tenant_id')::UUID);

SELECT is(
    (SELECT status::TEXT FROM api.document
     WHERE entity_id = '00000000-0000-4000-8000-000000000016' AND type = 'spec_sheet' AND version = 2),
    'draft',
    'another tenant''s higher version does not supersede this tenant''s documents'
);

SELECT * FROM finish();

ROLLBACK;
