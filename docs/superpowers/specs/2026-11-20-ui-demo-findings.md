# UI demo findings — elastic (lastik) product group entered through the panel (2026-11-20)

The OKAEI / THOMETZKI elastic group was entered on staging (preview `feat-plan-module-tiers`) through the
panel UI only, by six browser agents working in parallel, from the company's Google Drive. Goal: test
the system end to end with real records. This file lists what broke or slowed the work; raw agent logs
were kept outside the repo.

## What was entered

| Record | Count | How |
|---|---|---|
| Products (THO) | 240: 4 family parents, 188 OKAEI variants, 48 archived THOMETZKI SKUs | S10 CSV import, 0 errors |
| Product documents | 11 (3 OEKO-TEX certificates, 4 safety information, 4 product master) | product card → Documents |
| Media | 12 images, linked to 4 products | media library + product Media tab |
| Projects | 3 (THO-2026-002/003/004 = board MKT-2026-044/045/046), 6 tasks each, 4 documents | project list Add |
| Market cells | 11 (round cord in 9 Amazon countries, preparing; woven and flat DE, planned) + 9 listing reports | market matrix; reports via document-add URL |
| Change requests | 2, applied (CR-THO-2026-001 composition, -002 stretch claim with workbook v2) | menu right-click Add |
| Incidents | 2 open (OA-THO-2026-001 EAN data, OU-THO-2026-001 compliance evidence) | project card → New incident |
| Supplier | TEKIS (TR2) renamed TEKIS LASTIK, groups and notes | supplier card |
| Not entered | sourcing rows (blocked, see B2); POs, shipments, prices (no data in Drive) | — |

## A. Environment (fixed on branch `fix/hosted-default-privileges`, not yet pushed)

**A1 — blocker. Hosted Supabase projects get no write grants on the `api` views.** Every save except
SECURITY DEFINER RPCs (the product import) failed with 403 "permission denied for view …". The api view
generator (053/057) copies INSERT/UPDATE/DELETE from the base tables; Supabase's new-project default ACL
(staging, created 2026-11-04) grants anon/authenticated nothing, so 46 views got SELECT only. Local CLI
and the old production project have the legacy default, so neither tests nor local runs saw it. Staging
was repaired by hand (grants copied from a local reset); the fix makes 001 grant the legacy defaults
explicitly, adds `supabase/tests/database/001_default_privileges.test.sql`, and makes CI simulate the
hosted default. Privilege snapshots are identical with and without the simulation; pgTAP 1868/1868.

## B. Functional gaps

- **B1 — Change requests, purchase orders, shipments and incidents have no Add button on their lists.**
  Add exists only in the side menu's right-click context menu (or the `manage?showDialog=center` URL,
  or a project card). The Page guide says "Use Add". An agent concluded the module could not create
  records at all.
- **B2 — A provider cannot add sourcing to a client's product.** Product card → Sourcing (MOESA LTD
  active, THO relationship active and provider-procures) shows "add sourcing only under an active
  relationship…" with no Add. Likely cause: `Sourcing.vue` builds `useClientOptions()` inside the product
  card, whose form tenant is the product's (THO), so the provider's relationships are filtered out
  (`toClientOptions` keeps `row.tenant_id === formTenant`). Not verified by a code change.
- **B3 — No document attach for market cells or partner relationships in the UI.** The cell dialog and
  the relationship dialog have no Documents tab, the documents list has no Add; only the URL
  `/ops/document/add?showDialog=center&entity_type=…&entity_id=…` works, and the record uuid is not shown.
- **B4 — No bulk paths where volume is normal:** project products are linked one per click (≈170 for one
  family); sourcing per product; market-cell status/content/notes per cell (bulk "Add cells" has no
  status, content or note); status walks need one confirm per step per cell.
- **B5 — Document form has no file-name field;** the stored name is generated
  (`OKA-FBE_CERT_v01_20260708_onayli`). Versions are unique per record and type, so a second unrelated
  "Other" document on a record must be v2.
- **B6 — Task role list has no marketing/content roles** (packaging designer, photographer, video, SEO,
  listing team); tasks were saved without a role.
- **B7 — Product list is flat:** no parent → variant tree; default page size 5; "(1 of 48)" reads like a
  record count.
- **B8 — No incidents tab on the product card;** an incident linked to a product from a project card does
  not show on that project's Incidents tab.

## C. Bugs

- **C1 — major. Restored drafts pile up.** A dialog closed without saving, or a failed save, is restored
  on every later page as a stacked dialog, even after a successful save of the same record; drafts carry
  text across different entities; clearing needed up to four Discard rounds. Risk: a stale draft is
  saved into the wrong record. The banner "record has changed" also appears on brand-new records after
  a 403.
- **C2 — major. Documents list paging is unstable:** with 10 per page one record appeared on two pages
  and another on none (sort without a tiebreaker).
- **C3 — minor. Dropdowns mis-pick when the layout shifts** (Type with 21 options, severity); options
  chosen by click landed on a neighbour; keyboard Home/End unreliable.
- **C4 — minor. Fast consecutive saves are lost silently** (media renames, cell status steps).
- **C5 — minor. List filters persist across navigation and tabs** with only a small funnel highlight;
  the product list opened pre-filtered by another tab's SKU filter.
- **C6 — minor. Reopening CR-THO-2026-002 shows Project "Select a project"** and an empty SKU chip; the
  saved data is correct.
- **C7 — minor. Market "Add cells" country picker** mis-clicks easily; its search box does not filter.
- **C8 — cosmetic.** A saved document dialog stays open with Type/Version locked; the media picker shows
  file names, not titles; the first linked image silently becomes the primary image; a failed project
  create consumed code THO-2026-001 (first saved project is 002).
- **C9 — cosmetic. Route guesses 404:** `/ops/product`, `/ops/document/list`, `/ops/projects/new`,
  `/ops/partners/...`; the project card URL is not a reliable deep link.

## D. In-app guides (audit of `app/src/constants/guide.ts` against the code)

- 12 guide pages, 44 tasks, 132 steps: 119 accurate, 13 wrong or misleading (≈10 %). Pages with a guide:
  11 of 14 ops modules; 44 % of all 27 user-facing pages. Missing: Company profile, Partners, Copy or
  move products, project card tabs (Tasks, Documents, …), adding a single product or variant.
- Wrong/misleading examples: "Use Add" on PO, shipment, incident and change request lists (B1); "Pick
  from the library" vs the button "Link from library"; photo role change "from its menu" vs tile
  checkbox + "Set role"; supplier contact "official e-mail" rule has no field; Amazon Check/Publish live
  in the "Open Amazon listing" drawer and need a connected account; TR labels differ from the UI ("Satın
  alma siparişleri sekmesi" is "PO geçmişi", "Kabul sekmesi" is "Teslim kabulü", "Olaylar" names both
  incidents and shipment events).
- The system guide mentions none of the hidden entry points (context-menu Add, `?showDialog=center`
  dialog URLs, the document-add URL). EN and TR term keys match.

## E. Data issues found in Drive (recorded as incidents/notes, not panel bugs)

33 OKAEI EANs fail the GS1 check digit or are truncated; one EAN on two SKUs; 90 OKAEI variants reuse old
THOMETZKI barcodes; woven composition 75/25 vs 65/35 vs 60/40 across sources; the six flat "black" hero
images show beige bands; the OEKO-TEX certificate (holder TEKIN DAR TEKSTIL, class I baby articles)
conflicts with the safety text "not for children under 3"; no REACH report; no orders, prices or carton
data for the group.

## For agents

`.claude/skills/moesa-panel-ui/SKILL.md` holds the route map, hidden entry points, dialog and dropdown
handling, the shared-company rule and what each failure means.
