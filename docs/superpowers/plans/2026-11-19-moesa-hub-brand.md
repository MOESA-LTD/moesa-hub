# MOESA Hub Brand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The panel is named "MOESA Hub", carries the MOESA mark and colours, and its sign-in screen follows the MOESA design system.

**Architecture:** A new `TopbarBrand.vue` renders either the company's logo or the MOESA Hub lockup. A `moesa` palette in `tailwind.config.js` becomes the default primary. The sign-in welcome panel drops its glow.

**Tech Stack:** Vue 3.5, PrimeVue 4 (Aura), Tailwind 3, Vitest.

**Spec:** `docs/superpowers/specs/2026-11-19-moesa-hub-brand-design.md`

## Global Constraints

- Name: `MOESA Hub`, written exactly like that (capital MOESA).
- Mark: `app/public/brand/moesa_mark.png`, an unaltered copy of moesaltd.com's `moesa_mark.png`. Favicon: `app/public/brand/favicon.png`, an unaltered copy of moesaltd.com's `favicon.png`.
- Lockup type: Manrope 700, capitals and `letter-spacing: 0.04em` for "MOESA"; Manrope 400 for "Hub". Light: ink `#19324A` and slate `#536B7D`. Dark: white and `#B4CFE0`.
- Mark height is 26 px, light mode only.
- `moesa` palette: 0 `#ffffff`, 50 `#ebf5fb`, 100 `#cfe8f6`, 200 `#9fd3ee`, 300 `#5bbde6`, 400 `#14a3db`, 500 `#0069b2`, 600 `#005a99`, 700 `#004b85`, 800 `#003b72`, 900 `#102c49`, 950 `#0a1d31`.

## Review Focus

- A company without a logo shows the lockup; one with a logo shows only the logo. (TopbarBrand test)
- A stored theme with `primary: 'orange'` stays orange. (The settings schema already keeps valid stored values; the test pins it.)
- In dark mode the mark is not rendered. (TopbarBrand uses `dark:hidden`; checked by hand in the browser.)
- The sign-in screen with a user-picked primary is still readable. (Checked by hand with `emerald`.)

---

### Task 1: Default colour `moesa`

**Files:** Modify `app/tailwind.config.js` (add `moesa` under `theme.extend.colors`), `app/src/lib/theme/settings.ts:18` (`primary: 'moesa'`). Test: `app/tests/theme/settings.test.ts` (create).

- [ ] Test `defaults to the MOESA palette`: `expect(defaultSettings().light.primary).toBe('moesa')`; `expect(findPalette(PRIMARY_COLORS, 'moesa')?.['500']).toBe('#0069b2')`.
- [ ] Test `keeps a stored orange theme`: `parseSettings(JSON.stringify({ light: { primary: 'orange' } })).light.primary === 'orange'`.
- [ ] Run `npx vitest run tests/theme/settings.test.ts` and confirm the first test fails. Then implement and confirm both pass. Commit.

### Task 2: `TopbarBrand` + name + favicon

**Files:** Create `app/src/layouts/dashboard/TopbarBrand.vue` (props `logo?: string | null`, `alt?: string`). Modify `Topbar.vue:32-43` (use it), `Footer.vue` ("MOESA Hub by"), `index.html` (title `MOESA Hub`, icon `/brand/favicon.png`, Manrope 400;700 from Google Fonts). Add `public/brand/moesa_mark.png` and `public/brand/favicon.png`. Test: `app/tests/layouts/topbarBrand.test.ts`.

- [ ] Test `shows the MOESA Hub lockup without a company logo`: the text contains `MOESA` and `Hub`; `img[src="/brand/moesa_mark.png"]` exists.
- [ ] Test `shows only the company logo when there is one`: with `logo: 'https://x/logo.png'`, `img[src="https://x/logo.png"]` exists, there is no `MOESA` text and no mark img.
- [ ] Run and confirm the tests fail. Implement and confirm they pass. Commit.

### Task 3: Sign-in panel without the glow

**Files:** Modify `app/src/views/pages/auth/Index.vue`. Remove `<defs>`, the glow circle and the `.auth__glow-*` / `--glow` rules. Light: `--ink: primary-50`, `--line: primary-500`, `--trunk: primary-500`, the end node filled `primary-500`. Dark: `--ink: primary-900`, `--line: primary-400`, `--text: surface-0`.

- [ ] Run `npx vitest run tests/views` and confirm everything passes. Check in the browser in light and dark mode. Commit.
