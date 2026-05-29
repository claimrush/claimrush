# Color palette

Core colors (brand)
- Gold (primary accent): `#D4AF37`
- Gold Dim (subtle prestige): `#A8862C`  _(outlines/dividers, “selected” borders, quiet highlights)_
- Blue (action/tempo): `#0000FF` _(Base Blue, screen-native RGB 0 0 255; in print convert to PMS 286)_
- Ink (base background): `#0A0D14`

Dark UI neutrals
- Background: `#0A0D14`
- Surface: `#111827` _(primary cards/panels)_
- Surface 2: `#0F172A` _(deeper containers/drawers)_
- Surface 3: `#1F2937` _(elevated/hover state)_
- Overlay: `#0A0D14` _(use with alpha for modals: e.g. 70–85%)_
- Border: `#243041`
- Border subtle: `#1A2437`
- Border strong: `#334155`
- Text: `#F8FAFC`
- Text subtle: `#CBD5E1`
- Muted text: `#94A3B8`

Semantic states (optional)
- Success: `#2EE59D`
- Warning: `#F97316`
- Danger: `#EF4444`

Interaction
- Focus ring: `#0000FF` _(match primary)_

Usage rules
- Gold is prestige. Use it for highlights, badges, and key moments. Avoid flooding the UI.
- Gold Dim is for “quiet prestige” (thin borders, separators, selected states, default link underlines).
- Blue is speed. Use it on two surfaces only: the primary CTA button background (paired with white foreground text, 8.59:1 on Base Blue, passes AAA) and the a11y `:focus-visible` outline. The logo carries Base Blue for brand identification; outside of those three surfaces (CTA fill, focus outline, logo), Base Blue does not appear in product surfaces. Specifically, Base Blue is not used as a link colour, link underline, sidebar active fill, sidebar hover tint, search-input ring, or any other accent — every other accent slot resolves to the gold canon (Brand Gold for prestige beats, Gold Dim for quiet prestige).
- Default product UI is dark-first.

Links

One canonical pattern applies across product UI and MDX prose in the docs and developer manuals.

Body links (cards, tables, status banners, prose pages, MDX content)
- Default state: `Text` foreground (white, `#F8FAFC`), 1 px underline in Gold Dim at 55% alpha (`#A8862C` at α 0.55), offset 3 px. Visible enough to register as interactive at a glance, quiet enough that links inside cards do not read as button-shaped surfaces.
- Hover / focus-visible state: foreground shifts to full Gold (`#D4AF37`), 2 px underline in full Gold. No background tint — the link "lights up" in gold (text + underline together) as the commit beat.
- Active (mousedown / tap-active): same as hover.
- Visited: no separate treatment.
- Subheading anchors and other Nextra/MDX heading-anchor links keep their muted theme defaults.

UI chrome links (navbar, sidebar items, profile pills, action buttons, chips / badges / filter pills, table rows that act as row-level buttons) follow their own component canon, not this rule. A link styled as a button never carries the body-link underline — the button surface itself is the affordance.

Buttons that act as text-links (in-prose actions that are semantically links but cannot be `<a href>` — e.g. wallet-connect, page refresh, modal open from inside body text) opt into the body-link rule via the `.cr-text-link` utility class on the `<button>` element. The class resets the button chrome to inline text presentation and applies the same default and hover states as the body-link rule above.
