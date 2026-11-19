# Customer = tenant: design (2026-11-18)

## Why this exists

Phase 1 made the wrong call: "a customer is a row in a `customer` table inside the single MOESA tenant". The owner always meant that **every customer is a tenant**, an independent company in the panel. Everything built since then hangs on `customer_id`: products, purchase orders, shipments, projects, incidents, change requests, documents, market cells, Amazon accounts, the M21 customer transfer, the `customer_viewer` portal role and the field classification. This design removes the customer concept and replaces it with tenants, plus a provider relationship between MOESA and the customers it serves.

Scale today: `customer_id` sits on 32 tables and views (local DB). The customer concept is named in 135 app files and 36 migrations. There are five `customer*` tables: `customer`, `customer_brand`, `customer_contact`, `customer_platform_account` and `customer_warehouse`.

## Owner decisions (2026-11-18, in the owner's words where quoted)

1. **A customer is a tenant.** There is no separate customer structure. "Tüm bilgiler tenant'a ait kalıyor, `müşterinin kiracısı` diye bir şey yok."
2. **MOESA staff join a customer's tenant by invitation.** The customer's own users see what their roles allow.
3. **Each tenant defines its own suppliers.** There is no shared supplier catalog.
4. **Multi-tenant viewing stays as it is.** Staff pick several tenants in the existing scope picker to see several customers at once.
5. **A customer tenant is an independent company**, with its own subscription and settings. It is not a branch under MOESA LTD.
6. **The customer signs up by themselves and owns their tenant.** They then invite MOESA staff.
7. **Commercially sensitive information is managed only by MOESA staff**: cost, margin, supplier identity and terms, internal notes. "Bu tarz bilgilerin yönetimi sadece MOESA çalışanlarında olsa daha iyi olur."
8. **There is no single way of working.** If MOESA does the procurement, MOESA keeps that history even when the customer leaves. If the customer does the procurement, MOESA does not need to keep it.
9. **When MOESA procures, the customer sees its own order relationally.** The customer sees status, quantities, MOESA's selling price and shipment ETA; payments are left out (decision 15). This is not a copy that needs syncing; it is "otomatik veya ilişkisel".
10. **Enforced in the database.** "Müşteri tenant'ı okumaması gereken alanları API istekleriyle dahi okuyamasın." That means RLS and masking, as with field permissions. It holds for the tenant owner too.
11. **The M21 customer transfer is retired.** Its role is taken by moving data between tenants.
12. **The procurement model is set per customer**, on the provider relationship. "Müşteri tedariği yönetiyorsa bilgileri görmesinde sakınca yok, MOESA yönetiyorsa görmemesi iyi olur": in a client-procures tenant the client owns and sees all of its procurement data (cost, suppliers, terms). Provider-only masking applies only to provider-procured data.
13. **After the relationship ends, the client keeps seeing the shared history**: the orders and shipments MOESA procured for it, with the client-visible field set. The client may keep using the panel on its own subscription as a self-procuring tenant ("tedarikçi müşteridir"). Rows already created stay where they were created.
14. **Moving data between tenants is a general tool**: copy or move products and their linked records from one tenant to another. "Bu işlemi yapacak kullanıcının iki tenant'ta da ilgili yetkilere sahip olması güvenlik açısından önemli": the caller must hold the needed table and field rights in both the source and the target tenant.
15. **No balance or receivable tracking between provider and client.** "Bakiye tarzı işlere girersek yönetimi yorucu." When MOESA procures, the client sees no deposit and no payment rows. Today those amounts are MOESA's payments to the supplier, and they would reveal cost.

## Onboarding (owner decisions 16–18, 2026-11-18)

16. **Customers join by the provider's invitation link.** The owner could not tell whether today's open self-signup is right; the invitation flow was proposed and accepted.
    - The provider starts a "new customer invitation". It records:
      - the customer's e-mail and company name;
      - the procurement model;
      - the contract terms;
      - the provider staff who will work in the new tenant, with their roles.
    - The customer opens the link, sets a password, completes the company details and picks a plan. That single step does four things:
      - creates the customer's tenant, with the customer as owner;
      - creates the provider relationship, already accepted (accepting the invitation is the client's acceptance);
      - adds the chosen provider staff with their roles;
      - starts sharing if the provider procures.
    - Invitations expire, are single-use and can be revoked by the provider.
    - The invited e-mail must match the account that accepts the invitation. If the address already has an account, they sign in instead of signing up.
17. **Open self-signup is closed by default.** It sits behind a platform setting, so the panel can later be offered to companies outside MOESA. With the setting on, it is today's flow: a standalone tenant with no relationship.
18. **The customer chooses its plan at signup.** "Planın içeriğini iyi şekilde açıklamalıyız ki yanlış seçim yapmasın."
    - The plan step shows each plan side by side: its modules, its limits, who it suits, and what changes later if they upgrade or downgrade.
    - The provider may mark a recommended plan in the invitation. The customer can still choose another.
    - My call: payment collection is out of scope. The chosen plan becomes the tenant's subscription, as today.

## Owner decisions 19–21 (2026-11-19)

19. **A provider never invites itself.** An invitation is refused when its e-mail (compared lower-cased) belongs to an account that is a member or owner of any tenant of the provider's company (`invitation_self_invite`). Creation refuses it, and preview and acceptance check again, as the account may have joined the company in between.
20. **A client does not see drafts.** A client sees a provider's purchase order, and the lines, shipments, incidents and change requests linked through it, only once the order has left draft. The sharing policy (`client_select`) of the order and of every row naming an order excludes drafts, a client cannot cite a draft in an incident or a change request, and the client status `pending` now means sent only.

## Goals

- `public.customer` and every `customer_id` column are gone. A record belongs to the tenant it lives in.
- The data a customer owns lives in the customer's tenant: products, product media and documents, market cells and listings, Amazon seller connections, brands, contacts, warehouses, projects, gates and tasks, incidents and change requests.
- Procurement data lives in the **procuring tenant**: suppliers and their contacts, purchase orders, lines, payments, updates, shipments, shipment events and lines, plus the sourcing attributes of products (supplier link, supplier product code, purchase price and currency, landed cost, target price).
  - When the customer procures, the procuring tenant is the customer's.
  - When MOESA procures, it is MOESA's.
- A **provider relationship** links MOESA's tenant (the provider) to a customer tenant (the client). It records:
  - the procurement model: client procures, or provider procures;
  - the contract terms: what today sits on `customer` as commercial_model, packages, status, contract dates and document, deposit rate, extra-cost rule, EU responsible person;
  - provider-internal fields: notes and the restricted Drive link.
- When MOESA procures, the order, its lines and shipments are one record in MOESA's tenant, **shared** with the client tenant.
  - Client users read the shared rows through their own tenant, limited to a fixed client-visible field set: status, dates, quantities, products, the selling price per line, shipment ETA and tracking. Payments, the deposit and any balance stay provider-only (owner decision 15).
  - Purchase price, landed cost, supplier identity and contact, supplier terms and provider-internal notes are **never** visible to the client tenant, owner included.
- Security sits in the database and is proven over HTTP, as field permissions were. A client user cannot read a provider-only field, or an unshared provider row, through any PostgREST or RPC path: filters, ordering, counts, embeds, forged tenant headers, RETURNING, error messages or audit history. The field-permissions attack suite grows to cover it.
- MOESA staff working for several customers use the existing multi-tenant scope. Picking the MOESA tenant together with a customer tenant shows the product with MOESA's sourcing data side by side.
- The M21 customer-package transfer is removed from the app and the database. Moving data between tenants stays possible (see "Left to the builder").

## Non-goals

- Billing and plan changes: a customer tenant uses the existing self-signup, subscription and plan flow.
- A shared supplier catalog across tenants.
- Customers creating or editing purchase orders on provider-procured orders in this round. Shared rows are read-only for the client. This is my call; see "Calls made".
- Migrating real data. Production holds no real business data, so the local seed and the story seed are rewritten for the new model.

## Anti-goals

- **No sync.** The client side never holds a copy of provider data that has to be kept in step.
- **No owner bypass on shared rows.** The client tenant's owner or admin must never reach provider-only fields by granting themselves rights. Their role editor cannot even offer those fields.
- **No hidden coupling to MOESA.** "MOESA" must not be hard-coded. Any tenant can be a provider to any client. MOESA is simply the provider in practice. This follows the earlier owner rule that the operating company is never named MOESA in schema or copy.

## Constraints

- The existing stack and security model stay:
  - masked `api` views owned by `api_owner`, and the forwarder;
  - closed base tables;
  - `role_field_permission`, the field catalog and drift checks;
  - the HTTP attack suite and the R10 performance budget.
- The tenant model stays:
  - parent/branch hierarchy;
  - `tenant_owner`, `tenant_user` and roles;
  - `x-tenant-ids` scope;
  - per-root settings and subscriptions.
- Every child→parent link within a tenant stays composite `(x_id, tenant_id)`. The only new cross-tenant references are those the provider relationship allows, such as a provider purchase-order line pointing to a client product. Each must be guarded by an active relationship, in RLS and in triggers.
- Production holds nothing that matters ("production önemli değil, rahatça refactor edebilirsin", 2026-11-18): existing migrations may be edited in place or replaced; no data migration and no backwards compatibility are needed.

## Calls made on the owner's behalf (please check)

- **The relationship needs both sides.** The provider side creates it, and the client owner accepts it. Sharing starts only after acceptance, so no tenant can push rows into another tenant's view uninvited. MOESA staff still join the client tenant through the normal invitation.
- **Contract terms are readable by the client**, so the client sees their own deposit rate and package. Provider-internal notes and the restricted Drive link are not.
- **Shared rows are read-only for the client in this round.** Client-side actions, such as approving a PI or confirming a delivery, can come later.
- **The `customer_viewer` portal role is retired.** A client tenant's users get ordinary roles in their own tenant. The field-permission defaults for client tenants decide what those users see.
- **`customer_brand`, `customer_contact`, `customer_warehouse` and `customer_platform_account` become tenant-level tables.** Suggested names: `brand`, `contact`, `warehouse`, `platform_account`. Each belongs to the tenant it is created in.
- **The product's sourcing attributes move into a table in the procuring tenant**, one row per (procuring tenant, product): the `product` row in the client tenant no longer carries cost or supplier columns.
- **The selling price**, today `company_price_eur`, is the provider's price to the client. It lives with the sourcing data and is part of the client-visible field set.
- **Provider users reach client data only through their invitation** into the client tenant. The relationship grants no extra read. Provider rows that point at client products (sourcing, PO lines) keep a snapshot of the product's identity (SKU and name), so they stay meaningful if the client deletes the product or removes the provider's staff. The cross-tenant link does not block the client's delete.
- **Incidents and change requests stay in the client tenant.** When they refer to a provider-procured order they keep that reference. Their cost amount and cost payer are provider-only fields when the order is provider-procured.
- **Switching a customer from provider-procures to client-procures**, for example at the end of the relationship, moves nothing. New procurement goes to the client tenant from then on.

## Left to the builder

- Table and column names, and the exact shape of the relationship and of row sharing. One option is a `shared_with_tenant_id` set by the relationship. Another is a share table. Choose by RLS cost and drift-check fit.
- How the masked views extend to shared rows. The field-permission machinery evaluates rights per row tenant. Shared rows need a separate client-visible field set that client roles can narrow but never widen.
- How much of the M21 engine (dry-run and conflict report, copy path, file copy, the catalog-driven rights gate) to reuse for the general tenant-to-tenant move (owner decision 14). The customer-package framing goes either way.
- The order of work, and whether it splits into several plans: (1) remove customer and make the tenant-level tables; (2) procurement placement and the relationship; (3) sharing and its security; (4) app; (5) seeds, attack suite and walk.
- Field classification updates for every moved or new column, kept passing the schema test.
- App changes:
  - the customer pages, pickers and filters go;
  - a provider-relationships page goes in the provider tenant;
  - the client side shows shared orders and shipments;
  - the scope picker shows the tenants a user belongs to.

## Done means

- No `customer` table and no `customer_id` remain in the database or the app.
- Both procurement models run end to end in the story seed, with one customer tenant of each kind.
- The HTTP attack suite proves that a client owner cannot read provider-only fields or unshared provider rows by any path, and that a provider user sees both sides when both tenants are in scope.
- test:db, app tests, typecheck, lint, build, Deno tests, the attack suite and the R10 budget are all green. A browser walk covers four users: a MOESA staff member, a client owner, a client user with a limited role, and a client-procures owner.
