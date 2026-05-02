# Parser-Friendly Conventions — Recommendations

**Purpose**: Recommendations for `CC_FileFormat_Spec.md` derived from observations during Asset_Registry parser development (CSS + HTML extraction). These are forward-looking conventions that, when followed, make automated catalog parsing more accurate.

**Intended use**: Merge into `CC_FileFormat_Spec.md` when convenient. Maintained separately for now while the format spec is still actively evolving through the chrome standardization work.

**Source of these recommendations**: Patterns observed in the existing codebase that defeat or weaken static parsing, plus patterns that worked well and should be reinforced.

---

## Recommendations

### R1: Helper functions emit HTML in single coherent strings

**Problem observed**: PowerShell helper functions that build HTML via `$html += "..."` chains fragment HTML across token boundaries. When a class= attribute spans multiple concatenations, the parser can't statically resolve the value:

```powershell
# Parser-hostile — class= split across concatenation
$html = '<div class="' + $cssClass + '">'

# Parser-hostile — multiple short strings, attribute fragmented
$html += '<a class="'
$html += 'nav-link'
$html += '" href="/">Home</a>'
```

**Recommendation**: Helpers emitting HTML should use here-strings or single complete string literals. When string concatenation is unavoidable for control flow (loops, conditionals), keep entire HTML elements within single strings so attributes stay intact:

```powershell
# Parser-friendly — class= stays whole inside the here-string
$html = @"
<div class="nav-bar">
"@
foreach ($item in $items) {
    $html += @"
<a class="nav-link" href="$($item.Url)">$($item.Label)</a>
"@
}

# Also parser-friendly — class= value is a complete static string
$html = '<div class="nav-bar">'
foreach ($item in $items) {
    $html += "<a class=`"nav-link`" href=`"$($item.Url)`">$($item.Label)</a>"
}
```

**Why it matters**: Asset_Registry's HTML extraction reads CSS_CLASS USAGE rows from these helpers to track which pages consume which shared infrastructure. Fragmented attributes produce no rows, leaving consumption invisible.

**Impact on existing code**: When chrome standardization touches a helper file, restructure HTML emission to follow this pattern. xFACts-Helpers.psm1 currently has a mix of patterns — its consumption is partially visible in the catalog (8 rows) but likely under-counted.

---

### R2: Avoid variable interpolation in HTML class= attribute values

**Problem observed**: `class="$cssClass"` or `class="${prefix}-active"` in static HTML markup is statically unresolvable. The parser correctly skips these (they would otherwise produce garbage rows), but consumption visibility is lost for those locations.

**Recommendation**: In static HTML markup (here-strings inside route .ps1 files), class= values should be string literals. If conditional class application is needed, choose one of these patterns:

```powershell
# Pattern A — inline expansion produces a complete static-looking string
$html = @"
<div class="card $(if ($alert) { 'alert' })">
"@

# Pattern B — concatenate complete class lists, not class names
$baseClass = 'card'
if ($alert) { $baseClass = "card alert" }
$html = @"
<div class="$baseClass">
"@

# Pattern C — apply state classes at JS runtime via classList.add()
# (will be captured by future Phase 2 JS extraction)
```

**Why it matters**: Pattern A is parseable today (the parser sees `class="card alert"` or `class="card "` depending on the value of $alert — better than nothing). Pattern B is unparseable today but will work post-Phase 2 if we extend the parser to resolve simple variable assignments. Pattern C defers the visibility to JS extraction.

**Avoid**: assigning the entire class= value from a single variable. The parser can't see it.

---

### R3: Section banners are mandatory for parser-friendly file organization

**Existing spec covers this** — see `CC_FileFormat_Spec.md` Section 1.2. Asset_Registry parser produces COMMENT_BANNER rows from these banners and uses them to populate `source_section` on every component row. Without banners, components have no section context.

**Reinforcement during chrome work**: Verify each file has banners following the spec's exact pattern:
- 5+ `=` characters as the rule
- Title on next line
- Same structural form across CSS (`/* ===*/`), JS (`// ===`), and PS (`# ===`)

The parser detects all three syntaxes correctly. Files that use bespoke banner styles (e.g., `// **********`) will produce empty source_section values for everything in them.

**Catalog data point**: 190 LOCAL + 12 SHARED COMMENT_BANNER rows across the platform. Most files comply. The handful that don't will be visible during chrome work.

---

### R4: Class definitions should exist in CSS for every class used in HTML

**Problem observed**: 13+ class names are referenced in HTML markup but have no CSS DEFINITION row anywhere. Examples: `admin-badge`, `admin-tool`, `af-badge-count`, `gc-header-right`, `home-link`, `denied-container`, `denied-icon`, `notice-recon-tile`. These show up as `source_file = '<undefined>'` in the catalog.

**Categories of `<undefined>`**:
1. **State modifiers used as space-separated classes** (`active`, `disabled`, `hidden`, etc.) — legitimately have no standalone CSS rule because they're meant to compound with primary classes. Cannot be fixed in CSS; this is how HTML works.
2. **JS-targeting only** (e.g., `logout-link` for click handlers) — class exists for runtime selection, not styling. Acceptable but should be annotated.
3. **Dead references** — class added to HTML but CSS rule never written or got deleted. Should be either defined or removed.

**Recommendation**: For categories 2 and 3, add a CSS rule even if minimal. A 0-property rule serves as documentation that the class is intentional:

```css
/* ============================================================================
   N. JS TARGETING CLASSES (NO STYLING)
   ============================================================================ */

/* Used by JS for click-handler selection; intentionally unstyled. */
.logout-link { /* JS targeting only */ }
```

**Why it matters**: A future developer greps for `.logout-link` and finds the rule with the comment, immediately understanding intent. Without it, the class looks like a typo or dead code.

---

### R5: Naming follows established conventions surfaced by the catalog

**Problem observed**: 
- Slide-panel size modifiers: `wide` (most pages), `xwide` (BatchMonitoring), `extra-wide` (DmOperations) — all the same concept named three ways
- Custom modal classes (`modal-overlay`, `modal-content`) on 12 pages despite shared `xf-modal-*` infrastructure existing
- Activation classes: shared engine-events uses `.open` for slideouts; DmOps historically used `.active` for the same purpose (the canonical drift example)

**Recommendation**: Before naming any new CSS class, JS function, or significant identifier on a CC page, query the catalog for similar existing names:

```sql
-- Has someone already established a pattern for "X"?
SELECT DISTINCT component_name, scope, source_file
FROM dbo.Asset_Registry
WHERE component_type = 'CSS_CLASS'
  AND component_name LIKE '%modal%'  -- or %slide%, %card%, %badge%, etc.
  AND reference_type = 'DEFINITION'
ORDER BY scope DESC, component_name;
```

If a shared definition exists, use it. If a local-but-similar pattern exists on multiple pages, consider promoting before adding another variant.

**Why it matters**: This is the catalog's primary purpose — descriptive AND prescriptive. The data shows what conventions are established; new development should follow them.

---

### R6: Avoid CSS rules that target specific HTML IDs when shared classes exist

**Problem observed**: server-health.css line 729 enumerates 11 panel IDs (`#trans-panel.slide-panel.wide.open, #blocking-panel.slide-panel.wide.open, ...`) duplicating styling already defined for the shared `.slide-panel.wide.open` rule in engine-events.css.

**Recommendation**: If multiple HTML elements need the same styling, use a class. Don't enumerate IDs. If page-specific elements need page-specific overrides on top of shared styling, define a single page-class and apply it where needed:

```css
/* Parser-hostile and maintenance-hostile */
#trans-panel.slide-panel.wide.open,
#blocking-panel.slide-panel.wide.open,
#requests-panel.slide-panel.wide.open,
... 8 more IDs ... {
    /* same styling for all 11 */
}

/* Better — if 11 panels need extra styling beyond shared, use a marker class */
.slide-panel.wide.open.server-health-variant {
    /* override styling */
}
/* HTML: <div id="trans-panel" class="slide-panel server-health-variant">... */
```

**Why it matters**: ID-enumeration patterns produce one row in the catalog (correctly deduped), but the source CSS is harder to maintain and diverges from shared definitions over time. The catalog's `signature` column captures the full enumeration so refactor candidates are findable, but better to avoid the pattern up front.

---

### R7: PS files containing HTML should keep here-strings as the primary HTML emission pattern

**Reinforcement of existing implicit convention**: Route .ps1 files almost universally use `@" ... "@` here-strings for their main page HTML. This works perfectly with the parser. Helper functions in modules (.psm1 files) sometimes deviate — see R1.

**Recommendation**: Maintain the here-string convention for HTML markup in route files. When migrating helpers (per R1), convert their HTML emission to here-strings where feasible.

**Why it matters**: Here-strings preserve the exact structure of the HTML, line numbers map cleanly, and class= attributes stay intact. The parser is most accurate against here-string content.

---

### R8: Standard file headers stay as documented in spec

**Existing spec covers this** — see `CC_FileFormat_Spec.md` Section 1.1. The header format works. The parser doesn't currently extract from headers (component identity comes from System_Metadata via the `Version:` line, but Asset_Registry doesn't currently link to System_Metadata directly).

**Future possibility**: Asset_Registry could populate `source_file` and `parent_object` from header metadata to link rows back to the registered component. Defer until production rewrite if useful.

---

## Open recommendations (not yet drafted)

These are observations from the test parser runs that don't yet have concrete recommendation text. To be developed if/when chrome work touches the relevant files:

- **CSS @media nesting depth**: Deep at-rule nesting captures correctly but the chain isn't surfaced in queries. Possibly recommend keeping nesting shallow (1 level of @media inside top-level) for clarity. Investigate before committing to a recommendation.
- **JS module patterns**: When Phase 2 JS extraction lands, expect new recommendations about IIFE wrapping, module export conventions, and shared-vs-local function placement. Defer until parser exists.
- **API route registration patterns**: When Phase 3 PS extraction lands, recommendations about how `Add-PodeRoute` calls should be structured for clean cataloging.

---

## Document maintenance

This file is a working set of recommendations for eventual merge into `CC_FileFormat_Spec.md`. Edit freely as new observations arise from parser work or chrome standardization. Merge into the format spec when:
- The recommendations are stable
- The format spec itself is being actively revised
- A natural session boundary makes the merge easy

Until then, both documents coexist, with this one being the more current source for parser-related conventions.
