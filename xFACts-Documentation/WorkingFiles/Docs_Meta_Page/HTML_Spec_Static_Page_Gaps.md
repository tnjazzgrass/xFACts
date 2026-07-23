# HTML Spec Applicability Gap List - Static Doc-Site Pages

Produced during the backlog doc-site page build (2026-07-23). This is the input
named by the backlog item "Feasibility of extending HTML populator coverage to
static doc-site pages."

Scope: every rule in `xFACts_HTML_Spec.md` that does not map onto a static
doc-site page, and why. Rules that DO map were applied to `pages/backlog.html`
and are listed at the end as the portable set.

## Root cause of the mismatch

The HTML spec describes one artifact: a Control Center page emitted from a
PowerShell route file. Its rules assume server-side substitution
(`$browserTitle`, `$navHtml`, `$headerHtml`, `$bannerHtml`), a runtime
bootloader in `cc-shared.js` that reads `data-cc-page` and dynamically loads the
page module, and a chrome layer defined in `cc-shared.css`.

A static doc-site page shares none of those. It is a hand-authored `.html` file
with no server-side substitution, no bootloader, chrome supplied by
`docs-base.css`, and navigation injected client-side by `nav.js` into an empty
mount. Roughly two-thirds of the spec is therefore unmappable not because the
docs zone is non-conformant, but because the rules address machinery that does
not exist there.

A second, decisive fact: **the HTML populator reads HTML only from inside `.ps1`
files.** Static doc-site pages are never scanned, so they emit no catalog rows
at all. Every cross-reference rule is therefore inert for them today.

## Rules that do not map

### 1. Page shell (spec 1, 1.2)

| Rule | Why it cannot apply |
|---|---|
| `<html>` root element carries no attributes | Every one of the 66 docs pages carries `lang="en"`. A standalone document should declare its language; the CC rule is safe only because the shell is machine-emitted. |
| `<title>` content is the `$browserTitle` substitution | No PowerShell, no route file, no `Get-PageBrowserTitle`. A static page's title is necessarily a literal. Fires `FORBIDDEN_HARDCODED_TITLE` and `MISSING_BROWSER_TITLE_VAR` by construction. |
| `<head>` contains only `<title>` and `<link>`, in that order | Static pages must carry `<meta charset>` and `<meta name="viewport">`. Without a declared charset a standalone document leaves encoding to browser guessing. Fires `MALFORMED_HEAD`. |
| `<body>` carries `class="cc-section-<sectionKey>"` | `section_key` comes from `RBAC_NavSection`. Docs pages are not nav-registry pages and have no section. |
| `<body>` carries `data-cc-page` and `data-cc-prefix` | Both exist solely so the `cc-shared.js` bootloader can resolve and load the page module. The docs zone has no bootloader; its pages declare their scripts explicitly. |
| First content in `<body>` is the `$navHtml` substitution | Docs navigation is client-side: the page declares an empty `<nav class="doc-nav"></nav>` mount and `nav.js` fills it after fetching the registry. There is nothing to substitute at author time. |
| Mandated `<body>` element order and the shell whitespace/attribute-order rules | The mandated element sequence (nav, header bar, banners, content, overlays, script) does not exist. The docs shell is `doc-layout` wrapping `doc-nav` and `doc-content`, the latter holding `doc-header`, `doc-body`, and `doc-footer`. |

### 2. Page chrome (spec 2) - entirely inapplicable

The header bar, refresh info block, engine cards, and banner chrome are all CC
runtime constructs. `cc-refresh-info`, `cc-live-indicator`, `cc-page-refresh-btn`,
`cc-engine-*`, `cc-connection-banner`, and `cc-page-error-banner` are defined in
`cc-shared.css` and driven by WebSocket state and the orchestrator. A docs page
loads neither the stylesheet nor the script, and has no orchestrator
relationship. Every drift code in spec 2 is unreachable.

### 3. Asset references (spec 3)

| Rule | Why it cannot apply |
|---|---|
| Exactly two CSS references, `/css/<page>.css` then `/css/cc-shared.css` | Docs pages load `docs-base.css` followed by one page-type stylesheet, by **relative** path (`../css/...`) under `/docs/`, not `/css/`. |
| Page-specific stylesheet precedes the shared one | The docs zone loads them in the **opposite** order: the shell (`docs-base.css`) first, then the page-type sheet that overrides it. Fires `CSS_REFERENCE_ORDER_VIOLATION` against a deliberate and correct cascade. |
| Exactly one `<script>`, `src="/js/cc-shared.js"`, last in `<body>` | Docs pages declare two or three explicit script tags by relative path (`docs-shared.js`, `nav.js`, and any page-type renderer). With no bootloader there is no mechanism to load a page module implicitly. Fires `WRONG_SCRIPT_SOURCE`, `UNEXPECTED_SCRIPT_TAG`, and `MISSING_SHARED_SCRIPT_TAG`. |

The vendored-library rule (3.2.2) is inapplicable in its specifics (the closed
set is CC's) but its principle - never load from an external origin - holds and
was observed.

### 4. Prefix discipline (spec 4, 5) - portable only after restatement

The rules are written against the literal token `cc-` for chrome and
`Component_Registry.cc_prefix` for pages. In the docs zone both resolve to the
same token, `doc`, because the zone has exactly one component
(`Documentation.Site`). The page/chrome distinction that the rules turn on
collapses, and so does spec 5.3's cross-page collision rule, since the docs zone
has no per-page prefixes to collide.

Applying these rules to static pages needs a zone-parameterized restatement, not
a literal reading.

### 5. IDs (spec 5.2, 5.3) - applicable in principle, deliberately unused

`pages/backlog.html` declares **no IDs at all**. This is deliberate rather than
incidental: because static HTML is never scanned, no `HTML_ID` DEFINITION rows
exist for a docs page, so any `getElementById` from a docs JS file would resolve
to nothing and land as `JS_HTML_ID_UNRESOLVED`. The page is addressed entirely
by class and by `data-doc-*` attributes, and the JS uses `querySelector` and DOM
relationships instead. Extending populator coverage to static pages would remove
this constraint.

### 6. Overlay constructs (spec 5.4) - inapplicable

The whole `cc-dialog` family - modal, slideout, slide-up, dock, and their
structural and backdrop-close rules - is defined in `cc-shared.css`. A docs page
cannot reference those classes. Where the docs zone needs a comparable
construct it builds its own under the `doc-` prefix (`docs-controlcenter.js`
does exactly this).

### 7. Dynamic class values (spec 6.2) - inapplicable

The mandated array-join pattern is PowerShell. The docs analogue is string
concatenation in JS, which this spec does not describe and the JS spec governs
instead.

### 8. Action attributes and dispatch tables (spec 7) - inapplicable as mandated

`data-action-<event>` exists so the `cc-shared.js` bootloader can look the value
up in an event-scoped dispatch table. Without the bootloader the attribute has
no consumer. The established docs idiom, in both shipped docs renderers, is a
delegated listener on `document.body` that matches the event target by class.
`pages/backlog.html` therefore carries no `data-action-*` attributes, and
`UNRESOLVED_DATA_ACTION` / `ACTION_PREFIX_MISMATCH` cannot fire.

Two principles underneath spec 7 ARE portable and were applied: no inline `on*`
handlers, and a clickable region is a real `<button>` rather than a click-wired
`<div>` (spec 7.5). Both the column sort controls and the row disclosure control
are buttons.

### 9. Platform data attributes (spec 8, 14.4) - partially applicable

The naming rule is portable once the prefix is substituted: the page uses
`data-doc-filter` and `data-doc-sort`, matching the `data-<page-prefix>-<name>`
form. The closed platform set (`data-cc-page`, `data-cc-prefix`) is CC-only and
has no docs equivalent.

### 10. Section divider format (spec 10.1) - conflict, resolved toward the zone

The spec mandates a divider whose rule lines are exactly 76 `=` characters. The
docs pages universally use a shorter run. This is a portable rule that the docs
zone already diverges from, so it is a genuine conflict rather than an
inapplicable rule.

**Decision taken and flagged for review:** `pages/backlog.html` and the
`tools.html` insertion use the shorter existing docs form, for consistency with
the surrounding zone. Adopting the 76-character form would have made the new
page the only docs page with a different comment style. If populator coverage is
extended, this is a one-line-per-page normalization to settle deliberately
across all 66 pages rather than page by page.

### 11. Helper-emitted HTML (spec 11) - inapplicable

Helpers are functions in `xFACts-CCShared.psm1`. There is no PowerShell in the
docs zone.

### 12. Cross-spec resolution (spec 13) - inert

`HTML_CSS_CLASS_UNRESOLVED`, `HTML_CSS_FILE_UNRESOLVED`, and
`HTML_JS_FILE_UNRESOLVED` all require the HTML populator to emit USAGE rows for
the file. It never scans static pages, so a static page's class references,
stylesheet links, and script references are all uncatalogued. A clean catalog
today says nothing about these 66 files.

### 13. Chrome reference tables (spec 14) - inapplicable

Both tables enumerate identifiers defined in `cc-shared.css`. The docs zone's
equivalent chrome lives in `docs-base.css` and is not enumerated by any spec.

## The portable set - rules applied to pages/backlog.html

These carried over unchanged and were observed:

- `<!DOCTYPE html>` exactly, on its own line (spec 1.1).
- Class values: lowercase letters, digits, and hyphens; single spaces; no
  duplicates within one attribute; every class carrying the zone prefix
  (spec 6.1).
- `data-*` naming under the page prefix, values static (spec 8).
- User-facing attributes (`title`, `placeholder`, `aria-label`, `alt`) never
  declared empty (spec 9.1).
- Comments closed, no `--` inside a comment body (spec 10.2).
- No inline `<style>` block (spec 12).
- No inline `style=""` attribute on any element (spec 12).
- No `<script>` element with body content; script tags are `src`-only
  (spec 3.2, 12).
- No inline `on*` event handler attributes (spec 7, 12).
- Clickable regions expressed as `<button>` (spec 7.5).
- No external origins for any asset (spec 3.2.2, principle).

## Observation for the coverage decision

The two spec-conformance problems that a static-page populator would actually
catch in the docs zone today are both already known: the BDL Import Guide's
embedded `<style>` block with its inline `style=""` attributes, and the divider
format divergence in item 10 above. Nothing else in the zone violates the
portable set. Coverage would therefore buy regression protection going forward
more than it would surface a backlog of existing defects - worth weighing
against the cost of authoring a static-page section or a separate static-page
spec.
