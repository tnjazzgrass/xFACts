# Control Center HTML File Format Specification

*These rules are the current authority for HTML markup emitted by Control Center route files. They are settled until explicitly amended; any proposed change is discussed before adoption. Where rationale exists for a rule, it appears in the Appendix at the corresponding section number.*

*Specs describe rules and shapes — never present contents. Statements about how many files currently do something, which pages are empty today, or what the codebase looks like right now do not belong in this document; they age into inaccuracy the moment the codebase changes. If census-style information is needed, it lives in queries against `dbo.Asset_Registry`, not here.*

*The HTML spec governs the shape and content of HTML markup. The PowerShell file containing the markup — its file header, its section banners, its function definitions, its route declarations — is governed by the PowerShell spec. A row in the catalog with `file_type = 'HTML'` represents an HTML construct extracted from a PS file by the HTML populator; the file's PS-level constructs are extracted separately by the PowerShell populator and produce rows with `file_type = 'PS'`.*

---

## Spec Authoring Conventions

*This section governs how this spec is written. It applies to every section and every edit.*

1. **Rules state what, not why.** Each rule is a short declarative statement of the requirement. No rationale, explanation, or background in the rule itself.
2. **One rule per bullet, where possible.** Numbered or bulleted lists make rules scannable. Prose paragraphs are reserved for cases where a single rule genuinely requires more than a sentence.
3. **No introductory framing.** Section headings introduce what the section governs; the section body goes straight to rules. Paragraphs like "This section addresses X because Y" or "The purpose of these rules is Z" do not belong in the body.
4. **Rationale lives in the Appendix.** Where a rule's reasoning is worth recording, it goes in the Appendix at the corresponding section number. Most rules do not need a rationale entry.
5. **Drift codes live in a consolidated reference at the end of the spec, not inline with rules.** Each rule states the requirement only. The drift codes section (§15) maps each code to its rule section and description in the format `Code | Section | Description`. A rule that has a drift code is implicitly enforceable; the code is documented in the reference.
6. **Examples earn their place.** A code block illustrating a rule should be the shortest form that conveys the rule. Multi-example blocks belong in the spec's Examples section, not inline with rules.
7. **No status, history, or progress information.** The spec describes rules. What the codebase does today, what was added when, and what is planned live elsewhere.
8. **Inline SQL or script query blocks do not belong in the spec.** Operational queries live in Object_Metadata `common_queries` on the relevant script. The spec references the script; it does not contain executable queries.

*New content added to this spec conforms to these conventions immediately. Existing sections may contain prose that predates these conventions and will be cleaned up in a dedicated pass.*

---

## 1. Required structure

HTML in the Control Center is emitted from PowerShell route files (`*.ps1` in `scripts/routes/`) and from helper module functions (`*.psm1` in `scripts/modules/`). HTML does not exist as standalone `.html` files. Every HTML construct in the codebase appears inside a PowerShell string token — typically a here-string assigned to a `$html` variable that is then passed to `Write-PodeHtmlResponse`, or a string built up via `System.Text.StringBuilder` inside a helper function.

A page route's HTML must conform to the page-shell structure defined in this section.

### 1.1 Page shell

Every page route emits HTML conforming to this shape, in this exact order:

```
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/<page>.css">
    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-<sectionKey>" data-cc-page="<slug>" data-cc-prefix="<prefix>">
$navHtml

    <!-- page header bar -->
    <!-- connection banner placeholder -->
    <!-- page error banner placeholder -->
    <!-- page-specific content -->

    <script src="/js/cc-shared.js"></script>
</body>
</html>
```

### 1.2 Page shell rules

- The HTML document opens with `<!DOCTYPE html>` on its own line. The DOCTYPE token is exactly `<!DOCTYPE html>` — uppercase keyword, lowercase tag name. All other casings (`<!doctype html>`, `<!Doctype html>`, `<!DOCTYPE HTML>`, etc.) are forbidden. Drift code: `MALFORMED_DOCTYPE`.- The root element is `<html>` with no attributes. Drift code: `MALFORMED_HTML_ROOT`.
- The `<head>` contains exactly these elements, in this order: one `<title>` element, one or more `<link rel="stylesheet">` elements per Section 3, and nothing else. Drift code: `MALFORMED_HEAD`.
- The `<title>` element's content is the value of the `$browserTitle` PowerShell variable, sourced from `Get-PageBrowserTitle`. Drift code: `FORBIDDEN_HARDCODED_TITLE`.
- The `<body>` element opens with a `class="cc-section-<sectionKey>"` attribute, where `<sectionKey>` matches the page's `RBAC_NavSection.section_key` value. Drift code: `MISSING_BODY_SECTION_CLASS`.
- The `<body>` element declares a `data-cc-page="<slug>"` attribute, where `<slug>` matches the page's URL slug (lowercase, hyphen-separated, derived from the rightmost path segment of the page route). Drift code: `MISSING_DATA_CC_PAGE`.
- The `<body>` element declares a `data-cc-prefix="<prefix>"` attribute, where `<prefix>` matches the page's `cc_prefix` from `Component_Registry`. Drift code: `MISSING_DATA_CC_PREFIX`.
- The first content inside `<body>` is the `$navHtml` substitution, sourced from `Get-NavBarHtml`. Drift code: `MISSING_NAV_SUBSTITUTION`.
- The last content inside `<body>` before `</body>` is the `<script>` tag per Section 3. Drift code: `MALFORMED_BODY_CLOSE`.

### 1.3 Body content shape

Between `$navHtml` and the `<script>` tag, the body contains page content in this implicit order:

1. The page header bar — a single block containing the page title (via `$headerHtml` substitution) and refresh chrome (live indicator, last-updated timestamp, page refresh button, optional engine cards per Section 2).
2. The connection banner placeholder — a single `<div id="cc-connection-banner" class="cc-connection-banner"></div>` element with no content.
3. The page error banner placeholder — a single `<div id="cc-page-error-banner" class="cc-page-error-banner"></div>` element with no content.
4. The page-specific content — any number of layout containers, sections, slideouts, modals, or other page-level constructs.

### 1.4 Body content rules

- The page header bar is the first content element after `$navHtml`. Drift code: `MISSING_HEADER_BAR`.
- The page header bar contains exactly one `$headerHtml` substitution, sourced from `Get-PageHeaderHtml`. Drift code: `FORBIDDEN_HARDCODED_PAGE_HEADER`.
- The connection banner placeholder appears exactly once per page, with `id="cc-connection-banner"` and `class="cc-connection-banner"`. Drift code: `MISSING_CONNECTION_BANNER` if absent.
- The connection banner placeholder is empty — no content between the opening and closing tags. Drift code: `FORBIDDEN_BANNER_CONTENT`.
- The page error banner placeholder appears exactly once per page, with `id="cc-page-error-banner"` and `class="cc-page-error-banner"`. Drift code: `MISSING_PAGE_ERROR_BANNER` if absent.
- The page error banner placeholder is empty — no content between the opening and closing tags. Drift code: `FORBIDDEN_PAGE_ERROR_BANNER_CONTENT`.
- The page error banner placeholder appears immediately after the connection banner placeholder. Drift code: `PAGE_ERROR_BANNER_ORDER_VIOLATION`.
- Page-specific content begins after the page error banner placeholder.

### 1.5 Helper-emitted HTML fragments

A helper module function that emits an HTML fragment for substitution into a page shell — `Get-NavBarHtml`, `Get-PageHeaderHtml`, `Get-HomePageSections`, and similar — produces partial markup, not a complete page. Helper-emitted fragments are governed by Section 5 (Class attribute conventions), Section 6 (Action dispatch via data-action attributes), and other applicable attribute-level rules, but are not subject to the page-shell rules in §1.1–1.4.

### 1.6 Access-denied page

The 403 Access Denied response — emitted by `Get-AccessDeniedHtml` in `xFACts-Helpers.psm1` — is a complete HTML page returned before authenticated page resources are reachable. It is subject to the same spec rules as every other emission. There are no rule carve-outs for the access-denied page; any drift its emission produces is real drift that should be resolved by bringing the page into compliance with the standard page shell, not by spec exemption.

The decision to remove access-denied carve-outs reflects a deliberate "no shortcuts, no half-measures" stance: a page that emits HTML must conform to the HTML spec. If the access-denied page needs to render before authenticated resources are reachable, it must do so within the same structural rules every other page follows.

---

## 2. Page chrome

The page chrome is the set of structural elements every conforming page renders, regardless of page-specific content. Chrome elements connect the page to the shared `cc-shared.js` runtime, the WebSocket engine-events stream, and the live-update timing system. The exact markup of every chrome element is mandated; deviations are drift.

### 2.1 Page header bar

The page header bar appears as the first content element after `$navHtml`. The header bar contains the page title block on the left and the refresh chrome on the right.

The header bar's outer structure is exactly:

```
<div class="cc-header-bar">
    <div>
        $headerHtml
    </div>
    <div class="cc-header-right">
        <div class="cc-refresh-info">...</div>
        <div class="cc-engine-row">...</div>     ← optional, see §2.3
    </div>
</div>
```

#### 2.1.1 Header bar rules

- The outer container is exactly `<div class="cc-header-bar">`. Drift code: `MALFORMED_HEADER_BAR_CONTAINER`.
- The first child of `cc-header-bar` is exactly `<div>` (no class) containing only the `$headerHtml` substitution. Drift code: `MALFORMED_HEADER_BAR_LEFT`.
- The second child of `cc-header-bar` is exactly `<div class="cc-header-right">`. Drift code: `MALFORMED_HEADER_BAR_RIGHT`.
- `cc-header-right` contains exactly `<div class="cc-refresh-info">` followed optionally by `<div class="cc-engine-row">`. No other children are permitted. Drift code: `MALFORMED_HEADER_RIGHT_CHILDREN`.

### 2.2 Refresh info block

The refresh info block contains the live indicator dot, the live-update status line, the last-update timestamp, and the page refresh button.

The refresh info block's markup is exactly:

```
<div class="cc-refresh-info">
    <span class="cc-live-indicator"></span>
    <span>Live</span> | Updated: <span id="cc-last-update" class="cc-last-updated">-</span>
    <button class="cc-page-refresh-btn" data-action-click="cc-page-refresh" title="Refresh all data">&#8635;</button>
</div>
```

#### 2.2.1 Refresh info rules

- The outer container is exactly `<div class="cc-refresh-info">`. Drift code: `MALFORMED_REFRESH_INFO_CONTAINER`.
- The first child is exactly `<span class="cc-live-indicator"></span>`. The element is empty (no content). Drift code: `MALFORMED_LIVE_INDICATOR`.
- The status line is exactly `<span>Live</span> | Updated: <span id="cc-last-update" class="cc-last-updated">-</span>`. The literal text `| Updated: ` between the two spans is required. The `cc-last-update` span's content is exactly the literal `-`. Drift code: `MALFORMED_LIVE_STATUS_LINE`.
- The page refresh button is exactly `<button class="cc-page-refresh-btn" data-action-click="cc-page-refresh" title="Refresh all data">&#8635;</button>`. Class, `data-action-click` value, title, and entity reference are mandated verbatim. Drift code: `MALFORMED_REFRESH_BUTTON`.
- The `cc-last-update` ID is the canonical chrome ID for the last-update timestamp. It appears exactly once per page. Drift code: `DUPLICATE_LAST_UPDATE_ID`.

### 2.3 Engine cards

A page that consumes engine events from the orchestrator displays engine cards inside the header bar. Engine cards are optional — pages without orchestrator-driven content omit the entire `cc-engine-row` block. Pages with engine cards must conform exactly to the rules in this section.

The engine row's markup is exactly:

```
<div class="cc-engine-row">
    <div class="cc-engine-card" id="cc-card-engine-<slug>">
        <span class="cc-engine-label">LABEL</span>
        <div class="cc-engine-bar disabled" id="cc-engine-bar-<slug>"></div>
        <span class="cc-engine-countdown" id="cc-engine-cd-<slug>">&nbsp;</span>
    </div>
    <div class="cc-engine-card" id="cc-card-engine-<slug>">
        ...
    </div>
    ...
</div>
```

The `disabled` token on the bar element is a compound modifier class (defined in `cc-shared.css` only as `.cc-engine-bar.disabled`) and is exempt from the `cc-` prefix rule per §5.1.1. JavaScript toggles `disabled` on/off as engine state changes.

#### 2.3.1 Engine row rules

- The outer container is exactly `<div class="cc-engine-row">`. Drift code: `MALFORMED_ENGINE_ROW_CONTAINER`.
- The engine row contains one or more `cc-engine-card` children, in declaration order matching `Orchestrator.ProcessRegistry.cc_sort_order` for the page's process set. Drift code: `ENGINE_CARD_ORDER_MISMATCH`.
- The engine row contains no other children. Drift code: `MALFORMED_ENGINE_ROW_CHILDREN`.

#### 2.3.2 Engine card rules

- Each engine card's structure is exactly the four-element block shown above: card div, label span, bar div, countdown span. Drift code: `MALFORMED_ENGINE_CARD`.
- The card div has exactly the classes `cc-engine-card` (no others) and the ID `cc-card-engine-<slug>`. Drift code: `MALFORMED_ENGINE_CARD_ATTRIBUTES`.
- The label span has exactly the class `cc-engine-label` and contains the engine label text from `Orchestrator.ProcessRegistry.cc_engine_label`. Drift code: `MALFORMED_ENGINE_LABEL`.
- The bar div has exactly the classes `cc-engine-bar disabled` and the ID `cc-engine-bar-<slug>`. The element is empty (no content). Drift code: `MALFORMED_ENGINE_BAR`.
- The countdown span has exactly the class `cc-engine-countdown` and the ID `cc-engine-cd-<slug>`. The element's content is exactly the entity reference `&nbsp;`. Drift code: `MALFORMED_ENGINE_COUNTDOWN`.

#### 2.3.3 Engine slug registry sourcing

The `<slug>` value used in the three IDs (`cc-card-engine-<slug>`, `cc-engine-bar-<slug>`, `cc-engine-cd-<slug>`) is sourced from `Orchestrator.ProcessRegistry.cc_engine_slug` for the orchestrator process the card represents.

The four cc-prefixed columns on ProcessRegistry govern engine card display:

| Column | Purpose |
|---|---|
| `cc_engine_slug` | The slug used in card IDs (e.g., `nb`, `pmt`, `collect`). |
| `cc_engine_label` | The text shown in the `cc-engine-label` span (e.g., `NB`, `PMT`, `Collect`). |
| `cc_page_route` | The page route on which this process appears as an engine card. |
| `cc_sort_order` | The display order of the card within the page's engine row. |

The `run_mode` column on ProcessRegistry determines whether the four cc-prefixed columns must be populated:

- `run_mode = 1` (active scheduled process) → all four cc-prefixed columns must be populated. The HTML populator emits `MISSING_ENGINE_CARD_REGISTRATION` against the corresponding engine card if any are NULL.
- `run_mode = 2` (active on-demand process / queue processor) → all four cc-prefixed columns must be NULL. Queue processors do not appear as engine cards, so they produce no HTML drift; a queue processor row with populated cc-prefixed columns is a registry-side data integrity violation surfaced by Q5 in §16, not by the HTML populator.
- `run_mode = 0` (inactive) → either acceptable; inactive processes are not validated.

#### 2.3.4 Slug validation rules

The HTML populator validates the slug used in engine card IDs against `Orchestrator.ProcessRegistry.cc_engine_slug` for the process the card represents.

- The `<slug>` value in `cc-card-engine-<slug>`, `cc-engine-bar-<slug>`, and `cc-engine-cd-<slug>` must match the `cc_engine_slug` registered for the corresponding process. Drift code: `ENGINE_SLUG_REGISTRY_MISMATCH`.
- The label text inside the `cc-engine-label` span must match the `cc_engine_label` registered for the corresponding process. Drift code: `ENGINE_LABEL_REGISTRY_MISMATCH`.
- The page emitting the engine card must match the process's `cc_page_route`. Drift code: `ENGINE_CARD_PAGE_MISMATCH`.

Additional validations of the JS-side `ENGINE_PROCESSES` declaration against the registry are governed by the JavaScript spec, not this spec. Those drift codes are emitted by the JS populator on rows with `file_type = 'JS'`.

### 2.4 Connection banner placeholder

The connection banner placeholder is governed by §1.4 (an empty `<div>` with `id="cc-connection-banner"` and `class="cc-connection-banner"`, appearing exactly once per page). The banner's content is rendered at runtime by `cc-shared.js` based on WebSocket connection state. The placeholder element exists only as a DOM target for the runtime.

### 2.5 Page error banner placeholder

The page error banner placeholder is governed by §1.4 (an empty `<div>` with `id="cc-page-error-banner"` and `class="cc-page-error-banner"`, appearing exactly once per page, immediately after the connection banner placeholder). The banner's content is rendered at runtime by `cc-shared.js` when page module loading or initialization fails. The placeholder element exists only as a DOM target for the runtime.

---

## 3. Asset references

A page references external CSS and JavaScript files via `<link rel="stylesheet">` and `<script src="">` elements. Asset references identify the file path to load, the load order, and the placement within the page shell.

### 3.1 CSS file references

CSS file references appear inside `<head>` between the `<title>` element and the closing `</head>` tag. A page references exactly two CSS files, in this exact order:

```
<link rel="stylesheet" href="/css/<page>.css">
<link rel="stylesheet" href="/css/cc-shared.css">
```

#### 3.1.1 CSS reference rules

- Every CSS reference uses the form `<link rel="stylesheet" href="...">` exactly. No additional attributes are permitted (no `type=`, no `media=`, no `crossorigin=`). Drift code: `MALFORMED_CSS_LINK`.
- The first CSS reference is the page-specific stylesheet. Its `href` value is `/css/<page>.css` where `<page>` matches the page's URL slug. Drift code: `MALFORMED_PAGE_CSS_REFERENCE`.
- The second CSS reference is exactly `<link rel="stylesheet" href="/css/cc-shared.css">`. Drift code: `MALFORMED_SHARED_CSS_REFERENCE`.
- The page-specific reference appears before the shared reference. Drift code: `CSS_REFERENCE_ORDER_VIOLATION`.
- Exactly two CSS references appear in `<head>`. Pages do not load other CSS files. Drift code: `UNEXPECTED_CSS_REFERENCE`.

### 3.2 JavaScript file reference

Exactly one JavaScript file is referenced in HTML markup, via a single `<script>` tag appearing immediately before the closing `</body>` tag:

```
<script src="/js/cc-shared.js"></script>
```

The page-specific JS file (e.g., `/js/batch-monitoring.js`) is loaded dynamically by the bootloader in `cc-shared.js` based on the `data-cc-page` attribute (§1.2). It does not appear in HTML markup as a `<script>` tag and is not catalogued as a `JS_FILE USAGE` row from HTML.

#### 3.2.1 JS reference rules

- The `<script>` tag uses the form `<script src="..."></script>` exactly. The element is empty (no content between opening and closing tags). No additional attributes are permitted (no `type=`, no `defer`, no `async`, no `crossorigin=`). Drift code: `MALFORMED_JS_SCRIPT`.
- Exactly one `<script>` tag appears in `<body>`. Drift code: `MISSING_SHARED_SCRIPT_TAG` if absent; `UNEXPECTED_SCRIPT_TAG` if more than one `<script>` tag is present.
- The `<script>` tag's `src` value is exactly `/js/cc-shared.js`. Drift code: `WRONG_SCRIPT_SOURCE`.
- The `<script>` tag is the last content inside `<body>`. No other elements appear between the `<script>` tag and the closing `</body>` tag. Drift code: `JS_REFERENCE_NOT_LAST`.
- A `<script>` element containing body content (i.e., not the asset reference form `<script src="..."></script>`) is forbidden. Drift code: `FORBIDDEN_INLINE_SCRIPT_BLOCK`. (See §12.12.)

### 3.3 Asset path mapping

The `<page>` placeholder in CSS reference paths and the `data-cc-page` attribute value both match the page's URL slug:

| Page route | CSS path | `data-cc-page` value |
|---|---|---|
| `/batch-monitoring` | `/css/batch-monitoring.css` | `batch-monitoring` |
| `/departmental/business-services` | `/css/business-services.css` | `business-services` |
| `/server-health` | `/css/server-health.css` | `server-health` |

The slug is derived from the rightmost path segment of the page route, lowercase, hyphen-separated.

The HTML populator resolves each CSS reference against `CSS_FILE` definition rows already in the catalog. References that resolve to a known file have `source_file` populated with the matching definition's file path. References that do not resolve (the target file does not exist or has not been cataloged yet) have `source_file = '<undefined>'`. This mirrors the `CSS_CLASS USAGE` resolution pattern.

The single `<script src="/js/cc-shared.js">` reference resolves to the `JS_FILE DEFINITION` row for `cc-shared.js` emitted by the JS populator. Per pipeline order (CSS → HTML → JS → PS), this reference resolves at HTML-populator scan time only when the JS populator has previously run; in standalone runs, the reference resolves to `source_file = '<undefined>'`. This is the structural resolution gap discussed in the populator pipeline; it is a property of pipeline order, not of HTML conformance.

### 3.4 Inline asset blocks

The HTML spec forbids inline `<style>` blocks, inline `style="..."` attributes, and inline `<script>` blocks containing code (script blocks with `src=` only are permitted per §3.2). These are enumerated in Section 12 (Forbidden patterns).

### 3.5 Asset references in helper-emitted HTML

Helper module functions that emit HTML fragments (e.g., `Get-NavBarHtml`, `Get-PageHeaderHtml`) do not declare asset references. Their output is consumed by route files via `$variable` substitution and inherits the asset references declared by the consuming page. Helper-emitted HTML fragments containing `<link>` or `<script>` elements are drift. Drift code: `FORBIDDEN_HELPER_ASSET_REFERENCE`.

---

## 4. ID conventions

Element IDs are unique identifiers assigned via the `id="..."` attribute. IDs serve as DOM lookup targets for JavaScript (`getElementById`), CSS hooks for chrome elements, and ARIA reference anchors.

### 4.0 Unified prefix rule

Every identifier in xFACts HTML markup — every ID, every page-local CSS class name, and every page-emitted `data-*` attribute name — carries a prefix indicating its source. The prefix is either:

- The page's `cc_prefix` from `Component_Registry` (e.g., `bkp`, `bsv`, `bch`) for page-local identifiers, or
- The literal token `cc-` for platform-shared chrome identifiers.

Every ID, class, and page-emitted data-attribute name begins with one of these two prefixes followed by a hyphen. An identifier with neither prefix is drift. Drift code: `MISSING_PREFIX_ID` (for IDs), `CLASS_PREFIX_MISMATCH` (for classes), `MALFORMED_DATA_ATTRIBUTE_NAME` (for data-* names without an accepted prefix).

**Exemption: compound modifier classes.** A class token that is defined in CSS only as the rightmost component of a compound selector (e.g., `disabled` defined only as `.cc-engine-bar.disabled`) is a compound modifier. Compound modifiers are exempt from the prefix rule and are recognized by the CSS populator's compound-modifier resolution. Their validity in markup depends on the companion class on the same element being a registered compound base for that modifier. The CSS spec governs compound modifier definition and resolution.

### 4.1 Chrome IDs

Chrome IDs are platform-wide identifiers used by `cc-shared.js`, `cc-shared.css`, and the WebSocket runtime to locate specific DOM elements. The set of chrome IDs is closed; pages do not invent new chrome IDs. Adding a new chrome ID to the platform requires a spec amendment to add it to the table below.

| Chrome ID | Purpose | Defined in |
|---|---|---|
| `cc-last-update` | Timestamp display target. Updated by `cc-shared.js` on each successful refresh. | §2.2 |
| `cc-connection-banner` | Connection state banner placeholder. Populated by `cc-shared.js` on WebSocket state change. | §1.4, §2.4 |
| `cc-page-error-banner` | Page boot error banner placeholder. Populated by `cc-shared.js` when page module loading or initialization fails. | §1.4, §2.5 |
| `cc-card-engine-<slug>` | Engine card outer container. Slug from `Orchestrator.ProcessRegistry.cc_engine_slug`. | §2.3 |
| `cc-engine-bar-<slug>` | Engine status bar element. Updated by WebSocket events. | §2.3 |
| `cc-engine-cd-<slug>` | Engine countdown text element. Updated by JS-side timer logic. | §2.3 |

#### 4.1.1 Chrome ID rules

- A page must declare each chrome ID exactly when its associated chrome element is present. Chrome ID declaration is governed by the rules in the section that defines the element (§1.4 for connection banner and page error banner, §2.2 for last-update, §2.3 for engine card IDs).
- Chrome IDs are never used as page-local IDs. A page-local element may not be assigned `id="cc-last-update"` or any other chrome ID. Drift code: `CHROME_ID_REUSED_AS_LOCAL`.
- Chrome IDs are never used in CSS selectors. The CSS spec forbids ID selectors entirely (§13 of CSS spec, drift code `FORBIDDEN_ID_SELECTOR`); chrome IDs exist solely for JS DOM lookups. This is enforced by the CSS spec.

### 4.2 Page-local IDs

Page-local IDs are page-author-defined identifiers used as DOM lookup targets for page-specific JavaScript and as anchor points for slideouts, modals, and form controls. Page-local IDs must be prefixed with the page's `cc_prefix` from `Component_Registry`.

#### 4.2.1 Page-local ID format

A page-local ID has the form `<prefix>-<purpose>` where:

- `<prefix>` is the page's three-character prefix from `Component_Registry.cc_prefix` (e.g., `bsv`, `bkp`, `bch`).
- `<purpose>` is a descriptive identifier, lowercase, hyphen-separated, indicating what the element is or what it contains (e.g., `pipeline-card-host`, `slideout-title`, `detail-modal-body`).

Example: `bsv-history-tree`, `bkp-storage-drive-c`, `bch-batch-slideout-overlay`.

#### 4.2.2 Page-local ID rules

- Every page-local ID begins with the page's registered `cc_prefix` followed by a hyphen. Drift code: `MISSING_PREFIX_ID`.
- An ID that begins with a known prefix from another page's registration emits drift indicating cross-page prefix collision. Drift code: `CROSS_PAGE_PREFIX_COLLISION`.
- Page-local IDs are unique within the page. The same ID value declared more than once on a page emits drift on every duplicate. Drift code: `DUPLICATE_ID_DECLARATION`.
- Page-local IDs use lowercase letters, digits, and hyphens only. Other characters (underscores, periods, mixed case) emit drift. Drift code: `MALFORMED_ID_VALUE`.

#### 4.2.3 JavaScript references to page-local IDs

JavaScript code that references page-local IDs (e.g., `document.getElementById('bsv-modal-detail')`) must use the same prefixed form as the HTML declaration. The HTML populator emits `HTML_ID DEFINITION` rows for IDs declared in markup; the JS populator (running after HTML in the populator pipeline) emits `HTML_ID USAGE` rows for IDs referenced in JS. The two row types resolve against each other via `component_name` at JS-populator scan time.

A JS reference to an ID with no matching HTML declaration resolves with `source_file = '<undefined>'`. The HTML populator does not emit drift on the JS side; cross-spec validation of ID-string formatting in JS code is the JavaScript spec's responsibility. The HTML populator's role is to produce the authoritative `HTML_ID DEFINITION` rows that the JS populator resolves against.

### 4.3 Slideout, modal, and panel IDs

Slideouts, modals, and slide-up panels are common page constructs that anchor multiple related elements via IDs. The spec mandates a convention for these ID groupings to keep cross-page comparison meaningful.

#### 4.3.1 Slideout ID convention

A slideout consists of an overlay element and a panel element. The IDs for both follow this form:

- Overlay: `<prefix>-slideout-<purpose>-overlay`
- Panel: `<prefix>-slideout-<purpose>`

Example: a request-detail slideout on the BusinessServices page would use `bsv-slideout-request-overlay` (overlay) and `bsv-slideout-request` (panel).

#### 4.3.2 Modal ID convention

A modal is a single construct identified by one ID on its outermost `.xf-modal-overlay` element. The modal's structure is a `.xf-modal-overlay` containing a nested `.xf-modal`, which contains the modal's header, body, and action elements.

- Outer element ID: `<prefix>-modal-<purpose>`

The nested `.xf-modal` element carries no ID. Sub-elements inside the modal (header title text, body content slot, action buttons) may carry their own page-local IDs for content-update purposes; those IDs follow the standard page-local ID format in §4.2.1.

Example: a delete-confirmation modal on the BusinessServices page uses `bsv-modal-delete` on the outer overlay element.

#### 4.3.3 Slide-up panel ID convention

A slide-up panel consists of a backdrop element and a panel element:

- Backdrop: `<prefix>-slideup-<purpose>-backdrop`
- Panel: `<prefix>-slideup-<purpose>`

#### 4.3.4 Slideout, modal, and panel rules

- A slideout's overlay and panel IDs both use the `<prefix>-slideout-<purpose>-*` form. Drift code: `MALFORMED_SLIDEOUT_ID`.
- A modal's outer element ID uses the `<prefix>-modal-<purpose>` form. Drift code: `MALFORMED_MODAL_ID`.
- A slide-up panel's backdrop and panel IDs both use the `<prefix>-slideup-<purpose>-*` form. Drift code: `MALFORMED_SLIDEUP_ID`.
- A slideout that declares one half of the overlay/panel pair without the other emits drift. Drift code: `INCOMPLETE_OVERLAY_PAIR`. The same rule applies to slide-up panels (backdrop and panel both required). Modals are single-element constructs and are not subject to this rule.
- A modal's outer element has class `xf-modal-overlay` and contains exactly one direct child with class `xf-modal`. A modal missing the nested `.xf-modal` child emits drift. Drift code: `MALFORMED_MODAL_STRUCTURE`.

#### 4.3.5 Overlay panel contiguity

Slideouts, modals, and slide-up panels are layered overlay constructs that float above the page's normal flow. They are not part of any specific page section — they sit outside the page's content layout and surface via JavaScript when triggered.

A page that declares slideouts, modals, and/or slide-up panels groups all such declarations into a single contiguous block of markup. The block is the last content in the body before the `<script>` tag, after all page-specific section content. Non-overlay structural elements (page content cards, layout containers, form sections) do not interleave with overlay panel declarations.

A page with two slideouts and one modal declares them as one block:

```
<!-- ... page content sections ... -->

<!-- Slideout for request details -->
<div id="bsv-slideout-request-overlay" ...></div>
<div id="bsv-slideout-request" ...>...</div>

<!-- Slideout for comment thread -->
<div id="bsv-slideout-comments-overlay" ...></div>
<div id="bsv-slideout-comments" ...>...</div>

<!-- Modal for delete confirmation -->
<div id="bsv-modal-delete" class="xf-modal-overlay hidden">
    <div class="xf-modal">
        <div class="xf-modal-header">...</div>
        <div class="xf-modal-body">...</div>
        <div class="xf-modal-actions">...</div>
    </div>
</div>

<script src="/js/cc-shared.js"></script>
```

If a slideout, modal, or slide-up panel declaration is interleaved with non-overlay structural content, drift fires on the constructs that break the contiguous run. Drift code: `OVERLAY_PANEL_NOT_CONTIGUOUS`.

The rule serves catalog clarity: overlay panels are conceptually outside the page's normal content flow, and their grouping in markup mirrors that conceptual separation. It also makes the panel-purpose comment convention (§4.3.6) cleaner to author and read: a single block of overlay declarations with one purpose comment per pair is easier to scan than overlay declarations sprinkled throughout the page.

#### 4.3.6 Purpose comments

Every slideout, modal, and slide-up panel declaration must be preceded by an HTML comment describing the purpose of the construct. The comment immediately precedes the construct's outermost element.

```
<!-- Slideout for displaying request details with comments and timeline -->
<div id="bsv-slideout-request-overlay" class="slide-panel-overlay" data-action-click="close-request-slideout"></div>
<div id="bsv-slideout-request" class="slide-panel xwide">...</div>
```

```
<!-- Modal for confirming the delete operation -->
<div id="bsv-modal-delete" class="xf-modal-overlay hidden">
    <div class="xf-modal">...</div>
</div>
```

The comment text is read by the HTML populator into the `purpose_description` column of the row(s) for the construct. For slideouts and slide-up panels, the purpose text is written to both rows of the pair. For modals (single-element constructs), the purpose text is written to the single row.

Drift code: `MISSING_PANEL_PURPOSE_COMMENT` if a slideout, modal, or slide-up panel declaration is not preceded by an HTML comment.

### 4.4 Form field IDs

Form input elements (`<input>`, `<select>`, `<textarea>`) used as page-local form fields follow the page-local ID format defined in §4.2. The spec does not mandate a specific naming convention beyond the prefix-and-hyphen rule (e.g., `bsv-date-range-start` is permitted; `bsv-input-modal-field` is permitted).

### 4.5 IDs in helper-emitted HTML

Helper module functions that emit HTML fragments (e.g., `Get-NavBarHtml`, `Get-PageHeaderHtml`) may declare IDs that are platform-shared rather than page-local. These IDs follow the same chrome-ID rules in §4.1: they are part of the platform's chrome contract and are not subject to page-prefix rules.

A helper function emitting HTML with a page-prefixed ID is drift, since helpers do not belong to a specific page. Drift code: `FORBIDDEN_HELPER_PAGE_PREFIX_ID`.

---

## 5. Class attribute conventions

The `class` attribute on HTML elements references CSS classes that style the element. Class references in HTML are catalog `CSS_CLASS USAGE` rows; they resolve against `CSS_CLASS DEFINITION` rows emitted by the CSS populator.

Class attribute values fall into two categories: static values (the class names are literal strings in the markup) and dynamic values (the class names are computed from PowerShell variables). Each category has its own rules.

### 5.1 Static class values

A static class value is a literal string with no PowerShell variable interpolation. Each space-separated token in the value is one class name and produces one `CSS_CLASS USAGE` row.

```
<div class="bsv-pipeline-card">                       ← one class
<div class="bsv-pipeline-card warning">               ← two classes
<div class="bsv-pipeline-card warning highlighted">   ← three classes
```

#### 5.1.1 Static class rules

- A class attribute value contains zero or more class names separated by single spaces. Multiple consecutive spaces, leading or trailing whitespace, and tabs within the value emit drift. Drift code: `MALFORMED_CLASS_VALUE_WHITESPACE`.
- Each class name in the value uses lowercase letters, digits, and hyphens only. Other characters (uppercase, underscores, periods) emit drift on the row for that class. Drift code: `MALFORMED_CLASS_NAME`.
- Each class name is unique within the value. Duplicate class names in the same attribute (e.g., `class="card card"`) emit drift. Drift code: `DUPLICATE_CLASS_IN_VALUE`.
- Every class name begins with the page's `cc_prefix` (page-local) or with `cc-` (shared chrome), per the unified prefix rule in §4.0. A class name that satisfies neither prefix and is not a recognized compound modifier emits drift. Drift code: `CLASS_PREFIX_MISMATCH`.
- A compound modifier class (one defined in CSS only as the rightmost component of a compound selector — e.g., `disabled` defined only as `.cc-engine-bar.disabled`) is exempt from the prefix rule. A compound modifier appearing on an element whose companion class is not a registered compound base for that modifier emits drift. Drift code: `INVALID_MODIFIER_CONTEXT`. The CSS spec governs compound modifier definition and resolution.

### 5.2 Dynamic class values

A dynamic class value is one where part or all of the attribute value is computed from a PowerShell variable. This pattern is required when class composition depends on runtime state — active/inactive flags, status indicators, conditional modifiers.

The spec mandates exactly one pattern for dynamic class assembly. All other forms of dynamic class composition are forbidden.

#### 5.2.1 The mandated pattern

A dynamic class value is built by:

1. Initializing a PowerShell array variable with the base class as its first element.
2. Conditionally appending modifier classes to the array.
3. Joining the array with a single space.
4. Substituting the joined string into the attribute via PowerShell variable interpolation.

```powershell
$classList = @('nav-link')
if ($isActive) { $classList += 'active' }
if ($accentClass) { $classList += $accentClass }
$cssClasses = ($classList -join ' ')

# In the HTML emission:
[void]$sb.AppendLine("<a class=`"$cssClasses`">$label</a>")
```

The resulting `class` attribute value contains exactly one substitution token (`$cssClasses`) and no other content. The classes it expands to are determined entirely by the array contents.

#### 5.2.2 Dynamic class rules

- A class attribute containing PowerShell variable interpolation must use the array-join pattern. The attribute value is exactly `class="$<variable>"` with the variable holding the joined string.
- The array variable's first element is the base class — the class that always appears regardless of state. Subsequent elements are conditional modifiers. The array literal must be the first construct in the assembly sequence.
- The array elements that are literal strings produce `CSS_CLASS USAGE` rows in the catalog. Conditionally-appended dynamic values (variables holding strings determined at runtime, such as parameters passed into the function) are not catalogable individually; their presence is recorded via the `has_dynamic_content` flag on the static rows from the same attribute (see §5.5).

#### 5.2.3 Forbidden dynamic patterns

| Pattern | Drift code |
|---|---|
| `class="nav-link$accent"` (interpolation appended to static text) | `INLINE_CLASS_CONCATENATION` |
| `class="$type wide"` or `class="card $modifier"` (interpolation followed or preceded by static text) | `INLINE_CLASS_PREFIX_MIX` |
| `class="$a $b"` (multiple top-level interpolations, neither using array-join) | `INLINE_CLASS_MULTI_INTERPOLATION` |
| `class="${a}wide"` or `class="$($section.accent)wide"` (PowerShell `${...}` or `$(...)` form mixed with static text) | `INLINE_CLASS_BRACED_INTERPOLATION` |

The mandated array-join pattern (§5.2.1) is the only legitimate way to construct a dynamic class string. Each forbidden form has its own drift code so resolution is precise and queryable.

### 5.3 Class catalog rows

Each class name in HTML markup produces one `CSS_CLASS USAGE` row.

| Column | Value |
|---|---|
| `component_type` | `CSS_CLASS` |
| `component_name` | The class name (e.g., `bsv-pipeline-card`, `nav-link`) |
| `reference_type` | `USAGE` |
| `signature` | The full `class="..."` attribute value, including all class names in the attribute |
| `scope` | Resolved from CSS_CLASS DEFINITION rows: `SHARED` if defined in `cc-shared.css`, `LOCAL` if defined in a page-specific CSS file |
| `source_file` | The file containing the matching DEFINITION row, or `'<undefined>'` if no match |
| `parent_function` | The PS function emitting the markup (when applicable) |
| `has_dynamic_content` | TRUE when the class attribute also contains runtime-only class composition not statically catalogable; FALSE when the attribute is fully resolved |

The `signature` column carries the full attribute value (not just the individual class name), which makes class-combination queries possible — "find every place where `bsv-pipeline-card` appears with `warning`" is a single signature pattern match.

### 5.4 Class references in helper-emitted HTML

Helper module functions that emit HTML fragments produce class references the same way route files do. Helper-emitted classes resolve against the same CSS DEFINITION rows. There is no special handling for helpers — class rules apply uniformly.

When a helper uses dynamic class assembly (the array-join pattern), the array literal and conditional appends within the helper function's body are visible to the populator. Variables passed into the helper as parameters (e.g., `$accentClass` from a caller) are not statically resolvable; their presence is recorded via `has_dynamic_content` on the helper's static class rows (see §5.5).

### 5.5 Static fragments and the dynamic content flag

The populator emits `CSS_CLASS USAGE` rows for every class name it can statically resolve in a class attribute value. When the attribute also contains runtime-only class composition (parameter-passed classes, classes built from data the populator cannot read), the populator does not invent rows for the unresolvable portions. Instead, it sets `has_dynamic_content = TRUE` on the static rows from the same attribute.

For example:

```powershell
function Get-NavLinkHtml {
    param([string]$AccentClass, [bool]$IsActive)

    $classList = @('nav-link')
    if ($IsActive) { $classList += 'active' }
    if ($AccentClass) { $classList += $AccentClass }
    $cssClasses = ($classList -join ' ')

    return "<a class=`"$cssClasses`">Link</a>"
}
```

The populator emits:

- `CSS_CLASS USAGE` for `nav-link` with `has_dynamic_content = TRUE` (literal in array initialization, but a parameter-passed class is also being conditionally added)
- `CSS_CLASS USAGE` for `active` with `has_dynamic_content = TRUE` (literal in conditional append, same reason)

If `$AccentClass` is replaced with another literal string (e.g., a hardcoded `'departmental'`), the populator emits a third row for `departmental` and updates all three rows to `has_dynamic_content = FALSE` (no remaining unresolvable composition).

The `has_dynamic_content` flag lets queries distinguish between:

- Class compositions the catalog has fully captured (`has_dynamic_content = FALSE`)
- Class compositions where additional runtime classes may also be applied (`has_dynamic_content = TRUE`)

This flag also applies to JS-side class extraction (Group A rows from JS template literals). It is not meaningful for CSS rows, which are always fully literal.

### 5.6 Class catalog and CSS resolution

The HTML populator resolves each emitted `CSS_CLASS USAGE` row's `scope` and `source_file` columns against `CSS_CLASS DEFINITION` rows already in the catalog at populator scan time. Per the populator pipeline order (CSS → HTML → JS → PS), CSS DEFINITION rows always exist before HTML scans, except in standalone-reload scenarios.

When standalone-reloading the HTML populator before CSS has been populated, every USAGE row emitted will resolve to `scope = LOCAL` and `source_file = '<undefined>'`. The populator emits a startup warning when no CSS DEFINITION rows are present and continues without resolution.

---

## 6. Action dispatch via data-action attributes

Pages connect user interactions to JavaScript by declaring `data-action-<event>` attributes on HTML elements. The JavaScript file boots via the bootloader in `cc-shared.js`, which registers delegated event listeners on `document.body`; those listeners route events to handler functions by looking up the `data-action-<event>` value in a dispatch table.

This section governs the shape of the HTML attributes. The JS-side dispatch tables and their structure are governed by the JavaScript spec.

### 6.1 Action attribute format

Every action attribute uses the form `data-action-<event>="<action-value>"` where:

- `<event>` is one of the recognized event names from §6.4
- `<action-value>` is a kebab-case identifier (lowercase letters, digits, and hyphens) naming the action

Action values fall into two categories:

- **Page-local actions** are unprefixed (e.g., `open-request-detail`, `filter-by-status`). They dispatch through the page's own dispatch table (`<prefix>_<event>Actions`, defined in the page's JS file).
- **Shared chrome actions** are `cc-` prefixed (e.g., `cc-page-refresh`, `cc-reload-page`). They dispatch through `cc_clickActions`, `cc_changeActions`, etc., defined in `cc-shared.js`. See CC_JS_Spec.md §11.3.2 for the chrome dispatch table naming and structure.

Action values occupy their own resolution namespace and are not subject to the unified prefix rule in §4.0 (which governs IDs, classes, and page-emitted `data-*` attribute names). The `data-action-` attribute name itself is the chrome prefix; the value space distinguishes page-local from shared by the presence or absence of the `cc-` value prefix.

```
<button data-action-click="open-request-detail">View</button>
<button data-action-click="cc-page-refresh">Refresh</button>
<select data-action-change="filter-by-status">...</select>
<input data-action-keydown="search-on-enter">
```

### 6.2 Action attribute rules

- Every action attribute name is exactly `data-action-<event>` where `<event>` is in the closed set from §6.4. Drift code: `UNKNOWN_EVENT_TYPE`.
- Every action value uses lowercase letters, digits, and hyphens only. Other characters emit drift. Drift code: `MALFORMED_ACTION_VALUE`.
- Page-local action values are unprefixed. Shared action values use the `cc-` prefix exactly. Action values that begin with `cc-` resolve against the shared dispatch table; action values without `cc-` resolve against the page's local dispatch table.
- An action value (page-local or shared) must have a matching entry in the corresponding dispatch table. If no match exists, drift code: `UNRESOLVED_DATA_ACTION`. Resolution is event-type-scoped: a `data-action-click="save"` resolves against `<prefix>_clickActions['save']` or `cc_clickActions['save']`, not against any other event's dispatch table.

### 6.3 Action argument attributes

An element with a `data-action-<event>` attribute may declare zero or more argument attributes that pass data to the dispatched handler.

```
<button data-action-click="open-batch-detail" data-action-batch-id="12345">Open</button>
<select data-action-change="filter-by-priority" data-action-default-priority="high">...</select>
```

Argument attributes use the form `data-action-<arg-name>="<value>"` where:

- `<arg-name>` is a kebab-case identifier (lowercase letters, digits, hyphens)
- `<arg-name>` must not be any value from the recognized event list in §6.4

The JS handler reads each argument via the corresponding dataset property using the standard kebab-to-camelCase conversion: `data-action-batch-id` is read as `target.dataset.actionBatchId`.

#### 6.3.1 Argument attribute rules

- Every argument attribute appears on an element that also declares at least one `data-action-<event>` attribute. An argument attribute without an action attribute on the same element is orphaned. Drift code: `ORPHANED_ACTION_ARGUMENT`.
- An argument attribute's name (`<arg-name>` portion) must not match any event name from §6.4. (This prevents collision between argument attributes and event-type attributes.) Drift code: `ARGUMENT_NAME_COLLIDES_WITH_EVENT`.
- Argument attribute names use lowercase letters, digits, and hyphens only. Drift code: `MALFORMED_ACTION_ARGUMENT_NAME`.
- Argument attribute values are static strings. PowerShell variable interpolation in argument values follows the same rules as `data-*` attributes (§7.2): values must come from a fully-resolved variable, not mixed inline. Drift code: `FORBIDDEN_INLINE_ACTION_ARGUMENT_INTERPOLATION`.

### 6.4 Recognized events

The closed set of recognized events that may appear as the `<event>` portion of `data-action-<event>`:

| Event | When it fires |
|---|---|
| `click` | Mouse click or keyboard activation on the element |
| `change` | User changes a form control's value and the change is committed (typically when the control loses focus) |
| `input` | User changes a form control's value (fires on every keystroke or modification) |
| `submit` | A form is submitted |
| `keydown` | A keyboard key is pressed down while the element has focus |
| `keyup` | A keyboard key is released while the element has focus |
| `focus` | The element gains focus |
| `blur` | The element loses focus |

Events not in this set emit `UNKNOWN_EVENT_TYPE` drift on the offending attribute. Extending the recognized set requires a spec amendment to add a row to this table and a corresponding extension to the bootloader and to relevant pages' dispatch tables.

### 6.5 Catalog rows for action attributes

Each `data-action-<event>` attribute on each element produces one `HTML_DATA_ATTRIBUTE DEFINITION` row.

| Column | Value |
|---|---|
| `component_type` | `HTML_DATA_ATTRIBUTE` |
| `component_name` | The attribute name including the `data-` prefix (e.g., `data-action-click`, `data-action-change`) |
| `reference_type` | `DEFINITION` |
| `signature` | The full attribute including the value (e.g., `data-action-click="open-detail"`) |
| `variant_type` | The action value (e.g., `open-detail`, `cc-page-refresh`) |
| `variant_qualifier_1` | The event name (e.g., `click`, `change`) |
| `scope` | `LOCAL` for page-local action values (no `cc-` prefix); `SHARED` for `cc-` prefixed action values |
| `source_file` | The file containing the row (route file or helper) |
| `parent_function` | The PS function emitting the markup (when applicable) |

The `variant_type` and `variant_qualifier_1` columns let the populator emit per-action rows that are queryable in two natural ways: "find every `data-action-click="open-detail"` declaration" and "find every action attribute targeting the `click` event."

Each `data-action-<arg-name>` attribute produces a separate `HTML_DATA_ATTRIBUTE DEFINITION` row using the same column shape, with `component_name = data-action-<arg-name>` and `variant_type` carrying the value. The argument attribute does not have a `variant_qualifier_1` because it is not tied to a specific event — it carries data for whichever event(s) the element declares.

### 6.6 Action attributes in helper-emitted HTML

Helper module functions emit only `cc-` prefixed action values. A helper emitting a page-local action value (one without `cc-` prefix) couples the helper to a specific page, defeating the purpose of having a helper. Drift code: `FORBIDDEN_HELPER_PAGE_ACTION`.

Argument attributes (`data-action-<arg-name>`) in helper-emitted HTML must derive their values entirely from data the helper received from its caller. Concretely, the value must be either a fully static string, or a string whose every PowerShell interpolation traces — at its root variable — to a parameter the helper declares (directly, or as the iterator over such a parameter via `foreach`).

Argument attribute values that interpolate script-scope variables, module-level variables, function calls, or any other state the helper reached out to obtain are forbidden. Such values represent the helper coupling itself to context outside the caller's intent. A helper that needs additional state must receive it as a parameter so the caller controls what the helper sees. Drift code: `FORBIDDEN_HELPER_PAGE_ACTION_ARGUMENT`.

---

## 7. data-* attribute conventions

The `data-*` attribute family is HTML's standard mechanism for attaching custom data to elements. Values are read by JavaScript at runtime via `element.dataset.<name>` (or `element.getAttribute('data-<name>')`). In Control Center pages, `data-*` attributes carry filter values, view state, sort modes, and similar JS-readable parameters that don't belong in `class` or `id`.

### 7.1 data-* attribute format

A `data-*` attribute name follows the form `data-<prefix>-<name>` where `<prefix>` is either the page's `cc_prefix` (for page-emitted attributes) or `cc` (for helper-emitted/chrome attributes), and `<name>` uses lowercase letters, digits, and hyphens only. The unified prefix rule in §4.0 applies to `data-*` attribute names just as it applies to IDs and classes.

```
<button data-bkp-filter="ALL">                       ← page-emitted (backup page, prefix bkp)
<button data-bsv-window="30">                        ← page-emitted (business services page)
<div data-bch-batch-id="12345">                      ← page-emitted (batch monitoring page)
<select data-cc-priority="high">                     ← helper-emitted / chrome
```

The `data-action-*` attribute family is governed by §6 (Action dispatch via data-action attributes), not by this section. This includes `data-action-<event>` attributes (action declarations) and `data-action-<arg-name>` attributes (action arguments). The `data-action-` attribute name is itself a recognized chrome prefix and is exempt from the unified prefix rule in §4.0; the generic `data-*` rules in §7.2 do not apply to those attributes. The more specific rules in §6.2 and §6.3.1 apply instead. All other `data-*` attributes (such as `data-bkp-filter`, `data-bch-batch-id`, `data-cc-window`) are governed by this section.

### 7.2 data-* attribute rules

- Attribute names use lowercase letters, digits, and hyphens only after the `data-` prefix. Drift code: `MALFORMED_DATA_ATTRIBUTE_NAME`.
- Page-emitted `data-*` attribute names begin with `data-<page_prefix>-` where `<page_prefix>` is the page's `cc_prefix` from `Component_Registry`. Helper-emitted `data-*` attribute names begin with `data-cc-`. A name that satisfies neither and is not in the `data-action-*` family emits drift. Drift code: `MALFORMED_DATA_ATTRIBUTE_NAME`.
- Attribute values are static strings. PowerShell variable interpolation in `data-*` values is forbidden except via the same rules as class attributes — values must come from a fully-resolved variable, not mixed inline. Drift code: `FORBIDDEN_INLINE_DATA_INTERPOLATION` for any attribute value containing both static text and `$` interpolation.
- A page-author may use any `<name>` portion within their prefix's namespace. There is no closed set; the catalog tracks every distinct name.
- `data-*` values are treated as opaque strings by the spec. The spec does not validate value content.

### 7.3 Catalog rows for data-* attributes

Each `data-*` attribute on each element produces one `HTML_DATA_ATTRIBUTE DEFINITION` row.

| Column | Value |
|---|---|
| `component_type` | `HTML_DATA_ATTRIBUTE` |
| `component_name` | The attribute name including the `data-` prefix (e.g., `data-bkp-filter`, `data-bch-batch-id`, `data-cc-priority`) |
| `reference_type` | `DEFINITION` |
| `signature` | The full attribute (e.g., `data-bkp-filter="ALL"`) |
| `scope` | `LOCAL` for page-emitted (page-prefixed) attributes; `SHARED` for helper-emitted (`cc-` prefixed) attributes |
| `source_file` | The file containing the row (route file or helper) |
| `parent_function` | The PS function emitting the markup (when applicable) |
| `has_dynamic_content` | TRUE when value composition involves runtime data; FALSE when fully static |

The `signature` carries the full attribute including the value, which makes value-comparison queries possible.

### 7.4 data-* attributes referenced from JavaScript

JavaScript code that reads `data-*` attributes (via `element.dataset.bkpFilter` or `element.getAttribute('data-bkp-filter')`) produces `HTML_DATA_ATTRIBUTE USAGE` rows in the JS populator. These rows resolve against the HTML populator's DEFINITION rows via `component_name`, mirroring the same pattern as ID and class resolution.

Cross-population validation rules for `data-*` references in JavaScript are governed by the JavaScript spec.

### 7.5 data-* attributes in helper-emitted HTML

Helper module functions emit only `data-cc-*` prefixed attributes. A helper emitting a `data-*` attribute with a page prefix (e.g., `data-bsv-filter`) couples the helper to a specific page. Drift code: `FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE`.

---

## 8. Text content and entity references

Text content is human-readable copy that appears in HTML markup — section titles, button labels, status messages, tooltip text, placeholder text. HTML entity references and direct Unicode characters are graphical glyphs (icons, special symbols) used as decorative or semantic content.

The catalog records text and entities for two reasons: structural completeness (every visible element is accounted for) and cross-page consistency comparison (similar UI elements should display similar copy across pages).

### 8.1 What counts as text content

Text content is any non-trivial character data that appears between HTML element opening and closing tags, plus user-facing attribute values that carry display text.

#### 8.1.1 Element text content

Character data appearing between an element's opening and closing tags is text content when it is not whitespace-only.

```
<h2>Live Activity</h2>                              ← "Live Activity" is text
<p>Loading data...</p>                              ← "Loading data..." is text
<button>Cancel</button>                             ← "Cancel" is text
<div>                                                ← whitespace-only, ignored
    <span>Hello</span>                              ← "Hello" is text
</div>
```

#### 8.1.2 User-facing attribute values

Four HTML attributes carry user-facing display text and are catalogued as text content:

| Attribute | Purpose |
|---|---|
| `title` | Tooltip text shown on hover |
| `placeholder` | Ghost text shown in empty form fields |
| `aria-label` | Screen-reader accessibility label |
| `alt` | Alternative text for images |

These are governed by §8.2 and §8.3 along with element text.

#### 8.1.3 What is not text content

The following are not catalogued as text content:

- Pure whitespace between elements (newlines, spaces used for indentation)
- Text inside `<script>` and `<style>` blocks (these are forbidden in route HTML by §12 anyway)
- HTML comment content (catalogued separately by §10)
- Element attribute values other than the four listed in §8.1.2

### 8.2 Text content rules

The catalog records text content as it appears, without normalization. Display copy variation across pages is the primary signal the catalog surfaces — different copy on similar elements is information, not noise.

- Text content character data is stored verbatim in the catalog row's `component_name` and `raw_text` columns. Whitespace within the text (interior spaces) is preserved. Leading and trailing whitespace is trimmed before storage.
- A text content row's `signature` indicates the source of the text (see §8.4).
- Text content containing PowerShell variable interpolation (e.g., `<h1>$pageTitle</h1>` or `title="Refresh $itemType"`) is catalogued with `has_dynamic_content = TRUE` on the row. The static portions are stored in `component_name`; the row signals the value will differ at runtime.
- The spec does not validate text content against any standard. Cross-page consistency emerges from catalog query analysis, not from spec mandates.

#### 8.2.1 Storage and length

Text content is stored in two columns:

- `component_name` — a categorical name derived from the element context (see §8.2.2). Always fits within the column's 256-character maximum.
- `raw_text` — the literal text content as it appears in the source, with no transformation other than trimming leading and trailing whitespace.

The categorical name is the queryable handle for cross-page comparison. The literal text in `raw_text` is the answer to "what does this page actually say?" Together they let queries scope by element kind (`component_name`) and inspect content (`raw_text`).

#### 8.2.2 Categorical name derivation

The HTML populator constructs `component_name` for each `HTML_TEXT` row by inspecting the parent element and applying these rules:

| Source | component_name |
|---|---|
| Text inside an element with one or more classes | `<tag>-<first-class-token-with-page-prefix-stripped>` |
| Text inside an element with no class | `<tag>-text` |
| Value of a user-facing attribute (`title`, `placeholder`, `aria-label`, `alt`) | `attr-<attribute-name>` |

The page prefix or the `cc-` chrome prefix is recognized and stripped from the leading class token. For page-local classes, the page's `cc_prefix` from `Component_Registry` is looked up. For shared chrome classes, the `cc-` prefix is stripped. The remaining token after prefix-stripping is used in `component_name`.

Examples:

| Source markup | component_name |
|---|---|
| `<h2 class="bsv-section-title">Live Activity</h2>` | `h2-section-title` |
| `<h2 class="cc-section-title">Live Activity</h2>` (shared chrome class) | `h2-section-title` |
| `<h2>No Title Class</h2>` | `h2-text` |
| `<button class="cc-page-refresh-btn" title="Refresh all data">↻</button>` (text node `↻`) | `button-page-refresh-btn` |
| `<span class="cc-engine-label">NB</span>` | `span-engine-label` |
| `<input placeholder="Search...">` (no text node, but the placeholder value is text) | `attr-placeholder` |
| `<button title="Refresh all data">↻</button>` (the title attribute value) | `attr-title` |

The categorical naming rule means cross-page comparison is direct:

- "All section titles platform-wide" → `WHERE component_name = 'h2-section-title'`
- "All loading messages" → `WHERE component_name LIKE '%-loading%'` (loose, since loading divs vary by tag)
- "All tooltip text" → `WHERE component_name = 'attr-title'`
- "All engine labels" → `WHERE component_name = 'span-engine-label'`

#### 8.2.3 Text inside helper-emitted HTML

Text content emitted by helper functions (e.g., the "Sorry, you don't have permission..." text in `Get-AccessDeniedHtml`) is catalogued the same way as route-emitted text, with `scope = SHARED`. This makes shared text content (which appears identically on every page) queryable as a distinct group.

### 8.3 Entity references and direct Unicode

HTML entity references (`&amp;`, `&times;`, `&#9881;`, etc.) and direct Unicode characters appearing as element text content or text-content attribute values are catalogued as a separate component type from regular text. They are typically used as icons, special symbols, or decorative glyphs.

#### 8.3.1 Forms catalogued

Three forms are catalogued as `HTML_ENTITY` rows:

| Form | Example | signature value |
|---|---|---|
| Named entity reference | `&times;`, `&nbsp;`, `&amp;` | `entity_named` |
| Numeric entity reference | `&#9881;`, `&#x2699;` | `entity_numeric` |
| Direct Unicode character | `⚙`, `⚡`, `→` (typed inline in the source) | `direct_unicode` |

A common ASCII string like "Hello World" is not catalogued as `HTML_ENTITY` — only special characters that serve as glyphs or symbols, which are characters above the basic ASCII printable range or named-entity escapes.

#### 8.3.2 Entity catalog rows

Each entity reference or direct Unicode character produces one `HTML_ENTITY DEFINITION` row.

| Column | Value |
|---|---|
| `component_type` | `HTML_ENTITY` |
| `component_name` | The literal entity reference or Unicode character (e.g., `&#9881;`, `⚙`) |
| `reference_type` | `DEFINITION` |
| `signature` | One of `entity_named`, `entity_numeric`, `direct_unicode` |
| `scope` | `LOCAL` for page-emitted entities; `SHARED` for helper-emitted entities |
| `source_file` | The file containing the row |
| `parent_function` | The PS function emitting the markup (when applicable) |

#### 8.3.3 Entity rules

The spec does not mandate which form (named entity, numeric entity, or direct Unicode) authors should use. The catalog tracks every distinct form used. Cross-form consistency is a Phase 3 candidate for tightening if catalog analysis surfaces inconsistency worth eliminating.

### 8.4 Signature column for text content

Under the categorical naming model (§8.2.2), `component_name` already carries the source distinction (`attr-title` vs `h2-section-title` vs `button-page-refresh-btn`). The `signature` column on `HTML_TEXT` rows is therefore unused for these rows; it is set to NULL.

This is a deliberate departure from the convention used for other row types (where `signature` distinguishes shape variants). For `HTML_TEXT`, the categorical `component_name` does that work directly.

### 8.5 Catalog rows for text content

Each text content node and each user-facing attribute value produces one `HTML_TEXT DEFINITION` row.

| Column | Value |
|---|---|
| `component_type` | `HTML_TEXT` |
| `component_name` | The categorical name derived per §8.2.2 (e.g., `h2-section-title`, `attr-title`) |
| `reference_type` | `DEFINITION` |
| `signature` | NULL (the categorical `component_name` already conveys source) |
| `scope` | `LOCAL` or `SHARED` based on whether the row originates in a route or helper |
| `source_file` | The file containing the row |
| `parent_function` | The PS function emitting the markup (when applicable) |
| `raw_text` | The literal text content as it appears in the source |
| `has_dynamic_content` | TRUE when the text contains PowerShell variable interpolation; FALSE when fully static |

### 8.6 Text content drift codes

The spec mandates few rules on text content because the catalog's purpose for text is primarily descriptive (surface what exists) rather than prescriptive (mandate what should be).

| Drift code | Trigger |
|---|---|
| `MALFORMED_TEXT_INTERPOLATION` | Text contains PowerShell variable interpolation that uses forbidden patterns from §5.2.3 (inline mixing, etc.) — the same patterns forbidden in class attributes |
| `EMPTY_DISPLAY_TEXT` | A user-facing attribute (`title`, `placeholder`, `aria-label`, `alt`) is declared with an empty value (e.g., `title=""`). User-facing attributes exist to display text; a declared-but-empty value is treated as an authoring error. |

These are the only text-content-specific drift codes. Cross-page consistency analysis happens via queries against the catalog, not via drift codes — the catalog model is the surfacing mechanism.

---

## 9. Inline SVG

Inline SVG is `<svg>...</svg>` markup embedded directly in HTML. SVG is used for icons, decorative graphics, and small diagrams that benefit from being part of the document rather than loaded as separate image files.

The HTML spec catalogs SVG at the outer-element level only — one row per `<svg>` element regardless of internal complexity. The internal structure of the SVG (paths, polygons, gradients, etc.) is stored in `raw_text` for reference but is not parsed into individual catalog rows.

### 9.1 What gets catalogued

Each `<svg>` element in HTML markup produces one `HTML_SVG DEFINITION` row.

```
<svg width="20" height="20" viewBox="0 0 20 20" fill="currentColor">
    <path d="M10 0c5.5 0 10 4.5 10 10..."/>
</svg>
```

The above produces one row. The `<path>` element inside is not catalogued separately.

### 9.2 SVG catalog rows

| Column | Value |
|---|---|
| `component_type` | `HTML_SVG` |
| `component_name` | A categorical name derived per §9.3 |
| `reference_type` | `DEFINITION` |
| `signature` | NULL (the categorical `component_name` already conveys source) |
| `scope` | `LOCAL` for page-emitted SVG; `SHARED` for helper-emitted SVG |
| `source_file` | The file containing the row |
| `parent_function` | The PS function emitting the markup (when applicable) |
| `raw_text` | The complete `<svg>...</svg>` markup, including all child elements and attributes |

### 9.3 SVG categorical naming

`component_name` for an SVG row follows the same derivation pattern as text content (§8.2.2), based on the SVG's class attribute:

| Source | component_name |
|---|---|
| `<svg class="bsv-icon-warning">...` | `svg-icon-warning` |
| `<svg class="cc-icon-success">...` (shared chrome class) | `svg-icon-success` |
| `<svg>...` (no class) | `svg-untagged` |

The page prefix or `cc-` chrome prefix is stripped from the leading class token by the same lookup as §8.2.2.

### 9.4 SVG content rules

- The `<svg>` element's outer attributes (`width`, `height`, `viewBox`, `fill`, etc.) are part of `raw_text` and not separately validated.
- The internal SVG structure is not validated by the spec. Whatever appears between `<svg>` and `</svg>` is stored verbatim.
- An SVG element that contains PowerShell variable interpolation in its outer attributes or internal markup emits `has_dynamic_content = TRUE`. The interpolation pattern itself is not enforced.

### 9.5 SVG and the inline-style discussion

`<svg>` elements may legitimately contain `<style>` blocks for SVG-internal styling. These are SVG-scoped, not HTML-scoped, and do not violate the §12 prohibition on inline `<style>` blocks in HTML. The spec recognizes this as an SVG-internal concern outside HTML spec validation.

### 9.6 SVG drift codes

The HTML spec mandates few rules on SVG content because SVG is treated as opaque markup at the catalog level.

| Drift code | Trigger |
|---|---|
| `MALFORMED_SVG_INTERPOLATION` | An SVG's outer markup contains PowerShell variable interpolation that uses forbidden patterns from §5.2.3 (inline mixing, etc.) |

This is the only SVG-specific drift code. Cross-page SVG consistency comparison happens via queries against `raw_text`.

---

## 10. Comments

HTML comments (`<!-- ... -->`) appear in route files as section dividers, structural annotations, and the purpose comments mandated for slideouts/modals/panels by §4.3.6. The HTML spec recognizes a small set of legitimate comment uses and catalogs them all.

### 10.1 Recognized comment kinds

Three kinds of HTML comments are recognized by the spec:

| Kind | Format | Purpose |
|---|---|---|
| Section divider | Multi-line block of `<!-- ===== -->` style | Visual separation between major content blocks within a route file's HTML |
| Inline annotation | Single-line `<!-- short text -->` | Brief contextual note on a specific element or block |
| Panel purpose comment | Single-line `<!-- short text -->` immediately preceding a slideout, modal, or slide-up panel | Required by §4.3.6; describes the construct's purpose |

### 10.2 Section dividers

A section divider is a multi-line block comment that visually separates major content blocks within an HTML emission. The format is:

```
<!-- ============================================================================
     SECTION TITLE
     ============================================================================ -->
```

Section dividers are useful when the HTML inside a single route handler grows large enough that visual separation aids readability. They are not required.

#### 10.2.1 Section divider rules

- The opening and closing rule lines are exactly 76 `=` characters (matching the CSS spec's banner convention).
- The title line is uppercase letters, digits, spaces, and select punctuation (commas, colons, hyphens). The title is human-readable.
- The block opens with `<!--` and closes with `-->`.
- A section divider may appear anywhere within the HTML body content — between the page header bar and content sections, between distinct content sections, or wherever visual separation aids reading.

### 10.3 Inline annotations

An inline annotation is a single-line comment providing brief context on the next element or block:

```
<!-- Toolbar across the top of the timeline -->
<div class="timeline-toolbar">
    ...
</div>
```

Inline annotations are optional and are not subject to a fixed format beyond standard HTML comment syntax.

### 10.4 Panel purpose comments

Panel purpose comments are required by §4.3.6 for slideouts, modals, and slide-up panels. They are inline annotations placed immediately before the construct's outermost element:

```
<!-- Slideout for displaying request details with comments and timeline -->
<div id="bsv-slideout-request-overlay" class="slide-panel-overlay" data-action-click="close-request-slideout"></div>
<div id="bsv-slideout-request" class="slide-panel xwide">...</div>
```

```
<!-- Modal for confirming the delete operation -->
<div id="bsv-modal-delete" class="xf-modal-overlay hidden">
    <div class="xf-modal">...</div>
</div>
```

The HTML populator reads the comment text into the `purpose_description` column for the row(s) of the construct. For slideouts and slide-up panels, the text is written to both rows of the pair. For modals (single-element constructs), the text is written to the single row. See §4.3.6 for the full rule.

### 10.5 Catalog rows for comments

Each recognized comment produces one `HTML_COMMENT DEFINITION` row in the catalog.

| Column | Value |
|---|---|
| `component_type` | `HTML_COMMENT` |
| `component_name` | The categorical name based on comment kind: `comment-section-divider`, `comment-inline`, `comment-panel-purpose` |
| `reference_type` | `DEFINITION` |
| `signature` | NULL |
| `scope` | `LOCAL` for page-emitted comments; `SHARED` for helper-emitted comments |
| `source_file` | The file containing the row |
| `parent_function` | The PS function emitting the markup (when applicable) |
| `raw_text` | The complete comment text including delimiters |

#### 10.5.1 Categorical name derivation

The HTML populator distinguishes between the three comment kinds based on shape and position:

| Categorical name | Trigger |
|---|---|
| `comment-section-divider` | Multi-line block comment whose body contains rule lines (76-character `=` runs) per §10.2 |
| `comment-panel-purpose` | Single-line comment immediately preceding a slideout overlay (`<prefix>-slideout-<purpose>-overlay`), a modal outer element (`<prefix>-modal-<purpose>`), or a slide-up backdrop (`<prefix>-slideup-<purpose>-backdrop`) per §4.3 |
| `comment-inline` | Any other single-line comment |

When a comment is categorized as `comment-panel-purpose`, its text is also written into the `purpose_description` column for the row(s) of the slideout/modal/panel construct it precedes (per §4.3.6). For `comment-inline` and `comment-section-divider` rows, `purpose_description` is not derived from the comment text.

A comment whose text resembles a panel purpose comment but is not positioned immediately before a slideout/modal/panel construct is categorized as `comment-inline`. The populator's categorization is determined by structural context, not by comment content.

### 10.6 Forbidden comment patterns

| Pattern | Drift code |
|---|---|
| Comment containing `--` within the body (other than the closing `-->`) | `MALFORMED_COMMENT_DASHES` |
| Comment containing PowerShell variable interpolation | `FORBIDDEN_COMMENT_INTERPOLATION` |
| Comment that is unclosed (opening `<!--` without matching `-->`) | `MALFORMED_COMMENT_UNCLOSED` |

The first rule reflects the HTML standard: `--` inside a comment body produces undefined parsing behavior in some browsers.

### 10.7 Comments inside other constructs

Comments inside `<script>` blocks (`//` or `/* */` style) are JavaScript comments, not HTML comments. They are governed by the JavaScript spec, not this section.

Comments inside `<svg>` blocks are SVG-internal and are catalogued as part of the SVG's `raw_text` (§9.4), not as separate `HTML_COMMENT` rows.

PowerShell-side comments (`#` and `<# ... #>`) inside the PS file containing the HTML are governed by the PowerShell spec, not this section. They are not part of HTML markup.


---

## 11. Required patterns summary

Every conforming HTML emission must satisfy these requirements. This section is a summary index; the authoritative rule for each item lives in the section cited.

### 11.1 Page shell

1. Open with `<!DOCTYPE html>` (§1.2)
2. Root element `<html>` with no attributes (§1.2)
3. `<head>` contains exactly one `<title>$browserTitle</title>` and the mandated `<link>` tags, nothing else (§1.2, §3.1)
4. `<body class="cc-section-<sectionKey>" data-cc-page="<slug>" data-cc-prefix="<prefix>">` opens body content (§1.2)
5. First content inside `<body>` is `$navHtml` substitution (§1.2)
6. Last content inside `<body>` is the `<script>` tag (§1.2, §3.2)

### 11.2 Page chrome

1. Page header bar appears as first content after `$navHtml` (§1.4, §2.1)
2. Header bar contains `$headerHtml` substitution and refresh-info block in mandated structure (§2.1, §2.2)
3. Refresh info block contains live indicator, status line, last-update span, and refresh button in exact mandated markup (§2.2)
4. Connection banner placeholder appears once per page as empty `<div>` (§1.4)
5. Page error banner placeholder appears once per page as empty `<div>`, immediately after the connection banner placeholder (§1.4)
6. Engine cards (when present) follow exact structure and registry-sourced slugs/labels (§2.3)

### 11.3 Asset references

1. Exactly two CSS files referenced in `<head>`: page-specific then `cc-shared.css` (§3.1)
2. Exactly one JS file referenced before `</body>`: `cc-shared.js` (§3.2)
3. The single `<script>` tag is the last content in `<body>` (§3.2)
4. No `defer`, `async`, or other attributes on the `<script>` tag (§3.2)

### 11.4 ID conventions

1. Every identifier in HTML markup uses the page's `cc_prefix` (page-local) or `cc-` (shared chrome); compound modifier classes are exempt (§4.0)
2. Chrome IDs come from the closed set in §4.1; new chrome IDs require spec amendment
3. Page-local IDs use `<prefix>-<purpose>` form where prefix matches `Component_Registry.cc_prefix` (§4.2)
4. Slideout IDs use `<prefix>-slideout-<purpose>-overlay` and `<prefix>-slideout-<purpose>` (§4.3.1)
5. Modal IDs use `<prefix>-modal-<purpose>` on the outermost `.xf-modal-overlay` element; the nested `.xf-modal` carries no ID (§4.3.2)
6. Slide-up panel IDs use `<prefix>-slideup-<purpose>-backdrop` and `<prefix>-slideup-<purpose>` (§4.3.3)
7. Slideouts, modals, and slide-up panels are declared in one contiguous block of markup (§4.3.5)
8. Every slideout, modal, and slide-up panel is preceded by an HTML purpose comment (§4.3.6)
9. JS references to page-local IDs use the same prefixed form as HTML declarations (§4.2.3)

### 11.5 Class attributes

1. Static class values use space-separated lowercase tokens (§5.1)
2. Every class name begins with the page's `cc_prefix` or with `cc-`; compound modifier classes are exempt (§4.0, §5.1.1)
3. Dynamic class assembly uses the array-join pattern only (§5.2.1)
4. `class` attribute values containing PowerShell interpolation use a single fully-resolved variable (§5.2.2)

### 11.6 Action attributes

1. Every action attribute uses the form `data-action-<event>="<action-value>"` where `<event>` is in the closed set of recognized events from §6.4 (§6.1)
2. Action values are unprefixed for page-local actions and `cc-` prefixed for shared chrome actions (§6.1, §6.2)
3. Every action value has a matching entry in its event-scoped dispatch table — page-local in `<prefix>_<event>Actions`, shared in `shared<Event>Actions` (§6.2)
4. Argument attributes use the form `data-action-<arg-name>="<value>"` and only appear on elements with at least one `data-action-<event>` attribute (§6.3)
5. Helpers emit only `cc-` prefixed action values, never page-local action values (§6.6)

### 11.7 data-* attributes

1. Page-emitted `data-*` attribute names begin with `data-<page_prefix>-`; helper-emitted `data-*` names begin with `data-cc-`; the `data-action-*` family is governed separately by §6 (§7.2)
2. Values are static strings or fully-resolved variables; no inline interpolation mixing (§7.2)
3. Helpers emit only `data-cc-*` attributes; helper-emitted `data-<page_prefix>-*` attributes are forbidden (§7.5)

### 11.8 Text content and entities

1. Text content character data and the four user-facing attributes (`title`, `placeholder`, `aria-label`, `alt`) are catalogued (§8.1)
2. Categorical naming derives `component_name` from element context (§8.2.2)
3. Entity references and direct Unicode are catalogued in three forms (named, numeric, direct) (§8.3)
4. User-facing attributes are not declared with empty values (§8.6)

### 11.9 SVG

1. Inline `<svg>` elements are catalogued at the outer-element level only; internals stored in `raw_text` (§9.1)
2. Categorical naming follows the same rule as text content (§9.3)
3. SVG-internal `<style>` blocks are SVG-scoped and exempt from the §12 inline-style prohibition (§9.5)

### 11.10 Comments

1. Recognized comment kinds: section divider, inline annotation, panel purpose comment (§10.1)
2. Section dividers use 76-character `=` rule lines (§10.2.1)
3. Panel purpose comments precede slideouts, modals, and slide-up panels per §4.3.6 (§10.4)
4. Comment categorization is determined by structural context, not comment content (§10.5.1)

### 11.11 Helper-emitted HTML

1. Helpers do not declare asset references (§3.5)
2. Helpers emit only chrome IDs, never page-prefixed IDs (§4.5)
3. Helpers emit only `cc-` prefixed action values, never page-local action values (§6.6)
4. Helpers emit only platform-shared `data-*` attributes (§7.5)

---

## 12. Forbidden patterns

This section consolidates patterns that are forbidden by spec rules in §1–§10. Each row maps a pattern to its drift code and the rule that forbids it. Section 15 carries the full drift code reference with descriptions.

### 12.1 Page shell forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| DOCTYPE missing or any casing other than `<!DOCTYPE html>` | `MALFORMED_DOCTYPE` | §1.2 |
| `<html>` element with attributes | `MALFORMED_HTML_ROOT` | §1.2 |
| `<head>` containing elements other than `<title>` and `<link>` | `MALFORMED_HEAD` | §1.2 |
| `<title>` content hardcoded instead of `$browserTitle` substitution | `FORBIDDEN_HARDCODED_TITLE` | §1.2 |
| `<body>` missing `class="cc-section-<sectionKey>"` | `MISSING_BODY_SECTION_CLASS` | §1.2 |
| `<body>` missing `data-cc-page="<slug>"` attribute | `MISSING_DATA_CC_PAGE` | §1.2 |
| `<body>` missing `data-cc-prefix="<prefix>"` attribute | `MISSING_DATA_CC_PREFIX` | §1.2 |
| First content inside `<body>` is not `$navHtml` | `MISSING_NAV_SUBSTITUTION` | §1.2 |
| Content appears between the `<script>` tag and `</body>` | `MALFORMED_BODY_CLOSE` | §1.2, §3.2 |
| Page header bar missing | `MISSING_HEADER_BAR` | §1.4 |
| Page header hardcoded instead of `$headerHtml` substitution | `FORBIDDEN_HARDCODED_PAGE_HEADER` | §1.4 |
| Connection banner placeholder missing | `MISSING_CONNECTION_BANNER` | §1.4 |
| Connection banner placeholder contains content | `FORBIDDEN_BANNER_CONTENT` | §1.4 |
| Page error banner placeholder missing | `MISSING_PAGE_ERROR_BANNER` | §1.4 |
| Page error banner placeholder contains content | `FORBIDDEN_PAGE_ERROR_BANNER_CONTENT` | §1.4 |
| Page error banner placeholder not immediately after connection banner placeholder | `PAGE_ERROR_BANNER_ORDER_VIOLATION` | §1.4 |

### 12.2 Page chrome forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Header bar outer container malformed | `MALFORMED_HEADER_BAR_CONTAINER` | §2.1 |
| Header bar children malformed | `MALFORMED_HEADER_BAR_LEFT`, `MALFORMED_HEADER_BAR_RIGHT`, `MALFORMED_HEADER_RIGHT_CHILDREN` | §2.1 |
| Refresh info block malformed | `MALFORMED_REFRESH_INFO_CONTAINER` | §2.2 |
| Live indicator span malformed | `MALFORMED_LIVE_INDICATOR` | §2.2 |
| Live status line malformed | `MALFORMED_LIVE_STATUS_LINE` | §2.2 |
| Page refresh button markup deviates from mandated form | `MALFORMED_REFRESH_BUTTON` | §2.2 |
| `cc-last-update` ID declared more than once | `DUPLICATE_LAST_UPDATE_ID` | §2.2 |
| Engine row container malformed | `MALFORMED_ENGINE_ROW_CONTAINER`, `MALFORMED_ENGINE_ROW_CHILDREN` | §2.3 |
| Engine card structure deviates from mandated form | `MALFORMED_ENGINE_CARD`, `MALFORMED_ENGINE_CARD_ATTRIBUTES`, `MALFORMED_ENGINE_LABEL`, `MALFORMED_ENGINE_BAR`, `MALFORMED_ENGINE_COUNTDOWN` | §2.3 |
| Engine card order doesn't match `cc_sort_order` | `ENGINE_CARD_ORDER_MISMATCH` | §2.3 |
| Active scheduled process missing engine card registration | `MISSING_ENGINE_CARD_REGISTRATION` | §2.3 |
| Slug in card IDs doesn't match `cc_engine_slug` | `ENGINE_SLUG_REGISTRY_MISMATCH` | §2.3 |
| Label text doesn't match `cc_engine_label` | `ENGINE_LABEL_REGISTRY_MISMATCH` | §2.3 |
| Engine card on a page that doesn't match `cc_page_route` | `ENGINE_CARD_PAGE_MISMATCH` | §2.3 |

### 12.3 Asset reference forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Malformed `<link>` tag | `MALFORMED_CSS_LINK` | §3.1 |
| Page-specific CSS reference malformed | `MALFORMED_PAGE_CSS_REFERENCE` | §3.1 |
| Shared CSS reference malformed | `MALFORMED_SHARED_CSS_REFERENCE` | §3.1 |
| CSS references in wrong order | `CSS_REFERENCE_ORDER_VIOLATION` | §3.1 |
| Unexpected number of CSS references | `UNEXPECTED_CSS_REFERENCE` | §3.1 |
| Malformed `<script>` tag | `MALFORMED_JS_SCRIPT` | §3.2 |
| Page is missing the `cc-shared.js` `<script>` tag | `MISSING_SHARED_SCRIPT_TAG` | §3.2 |
| Page has more than one `<script>` tag | `UNEXPECTED_SCRIPT_TAG` | §3.2 |
| `<script>` tag's `src` value is not `/js/cc-shared.js` | `WRONG_SCRIPT_SOURCE` | §3.2 |
| Helper emits `<link>` or `<script>` reference | `FORBIDDEN_HELPER_ASSET_REFERENCE` | §3.5 |

### 12.4 ID forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Chrome ID reused as page-local ID | `CHROME_ID_REUSED_AS_LOCAL` | §4.1 |
| Page-local ID missing prefix | `MISSING_PREFIX_ID` | §4.2 |
| Page-local ID uses another page's prefix | `CROSS_PAGE_PREFIX_COLLISION` | §4.2 |
| Same ID declared twice on a page | `DUPLICATE_ID_DECLARATION` | §4.2 |
| ID value contains forbidden characters | `MALFORMED_ID_VALUE` | §4.2 |
| Slideout/modal/panel ID malformed | `MALFORMED_SLIDEOUT_ID`, `MALFORMED_MODAL_ID`, `MALFORMED_SLIDEUP_ID` | §4.3 |
| Slideout or slide-up panel pair incomplete | `INCOMPLETE_OVERLAY_PAIR` | §4.3.4 |
| Modal missing nested `.xf-modal` child element | `MALFORMED_MODAL_STRUCTURE` | §4.3.4 |
| Slideout/modal/panel declarations interleaved with non-overlay content | `OVERLAY_PANEL_NOT_CONTIGUOUS` | §4.3.5 |
| Slideout/modal/panel missing purpose comment | `MISSING_PANEL_PURPOSE_COMMENT` | §4.3.6 |
| Helper emits page-prefixed ID | `FORBIDDEN_HELPER_PAGE_PREFIX_ID` | §4.5 |

### 12.5 Class attribute forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Class value contains malformed whitespace | `MALFORMED_CLASS_VALUE_WHITESPACE` | §5.1 |
| Class name contains forbidden characters | `MALFORMED_CLASS_NAME` | §5.1 |
| Duplicate class in same attribute | `DUPLICATE_CLASS_IN_VALUE` | §5.1 |
| Class doesn't satisfy unified prefix rule and is not a compound modifier | `CLASS_PREFIX_MISMATCH` | §4.0, §5.1.1 |
| Compound modifier appears on element without registered companion class | `INVALID_MODIFIER_CONTEXT` | §5.1.1 |
| `class="nav-link$accent"` (interpolation appended to static text) | `INLINE_CLASS_CONCATENATION` | §5.2.3 |
| `class="$type wide"` (interpolation followed/preceded by static text) | `INLINE_CLASS_PREFIX_MIX` | §5.2.3 |
| `class="$a $b"` (multiple interpolations, neither using array-join) | `INLINE_CLASS_MULTI_INTERPOLATION` | §5.2.3 |
| `class="${a}wide"` or `class="$($x)wide"` | `INLINE_CLASS_BRACED_INTERPOLATION` | §5.2.3 |

### 12.6 Action attribute forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Unknown event in `data-action-<event>` attribute | `UNKNOWN_EVENT_TYPE` | §6.2, §6.4 |
| Action value contains forbidden characters | `MALFORMED_ACTION_VALUE` | §6.2 |
| Action value has no matching dispatch table entry | `UNRESOLVED_DATA_ACTION` | §6.2 |
| `data-action-<arg-name>` attribute on element without `data-action-<event>` | `ORPHANED_ACTION_ARGUMENT` | §6.3.1 |
| Argument attribute name matches an event name | `ARGUMENT_NAME_COLLIDES_WITH_EVENT` | §6.3.1 |
| Argument attribute name contains forbidden characters | `MALFORMED_ACTION_ARGUMENT_NAME` | §6.3.1 |
| Argument attribute value mixes static text with PowerShell interpolation | `FORBIDDEN_INLINE_ACTION_ARGUMENT_INTERPOLATION` | §6.3.1 |
| Helper emits a page-local action value | `FORBIDDEN_HELPER_PAGE_ACTION` | §6.6 |
| Helper emits an argument attribute with page-specific meaning | `FORBIDDEN_HELPER_PAGE_ACTION_ARGUMENT` | §6.6 |

### 12.7 data-* attribute forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| `data-*` attribute name uses forbidden characters or doesn't satisfy unified prefix rule | `MALFORMED_DATA_ATTRIBUTE_NAME` | §4.0, §7.2 |
| `data-*` value mixes static text with PS interpolation | `FORBIDDEN_INLINE_DATA_INTERPOLATION` | §7.2 |
| Helper emits a page-prefixed `data-*` attribute (i.e., not `data-cc-*`) | `FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE` | §7.5 |

### 12.8 Text content forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Text contains forbidden interpolation pattern | `MALFORMED_TEXT_INTERPOLATION` | §8.6 |
| User-facing attribute declared with empty value | `EMPTY_DISPLAY_TEXT` | §8.6 |

### 12.9 SVG forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| SVG markup contains forbidden interpolation pattern | `MALFORMED_SVG_INTERPOLATION` | §9.6 |

### 12.10 Comment forbidden patterns

| Pattern | Drift code | Rule |
|---|---|---|
| Comment body contains `--` (other than closing `-->`) | `MALFORMED_COMMENT_DASHES` | §10.6 |
| Comment contains PowerShell variable interpolation | `FORBIDDEN_COMMENT_INTERPOLATION` | §10.6 |
| Comment unclosed | `MALFORMED_COMMENT_UNCLOSED` | §10.6 |

### 12.11 Inline `<style>` blocks and `style` attributes

Inline `<style>` blocks and inline `style="..."` attributes are forbidden in HTML markup with one exception: SVG-internal `<style>` blocks (per §9.5) are SVG-scoped, not HTML-scoped, and are exempt.

| Pattern | Drift code |
|---|---|
| `<style>` block in HTML markup (outside SVG) | `FORBIDDEN_INLINE_STYLE_BLOCK` |
| `style="..."` attribute on any element | `FORBIDDEN_INLINE_STYLE_ATTRIBUTE` |

Styling lives in CSS files. Both block-level and attribute-level inline styling are forbidden uniformly, with no carve-outs for the access-denied page or any other special case.

### 12.12 Inline `<script>` blocks

Inline `<script>` blocks containing JavaScript code are forbidden in HTML markup. The only permitted form of `<script>` element is the asset reference form (`<script src="..."></script>`) per §3.2. A `<script>` element with body content (e.g., `<script>doSomething();</script>`) emits `FORBIDDEN_INLINE_SCRIPT_BLOCK`.

### 12.13 Inline event handler attributes

HTML attributes whose name begins with `on` followed by an event name (`onclick`, `onchange`, `onkeydown`, `onsubmit`, `onfocus`, `onblur`, etc.) — the inline event handler family — are forbidden in all HTML markup. User interaction in Control Center pages is wired through the `data-action-<event>` family (§6) and the bootloader-driven dispatch model.

Any `on*` attribute on any element emits `FORBIDDEN_INLINE_EVENT_HANDLER`. Additional drift codes may also fire describing the specific shape of the violation:

| Pattern | Drift code |
|---|---|
| Bare existence of any `on*` attribute on any element (always fires) | `FORBIDDEN_INLINE_EVENT_HANDLER` |
| Multiple statements in handler value | `MULTIPLE_HANDLER_STATEMENTS` |
| Handler value contains expressions other than a single function call | `INLINE_HANDLER_EXPRESSION` |
| Whitespace between function name and opening parenthesis | `MALFORMED_HANDLER_CALL` |
| Trailing semicolon in handler value | `TRAILING_HANDLER_SEMICOLON` |
| Handler calls a function via dotted property access | `FORBIDDEN_REVEALING_MODULE_CALL` |
| Handler calls a method on a built-in object | `FORBIDDEN_BUILTIN_METHOD_CALL` |
| Handler function name is not a recognized chrome function and does not match the page's prefix | `HANDLER_FUNCTION_NAME_MISMATCH` |
| Handler calls a method on the event object | `FORBIDDEN_EVENT_METHOD_CALL` |
| Handler contains conditional logic | `FORBIDDEN_HANDLER_CONDITIONAL` |
| Handler performs DOM manipulation inline | `FORBIDDEN_INLINE_DOM_OPERATION` |
| Handler contains assignment expressions | `FORBIDDEN_INLINE_ASSIGNMENT` |
| Handler uses the `javascript:` pseudo-protocol | `FORBIDDEN_JAVASCRIPT_PROTOCOL` |
| Argument is an expression other than literal, `this`, or `this.<property>` | `FORBIDDEN_ARGUMENT_EXPRESSION` |
| String literal argument uses double quotes (conflicting with surrounding attribute) | `MALFORMED_ARGUMENT_QUOTING` |
| Multiple arguments not separated by `, ` | `MALFORMED_ARGUMENT_LIST` |
| Helper module function emits an event handler calling a page-prefixed function | `FORBIDDEN_HELPER_PAGE_FUNCTION_CALL` |

A single inline handler may carry the umbrella code plus one or more specific codes simultaneously. The umbrella ensures every inline handler is detected; the specifics describe the handler's content shape for refactor planning.

---

## 13. Catalog model

The HTML populator emits rows into `dbo.Asset_Registry` representing every catalogable construct found in HTML markup. This section describes the catalog model as it relates to HTML rows.

### 13.1 What the catalog represents

A row's identity is described by the combination of `component_type`, `component_name`, `reference_type`, `file_name`, and `occurrence_index`. The HTML populator emits one `HTML_FILE DEFINITION` row per scanned PS file as the file-level anchor, plus one row per definition or usage instance found while walking the HTML markup inside PS string tokens.

The catalog is the authoritative answer to questions like: "where is the `bsv-modal-detail` ID declared?", "how many pages emit engine cards?", "what tooltip text appears on the page refresh button across pages?", "which HTML files contain spec drift today, and of what kinds?". Every such question becomes a SQL query against this table.

### 13.2 HTML-relevant component_type values

| `component_type` | Source | Meaning |
|---|---|---|
| `HTML_FILE` | The PS file containing HTML emission | One row per scanned PS file. The file-level anchor for §15.1 page-shell drift codes. Emitted by the HTML populator. (Note: distinct from `FILE_HEADER`, which is the PS populator's file-level anchor row. The two coexist when the PS populator has run, one for HTML concerns and one for PS concerns.) |
| `HTML_ID` | `id="..."` attributes | One row per ID declaration. Resolved against `getElementById` calls in JS for cross-population linkage. |
| `HTML_DATA_ATTRIBUTE` | `data-*` attributes (including `data-action-*`) | One row per data-* attribute declaration. Resolved against JS `dataset.foo` reads for cross-population linkage. Rows for `data-action-<event>` attributes additionally populate `variant_type` and `variant_qualifier_1` per §6.5. |
| `HTML_TEXT` | Element text content and four user-facing attribute values (`title`, `placeholder`, `aria-label`, `alt`) | One row per text node or attribute value. Categorical naming per §8.2.2. |
| `HTML_ENTITY` | HTML entity references (`&times;`, `&#9881;`) and direct Unicode characters | One row per entity or special character. Three forms catalogued per §8.3.1. |
| `HTML_SVG` | Inline `<svg>` elements | One row per outer `<svg>` element. Internals stored in `raw_text` (§9.1). |
| `HTML_COMMENT` | HTML comments | One row per recognized comment kind (§10.5.1). |
| `HTML_EVENT_HANDLER` | `on<event>="..."` attributes (`onclick`, `onchange`, etc.) | One row per inline event handler attribute. Inline handlers are forbidden per §12.13; this component type exists to give §12.13's drift codes a row to attach to. |
| `CSS_CLASS` | `class="..."` attribute values | One row per class name in the attribute. Resolves against CSS_CLASS DEFINITION rows (§5.6). |
| `CSS_FILE` | `<link rel="stylesheet" href="...">` references | One row per CSS file reference. Resolves against CSS_FILE DEFINITION rows. |
| `JS_FILE` | `<script src="...">` reference | One row per JS file reference. Resolves against JS_FILE DEFINITION rows. |

The CSS_CLASS USAGE rows from HTML markup share the `component_type` value with CSS_CLASS DEFINITION rows from CSS files; the `reference_type` and `scope` columns distinguish them. The same pattern applies to CSS_FILE and JS_FILE.

### 13.3 reference_type values for HTML rows

For HTML markup, most rows are emitted as DEFINITION:

- `id="..."` declarations are HTML_ID DEFINITION rows (declarations of the ID)
- `data-*` declarations are HTML_DATA_ATTRIBUTE DEFINITION rows (including `data-action-*` rows)
- text nodes are HTML_TEXT DEFINITION rows
- comments are HTML_COMMENT DEFINITION rows
- SVG elements are HTML_SVG DEFINITION rows
- entity references are HTML_ENTITY DEFINITION rows
- inline event handlers are HTML_EVENT_HANDLER DEFINITION rows (forbidden per §12.13; cataloged for drift detection)

Three row types are USAGE rows because they reference constructs defined elsewhere:

- `class="..."` produces CSS_CLASS USAGE rows (the class is *defined* in CSS files)
- `<link rel="stylesheet">` references produce CSS_FILE USAGE rows (the file is *defined* by the CSS populator's CSS_FILE anchor row)
- `<script>` references produce JS_FILE USAGE rows (the file is *defined* by the JS populator's JS_FILE anchor row)

### 13.4 Drift recording

The HTML populator evaluates every row against the spec and records two things when the row deviates:

- `drift_codes` — comma-separated list of stable short codes (e.g., `MISSING_PREFIX_ID,DUPLICATE_ID_DECLARATION`)
- `drift_text` — joined human-readable descriptions corresponding to each code

A row may carry zero, one, or many drift codes. Both columns are NULL when the row is fully spec-compliant. Empty strings are treated as NULL.

### 13.5 has_dynamic_content flag

The `has_dynamic_content` BIT column is set TRUE on rows where the parent attribute or text construct contains additional runtime-only content the populator cannot statically resolve. See §5.5 (class attributes), §8.5 (text), §9.4 (SVG), and the JS spec for JS-side application. A FALSE or NULL value means the row's parent construct is fully captured in the catalog.

### 13.6 Cross-populator dependencies

The HTML populator's emitted rows resolve their cross-populator references against existing catalog rows at scan time. The HTML populator never edits rows emitted by other populators; it reads them.

- `CSS_CLASS USAGE` rows have `scope` and `source_file` resolved against `CSS_CLASS DEFINITION` rows already in the catalog at HTML-populator scan time. Per pipeline order CSS → HTML → JS → PS, CSS DEFINITION rows always exist when HTML scans.
- `CSS_FILE USAGE` rows (from `<link rel="stylesheet">` references) have `scope` and `source_file` resolved against `CSS_FILE DEFINITION` rows already in the catalog. Same pipeline relationship.
- `JS_FILE USAGE` rows (from the single `<script src="/js/cc-shared.js">` reference) reference the `JS_FILE DEFINITION` row that the JS populator emits when it scans `cc-shared.js`. Because the JS populator runs after the HTML populator in the standard pipeline order, the HTML populator cannot resolve this reference at scan time; resolution is verified post-pipeline via SQL query joining the `JS_FILE USAGE` row's `component_name` against `JS_FILE DEFINITION` rows. In standalone runs of the HTML populator before JS has scanned, the reference resolves to `source_file = '<undefined>'`.
- `HTML_ID DEFINITION` rows are produced by HTML and consumed by JS. Per pipeline order, JS scans after HTML, so JS USAGE rows resolve against HTML DEFINITION rows.
- `HTML_DATA_ATTRIBUTE DEFINITION` rows are produced by HTML and consumed by JS. Same pipeline relationship.

`data-action-<event>` attribute values are emitted as `HTML_DATA_ATTRIBUTE DEFINITION` rows by the HTML populator. These reference dispatch table entries cataloged as `JS_DISPATCH_ENTRY DEFINITION` rows by the JS populator. Because the JS populator runs after the HTML populator in the standard pipeline order, the HTML populator cannot resolve action values against dispatch table entries at scan time; resolution is verified post-pipeline via SQL query joining `HTML_DATA_ATTRIBUTE DEFINITION` rows (where `component_name LIKE 'data-action-%'` and the value is in `variant_type`) against `JS_DISPATCH_ENTRY DEFINITION` rows. The `UNRESOLVED_DATA_ACTION` drift code (§6.2) is attached at query time, not at HTML scan time. This is the same structural property as `JS_FILE USAGE` resolution. The exact column shape of `JS_DISPATCH_ENTRY` rows is governed by the JavaScript spec.

The `parent_function` column on every HTML row is filled by the HTML populator itself at row-emit time, from the enclosing PowerShell function name observed during the populator's own PS-AST walk of the route or helper file. No other populator edits this column.

When a populator runs standalone (out of pipeline order), unresolved cross-populator references resolve to `<undefined>` for `source_file` and `LOCAL` for `scope`. Standalone runs are valid for development and testing; production pipeline runs always follow the CSS → HTML → JS → PS order.


---

## 14. What the parser extracts

This table maps source HTML constructs to the catalog rows the HTML populator emits. The populator walks HTML markup inside PS string tokens, identifies recognized constructs, and emits rows accordingly.

| Source construct | Row type | Key columns |
|---|---|---|
| Route file containing HTML emission | `HTML_FILE DEFINITION` | `component_name` = the page route (e.g., `/server-health`), `scope` = `LOCAL`, `line_start` = 1, `line_end` = file's total line count. Anchor row for §15.1 page-shell drift codes. |
| Helper file emitting HTML fragments | `HTML_FILE DEFINITION` | `component_name` = the helper function name (e.g., `Get-NavBarHtml`), `scope` = `SHARED`, `line_start` = 1, `line_end` = file's total line count. Helper files have one `HTML_FILE` row per file, not per emitting function — multiple helper functions in the same file share the row. |
| `id="..."` attribute on any element | `HTML_ID DEFINITION` | `component_name` = the ID value, `signature` = the full attribute |
| `data-*="..."` attribute on any element (non-action) | `HTML_DATA_ATTRIBUTE DEFINITION` | `component_name` = the attribute name including `data-`, `signature` = the full attribute |
| `data-action-<event>="..."` attribute on any element | `HTML_DATA_ATTRIBUTE DEFINITION` | `component_name` = the attribute name including `data-` prefix (e.g., `data-action-click`), `variant_type` = the action value, `variant_qualifier_1` = the event name (e.g., `click`), `signature` = full attribute |
| `data-action-<arg-name>="..."` attribute on any element | `HTML_DATA_ATTRIBUTE DEFINITION` | `component_name` = the attribute name including `data-` prefix (e.g., `data-action-batch-id`), `variant_type` = the value, `signature` = full attribute. No `variant_qualifier_1` (argument is not event-scoped). |
| `on<event>="..."` attribute on any element (e.g., `onclick=`, `onchange=`) | `HTML_EVENT_HANDLER DEFINITION` | `component_name` = the attribute name (e.g., `onclick`), `signature` = full attribute, carries §12.13 drift codes (forbidden) |
| Element text node (non-whitespace character data between opening and closing tags) | `HTML_TEXT DEFINITION` | `component_name` = categorical name per §8.2.2, `raw_text` = literal text |
| `title="..."` attribute value | `HTML_TEXT DEFINITION` | `component_name` = `attr-title`, `raw_text` = literal value |
| `placeholder="..."` attribute value | `HTML_TEXT DEFINITION` | `component_name` = `attr-placeholder`, `raw_text` = literal value |
| `aria-label="..."` attribute value | `HTML_TEXT DEFINITION` | `component_name` = `attr-aria-label`, `raw_text` = literal value |
| `alt="..."` attribute value | `HTML_TEXT DEFINITION` | `component_name` = `attr-alt`, `raw_text` = literal value |
| HTML entity reference (`&named;`) | `HTML_ENTITY DEFINITION` | `component_name` = the literal entity, `signature` = `entity_named` |
| HTML numeric entity reference (`&#NNN;`) | `HTML_ENTITY DEFINITION` | `component_name` = the literal entity, `signature` = `entity_numeric` |
| Direct Unicode character (above basic ASCII range) | `HTML_ENTITY DEFINITION` | `component_name` = the literal character, `signature` = `direct_unicode` |
| `<svg>...</svg>` element | `HTML_SVG DEFINITION` | `component_name` = categorical name per §9.3, `raw_text` = full SVG markup |
| HTML comment (`<!-- ... -->`) | `HTML_COMMENT DEFINITION` | `component_name` = categorical name per §10.5.1, `raw_text` = full comment text |
| Each class name in `class="..."` (one row per class) | `CSS_CLASS USAGE` | `component_name` = the class name, `signature` = full attribute value, `has_dynamic_content` per §5.5 |
| `<link rel="stylesheet" href="...">` reference | `CSS_FILE USAGE` | `component_name` = the href value, resolved against CSS_FILE DEFINITION rows |
| `<script src="..."></script>` reference | `JS_FILE USAGE` | `component_name` = the src value, resolved against JS_FILE DEFINITION rows |

Each emitted row carries its `drift_codes` and `drift_text` columns populated when the row violates a spec rule. Rows with no violations have NULL drift columns.

The populator does not emit rows for:

- Whitespace between elements (newlines, indentation spaces)
- Element tag names themselves (the populator extracts attributes and text but does not catalog the tag as a separate row; tag context is preserved via categorical naming and `parent_function`)
- Attribute names that are not in the catalogued attribute set (the populator catalogs `id`, `class`, `data-*`, the four user-facing attributes, asset reference attributes, and `on*` inline event handler attributes; other attributes like `width`, `height`, `viewBox` on SVG, or `type`, `name`, `disabled` on form fields are not emitted as rows but are stored as part of `raw_text` on parent rows)

---

## 15. Drift codes reference

The HTML populator may emit any of the following drift codes on emitted rows. Codes are organized by spec section. For the full pattern-to-code mapping, see Section 12 (Forbidden patterns).

### 15.1 Page shell codes (§1)

Page shell drift codes attach to the file's `HTML_FILE DEFINITION` row per §13.2, not to extracted construct rows. The `HTML_FILE` row represents the file as a structural unit; page-shell violations are file-level concerns about whether the emission is well-shaped overall, not about any individual construct.

| Code | Description |
|---|---|
| `MALFORMED_DOCTYPE` | The HTML document does not open with `<!DOCTYPE html>` on its own line in the canonical form (uppercase keyword, lowercase tag name). |
| `MALFORMED_HTML_ROOT` | The root `<html>` element has attributes (e.g., `<html lang="en">`); attributes are not permitted on the root element. |
| `MALFORMED_HEAD` | The `<head>` element contains constructs other than `<title>` and `<link>` (e.g., inline `<style>`, `<meta>`, `<script>`). |
| `FORBIDDEN_HARDCODED_TITLE` | The `<title>` content is a hardcoded string instead of the `$browserTitle` PowerShell variable substitution. |
| `MISSING_BODY_SECTION_CLASS` | The `<body>` element does not declare a `class="cc-section-<sectionKey>"` attribute. |
| `MISSING_DATA_CC_PAGE` | The `<body>` element does not declare a `data-cc-page="<slug>"` attribute. |
| `MISSING_DATA_CC_PREFIX` | The `<body>` element does not declare a `data-cc-prefix="<prefix>"` attribute. |
| `MISSING_NAV_SUBSTITUTION` | The first content inside `<body>` is not the `$navHtml` substitution. |
| `MALFORMED_BODY_CLOSE` | Content appears between the `<script>` tag and `</body>`. |
| `MISSING_HEADER_BAR` | The page header bar is missing as the first content after `$navHtml`. |
| `FORBIDDEN_HARDCODED_PAGE_HEADER` | The page header content is hardcoded instead of the `$headerHtml` PowerShell variable substitution. |
| `MISSING_CONNECTION_BANNER` | The connection banner placeholder is missing. |
| `FORBIDDEN_BANNER_CONTENT` | The connection banner placeholder contains content (it must be empty). |
| `MISSING_PAGE_ERROR_BANNER` | The page error banner placeholder is missing. |
| `FORBIDDEN_PAGE_ERROR_BANNER_CONTENT` | The page error banner placeholder contains content (it must be empty). |
| `PAGE_ERROR_BANNER_ORDER_VIOLATION` | The page error banner placeholder is not immediately after the connection banner placeholder. |

### 15.2 Page chrome codes (§2)

The HTML populator emits the codes below by walking page markup and (where indicated) cross-referencing `Orchestrator.ProcessRegistry`. `UNEXPECTED_ENGINE_CARD_REGISTRATION` is a registry-side data integrity check (a queue processor row should not have cc-prefixed columns populated) surfaced by Q5 in §16, not by the HTML populator.

| Code | Description |
|---|---|
| `MALFORMED_HEADER_BAR_CONTAINER` | The header bar's outer container is not `<div class="cc-header-bar">`. |
| `MALFORMED_HEADER_BAR_LEFT` | The first child of `cc-header-bar` is not the unattributed `<div>` containing the `$headerHtml` substitution. |
| `MALFORMED_HEADER_BAR_RIGHT` | The second child of `cc-header-bar` is not `<div class="cc-header-right">`. |
| `MALFORMED_HEADER_RIGHT_CHILDREN` | The `cc-header-right` element contains children other than `cc-refresh-info` and optional `cc-engine-row`. |
| `MALFORMED_REFRESH_INFO_CONTAINER` | The refresh info block's outer container is not `<div class="cc-refresh-info">`. |
| `MALFORMED_LIVE_INDICATOR` | The live indicator span is malformed; expected `<span class="cc-live-indicator"></span>` exactly. |
| `MALFORMED_LIVE_STATUS_LINE` | The live status line ("`Live | Updated:`") deviates from mandated form. |
| `MALFORMED_REFRESH_BUTTON` | The page refresh button markup deviates from mandated form (class, `data-action-click`, title, or entity reference). |
| `DUPLICATE_LAST_UPDATE_ID` | The `cc-last-update` ID appears more than once on the page. |
| `MALFORMED_ENGINE_ROW_CONTAINER` | The engine row's outer container is not `<div class="cc-engine-row">`. |
| `MALFORMED_ENGINE_ROW_CHILDREN` | The engine row contains children other than engine cards. |
| `ENGINE_CARD_ORDER_MISMATCH` | Engine cards are not in declaration order matching `cc_sort_order`. |
| `MALFORMED_ENGINE_CARD` | An engine card's structure deviates from the mandated four-element block. |
| `MALFORMED_ENGINE_CARD_ATTRIBUTES` | An engine card's attributes are malformed (class or ID). |
| `MALFORMED_ENGINE_LABEL` | An engine label span is malformed (class or text). |
| `MALFORMED_ENGINE_BAR` | An engine bar div is malformed (class or ID, or contains content). |
| `MALFORMED_ENGINE_COUNTDOWN` | An engine countdown span is malformed (class, ID, or content). |
| `MISSING_ENGINE_CARD_REGISTRATION` | An active scheduled process (`run_mode = 1`) has NULL values in `cc_engine_slug`, `cc_engine_label`, `cc_page_route`, or `cc_sort_order`. |
| `ENGINE_SLUG_REGISTRY_MISMATCH` | The slug used in card IDs doesn't match `Orchestrator.ProcessRegistry.cc_engine_slug` for the corresponding process. |
| `ENGINE_LABEL_REGISTRY_MISMATCH` | The label text in the engine label span doesn't match `Orchestrator.ProcessRegistry.cc_engine_label`. |
| `ENGINE_CARD_PAGE_MISMATCH` | An engine card appears on a page whose route doesn't match `Orchestrator.ProcessRegistry.cc_page_route`. |

### 15.3 Asset reference codes (§3)

| Code | Description |
|---|---|
| `MALFORMED_CSS_LINK` | A `<link>` element uses additional attributes beyond `rel="stylesheet"` and `href="..."`, or has an incorrect form. |
| `MALFORMED_PAGE_CSS_REFERENCE` | The page-specific CSS reference's `href` doesn't match `/css/<page>.css` form. |
| `MALFORMED_SHARED_CSS_REFERENCE` | The shared CSS reference is not exactly `<link rel="stylesheet" href="/css/cc-shared.css">`. |
| `CSS_REFERENCE_ORDER_VIOLATION` | The page-specific CSS reference does not appear before the shared reference. |
| `UNEXPECTED_CSS_REFERENCE` | A page references more or fewer than two CSS files in `<head>`. |
| `MALFORMED_JS_SCRIPT` | A `<script>` element uses additional attributes (e.g., `defer`, `async`) or has body content. |
| `MISSING_SHARED_SCRIPT_TAG` | The page is missing the `cc-shared.js` `<script>` tag before `</body>`. |
| `UNEXPECTED_SCRIPT_TAG` | The page has more than one `<script>` tag. The single permitted `<script>` tag references `cc-shared.js`. |
| `WRONG_SCRIPT_SOURCE` | The page's `<script>` tag has a `src` value other than `/js/cc-shared.js`. |
| `FORBIDDEN_HELPER_ASSET_REFERENCE` | A helper module function emits a `<link>` or `<script>` element. |

### 15.4 ID codes (§4)

| Code | Description |
|---|---|
| `CHROME_ID_REUSED_AS_LOCAL` | A page-local element is assigned a chrome ID (e.g., `id="cc-last-update"` on a non-chrome element). |
| `MISSING_PREFIX_ID` | A page-local ID does not begin with the page's `cc_prefix` followed by a hyphen. |
| `CROSS_PAGE_PREFIX_COLLISION` | A page-local ID begins with another page's prefix. |
| `DUPLICATE_ID_DECLARATION` | The same ID value is declared more than once on a page. |
| `MALFORMED_ID_VALUE` | An ID value contains characters other than lowercase letters, digits, and hyphens. |
| `MALFORMED_SLIDEOUT_ID` | A slideout overlay or panel ID does not follow `<prefix>-slideout-<purpose>-*` form. |
| `MALFORMED_MODAL_ID` | A modal's outer element ID does not follow `<prefix>-modal-<purpose>` form (no `-overlay` suffix; the construct is single-element, not a pair). |
| `MALFORMED_MODAL_STRUCTURE` | A modal's outer `.xf-modal-overlay` element is missing the nested `.xf-modal` direct child. |
| `MALFORMED_SLIDEUP_ID` | A slide-up panel backdrop or panel ID does not follow `<prefix>-slideup-<purpose>-*` form. |
| `INCOMPLETE_OVERLAY_PAIR` | A slideout or slide-up panel declares one half of the overlay/panel pair without the other. Does not apply to modals (which are single-element constructs). |
| `OVERLAY_PANEL_NOT_CONTIGUOUS` | Slideout, modal, or slide-up panel declarations are interleaved with non-overlay structural content (per §4.3.5, overlay panel declarations must form one contiguous block). |
| `MISSING_PANEL_PURPOSE_COMMENT` | A slideout, modal, or slide-up panel declaration is not preceded by an HTML purpose comment. |
| `FORBIDDEN_HELPER_PAGE_PREFIX_ID` | A helper module function emits HTML with a page-prefixed ID. |

### 15.5 Class attribute codes (§5)

| Code | Description |
|---|---|
| `MALFORMED_CLASS_VALUE_WHITESPACE` | A class attribute value contains multiple consecutive spaces, leading/trailing whitespace, or tabs. |
| `MALFORMED_CLASS_NAME` | A class name contains characters other than lowercase letters, digits, and hyphens. |
| `DUPLICATE_CLASS_IN_VALUE` | The same class name appears more than once in the same `class` attribute. |
| `CLASS_PREFIX_MISMATCH` | A class name does not begin with the page's `cc_prefix` or with `cc-`, and is not a recognized compound modifier (per §4.0 unified prefix rule). |
| `INVALID_MODIFIER_CONTEXT` | A compound modifier class appears on an element whose companion class is not a registered compound base for that modifier (per §5.1.1). |
| `INLINE_CLASS_CONCATENATION` | A class attribute uses inline interpolation appended to static text (e.g., `class="nav-link$accent"`). |
| `INLINE_CLASS_PREFIX_MIX` | A class attribute uses inline interpolation followed or preceded by static text (e.g., `class="$type wide"`). |
| `INLINE_CLASS_MULTI_INTERPOLATION` | A class attribute uses multiple top-level interpolations without using the array-join pattern. |
| `INLINE_CLASS_BRACED_INTERPOLATION` | A class attribute uses PowerShell `${...}` or `$(...)` form mixed with static text. |

### 15.6 Action attribute codes (§6)

| Code | Description |
|---|---|
| `UNKNOWN_EVENT_TYPE` | A `data-action-<event>` attribute uses an event name not in the §6.4 closed set. |
| `MALFORMED_ACTION_VALUE` | An action value contains characters other than lowercase letters, digits, and hyphens. |
| `UNRESOLVED_DATA_ACTION` | An action value has no matching entry in its event-scoped dispatch table. Attached at query time post-pipeline, not at HTML scan time. |
| `ORPHANED_ACTION_ARGUMENT` | A `data-action-<arg-name>` attribute appears on an element that has no `data-action-<event>` attribute. |
| `ARGUMENT_NAME_COLLIDES_WITH_EVENT` | An argument attribute's name matches an event name from §6.4 (collision between argument and event-type attribute). |
| `MALFORMED_ACTION_ARGUMENT_NAME` | An argument attribute name contains characters other than lowercase letters, digits, and hyphens. |
| `FORBIDDEN_INLINE_ACTION_ARGUMENT_INTERPOLATION` | An argument attribute value mixes static text with PowerShell interpolation. |
| `FORBIDDEN_HELPER_PAGE_ACTION` | A helper module function emits a page-local (non-`cc-` prefixed) action value. |
| `FORBIDDEN_HELPER_PAGE_ACTION_ARGUMENT` | A helper module function emits an argument attribute whose value carries page-specific meaning. |

### 15.7 data-* attribute codes (§7)

| Code | Description |
|---|---|
| `MALFORMED_DATA_ATTRIBUTE_NAME` | A `data-*` attribute name contains forbidden characters, or does not begin with `data-<page_prefix>-` (page-emitted) or `data-cc-` (helper-emitted), and is not in the `data-action-*` family. |
| `FORBIDDEN_INLINE_DATA_INTERPOLATION` | A `data-*` attribute value mixes static text with PowerShell interpolation. |
| `FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE` | A helper module function emits a `data-*` attribute with a page prefix (helpers must use only `data-cc-*`). |

### 15.8 Text content codes (§8)

| Code | Description |
|---|---|
| `MALFORMED_TEXT_INTERPOLATION` | Text content contains PowerShell variable interpolation that uses forbidden patterns from §5.2.3. |
| `EMPTY_DISPLAY_TEXT` | A user-facing attribute (`title`, `placeholder`, `aria-label`, `alt`) is declared with an empty value. |

### 15.9 SVG codes (§9)

| Code | Description |
|---|---|
| `MALFORMED_SVG_INTERPOLATION` | An SVG element's outer markup contains forbidden interpolation patterns. |

### 15.10 Comment codes (§10)

| Code | Description |
|---|---|
| `MALFORMED_COMMENT_DASHES` | An HTML comment body contains `--` other than the closing `-->`. |
| `FORBIDDEN_COMMENT_INTERPOLATION` | An HTML comment contains PowerShell variable interpolation. |
| `MALFORMED_COMMENT_UNCLOSED` | An HTML comment's opening `<!--` does not have a matching closing `-->`. |

### 15.11 Inline style and script block codes (§12)

| Code | Description |
|---|---|
| `FORBIDDEN_INLINE_STYLE_BLOCK` | A `<style>` block appears in HTML markup outside the §9.5 (SVG-internal) carve-out. |
| `FORBIDDEN_INLINE_STYLE_ATTRIBUTE` | An element carries an inline `style="..."` attribute. All styling lives in CSS files. |
| `FORBIDDEN_INLINE_SCRIPT_BLOCK` | A `<script>` element contains body content (i.e., is not the asset reference form `<script src="..."></script>`). |

### 15.12 Inline event handler codes (§12.13)

| Code | Description |
|---|---|
| `FORBIDDEN_INLINE_EVENT_HANDLER` | An `on*` attribute is present on an element. Inline event handlers are forbidden regardless of content shape. This code fires on every inline handler. The dispatch model in §6 is the required replacement. |
| `MULTIPLE_HANDLER_STATEMENTS` | An inline event handler attribute contains multiple statements. |
| `INLINE_HANDLER_EXPRESSION` | An inline event handler attribute contains expressions other than a single function call. |
| `MALFORMED_HANDLER_CALL` | An inline event handler's function call has whitespace between the function name and the opening parenthesis. |
| `TRAILING_HANDLER_SEMICOLON` | An inline event handler attribute ends with a trailing semicolon. |
| `FORBIDDEN_REVEALING_MODULE_CALL` | An inline event handler calls a function via dotted property access. |
| `FORBIDDEN_BUILTIN_METHOD_CALL` | An inline event handler calls a method on a built-in object. |
| `HANDLER_FUNCTION_NAME_MISMATCH` | An inline event handler's function name is not a recognized chrome function and does not match the page's prefix. |
| `FORBIDDEN_EVENT_METHOD_CALL` | An inline event handler calls a method on the event object. |
| `FORBIDDEN_HANDLER_CONDITIONAL` | An inline event handler contains conditional logic. |
| `FORBIDDEN_INLINE_DOM_OPERATION` | An inline event handler performs DOM manipulation inline. |
| `FORBIDDEN_INLINE_ASSIGNMENT` | An inline event handler contains assignment expressions. |
| `FORBIDDEN_JAVASCRIPT_PROTOCOL` | An inline event handler uses the `javascript:` pseudo-protocol. |
| `FORBIDDEN_ARGUMENT_EXPRESSION` | An inline event handler argument is an expression other than a literal, `this`, or `this.<property>`. |
| `MALFORMED_ARGUMENT_QUOTING` | A string literal argument uses double quotes (conflicting with the surrounding attribute's quoting). |
| `MALFORMED_ARGUMENT_LIST` | Multiple inline event handler arguments are not separated by `, ` (comma followed by single space). |
| `FORBIDDEN_HELPER_PAGE_FUNCTION_CALL` | A helper module function emits an inline event handler that calls a page-prefixed function. |


---

## 16. Compliance queries

Standard SQL queries against `dbo.Asset_Registry` for HTML compliance reporting. Each query is scoped to `WHERE file_type = 'HTML'` (or includes related cross-population scopes where indicated).

### 16.1 Q1 — Drift summary per file

Counts of total HTML rows and rows-with-drift per file. Use to prioritize refactor work.

```sql
SELECT
    file_name,
    COUNT(*)                                                     AS total_rows,
    SUM(CASE WHEN drift_codes IS NOT NULL THEN 1 ELSE 0 END)     AS rows_with_drift
FROM dbo.Asset_Registry
WHERE file_type = 'HTML'
GROUP BY file_name
ORDER BY rows_with_drift DESC;
```

### 16.2 Q2 — Drift code distribution

What kinds of drift are most common across the HTML codebase?

```sql
SELECT
    TRIM(value)         AS code,
    COUNT(*)            AS occurrences
FROM dbo.Asset_Registry
CROSS APPLY STRING_SPLIT(drift_codes, ',')
WHERE file_type    = 'HTML'
  AND drift_codes  IS NOT NULL
  AND TRIM(value)  <> ''
GROUP BY TRIM(value)
ORDER BY COUNT(*) DESC;
```

### 16.3 Q3 — Per-file rewrite checklist

For one specific file, what does the work look like, grouped by drift code?

```sql
SELECT
    drift_codes,
    COUNT(*)            AS occurrences,
    MIN(line_start)     AS first_line,
    MAX(line_start)     AS last_line
FROM dbo.Asset_Registry
WHERE file_type    = 'HTML'
  AND file_name    = '<filename.ps1>'
  AND drift_codes  IS NOT NULL
GROUP BY drift_codes
ORDER BY occurrences DESC;
```

### 16.4 Q4 — Cross-page text comparison

For each text categorical name, list every page's variation. Surfaces copy inconsistency.

```sql
SELECT
    component_name        AS category,
    file_name,
    raw_text
FROM dbo.Asset_Registry
WHERE file_type      = 'HTML'
  AND component_type = 'HTML_TEXT'
ORDER BY component_name, file_name;
```

### 16.5 Q5 — Engine card registry validation

Which active scheduled processes lack engine card registration, or are registered to non-existent pages? This is a registry-side data integrity check covering both directions:

- `run_mode = 1` (active scheduled) rows missing any of the four cc-prefixed columns
- `run_mode = 2` (queue processor) rows with any of the four cc-prefixed columns populated (queue processors do not appear on CC pages, so populated values indicate dirty registry data)

```sql
SELECT
    process_id,
    process_name,
    run_mode,
    cc_engine_slug,
    cc_engine_label,
    cc_page_route,
    cc_sort_order,
    CASE
        WHEN run_mode = 1 AND (cc_engine_slug IS NULL OR cc_engine_label IS NULL OR cc_page_route IS NULL OR cc_sort_order IS NULL)
            THEN 'Active scheduled process missing engine card registration'
        WHEN run_mode = 2 AND (cc_engine_slug IS NOT NULL OR cc_engine_label IS NOT NULL OR cc_page_route IS NOT NULL OR cc_sort_order IS NOT NULL)
            THEN 'Queue processor has unexpected engine card registration'
        ELSE NULL
    END AS issue
FROM Orchestrator.ProcessRegistry
WHERE run_mode IN (1, 2)
  AND (
      (run_mode = 1 AND (cc_engine_slug IS NULL OR cc_engine_label IS NULL OR cc_page_route IS NULL OR cc_sort_order IS NULL))
      OR
      (run_mode = 2 AND (cc_engine_slug IS NOT NULL OR cc_engine_label IS NOT NULL OR cc_page_route IS NOT NULL OR cc_sort_order IS NOT NULL))
  );
```

### 16.6 Q6 — Slideout/modal/panel inventory

List every slideout, modal, and slide-up panel platform-wide, grouped by construct kind.

```sql
SELECT
    file_name,
    component_name,
    purpose_description,
    drift_codes
FROM dbo.Asset_Registry
WHERE file_type      = 'HTML'
  AND component_type = 'HTML_ID'
  AND reference_type = 'DEFINITION'
  AND (
      component_name LIKE '%-slideout-%'
      OR component_name LIKE '%-modal-%'
      OR component_name LIKE '%-slideup-%'
  )
ORDER BY component_name, file_name;
```

### 16.7 Q7 — Cross-form entity inventory

Find every distinct icon/symbol used platform-wide across all three forms (named entity, numeric entity, direct Unicode).

```sql
SELECT
    component_name,
    signature              AS form,
    COUNT(DISTINCT file_name) AS appears_on_n_pages,
    STRING_AGG(file_name, ', ') WITHIN GROUP (ORDER BY file_name) AS files
FROM dbo.Asset_Registry
WHERE file_type      = 'HTML'
  AND component_type = 'HTML_ENTITY'
GROUP BY component_name, signature
ORDER BY appears_on_n_pages DESC, component_name;
```

Q7 surfaces three-form inconsistencies — where the same conceptual icon (e.g., a gear) appears as `&#9881;` on one page and `⚙` on another.

### 16.8 Q8 — Unresolved cross-population references

Find every USAGE row from HTML where the referenced construct doesn't have a matching DEFINITION row.

```sql
SELECT
    file_name,
    component_type,
    component_name,
    line_start
FROM dbo.Asset_Registry
WHERE file_type    = 'HTML'
  AND reference_type = 'USAGE'
  AND source_file  = '<undefined>'
ORDER BY component_type, component_name, file_name;
```

### 16.9 Q9 — Helper coupling check

Find any helper-emitted HTML that has page-prefixed IDs, page-prefixed function calls, page-local action values, or page-specific data-* attributes (all forbidden by helper rules).

```sql
SELECT
    file_name,
    component_type,
    component_name,
    parent_function,
    drift_codes
FROM dbo.Asset_Registry
WHERE file_type   = 'HTML'
  AND scope       = 'SHARED'
  AND drift_codes LIKE '%FORBIDDEN_HELPER_%'
ORDER BY file_name, component_name;
```

### 16.10 Q10 — Has-dynamic-content inventory

Find every catalog row where the parent attribute or text construct contains additional runtime-only content.

```sql
SELECT
    file_name,
    component_type,
    component_name,
    raw_text
FROM dbo.Asset_Registry
WHERE has_dynamic_content = 1
ORDER BY file_name, line_start;
```

This query identifies places where the catalog's static analysis is incomplete by design, useful for distinguishing "the catalog has the full picture" from "the catalog has a partial picture."

### 16.11 Q11 — HTML data-action with no JS dispatch entry

Find `data-action-<event>` declarations in HTML that have no matching entry in the corresponding JS dispatch table. Column names for `JS_DISPATCH_ENTRY` rows are placeholders pending the JS populator update; if the JS spec lands on different column names, this query will need a small column-name adjustment.

```sql
WITH html_actions AS (
    SELECT
        file_name        AS html_file,
        variant_qualifier_1 AS event_name,
        variant_type     AS action_value,
        line_start
    FROM dbo.Asset_Registry
    WHERE file_type      = 'HTML'
      AND component_type = 'HTML_DATA_ATTRIBUTE'
      AND component_name LIKE 'data-action-%'
      AND variant_qualifier_1 IS NOT NULL  -- event-type rows, not arg rows
),
js_dispatch AS (
    SELECT
        file_name        AS js_file,
        variant_qualifier_1 AS event_name,
        component_name   AS action_value
    FROM dbo.Asset_Registry
    WHERE file_type      = 'JS'
      AND component_type = 'JS_DISPATCH_ENTRY'
)
SELECT
    h.html_file,
    h.event_name,
    h.action_value,
    h.line_start,
    'HTML declares action with no JS dispatch entry' AS issue
FROM html_actions h
LEFT JOIN js_dispatch j
       ON j.event_name   = h.event_name
      AND j.action_value = h.action_value
WHERE j.action_value IS NULL
ORDER BY h.html_file, h.event_name, h.action_value;
```

### 16.12 Q12 — JS dispatch entry with no HTML usage

Find JS dispatch table entries with no HTML element declaring the action. Surfaces dead dispatch entries that no HTML element triggers.

Caveat: this query can produce false positives for entries that are dispatched programmatically from other JS code (rather than from user events on HTML elements). Operator should review each row to distinguish dead code from programmatic dispatch. A future enhancement could exclude entries that have matching `JS_DISPATCH_LOOKUP USAGE` rows from JS code, but that requires JS populator support not yet present.

```sql
WITH js_dispatch AS (
    SELECT
        file_name        AS js_file,
        variant_qualifier_1 AS event_name,
        component_name   AS action_value
    FROM dbo.Asset_Registry
    WHERE file_type      = 'JS'
      AND component_type = 'JS_DISPATCH_ENTRY'
),
html_actions AS (
    SELECT
        variant_qualifier_1 AS event_name,
        variant_type     AS action_value
    FROM dbo.Asset_Registry
    WHERE file_type      = 'HTML'
      AND component_type = 'HTML_DATA_ATTRIBUTE'
      AND component_name LIKE 'data-action-%'
      AND variant_qualifier_1 IS NOT NULL
)
SELECT
    j.js_file,
    j.event_name,
    j.action_value,
    'JS dispatch entry with no HTML element declaring this action' AS issue
FROM js_dispatch j
LEFT JOIN html_actions h
       ON h.event_name   = j.event_name
      AND h.action_value = j.action_value
WHERE h.action_value IS NULL
ORDER BY j.js_file, j.event_name, j.action_value;
```

### 16.13 Q13 — Inline event handler inventory

Find every inline event handler in the HTML codebase, grouped by file. The umbrella code `FORBIDDEN_INLINE_EVENT_HANDLER` fires on every inline handler; additional drift codes describe the specific shape violations.

```sql
SELECT
    file_name,
    line_start,
    component_name        AS attribute_name,
    signature             AS full_attribute,
    drift_codes
FROM dbo.Asset_Registry
WHERE file_type      = 'HTML'
  AND component_type = 'HTML_EVENT_HANDLER'
ORDER BY file_name, line_start;
```

### 16.14 Q14 — Inline event handler shape breakdown

Distribution of inline-handler drift codes across the codebase. Helps distinguish handlers that need only mechanical conversion (umbrella code only) from handlers that need real JS refactoring (umbrella plus content-shape codes).

```sql
SELECT
    TRIM(value)                    AS drift_code,
    COUNT(*)                       AS occurrences,
    COUNT(DISTINCT file_name)      AS files_affected
FROM dbo.Asset_Registry
CROSS APPLY STRING_SPLIT(drift_codes, ',')
WHERE file_type      = 'HTML'
  AND component_type = 'HTML_EVENT_HANDLER'
  AND drift_codes    IS NOT NULL
  AND TRIM(value)    <> ''
GROUP BY TRIM(value)
ORDER BY occurrences DESC;
```


---

## 17. Examples

### 17.1 Minimal complete page emission

A small page demonstrating every required pattern. Real pages have more sections.

```html
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/example.css">
    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-platform" data-cc-page="example" data-cc-prefix="exa">
$navHtml

<div class="cc-header-bar">
    <div>
        $headerHtml
    </div>
    <div class="cc-header-right">
        <div class="cc-refresh-info">
            <span class="cc-live-indicator"></span>
            <span>Live</span> | Updated: <span id="cc-last-update" class="cc-last-updated">-</span>
            <button class="cc-page-refresh-btn" data-action-click="cc-page-refresh" title="Refresh all data">&#8635;</button>
        </div>
    </div>
</div>

<div id="cc-connection-banner" class="cc-connection-banner"></div>
<div id="cc-page-error-banner" class="cc-page-error-banner"></div>

<div class="exa-page-grid">
    <div class="exa-status-card">
        <h2 class="exa-section-title">Status Overview</h2>
        <p class="exa-message">Loading data...</p>
    </div>
</div>

<script src="/js/cc-shared.js"></script>
</body>
</html>
```

This emission produces these catalog rows (illustrative, not exhaustive):

- 1 × `HTML_ID DEFINITION` for `cc-last-update` (chrome ID)
- 1 × `HTML_ID DEFINITION` for `cc-connection-banner` (chrome ID)
- 1 × `HTML_ID DEFINITION` for `cc-page-error-banner` (chrome ID)
- Multiple × `CSS_CLASS USAGE` rows resolving to either `cc-shared.css` (chrome classes) or `example.css` (page classes)
- 1 × `HTML_DATA_ATTRIBUTE DEFINITION` for `data-action-click="cc-page-refresh"` on the refresh button, with `variant_type = cc-page-refresh`, `variant_qualifier_1 = click`, `scope = SHARED`
- 2 × `CSS_FILE USAGE` rows for the two stylesheet references
- 1 × `JS_FILE USAGE` row for the single script reference (`cc-shared.js`)
- Several × `HTML_TEXT DEFINITION` rows: `attr-title` for the refresh button tooltip, `h2-section-title`, `p-message`, etc.
- 1 × `HTML_ENTITY DEFINITION` for `&#8635;` with `signature = entity_numeric`

Zero drift rows expected when the page conforms.

### 17.2 Engine card block

Three engine cards on a page that consumes orchestrator events:

```html
<div class="cc-engine-row">
    <div class="cc-engine-card" id="cc-card-engine-nb">
        <span class="cc-engine-label">NB</span>
        <div class="cc-engine-bar disabled" id="cc-engine-bar-nb"></div>
        <span class="cc-engine-countdown" id="cc-engine-cd-nb">&nbsp;</span>
    </div>
    <div class="cc-engine-card" id="cc-card-engine-pmt">
        <span class="cc-engine-label">PMT</span>
        <div class="cc-engine-bar disabled" id="cc-engine-bar-pmt"></div>
        <span class="cc-engine-countdown" id="cc-engine-cd-pmt">&nbsp;</span>
    </div>
    <div class="cc-engine-card" id="cc-card-engine-bdl">
        <span class="cc-engine-label">BDL</span>
        <div class="cc-engine-bar disabled" id="cc-engine-bar-bdl"></div>
        <span class="cc-engine-countdown" id="cc-engine-cd-bdl">&nbsp;</span>
    </div>
</div>
```

Each card produces three `HTML_ID DEFINITION` rows (the three IDs) plus the corresponding text content rows for the labels. Cross-validation against `Orchestrator.ProcessRegistry` confirms slugs (`nb`, `pmt`, `bdl`), labels (`NB`, `PMT`, `BDL`), and that all three processes have `cc_page_route = '/batch-monitoring'`.

### 17.3 Dynamic class assembly

Building a navigation link with conditional state classes:

```powershell
$classList = @('nav-link')
if ($section.accent_class) { $classList += $section.accent_class }
if ($page.page_route -eq $CurrentPageRoute) { $classList += 'active' }
$cssClasses = ($classList -join ' ')

[void]$sb.AppendLine("<a href=`"$($page.page_route)`" class=`"$cssClasses`">$($page.page_label)</a>")
```

The populator emits:

- `CSS_CLASS USAGE` for `nav-link` (literal in array initialization), `has_dynamic_content = TRUE`
- `CSS_CLASS USAGE` for `active` (literal in conditional append), `has_dynamic_content = TRUE`
- No row for `$section.accent_class` (parameter-fed, not statically resolvable)

The flag indicates that the catalog's view of these class compositions is partial — the runtime may add `nav-section-platform` or `nav-section-departmental` depending on the section.

### 17.4 Slideout with purpose comment

```html
<!-- Slideout for displaying request details with comments and timeline -->
<div id="bsv-slideout-request-overlay" class="slide-panel-overlay" data-action-click="close-request-slideout"></div>
<div id="bsv-slideout-request" class="slide-panel xwide">
    <div class="slide-panel-header">
        <h3 class="bsv-slideout-title">Request Details</h3>
        <button class="slide-panel-close" data-action-click="close-request-slideout" title="Close">×</button>
    </div>
    <div class="slide-panel-body" id="bsv-slideout-request-body"></div>
</div>
```

Catalog rows emitted:

- `HTML_COMMENT DEFINITION` for the comment, `component_name = comment-panel-purpose`
- `HTML_ID DEFINITION` for `bsv-slideout-request-overlay`, `purpose_description` populated from comment
- `HTML_ID DEFINITION` for `bsv-slideout-request`, `purpose_description` populated from comment
- `HTML_ID DEFINITION` for `bsv-slideout-request-body`
- 2 × `HTML_DATA_ATTRIBUTE DEFINITION` for `data-action-click="close-request-slideout"` (once on overlay, once on close button), with `variant_type = close-request-slideout`, `variant_qualifier_1 = click`, `scope = LOCAL`
- `HTML_TEXT DEFINITION` for "Request Details" with `component_name = h3-slideout-title`
- `HTML_ENTITY DEFINITION` for "×" (the close glyph) with `signature = direct_unicode`
- `HTML_TEXT DEFINITION` for "Close" attribute value with `component_name = attr-title`

JS-side (the page's `bsv_clickActions` table contains `'close-request-slideout': bsv_closeRequestSlideout`) is cataloged separately as a `JS_DISPATCH_ENTRY DEFINITION` row by the JS populator. The HTML populator's `data-action-click="close-request-slideout"` row resolves against that entry post-pipeline.

### 17.5 Anti-pattern: forbidden inline class composition

Anti-pattern (forbidden — emits multiple drift codes):

```powershell
$activeClass = if ($page.page_route -eq $CurrentPageRoute) { ' active' } else { '' }
[void]$sb.AppendLine("<a class=`"nav-link$($section.accent_class)$activeClass`">$label</a>")
```

This emits `INLINE_CLASS_CONCATENATION`, `INLINE_CLASS_BRACED_INTERPOLATION`, and possibly other codes depending on the populator's evaluation order.

Correct pattern (per §5.2.1):

```powershell
$classList = @('nav-link')
if ($section.accent_class) { $classList += $section.accent_class }
if ($page.page_route -eq $CurrentPageRoute) { $classList += 'active' }
$cssClasses = ($classList -join ' ')
[void]$sb.AppendLine("<a class=`"$cssClasses`">$label</a>")
```

The correct pattern produces clean catalog rows with no drift.

### 17.6 Anti-pattern: inline event handler

Anti-pattern (forbidden):

```html
<button onclick="if(event.target.dataset.confirmed === 'true') deleteItem(123)">Delete</button>
```

This emits these drift codes on the `HTML_EVENT_HANDLER DEFINITION` row:

- `FORBIDDEN_INLINE_EVENT_HANDLER` (umbrella — fires on every inline handler)
- `INLINE_HANDLER_EXPRESSION` (the value contains expressions beyond a single function call)
- `FORBIDDEN_HANDLER_CONDITIONAL` (the `if(...)` conditional logic)
- `FORBIDDEN_EVENT_METHOD_CALL` (`event.target.dataset` is method/property access on the event object)

Correct pattern (per §6 and §12.13):

```html
<button data-action-click="delete-item" data-action-item-id="123" data-action-confirm="true">Delete</button>
```

```javascript
const bsv_clickActions = {
    'delete-item': bsv_deleteItem
};

function bsv_deleteItem(target, event) {
    if (target.dataset.actionConfirm === 'true') {
        const itemId = parseInt(target.dataset.actionItemId, 10);
        bsv_performDelete(itemId);
    }
}
```

The handler:

- Lives in the page's JS file, where logic belongs
- Is registered in the dispatch table by action key (`delete-item`)
- Reads arguments via `target.dataset.<arg>` per §6.3
- Handles conditionals in JS, not in HTML

Catalog rows emitted by HTML for the new pattern (zero drift):

- 1 × `HTML_DATA_ATTRIBUTE DEFINITION` for `data-action-click="delete-item"` (`variant_type = delete-item`, `variant_qualifier_1 = click`)
- 1 × `HTML_DATA_ATTRIBUTE DEFINITION` for `data-action-item-id="123"` (argument attribute, `variant_type = 123`, no `variant_qualifier_1`)
- 1 × `HTML_DATA_ATTRIBUTE DEFINITION` for `data-action-confirm="true"` (argument attribute, `variant_type = true`, no `variant_qualifier_1`)
- 1 × `HTML_TEXT DEFINITION` for "Delete" with `component_name = button-text`

---

## Appendix - Rationale

This appendix explains why selected rules are what they are. Entries are keyed to body section numbers. Sections without entries here have no rationale beyond the rule itself.

### A.1 Required structure

The strict page shell shape (DOCTYPE, root, head, body, content order) is what lets the parser walk a route file's emitted HTML deterministically. Each emission has predictable phases the populator can recognize: file shell, chrome, content, asset references. Without a fixed shape, the populator would have to handle arbitrary structural variation, which inflates parser complexity for no platform benefit.

The page shell substitutions (`$browserTitle`, `$navHtml`, `$headerHtml`, `$sectionKey`) preserve the platform's centralized control over chrome behavior. If pages hardcoded their titles, headers, or section keys, every platform-wide chrome change would require touching every page. The substitution pattern lets `Get-PageBrowserTitle`, `Get-NavBarHtml`, and `Get-PageHeaderHtml` evolve independently of page authoring.

The two `<body>` attributes `data-cc-page` and `data-cc-prefix` exist to support the bootloader-driven JS module loading model (§6 and the JavaScript spec). The bootloader in `cc-shared.js` reads `data-cc-page` to determine which page-specific JS file to load and `data-cc-prefix` to determine the page's init function name (`<prefix>_init`). Carrying both attributes on `<body>` keeps the bootloader's logic simple: read two attributes, derive a file path and a function name. Surfacing the cc_prefix in the page-shell HTML also makes the prefix discipline visible at the top level of every page rather than implicit in identifier conventions throughout.

The `#cc-page-error-banner` placeholder gives the bootloader a DOM target for surfacing page-boot failures (script load errors, missing init functions, init function exceptions). Like the connection banner, it exists as an empty placeholder in markup and is populated at runtime by `cc-shared.js`. The placeholder's mandatory position (immediately after the connection banner) creates a predictable layout for users: connection state above the page, then any page-boot errors, then the page content below.

The DOCTYPE strict-casing rule (only `<!DOCTYPE html>` is permitted) reflects a "one way only" stance applied throughout the spec. HTML allows several casings of the DOCTYPE token, but a spec that allowed multiple forms produces a catalog full of stylistically inconsistent rows that say the same thing. Mandating exactly one form means: the catalog is uniform, the populator's detection logic is simple, and any deviation is real drift worth flagging.

The decision to remove all access-denied page carve-outs (§1.6) follows the same "no shortcuts, no half-measures" stance. A page that emits HTML must conform to the HTML spec. The access-denied page's special rendering context (it renders before authenticated resources are reachable) is real, but the spec's job is to govern markup shape regardless of rendering context. Exemptions for specific pages would establish a precedent that any page with a sufficiently special context can carve itself out — eroding the spec's authority over time. Cleaning up the access-denied page to comply with the standard page shell is the right resolution, not exempting it.

### A.2 Page chrome

The exact-markup mandate for chrome elements (refresh button entity reference, live indicator structure, engine card four-element block) is the spec's "design inconsistency surfacer" working as intended. Variations like "Refresh data" vs "Refresh all data" vs "Reload" are real inconsistencies that the catalog must distinguish between conforming and non-conforming. Loosening the rules to "any reasonable refresh button" defeats the purpose: the catalog can't surface variation it doesn't see as variation.

The engine card slug-from-registry rule (§2.3.3) makes ProcessRegistry the single source of truth for engine card identification. Without it, the slug exists in three places (registry, JS file, HTML IDs) and can drift between any of them. Tying all three to the registry value via cross-population rules ensures drift is detectable.

The `run_mode`-based validation rules split into two complementary checks. Active scheduled processes (run_mode = 1) without engine card registration produce `MISSING_ENGINE_CARD_REGISTRATION` drift attached to their corresponding engine card in the HTML populator's catalog rows. Queue processors (run_mode = 2) with populated cc-prefixed columns are not engine cards — they have no HTML representation — so the HTML populator cannot attach drift to them. That violation is surfaced by Q5 in §16, which queries ProcessRegistry directly. Splitting the check this way matches the populator's actual capability: it can only attach drift to HTML rows it emits, and only emits rows for things that appear in HTML.

### A.4 ID conventions

The closed set for chrome IDs (§4.1) is small by design. Chrome IDs represent platform-wide DOM contracts between `cc-shared.js` and the page. Letting pages add new chrome IDs unilaterally would mean shared JS code grows brittle dependencies on per-page identifiers. The "spec amendment required" gate forces deliberate platform decisions when shared infrastructure needs new DOM hooks.

The role-first ordering for slideout/modal/panel IDs (`<prefix>-slideout-<purpose>-overlay` rather than `<prefix>-<purpose>-slideout-overlay`) supports cross-page consistency queries: `LIKE 'bsv-slideout-%'` returns every slideout on a page; without role-first ordering, this query would need leading wildcards or lookups against tag-context.

Panel purpose comments (§4.3.5) exist because slideouts/modals/panels are the constructs that vary most in messaging across pages. Different pages have different request slideouts, different detail modals, different alert panels. Comparison queries against `purpose_description` for these constructs surface what each page actually does.

The contiguity rule for overlay panel declarations (§4.3.5) recognizes that slideouts, modals, and slide-up panels are conceptually outside the page's normal content flow. They float above the page when triggered by JavaScript, and the page's body content layout does not include them. Allowing overlay declarations to be sprinkled among section cards, layout containers, and other structural content blurs the conceptual separation and makes the markup harder to scan. Grouping every overlay declaration into one contiguous block — last in the body before the `<script>` tag — mirrors the conceptual separation in the markup itself. It also makes the panel-purpose-comment convention cleaner: one block of overlay declarations with one purpose comment per pair reads as a single unit, rather than as scattered notes throughout the file.

### A.5 Class attribute conventions

The single mandated dynamic class assembly pattern (array-join) deliberately constrains how class composition is expressed. Multiple legitimate-looking patterns exist for building dynamic strings (concatenation, here-strings, format operators, mixed interpolation), and a spec that allowed several would produce a catalog full of stylistically inconsistent rows that say the same thing.

Mandating one pattern means: catalogs are uniform, populator detection is simple (fail-on-deviation rather than recognize-many-variants), refactoring is mechanical (every dynamic class composition refactors to the same target shape), and code reviews are simpler ("does this match the pattern?").

The granular drift codes for forbidden interpolation patterns (§5.2.3) follow the CSS spec's banner-format precedent: `BANNER_INVALID_RULE_LENGTH`, `BANNER_INLINE_SHAPE`, `BANNER_MISSING_DESCRIPTION`, etc. are split rather than collapsed because each describes a specific kind of work to fix it. The same logic applies to inline class interpolation: `INLINE_CLASS_CONCATENATION` and `INLINE_CLASS_BRACED_INTERPOLATION` describe different syntactic problems requiring different mental refactor patterns, even though both end at the same array-join target.

The `has_dynamic_content` flag exists because static analysis cannot resolve parameter-passed class names. Without the flag, a catalog query like "what classes does `Get-NavBarHtml` apply to nav links?" returns an incomplete answer that looks complete. The flag makes incompleteness queryable: rows where the catalog knows there's more, but can't see it.

### A.6 Action dispatch via data-action attributes

The `data-action-<event>` family separates HTML's structural concern ("here's an element that triggers something") from JavaScript's behavioral concern ("here's what happens when something is triggered"). Under the old inline-event-handler model, HTML carried both: the markup contained the function name and call shape, coupling HTML markup directly to JavaScript function declarations. That coupling produced an asymmetric catalog (HTML emitted USAGE rows that JS DEFINITION rows had to resolve against in reverse pipeline order) and forced page authors to know JS function names while authoring HTML.

Under the new dispatch model, HTML elements declare what should happen via an action key (`open-request-detail`, `cc-page-refresh`) without referencing any function name. The JavaScript file's dispatch table is the single point that maps action keys to handler functions. HTML can change its action keys, JavaScript can rename its functions, and the two can evolve independently as long as their dispatch table mediates between them.

The hybrid prefix convention (`cc-` for shared chrome actions, unprefixed for page-local actions) is inverted from the convention used for IDs, classes, and JS top-level identifiers (where page-local has the prefix and shared is unprefixed). The inversion is intentional: the `cc-` prefix on `data-action` values is a dispatch-routing signal, not a categorization signal. The bootloader's shared dispatcher looks for `cc-` prefix to decide whether an event belongs to it; the page's local dispatcher handles everything else. Encoding the routing decision into the attribute's value rather than its name keeps the HTML readable (one attribute, one value, one routing decision) and the dispatcher logic simple (read the value's prefix to decide which table to look up).

Action keys are scoped by event type rather than global to the page because the same action key may legitimately appear on multiple events with different handlers (e.g., `data-action-click="save"` triggers a confirm-and-save flow while `data-action-change="save"` triggers an auto-save flow). Treating action keys as per-event values keeps the catalog clean: each `<prefix>_<event>Actions` table is its own namespace, and the populator's `UNRESOLVED_DATA_ACTION` resolution is straightforward (look up the value in the corresponding event's table, not across all tables).

The recognized event list (§6.4) is closed at 8 events: `click`, `change`, `input`, `submit`, `keydown`, `keyup`, `focus`, `blur`. Closed-list discipline serves the same purpose here as the chrome ID closed set (§4.1): adding a new event requires a spec amendment, a populator update, and (when the new event has a different shape than existing dispatchers handle) a bootloader update. The friction is intentional. The 8-event starting set covers the interactions Control Center pages typically wire up; new events are added as concrete needs surface during page conversions.

The argument attribute pattern (`data-action-<arg-name>="<value>"`) gives the dispatch model a way to pass per-element data to the handler without resorting to per-element listener attachment. The handler receives a reference to the element via the dispatcher's `(target, event)` signature and reads arguments via `target.dataset.<arg>`. The argument name rule that arg names cannot collide with event names (§6.3.1's `ARGUMENT_NAME_COLLIDES_WITH_EVENT`) keeps the attribute name space unambiguous: looking at any `data-action-<word>` attribute, the populator can determine whether `<word>` is an event name (from the §6.4 closed set) or an argument name (anything else) without further context.

The structural rule for helper argument attributes (§6.6) draws a line at one place: data the caller gave the helper is allowed, data the helper went and got on its own is not. PowerShell exposes caller-given data through `param()` declarations, and the populator can see foreach iterators over those parameters as the same data taking a different shape inside the function body. The forbidden side — script-scope, module-level, ambient state — is exactly what page coupling looks like in practice: a helper named `Get-NavBarHtml` should not be reading `$script:CurrentPageRoute` to decide what to emit, it should receive the current page route as a parameter and let the caller choose.

### A.7 data-* attribute conventions

The open-set policy for `data-*` names (no closed registry) reflects that data-* exists precisely to let pages attach arbitrary custom data without spec amendment. Forcing every distinct `data-*` name through a registry would defeat the attribute's purpose.

That said, the catalog tracks every distinct name. If patterns emerge — many pages using `data-batch-id`, `data-action`, etc. — the catalog query data informs whether a Phase 3 tightening is warranted (e.g., mandating that certain data-* names follow specific value formats).

### A.8 Text content and entity references

The categorical naming for HTML_TEXT rows (§8.2.2) supports the catalog's primary purpose for text: cross-page consistency comparison. Without categorical naming, queries like "all section titles platform-wide" would need to scan all `HTML_TEXT` rows and inspect parent elements at query time — slow and complex. With categorical naming, the same query is `WHERE component_name = 'h2-section-title'` — fast and indexable.

The page-prefix stripping in derivation handles a subtle issue: `<h2 class="bsv-section-title">` and `<h2 class="bch-section-title">` would otherwise have different `component_name` values (`h2-bsv-section-title` vs `h2-bch-section-title`), defeating cross-page comparison. Stripping the page prefix before deriving the category produces unified `h2-section-title` for both, which is the intent.

The decision not to mandate which form (named entity, numeric entity, direct Unicode) icons should use is a Phase 1 deferral. The catalog tracks all three forms; once data shows which forms are actually in use and where the inconsistencies are, Phase 3 tightening can mandate one form (likely numeric entities for typographic safety).

### A.9 Inline SVG

Treating SVG as opaque markup at the catalog level reflects a practical scoping choice. Deeply parsing SVG (paths, gradients, animations, text positioning) would be substantial parser work for limited catalog value. The current model (one row per outer `<svg>`, full markup in `raw_text`) supports both "what SVGs exist?" queries (against `component_name`) and "exact-content comparison" queries (against `raw_text`) without committing to internal parsing.

The §9.5 carve-out for SVG-internal `<style>` blocks recognizes that SVG has its own legitimate styling needs (gradients, animations) that can't reasonably move to external CSS. The carve-out is narrow — `<style>` is permitted only inside `<svg>` — and doesn't extend to HTML-scope `<style>` blocks anywhere else.

### A.13 Catalog model

The composite row identity (`component_type`, `component_name`, `reference_type`, `file_name`, `occurrence_index`) supports catalog queries that need different scoping. Same identifier can appear as a definition once and a usage many times; same file can have many rows of different types; same component_type can group across files. The composite identity makes all of these queryable.

The cross-populator dependency model (CSS → HTML → JS → PS) preserves single-pass resolution. Each populator runs against a catalog state where its dependencies have already emitted their rows. JS resolves IDs against HTML's DEFINITION rows; HTML resolves classes against CSS's DEFINITION rows. Standalone runs out of order produce `<undefined>` resolution, surfaced via the `source_file` column rather than as drift codes.

The `data-action` family introduces a forward reference from HTML to JS that the pipeline order does not satisfy at scan time. HTML emits `HTML_DATA_ATTRIBUTE DEFINITION` rows for `data-action-<event>` attributes before the JS populator has emitted any `JS_DISPATCH_ENTRY DEFINITION` rows. The `UNRESOLVED_DATA_ACTION` drift code (§6.2) therefore attaches at query time, post-pipeline, not at HTML scan time. The §16 compliance queries (Q11 and Q12) implement this resolution via SQL joins against rows emitted by both populators. The same structural property applies to the single `JS_FILE USAGE` row HTML emits for `<script src="/js/cc-shared.js">` — its resolution against the JS populator's `JS_FILE DEFINITION` row also waits for post-pipeline query.

The `HTML_EVENT_HANDLER` component type exists as a catalog home for forbidden inline-handler attributes (§12.13). Inline handlers are forbidden by spec but may still appear in source code (legacy code pre-refactor, or new code introduced without spec discipline). The populator must catalog them so their `FORBIDDEN_INLINE_EVENT_HANDLER` umbrella code (and any applicable specific codes from §12.13's table) have a row to attach to. Without a dedicated component type, these violations would have nowhere to live in the catalog and would go undetected — exactly the failure mode the catalog exists to prevent.

### A.15 Drift codes — granularity

The drift codes throughout the spec are granular by design — each describes one specific spec violation, not a general category. This mirrors the CSS spec's precedent (banner format codes, forbidden combinator codes) and serves the same purpose: precise refactor planning. A query for "every page with a malformed refresh button" returns rows with `MALFORMED_REFRESH_BUTTON`; a query for "every page with engine card label drift" returns rows with `ENGINE_LABEL_REGISTRY_MISMATCH`. The codes are the diagnostic vocabulary the catalog uses to describe what's wrong.

A coarser approach (one drift code per section, e.g., `MALFORMED_PAGE_CHROME`) would conflate many distinct violations and make refactor work harder to triage. The granular approach trades a higher code count for queryability — and the spec is the catalog's vocabulary, so vocabulary richness is a feature.

A small refinement to this pattern appears in §12.13 (inline event handlers). A single umbrella code (`FORBIDDEN_INLINE_EVENT_HANDLER`) fires on every inline handler regardless of content shape, paired with up to 16 specific codes that describe the handler's particular shape of badness. The umbrella ensures every inline handler is detected (a "clean" inline handler that violates no sub-rule still fires the umbrella). The specifics let refactor planning sort handlers by complexity. Both axes are queryable: the umbrella answers "is this an inline handler?" and the specifics answer "what is the inline handler doing that needs untangling?" This pattern fits naturally where a category-level prohibition coexists with content-level shape rules.
