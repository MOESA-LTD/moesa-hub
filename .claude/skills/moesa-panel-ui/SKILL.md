---
name: moesa-panel-ui
description: Use when entering, editing or checking records in the MOESA Hub panel through its web UI (browser automation on a staging preview, *.moesa-panel.pages.dev, or localhost) — products, documents, media, projects, market cells, change requests, incidents, suppliers, sourcing — or when a panel page, button, dialog or route cannot be found, a save fails with 403 "permission denied for view", or several agents share one signed-in browser.
---

# MOESA Hub panel through the UI

## Overview

The panel's buttons are not where the in-app Page guide says, several create dialogs are reachable only
from hidden entry points, and dialogs keep restored drafts. Agents that worked from the guide and
guessed routes spent most of their tool calls finding the way in. This page is the map. Pixel
coordinates are deliberately absent: they change with the viewport; find controls by name each time.

## Before you click anything

1. **One signed-in session, shared by every tab.** The account is signed in by the user (do not type
   passwords; ask the user). Check who is signed in:
   `Object.keys(localStorage).filter(k=>k.includes('auth-token')).map(k=>JSON.parse(localStorage.getItem(k)).user.email)`
2. **The active company is shared live across tabs** (localStorage `tenant-scope`). Switching it in one
   tab switches every other agent's tab. Rule: only the orchestrator switches; agents check the
   header selector shows the company their task needs and stop if it does not. Order multi-agent work
   by company (all work in company A, then switch once, then company B).
   - Switcher: header "Companies and branches" dropdown. Checkbox = shown companies; the star button
     "Make active" = the company new records go to.
   - A user sees only companies they are a member of. A provider's owner may not be a member of its
     client companies (demo: baris@ sees no THO rows; akif@ is management in both MOESA LTD and THO).
3. **Records go to the active company.** Client-owned data (products, documents, media, projects,
   market cells, change requests, incidents) is entered with the client company active; provider data
   (suppliers, sourcing, purchase orders, shipments, relationships) with the provider active.
4. Close the Page guide drawer when it covers the header (its "Close" button); it reopens on each load.

## Routes and hidden entry points (prefix `/en` or `/tr`)

| Need | Where it really is |
|---|---|
| Product list / import | `/ops/products/list`; S10 CSV import `/ops/product/import` (`/ops/product` is 404) |
| Product card | no deep link: product list → SKU column funnel → "Starts with" → Apply → row pencil |
| Add a document to ANY record | `/ops/document/add?showDialog=center&entity_type=<type>&entity_id=<uuid>&code=<label>` — the only way for a market cell; types: product, project, market_cell, supplier, sourcing, purchase_order, shipment, incident, change_request, provider_relationship, project_gate |
| Documents list | `/ops/documents/list` (`/ops/document/list` is 404); it has no Add button |
| New change request | side menu **right-click** "Change requests" → Add, or `/ops/change-requests/manage?showDialog=center` (the list has no Add button although the guide says "Use Add") |
| New purchase order / shipment | side menu right-click → Add, or from a project card ("New purchase order") |
| New incident | side menu right-click → Add, or project card → Incidents → New incident (pre-links the project; switch "Linked record kind" to Product etc. if needed) |
| New project | project list toolbar Add (opens `/ops/projects/add?showDialog=center`; `/ops/projects/new` is 404) |
| Market matrix | `/ops/market-matrix/list`; `?view=list` gives a row list with pencils; click an empty matrix cell or "Add cells" to create |
| Suppliers | `/ops/suppliers/list` (card tabs General, Contacts, Documents, Purchase orders) |
| Partner relationships | `/ops/clients/list` (menu "Partners → Relationships"; `/ops/partners/...` is 404) |
| Media library | `/ops/media`; link files to a record from the record's Media tab → "Link from library" (guide says "Pick from the library") |

Getting a record's uuid for the document URL:
- Product, project, supplier, purchase order, shipment, incident, change request: open the record's
  Documents tab and read the Add link's href (`read_page`).
- Market cell and partner relationship: the UI shows the uuid nowhere (no Documents tab, the card is a
  dialog without a URL). Ask the orchestrator for it (it reads it from the database); do not dig in
  app state or the session token.
- Without a valid `entity_id` the URL redirects to `/ops` and leaves an unlinked "Add document" dialog:
  close it, do not save it.

## Working with dialogs and controls

- **Restored drafts.** A dialog closed without saving (or a failed save) is restored on the next page
  as a stacked dialog with an "unsaved changes restored" banner. Before starting a task, and whenever
  a dialog you did not open appears: Discard → confirm (or the dialog's X when it has no Discard),
  repeat until none remains. Never save a draft you did not write. A dialog you opened and left
  untouched (Save disabled) closes with X and leaves no draft.
- **Dropdowns** (PrimeVue Select): click to open, then type the start of the option ("Commercial")
  to jump to it and press Enter — or move with ArrowDown/ArrowUp relative to the current value — then
  verify the shown value (zoom). Clicking options by ref or by position mis-picks
  when the layout shifts. Searchable pickers: open first, then click the search box inside the popup,
  type, wait ~1.5 s, ArrowDown + Enter.
- **Closed dialogs stay in the DOM**, so `find`/`read_page` refs can point at an invisible copy. Read
  values with `javascript_tool` over `input, textarea` when in doubt.
- **Layouts move.** The same dialog opens a few pixels off between loads, and fields shift when a
  select widens or a validation message appears. Screenshot after the dialog opens and after every
  select change; never reuse coordinates from an earlier load or batch clicks across a change.
- **One action, one check.** Saves take 2–4 s and a dialog may stay open after Save (fields locked).
  Fast chained clicks silently lose saves. After each save, confirm by toast, the new code in the
  title, or the list.
- **Status buttons** are named after the target status ("Approved", "Applied", "Preparing"); each asks
  a confirm; they are disabled ("Save or discard your changes first") while a tab is dirty.
- Date fields accept typed ISO text (`2026-09-03`) after clicking the field.

## Record rules that surprise

- **Documents**: every document, Draft included, needs a Drive link or a file ("Add a Drive link or a
  file") — get the real link before you start. No file-name field (the stored name is generated, e.g. `OKA-FBE_CERT_v01_20260708_onayli`);
  put the original file name at the start of Notes. Version is unique per record **and type**: a
  second "Other" on the same record must be v2. Approved/Signed did not require the
  signed/stamped/official-email flags.
- **Products**: bulk entry = S10 CSV import (header names from `S10_COLUMNS` in
  `app/src/api/product/csv.ts`; parents may sit in the same file via `parent_sku`; archived rows may
  share a GTIN with live ones; `asin_*` columns are ignored). The import writes in the active company
  only and looks supplier codes up there, so a client's products cannot get the provider's supplier
  through the import. The list is flat (no parent → variant tree).
- **Project products** are added one per click on the card's Products tab — no bulk link.
- **Change request** flow: Request tab Save creates it (code appears) → Impact tab saved separately →
  "Approved" → for a document change, add the new document version on the record, pick it in
  Decision → "New version", Save → "Applied".
- **Media**: upload via the library's hidden file input (`file_upload` accepts many files at once); the
  first image linked to a record becomes its primary image automatically.

## What a failure means

| Symptom | Meaning |
|---|---|
| 403 "permission denied for view <x>" on every save while imports work | the database's `api` views lack write grants (an environment problem, not your role) — stop and report; do not retry |
| Product Sourcing tab: "add sourcing only under an active relationship…" while the relationship is active and provider-procures | the provider cannot add sourcing to a client's product from the card (known gap) — report, do not loop |
| No Add button on a list | use the side-menu right-click or the dialog URL above |
| 404 on a guessed route | use the route table; the singular/plural form differs between pages |

## Common mistakes

- Switching the company in a shared browser → every other agent writes into the wrong company.
- Guessing `/add` or `/new` routes → 404 and a redirect to the profile page.
- Trusting the Page guide's button names → see the table; the guide is ~90 % right on steps but
  omits every hidden entry point.
- Letting a restored draft ride along → it is saved into the wrong record on the next Save.
