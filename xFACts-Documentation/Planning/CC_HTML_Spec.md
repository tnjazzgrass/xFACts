# Control Center HTML File Format Specification

## 1. Page shell

HTML in the Control Center is emitted from PowerShell route files. Every page route emits HTML conforming to this shape, in this exact order:

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

### 1.1 Rules

- `<!DOCTYPE html>` opens the document on its own line. The token is exactly `<!DOCTYPE html>` — uppercase keyword, lowercase tag name.
- The root element is `<html>` with no attributes.
- `<head>` contains exactly one `<title>` element followed by the mandated `<link rel="stylesheet">` elements per §3. No other elements.
- The `<title>` element's content is the `$browserTitle` PowerShell variable, sourced from `Get-PageBrowserTitle`.
- `<body>` declares three attributes: `class="cc-section-<sectionKey>"` where `<sectionKey>` matches `RBAC_NavSection.section_key`; `data-cc-page="<slug>"` where `<slug>` is the page's URL slug; `data-cc-prefix="<prefix>"` where `<prefix>` matches `Component_Registry.cc_prefix`.
- The first content inside `<body>` is the `$navHtml` substitution, sourced from `Get-NavBarHtml`.
- Between `$navHtml` and the closing `<script>` tag, the body contains, in order: the page header bar (§2.1), the connection banner placeholder (§2.4), the page error banner placeholder (§2.5), and page-specific content.
- The last content inside `<body>` before `</body>` is the single `<script>` tag per §3.

### 1.2 Helper-emitted HTML fragments

A helper module function that emits a partial HTML fragment for substitution into a page shell (`Get-NavBarHtml`, `Get-PageHeaderHtml`, and similar) is not subject to the page-shell rules in §1.1. It is subject to the attribute-level rules in §4–§10 and the helper-specific rules in §11.

### 1.3 Access-denied page

The 403 access-denied response is a complete page and is subject to every spec rule in this document. There are no carve-outs.

---

## 2. Page chrome

Every page renders the same structural chrome regardless of page-specific content: header bar, refresh info, optional engine cards, connection banner placeholder, page error banner placeholder. The exact markup is mandated; any deviation is drift.

### 2.1 Page header bar

The header bar is the first content element after `$navHtml`. Its structure is exactly:

```
<div class="cc-header-bar">
    <div>
        $headerHtml
    </div>
    <div class="cc-header-right">
        <div class="cc-refresh-info">...</div>
        <div class="cc-engine-row">...</div>     <!-- optional, see §2.3 -->
    </div>
</div>
```

#### 2.1.1 Rules

- The outer container is exactly `<div class="cc-header-bar">`.
- The first child is exactly an unattributed `<div>` containing only the `$headerHtml` substitution from `Get-PageHeaderHtml`. No hardcoded title content.
- The second child is exactly `<div class="cc-header-right">`.
- `cc-header-right` contains exactly `<div class="cc-refresh-info">` followed optionally by `<div class="cc-engine-row">`. No other children.

### 2.2 Refresh info block

Markup is exactly:

```
<div class="cc-refresh-info">
    <span class="cc-live-indicator"></span>
    <span>Live</span> | Updated: <span id="cc-last-update" class="cc-last-updated">-</span>
    <button class="cc-page-refresh-btn" data-action-click="cc-page-refresh" title="Refresh all data">&#8635;</button>
</div>
```

#### 2.2.1 Rules

- The outer container, live indicator span, live status line, last-update span, and page refresh button match the mandated markup verbatim — class names, attributes, text content, entity reference.
- The `cc-last-update` chrome ID appears exactly once per page.

### 2.3 Engine cards

A page that consumes engine events from the orchestrator displays engine cards inside the header bar's `cc-header-right` block. Pages without orchestrator-driven content omit the entire `cc-engine-row` block. Pages with engine cards conform exactly to the rules below.

Engine card row structure:

```
<div class="cc-engine-row">
    <div class="cc-card-engine" id="cc-card-engine-<slug>">
        <span class="cc-engine-label">SLUG_LABEL</span>
        <div class="cc-engine-bar" id="cc-engine-bar-<slug>"></div>
        <span class="cc-engine-cd" id="cc-engine-cd-<slug>">--</span>
    </div>
    <!-- additional cards follow -->
</div>
```

#### 2.3.1 Rules

- The outer container is exactly `<div class="cc-engine-row">`. The row contains only engine card elements as children.
- Each engine card has exactly four elements in this order: outer `cc-card-engine` div with `id="cc-card-engine-<slug>"`; `cc-engine-label` span containing the label text; `cc-engine-bar` div with `id="cc-engine-bar-<slug>"` and no content; `cc-engine-cd` span with `id="cc-engine-cd-<slug>"` containing the literal `--`.
- The `<slug>` for each card matches `Orchestrator.ProcessRegistry.cc_engine_slug` for an active process registered to this page.
- The label text matches `Orchestrator.ProcessRegistry.cc_engine_label` for the corresponding process.
- Engine cards appear in declaration order matching `Orchestrator.ProcessRegistry.cc_sort_order`.

### 2.4 Connection banner placeholder

A single `<div id="cc-connection-banner" class="cc-connection-banner"></div>` appears exactly once per page, immediately after the page header bar. The placeholder is empty — `cc-shared.js` populates it at runtime based on WebSocket state.

### 2.5 Page error banner placeholder

A single `<div id="cc-page-error-banner" class="cc-page-error-banner"></div>` appears exactly once per page, immediately after the connection banner placeholder. The placeholder is empty — `cc-shared.js` populates it at runtime when page module loading or initialization fails.

---

## 3. Asset references

### 3.1 CSS references

A page references exactly two CSS files, in this exact order, inside `<head>` between the `<title>` element and the closing `</head>` tag:

```
<link rel="stylesheet" href="/css/<page>.css">
<link rel="stylesheet" href="/css/cc-shared.css">
```

#### 3.1.1 Rules

- Every CSS reference uses the form `<link rel="stylesheet" href="...">` exactly. No other attributes.
- The first CSS reference is the page-specific stylesheet at `/css/<page>.css` where `<page>` matches the page's URL slug.
- The second CSS reference is exactly `<link rel="stylesheet" href="/css/cc-shared.css">`.
- The page-specific reference appears before the shared reference.
- Exactly two CSS references appear in `<head>`. Pages do not load other CSS files.

### 3.2 JavaScript reference

Exactly one JavaScript file is referenced in HTML markup:

```
<script src="/js/cc-shared.js"></script>
```

The `<script>` tag appears as the last content in `<body>` before `</body>`.

#### 3.2.1 Rules

- The single `<script>` tag's `src` is exactly `/js/cc-shared.js`. No other JavaScript files are referenced from HTML.
- The `<script>` tag has no other attributes — no `defer`, no `async`, no `type`, no `crossorigin`.
- The page-specific JS file is loaded dynamically by the bootloader based on the `data-cc-page` attribute (§1.1). It does not appear as a `<script>` tag in HTML.

---

## 4. Prefix discipline

Every identifier in HTML markup carries a prefix that identifies its source:

- **Page prefix** — the value of `Component_Registry.cc_prefix` for the page's component. Used on all page-local identifiers (IDs, classes, action values, page-emitted `data-*` attribute names).
- **Chrome prefix** — the literal token `cc-`. Used on all platform-shared identifiers emitted by `cc-shared.js`, `cc-shared.css`, helper module functions, or fixed in this spec as part of the page chrome.

### 4.1 Rules

- Every ID begins with the page's `cc_prefix` followed by `-` (page-local IDs), or with `cc-` (chrome IDs). No other forms.
- Every class begins with the page's `cc_prefix` followed by `-` (page-local classes), or with `cc-` (chrome classes). No other forms.
- Every `data-action-<event>` value begins with the page's `cc_prefix` followed by `-` (page-local actions), or with `cc-` (chrome actions). No other forms.
- Every `data-*` attribute name not in the `data-action-*` family begins with `data-<page-prefix>-` (page-emitted) or `data-cc-` (helper-emitted). No other forms.
- The set of valid chrome IDs is closed (§5.1). The set of valid chrome action values is governed by `cc-shared.js`. New chrome identifiers require a spec amendment.

---

## 5. IDs

### 5.1 Chrome IDs

Chrome IDs are platform-wide identifiers used by `cc-shared.js` and `cc-shared.css` to locate specific DOM elements. The set is closed:

| Chrome ID | Purpose |
|---|---|
| `cc-last-update` | Timestamp display target. |
| `cc-connection-banner` | Connection state banner placeholder. |
| `cc-page-error-banner` | Page boot error banner placeholder. |
| `cc-card-engine-<slug>` | Engine card outer container. Slug from `Orchestrator.ProcessRegistry.cc_engine_slug`. |
| `cc-engine-bar-<slug>` | Engine status bar element. |
| `cc-engine-cd-<slug>` | Engine countdown text element. |

Adding a new chrome ID requires a spec amendment to the table above.

### 5.2 Page-local IDs

Page-local IDs have the form `<prefix>-<purpose>` where `<prefix>` is the page's `cc_prefix` from `Component_Registry` and `<purpose>` is a lowercase hyphen-separated descriptor.

### 5.3 Rules

- Every page-local ID begins with the page's `cc_prefix` followed by a hyphen.
- An ID that begins with another page's registered prefix is a cross-page collision.
- ID values use lowercase letters, digits, and hyphens only.
- Page-local IDs are unique within the page.
- Chrome IDs are never used on page-local elements.

### 5.4 Slideout, modal, and slide-up panel IDs

These overlay constructs follow fixed ID conventions:

| Construct | Element | ID form |
|---|---|---|
| Slideout | Overlay | `<prefix>-slideout-<purpose>-overlay` |
| Slideout | Panel | `<prefix>-slideout-<purpose>` |
| Modal | Outer `.cc-modal-overlay` element | `<prefix>-modal-<purpose>` |
| Slide-up panel | Backdrop | `<prefix>-slideup-<purpose>-backdrop` |
| Slide-up panel | Panel | `<prefix>-slideup-<purpose>` |

#### 5.4.1 Rules

- A modal's outer element is `.cc-modal-overlay` containing exactly one direct child `.cc-modal`. The nested `.cc-modal` carries no ID.
- A slideout declares both its overlay and panel IDs. A slide-up panel declares both its backdrop and panel IDs. Declaring one half without the other is drift.
- All slideout, modal, and slide-up panel declarations on a page appear in one contiguous block of markup, placed after page-specific section content and before the closing `<script>` tag.
- Each slideout, modal, and slide-up panel declaration is immediately preceded by an HTML purpose comment (`<!-- short description of what this panel does -->`).

---

## 6. Classes

### 6.1 Static class values

A static class attribute contains zero or more space-separated class names:

```
class="<class-1> <class-2> <class-N>"
```

#### 6.1.1 Rules

- Class names are separated by exactly one space. No leading or trailing whitespace. No tabs. No multiple consecutive spaces.
- Class names use lowercase letters, digits, and hyphens only.
- Each class name in an attribute value is unique. Duplicates in the same `class=""` are drift.
- Every class name conforms to the prefix discipline in §4.

### 6.2 Dynamic class values

A class attribute that depends on runtime state is built via the array-join pattern:

```powershell
$classList = @('<prefix>-base-class')
if ($condition1) { $classList += '<prefix>-modifier-1' }
if ($condition2) { $classList += '<prefix>-modifier-2' }
$cssClasses = ($classList -join ' ')

# In the HTML emission:
[void]$sb.AppendLine("<a class=`"$cssClasses`">$label</a>")
```

#### 6.2.1 Rules

- A class attribute containing PowerShell variable interpolation uses exactly one substitution token (`$<variable>`) and no other content. The variable holds the joined class string.
- The array's first element is the base class. Subsequent elements are conditional modifiers.
- Every literal string class name in the array conforms to the prefix discipline in §4.
- Mixed interpolation patterns are forbidden: no static text adjacent to interpolation, no multiple top-level interpolations, no braced or paren forms mixed with static text.

---

## 7. Action attributes

Pages connect user interactions to JavaScript by declaring `data-action-<event>` attributes on HTML elements. The JavaScript bootloader in `cc-shared.js` registers delegated event listeners on `document.body`, looks up the `data-action-<event>` value in the corresponding dispatch table, and invokes the registered handler.

### 7.1 Action attribute format

Every action attribute uses the form `data-action-<event>="<action-value>"` where `<event>` is one of the recognized events from §7.3 and `<action-value>` is a prefixed identifier per §4.

```
<button data-action-click="bsv-open-request-detail">View</button>
<button data-action-click="cc-page-refresh">Refresh</button>
<select data-action-change="bsv-filter-by-status">...</select>
<input data-action-keydown="bsv-search-on-enter">
```

### 7.2 Rules

- Every action attribute name is exactly `data-action-<event>` where `<event>` is in the closed set from §7.3.
- Every action value carries a prefix per §4: `<page-prefix>-<name>` for page-local actions, `cc-<name>` for shared chrome actions.
- Action values use lowercase letters, digits, and hyphens only.
- Every action value has a matching entry in its event-scoped dispatch table — page-local in `<prefix>_<event>Actions`, shared in `cc_<event>Actions`. Resolution is event-type-scoped.

### 7.3 Recognized events

| Event | When it fires |
|---|---|
| `click` | Mouse click or keyboard activation on the element |
| `change` | User changes a form control's value and the change is committed |
| `input` | User changes a form control's value (fires on every modification) |
| `submit` | A form is submitted |
| `keydown` | A keyboard key is pressed down while the element has focus |
| `keyup` | A keyboard key is released while the element has focus |
| `focus` | The element gains focus |
| `blur` | The element loses focus |

The recognized event set is closed. Adding a new event requires a spec amendment.

### 7.4 Argument attributes

An element with a `data-action-<event>` attribute may declare zero or more argument attributes that pass data to the dispatched handler:

```
<button data-action-click="bsv-open-batch-detail" data-action-batch-id="12345">Open</button>
```

#### 7.4.1 Rules

- Every argument attribute appears on an element that also declares at least one `data-action-<event>` attribute.
- Argument attribute names use the form `data-action-<arg-name>` where `<arg-name>` is lowercase letters, digits, and hyphens only.
- `<arg-name>` must not match any event name from §7.3.
- Argument attribute values are static strings or fully-resolved PowerShell variables. No mixed interpolation.

---

## 8. Data attributes

Pages declare custom `data-*` attributes on HTML elements to attach structured data for JavaScript to consume. The `data-action-*` family is governed by §7; this section governs all other `data-*` attributes.

### 8.1 Rules

- Every page-emitted `data-*` attribute name begins with `data-<page-prefix>-`. Helper-emitted `data-*` attribute names begin with `data-cc-`. No other forms.
- Attribute names use lowercase letters, digits, and hyphens only.
- Attribute values are static strings or fully-resolved PowerShell variables. Mixed interpolation is forbidden.

---

## 9. Text content and SVG

### 9.1 Text content

Text content is human-readable display copy that appears between element opening and closing tags, plus the four user-facing attributes `title`, `placeholder`, `aria-label`, and `alt`.

#### 9.1.1 Rules

- Text content character data is stored verbatim, with leading and trailing whitespace trimmed. Interior whitespace is preserved.
- User-facing attributes (`title`, `placeholder`, `aria-label`, `alt`) are not declared with empty values.
- Text content that contains PowerShell variable interpolation follows the same interpolation rules as class attributes (§6.2): one fully-resolved variable, no mixed interpolation with static text.

### 9.2 Inline SVG

Inline `<svg>` elements are catalogued at the outer-element level only. Internal structure (paths, polygons, gradients, etc.) is stored as raw text but not separately validated.

#### 9.2.1 Rules

- SVG outer attributes (`width`, `height`, `viewBox`, `fill`, etc.) are not separately validated.
- The internal structure of the SVG is not validated.
- SVG-internal `<style>` blocks are SVG-scoped and are exempt from the §12 inline-style prohibition.
- SVG outer markup containing PowerShell interpolation follows the same interpolation rules as class attributes (§6.2).

---

## 10. Comments

HTML comments serve three purposes:

1. **Section dividers** — multi-line block comments separating major content blocks within a route file's HTML. Optional, used for readability.
2. **Inline annotations** — single-line comments providing brief context on a specific element or block. Optional.
3. **Panel purpose comments** — single-line comments immediately preceding a slideout, modal, or slide-up panel declaration, describing the construct's purpose. Required by §5.4.

### 10.1 Section divider format

A section divider is a multi-line block comment with the form:

```
<!-- ============================================================================
     SECTION TITLE
     ============================================================================ -->
```

The opening and closing rule lines are exactly 76 `=` characters.

### 10.2 Rules

- Comment bodies do not contain `--` other than the closing `-->`.
- Comments do not contain PowerShell variable interpolation.
- Every comment is closed with `-->`.
- A panel purpose comment immediately precedes the outermost element of the slideout, modal, or slide-up panel it describes.

---

## 11. Helper-emitted HTML

A helper module function emits a partial HTML fragment for substitution into a page shell (`Get-NavBarHtml`, `Get-PageHeaderHtml`, `Get-HomePageSections`, and similar). Helpers are owned by the platform, not by any specific page, and the markup they emit reflects that ownership.

### 11.1 Rules

- Helpers do not declare asset references (no `<link>` or `<script>` elements).
- Every ID a helper emits is a chrome ID (`cc-` prefixed) per §5.1. Page-prefixed IDs are forbidden.
- Every class a helper emits is `cc-` prefixed per §4. Page-prefixed classes are forbidden.
- Every action value a helper emits is `cc-` prefixed per §4 and §7.
- Every `data-*` attribute a helper emits begins with `data-cc-` per §8. Page-prefixed `data-*` names are forbidden.
- Argument attribute values in helper-emitted markup come from the helper's `param()` declarations or `foreach` iterators over those parameters. Values that reference script-scope, module-level, or ambient state are forbidden.

---

## 12. Forbidden patterns

| Pattern | Rule |
|---------|------|
| DOCTYPE missing or any casing other than `<!DOCTYPE html>` | §1.1 |
| `<html>` root element with attributes | §1.1 |
| `<head>` containing elements other than `<title>` and `<link>` | §1.1 |
| `<title>` content hardcoded instead of `$browserTitle` substitution | §1.1 |
| `<body>` missing any of `class="cc-section-<sectionKey>"`, `data-cc-page="<slug>"`, `data-cc-prefix="<prefix>"` | §1.1 |
| Page header bar missing or hardcoded instead of `$headerHtml` substitution | §2.1 |
| Connection banner placeholder missing, populated, or out of order | §2.4 |
| Page error banner placeholder missing, populated, or out of order | §2.5 |
| Chrome ID outside the closed set in §5.1 | §5.1 |
| Page-local ID missing its page prefix, using another page's prefix, or containing characters other than lowercase letters, digits, and hyphens | §5.3 |
| Duplicate ID values on a page | §5.3 |
| Modal outer `.cc-modal-overlay` missing its nested `.cc-modal` direct child | §5.4 |
| Slideout or slide-up panel declared with only one half of its overlay/panel (or backdrop/panel) pair | §5.4 |
| Slideout, modal, or slide-up panel declaration not preceded by an HTML purpose comment | §5.4 |
| Slideout, modal, or slide-up panel declarations not grouped in one contiguous block | §5.4 |
| Class name not carrying the page prefix or `cc-` prefix | §4, §6.1 |
| Class name containing characters other than lowercase letters, digits, and hyphens | §6.1 |
| Duplicate class names within the same `class=""` attribute | §6.1 |
| Class attribute whitespace malformed (leading, trailing, multiple consecutive, tabs) | §6.1 |
| Dynamic class attribute not using the array-join pattern | §6.2 |
| Action attribute using an event not in the §7.3 closed set | §7.2 |
| Action value not carrying the page prefix or `cc-` prefix | §4, §7.2 |
| Action value containing characters other than lowercase letters, digits, and hyphens | §7.2 |
| Action value with no matching entry in the corresponding dispatch table | §7.2 |
| Argument attribute on an element with no `data-action-<event>` attribute | §7.4 |
| Argument attribute name matching an event name from §7.3 | §7.4 |
| Argument attribute value mixing static text with PowerShell interpolation | §7.4 |
| `data-*` attribute name not beginning with `data-<page-prefix>-` (page) or `data-cc-` (helper), excluding `data-action-*` | §8 |
| `data-*` attribute value mixing static text with PowerShell interpolation | §8 |
| User-facing attribute (`title`, `placeholder`, `aria-label`, `alt`) declared with empty value | §9.1 |
| HTML comment containing `--` other than the closing `-->` | §10.2 |
| HTML comment containing PowerShell variable interpolation | §10.2 |
| Unclosed HTML comment | §10.2 |
| Inline `<style>` block (outside SVG) | — |
| Inline `style="..."` attribute on any element | — |
| Inline `<script>` block with body content (only the asset reference form `<script src="..."></script>` is permitted) | §3.2 |
| Inline event handler attribute (`onclick`, `onchange`, any `on*`) on any element | §7 |
| Helper emitting a page-prefixed ID, class, action value, `data-*` attribute, or argument value referencing non-parameter state | §11.1 |

---

## 13. Chrome class reference

The chrome classes referenced by the HTML spec are defined in `cc-shared.css`. The list below is the contract — when this spec references a chrome class, that class must exist in `cc-shared.css` with the same name. Adding or renaming a chrome class requires updates in both files.

### 13.1 Page chrome

| Class | Used by |
|---|---|
| `cc-header-bar` | Page header bar outer container (§2.1) |
| `cc-header-right` | Header bar right-side container (§2.1) |
| `cc-refresh-info` | Refresh info block container (§2.2) |
| `cc-live-indicator` | Pulsing live-state dot (§2.2) |
| `cc-last-updated` | Last-update timestamp span (§2.2) |
| `cc-page-refresh-btn` | Manual page refresh button (§2.2) |
| `cc-engine-row` | Engine card row container (§2.3) |
| `cc-card-engine` | Single engine card outer container (§2.3) |
| `cc-engine-label` | Engine card label span (§2.3) |
| `cc-engine-bar` | Engine card status bar (§2.3) |
| `cc-engine-cd` | Engine card countdown text (§2.3) |
| `cc-connection-banner` | Connection state banner placeholder (§2.4) |
| `cc-page-error-banner` | Page boot error banner placeholder (§2.5) |

### 13.2 Overlay constructs

| Class | Used by |
|---|---|
| `cc-modal-overlay` | Modal outermost element (§5.4) |
| `cc-modal` | Modal inner container (§5.4) |
| `cc-modal-header` | Modal header row |
| `cc-modal-title` | Modal header title text |
| `cc-modal-body` | Modal main content area |
| `cc-modal-actions` | Modal footer action button row |
| `cc-modal-close` | Modal close (X) button (shared with slide panels) |
| `cc-slide-overlay` | Slideout overlay element (§5.4) |
| `cc-slide-panel` | Slideout or slide-up panel container (§5.4) |
| `cc-slide-panel-header` | Slide panel header row |
| `cc-slide-panel-title` | Slide panel header title text |
| `cc-slide-panel-body` | Slide panel main content area |

### 13.3 Body section accent classes

The `<body>` carries a section accent class derived from `RBAC_NavSection.section_key`:

| Class | Section |
|---|---|
| `cc-section-platform` | Platform Operations section pages |
| `cc-section-departmental` | Departmental section pages |
| `cc-section-shared` | Shared section pages |

The list expands when `RBAC_NavSection` adds new sections. The spec follows registry state.

---

## 14. Drift code reference

Each rule that the populator enforces produces one drift code. This table is the contract between the spec and the populator.

| Code | Description | Rule |
|------|-------------|------|
| `MALFORMED_DOCTYPE` | DOCTYPE missing or non-canonical casing. | §1.1 |
| `MALFORMED_HTML_ROOT` | `<html>` root element has attributes. | §1.1 |
| `MALFORMED_HEAD` | `<head>` contains elements other than `<title>` and `<link>`. | §1.1 |
| `FORBIDDEN_HARDCODED_TITLE` | `<title>` content is hardcoded instead of `$browserTitle`. | §1.1 |
| `MISSING_BODY_SECTION_CLASS` | `<body>` missing `class="cc-section-<sectionKey>"`. | §1.1 |
| `MISSING_DATA_CC_PAGE` | `<body>` missing `data-cc-page` attribute. | §1.1 |
| `MISSING_DATA_CC_PREFIX` | `<body>` missing `data-cc-prefix` attribute. | §1.1 |
| `MISSING_NAV_SUBSTITUTION` | First content inside `<body>` is not `$navHtml`. | §1.1 |
| `MALFORMED_BODY_CLOSE` | Content appears between the `<script>` tag and `</body>`. | §1.1, §3.2 |
| `MISSING_HEADER_BAR` | Page header bar missing or not first content after `$navHtml`. | §2.1 |
| `FORBIDDEN_HARDCODED_PAGE_HEADER` | Page header hardcoded instead of `$headerHtml`. | §2.1 |
| `MALFORMED_HEADER_BAR_STRUCTURE` | Header bar children deviate from the mandated structure. | §2.1 |
| `MALFORMED_REFRESH_INFO_STRUCTURE` | Refresh info block deviates from mandated markup. | §2.2 |
| `DUPLICATE_LAST_UPDATE_ID` | `cc-last-update` ID appears more than once. | §2.2 |
| `MALFORMED_ENGINE_ROW_STRUCTURE` | Engine row container or children deviate from mandated structure. | §2.3 |
| `MALFORMED_ENGINE_CARD` | Engine card's four-element structure is wrong. | §2.3 |
| `ENGINE_CARD_PAGE_MISMATCH` | Engine card slug references a process registered to a different page. | §2.3 |
| `ENGINE_CARD_ORDER_MISMATCH` | Engine cards not in `Orchestrator.ProcessRegistry.cc_sort_order` order. | §2.3 |
| `MISSING_CONNECTION_BANNER` | Connection banner placeholder missing. | §2.4 |
| `FORBIDDEN_BANNER_CONTENT` | Connection banner placeholder contains content. | §2.4 |
| `MISSING_PAGE_ERROR_BANNER` | Page error banner placeholder missing. | §2.5 |
| `FORBIDDEN_PAGE_ERROR_BANNER_CONTENT` | Page error banner placeholder contains content. | §2.5 |
| `PAGE_ERROR_BANNER_ORDER_VIOLATION` | Page error banner not immediately after connection banner. | §2.5 |
| `MALFORMED_CSS_LINK` | CSS reference has attributes other than `rel` and `href`. | §3.1 |
| `MALFORMED_PAGE_CSS_REFERENCE` | First CSS reference is not `/css/<page>.css`. | §3.1 |
| `MALFORMED_SHARED_CSS_REFERENCE` | Second CSS reference is not `/css/cc-shared.css`. | §3.1 |
| `CSS_REFERENCE_ORDER_VIOLATION` | Page-specific reference appears after shared reference. | §3.1 |
| `UNEXPECTED_CSS_REFERENCE` | More than two CSS references in `<head>`. | §3.1 |
| `WRONG_SCRIPT_SOURCE` | `<script>` tag `src` is not `/js/cc-shared.js`. | §3.2 |
| `MALFORMED_SCRIPT_TAG` | `<script>` tag has attributes other than `src`. | §3.2 |
| `CHROME_ID_OUTSIDE_CLOSED_SET` | An ID starting with `cc-` is not in the §5.1 chrome ID set. | §5.1 |
| `CHROME_ID_REUSED_AS_LOCAL` | A page-local element carries a chrome ID. | §5.3 |
| `MISSING_PREFIX_ID` | Page-local ID does not begin with the page's prefix. | §5.3 |
| `CROSS_PAGE_PREFIX_COLLISION` | Page-local ID begins with another page's prefix. | §5.3 |
| `MALFORMED_ID_VALUE` | ID value contains characters other than lowercase letters, digits, and hyphens. | §5.3 |
| `DUPLICATE_ID_DECLARATION` | Same ID value declared more than once on a page. | §5.3 |
| `MALFORMED_MODAL_STRUCTURE` | Modal outer `.cc-modal-overlay` missing its nested `.cc-modal` child. | §5.4 |
| `MALFORMED_SLIDEOUT_ID` | Slideout overlay or panel ID does not follow `<prefix>-slideout-<purpose>-*` form. | §5.4 |
| `MALFORMED_MODAL_ID` | Modal outer element ID does not follow `<prefix>-modal-<purpose>` form. | §5.4 |
| `MALFORMED_SLIDEUP_ID` | Slide-up panel backdrop or panel ID does not follow `<prefix>-slideup-<purpose>-*` form. | §5.4 |
| `INCOMPLETE_OVERLAY_PAIR` | Slideout or slide-up panel missing one half of its pair. | §5.4 |
| `OVERLAY_PANEL_NOT_CONTIGUOUS` | Slideout, modal, or slide-up panel declarations not grouped. | §5.4 |
| `MISSING_PANEL_PURPOSE_COMMENT` | Slideout, modal, or slide-up panel not preceded by an HTML purpose comment. | §5.4 |
| `MALFORMED_CLASS_VALUE_WHITESPACE` | Class attribute value has leading, trailing, or excess whitespace. | §6.1 |
| `MALFORMED_CLASS_NAME` | Class name contains characters other than lowercase letters, digits, and hyphens. | §6.1 |
| `DUPLICATE_CLASS_IN_VALUE` | Same class name appears more than once in the same `class=""`. | §6.1 |
| `CLASS_PREFIX_MISMATCH` | Class name does not carry the page prefix or `cc-` prefix. | §4, §6.1 |
| `FORBIDDEN_DYNAMIC_CLASS_PATTERN` | Dynamic class attribute does not use the array-join pattern. | §6.2 |
| `UNKNOWN_EVENT_TYPE` | `data-action-<event>` uses an event not in the §7.3 closed set. | §7.2 |
| `MALFORMED_ACTION_VALUE` | Action value contains characters other than lowercase letters, digits, and hyphens. | §7.2 |
| `ACTION_PREFIX_MISMATCH` | Action value does not carry the page prefix or `cc-` prefix. | §4, §7.2 |
| `UNRESOLVED_DATA_ACTION` | Action value has no matching entry in the corresponding dispatch table. | §7.2 |
| `ORPHANED_ACTION_ARGUMENT` | Argument attribute on an element with no `data-action-<event>` attribute. | §7.4 |
| `ARGUMENT_NAME_COLLIDES_WITH_EVENT` | Argument attribute name matches an event name from §7.3. | §7.4 |
| `MALFORMED_ACTION_ARGUMENT_NAME` | Argument attribute name contains characters other than lowercase letters, digits, and hyphens. | §7.4 |
| `FORBIDDEN_INLINE_ACTION_ARGUMENT_INTERPOLATION` | Argument attribute value mixes static text with PowerShell interpolation. | §7.4 |
| `MALFORMED_DATA_ATTRIBUTE_NAME` | `data-*` attribute name does not begin with `data-<page-prefix>-` or `data-cc-`, excluding `data-action-*`. | §8 |
| `FORBIDDEN_INLINE_DATA_INTERPOLATION` | `data-*` attribute value mixes static text with PowerShell interpolation. | §8 |
| `EMPTY_DISPLAY_TEXT` | User-facing attribute declared with empty value. | §9.1 |
| `FORBIDDEN_TEXT_INTERPOLATION` | Text content uses a forbidden interpolation pattern. | §9.1 |
| `MALFORMED_COMMENT_DASHES` | HTML comment body contains `--` other than the closing `-->`. | §10.2 |
| `FORBIDDEN_COMMENT_INTERPOLATION` | HTML comment contains PowerShell variable interpolation. | §10.2 |
| `MALFORMED_COMMENT_UNCLOSED` | HTML comment is unclosed. | §10.2 |
| `FORBIDDEN_INLINE_STYLE_BLOCK` | `<style>` block in HTML markup outside SVG. | §12 |
| `FORBIDDEN_INLINE_STYLE_ATTRIBUTE` | Element has an inline `style=""` attribute. | §12 |
| `FORBIDDEN_INLINE_SCRIPT_BLOCK` | `<script>` element contains body content. | §3.2, §12 |
| `FORBIDDEN_INLINE_EVENT_HANDLER` | Element has an inline `on*` event handler attribute. | §7, §12 |
| `FORBIDDEN_HELPER_ASSET_REFERENCE` | Helper emits a `<link>` or `<script>` element. | §11.1 |
| `FORBIDDEN_HELPER_PAGE_PREFIX_ID` | Helper emits a page-prefixed ID. | §11.1 |
| `FORBIDDEN_HELPER_PAGE_PREFIX_CLASS` | Helper emits a page-prefixed class. | §11.1 |
| `FORBIDDEN_HELPER_PAGE_ACTION` | Helper emits a page-prefixed action value. | §11.1 |
| `FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE` | Helper emits a page-prefixed `data-*` attribute. | §11.1 |
| `FORBIDDEN_HELPER_PAGE_ACTION_ARGUMENT` | Helper emits an argument attribute referencing non-parameter state. | §11.1 |
