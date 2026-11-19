# MOESA Hub: the panel carries the MOESA brand

Short design, approved by the owner on 2026-11-19 after the preview
(https://claude.ai/artifact/XfqNgBWTiUgdjJfnCDzRSX).

## Why

The panel showed a placeholder name ("Moesa Panel" in an orange monospace face) and an orange
default theme, unrelated to the company's identity on moesaltd.com. MOESA's clients now sign in
to the panel themselves, so it should read as MOESA's product.

## Decisions

- **Name:** "MOESA Hub" (owner). Replaces "Moesa Panel" in the tab title, the topbar and the
  footer.
- **Source of the brand:** the "Moesa Design System" artifact
  (https://claude.ai/artifact/4fk4GS8QmHEqLSDCUmQWeE). The mark (`moesa_mark.png`) and the
  favicon are used unaltered. No vector original exists yet, so we use the PNG.
- **Topbar, light mode:** the mark at 26 px, then "MOESA" (Manrope 700, capitals, ink #19324A),
  a hairline, then "Hub" (Manrope 400, slate #536B7D).
- **Topbar, dark mode:** the name only, with no mark. The design system shows the mark only on
  light grounds.
- **Company logo:** when the signed-in company has a logo, it replaces the MOESA Hub lockup in
  the topbar. Today both are shown. The tab icon stays MOESA's.
- **Default theme colour:** a new `moesa` palette in `tailwind.config.js`, derived from the
  site tokens (500 = #0069B2 action blue, 400 = #14A3DB cyan, 900 = #102C49 navy). It becomes
  the default primary instead of `orange`. People can still pick any colour. Settings already
  stored in a browser keep their colour.
- **Sign-in screen:** the route drawing stays. The glow goes, because the design system has no
  gradients or glows. The welcome panel is pale blue in light mode and navy in dark mode, with
  the route in cyan and blue. These colours come from the primary palette, so a user-picked
  colour still recolours it.
- **Type:** Manrope is loaded only for the lockup. The rest of the panel stays on Lato.

## Approaches considered

1. Invent a panel mark (junction / route-M / gate). This was dropped once the company's own mark
   and design system turned up: two marks would read as two brands.
2. Apply the whole design system to the panel (Manrope everywhere, 2 px radii, navy surfaces).
   This is deferred. It is a wide visual change across every screen and conflicts with
   user-picked themes.
3. **Brand touchpoints only.** Chosen: the name, the lockup, the favicon, the default colour
   and the sign-in screen.

## Out of scope

The panel-wide typeface, corner radius, tables, forms and surface colours. The text on
moesaltd.com is also out of scope.
