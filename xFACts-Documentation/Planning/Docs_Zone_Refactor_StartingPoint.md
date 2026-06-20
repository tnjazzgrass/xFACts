# Docs Zone Refactor — Starting Point

Backlog: B-044 (Refactor the documentation-site pages zone to spec). Third and
final zone, after CC (Phase 1) and standalone (Phase 2, complete). This document
is the grounded starting point: what the zone actually contains, what the drift
really is, the decisions that have to be made before file work begins, and the
recommended sequence. It is a planning anchor, not a spec — the specs remain the
sole authority on how files are written.

---

## 1. What the zone actually is

The docs zone is the static documentation site under
`E:\xFACts-ControlCenter\public\docs`. It has two populator-visible file
families and one that is currently invisible:

| Family | Files | Populator status |
|---|---|---|
| CSS | 7 | Already scanned and drift-scored (component `Documentation.Site`) |
| JS | 3 | Already scanned and drift-scored (component `Documentation.Site`) |
| HTML pages | ~all the `pages/` tree | Not scanned. No populator, no spec. Unexplored. |

The CSS and JS populators already include the docs scan roots
(`public\docs\css`, `public\docs\js`), so those 10 files are catalogued today.
The HTML pages have never been extracted or considered — see Section 6.

The non-HTML inventory and its current drift:

| File | Type | Total rows | Non-compliant | Notes |
|---|---|---|---|---|
| docs-base.css | CSS | 228 | 96 | The zone foundation file (see Section 4) |
| docs-controlcenter.css | CSS | 735 | 256 | Largest single file; a full session on its own |
| docs-reference.css | CSS | 299 | 113 | |
| docs-architecture.css | CSS | 220 | 85 | |
| docs-hub.css | CSS | 147 | 59 | |
| docs-narrative.css | CSS | 108 | 45 | |
| docs-erd.css | CSS | 100 | 43 | Has no section banners at all (see Section 5) |
| ddl-loader.js | JS | 140 | 43 | Bulk is cross-reference unresolved |
| docs-controlcenter.js | JS | 70 | 45 | Drives the interactive guide pages |
| nav.js | JS | 24 | 11 | |
| ddl-erd.js | JS | 26 | 8 | |
| **Totals** | | **~2,197** | **~804 (~37%)** | 7 CSS / 3 JS |

The "~90 files" estimate in the backlog folded in the HTML pages. The actual
spec-governed surface today is 10 files.

---

## 2. The headline finding: the specs fit

The concern going in was that the CSS and JS specs were written around the CC
zone (their section models are CC-chrome concepts — `FOUNDATION`, `CHROME`,
`LAYOUT`, `CONTENT`, `FEEDBACK_OVERLAYS` for CSS; `IMPORTS`/`CONSTANTS`/`STATE`/
`FUNCTIONS` plus shell types for JS) and might not fit docs-zone files at all.

The drift-code breakdown says otherwise. The codes that would signal a real
misfit — `DUPLICATE_CHROME`, `DUPLICATE_FOUNDATION`, `UNKNOWN_SECTION_TYPE`,
`SECTION_TYPE_ORDER_VIOLATION`, chrome-prefix violations — are essentially
absent. What is firing is, overwhelmingly, the same mechanical and
selector-discipline drift cleared dozens of times in the standalone pass.

Conclusion: the docs zone is **Bucket A (mechanical cleanup) with one clean
Bucket-B exception** (the foundation-file designation, Section 4). It is not a
new-spec-from-scratch situation. The specs need one accommodation, already half
anticipated by the spec itself, plus possibly one or two small amendments
confirmed during the file passes.

---

## 3. What the drift breaks down into

Grouping the codes by kind and effort:

**Group 1 — Universal mechanical hygiene (the bulk, lowest risk).**
`MALFORMED_FILE_HEADER` + `FILE_ORG_MISMATCH` (one each per file — the header
rewrite to comment-based format with a FILE ORGANIZATION list), the `BANNER_*`
family (`BANNER_INLINE_SHAPE`, `BANNER_INVALID_RULE_LENGTH`,
`BANNER_MALFORMED_TITLE_LINE`, `MISSING_PREFIX_DECLARATION`, `EMPTY_SECTION` —
converting decorative `/* ===== Label ===== */` comments into real section
banners), `MISSING_PURPOSE_COMMENT` / `MISSING_VARIANT_COMMENT` (per-rule purpose
comments), `MISSING_BLANK_LINE_SEPARATOR`, `MISSING_TRAILING_NEWLINE`,
`FORBIDDEN_COMMENT_STYLE`. Identical in kind to the standalone pass.

**Group 2 — CSS selector discipline (largest substantive chunk, higher care).**
`FORBIDDEN_DESCENDANT`, `FORBIDDEN_COMPOUND_DECLARATION`,
`FORBIDDEN_GROUP_SELECTOR`, `FORBIDDEN_ELEMENT_SELECTOR`,
`FORBIDDEN_UNIVERSAL_SELECTOR`, `COMPOUND_DEPTH_3PLUS`, `BLANK_LINE_INSIDE_RULE`,
`PSEUDO_ELEMENT_OUT_OF_ORDER`. These are real and they apply to any CSS, CC or
docs. They are selector rewrites, not comment additions, so they can shift
specificity — behavior preservation matters here, eyeball the rendered page.

**Group 3 — JS cross-reference resolution (the interesting one).**
`JS_CSS_CLASS_UNRESOLVED` dominates the JS files (37 ddl-loader, 35
docs-controlcenter, 7 nav, 5 ddl-erd) and `JS_HTML_ID_UNRESOLVED` appears on
docs-controlcenter (4) and ddl-loader (1). These fire when a JS file references a
class/ID with no matching DEFINITION in the catalog, same zone. Much of the CSS
share should self-resolve once the docs CSS is cleaned and emitting clean
`CSS_CLASS` definitions (ddl-loader's classes are mostly the `.ddl-*` / `.obj-*`
reference-render classes that live in `docs-reference.css`, not in HTML). The
residue after that points into the static HTML — which is the data that decides
the HTML question (Section 6).

**Group 4 — JS structural patterns (real, bounded).** `FORBIDDEN_IIFE` (one per
JS file — these wrap in an IIFE the spec forbids), `FORBIDDEN_PER_ELEMENT_LISTENER_LOOP`,
`FORBIDDEN_PROPERTY_ASSIGN_EVENT`. A known refactor each.

---

## 4. Decision 1 (do first): designate the foundation file

`docs-base.css` is the docs zone's foundation file — it owns the `:root` token
palette (backgrounds, text, accent families with `-rgb`/`-dim` companions,
borders, typography, layout), the documentation equivalent of `cc-shared.css`.
Its 32 `FORBIDDEN_CUSTOM_PROPERTY_LOCATION` rows fire because the spec (CSS spec
§10.2) restricts custom-property declarations to the zone's shell file, and
`docs-base.css` is not currently registered as that shell file.

The CSS spec already anticipated a docs shell file. CSS spec §4.2 lists:

| Component | Shell file |
|---|---|
| `ControlCenter.Shared` | `cc-shared.css` |
| `Documentation.Site` | `docs-shared.css` |

Two mismatches with reality: the named file is `docs-shared.css`, but the actual
foundation on disk is `docs-base.css`; and `docs-base.css` does not carry
`scope_tier = SHELL` in `Object_Registry` (the populator reads shell designation
from there, not from the filename).

**Recommended resolution (fix the spec/registration, not the file):**
1. Set `scope_tier = SHELL` on the `docs-base.css` row in `Object_Registry`.
2. Correct CSS spec §4.2 shell-file table cell from `docs-shared.css` to
   `docs-base.css`.

This clears the 32 rows without touching the file, and makes every other docs
CSS file's `var()` references resolve as SHARED. Do this before any file passes,
so the rest of the cleanup runs against a corrected spec rather than re-litigating
it mid-stream.

**To verify during the pass:** confirm no other docs CSS file declares its own
`:root` tokens. If one does, that is correct `FORBIDDEN_CUSTOM_PROPERTY_LOCATION`
drift (only the shell may declare) and the file should consume from docs-base
instead. From the files reviewed, the others use `var()` only — good sign.

---

## 5. Decision 2 (confirm during the pass): docs-erd.css sectioning

`docs-erd.css` has 28 `MISSING_SECTION_BANNER` — nearly every rule is orphaned —
because the file has no section banners at all. It uses decorative
`/* ===== Label ===== */` comments instead of real spec banners. This is not a
spec misfit; it is a file that was never sectioned. It is pure mechanical work
(organize into proper sections with banners), just the largest single-file chunk
of it because the file starts from zero. The file also carries a `Version: 2.0.0`
line in its header comment, which is a `MALFORMED_FILE_HEADER` contributor
(version belongs in System_Metadata, same rule applied to the PS files), and uses
hardcoded `rgba(86,156,214,*)` literals where docs-base defines `--accent-blue-rgb`
— a tokenization opportunity, subject to the same value-and-purpose-match rule the
CSS spec uses (only drift if a token of matching value and purpose exists).

No decision needed beyond confirming the section TYPEs that fit docs content
(LAYOUT / CONTENT, since FOUNDATION and CHROME are shell-only) as the passes
proceed.

---

## 6. Decision 3 (defer — let the data decide): static HTML

This is the genuinely unexplored question: should static documentation HTML be
extracted and tracked at all? Nothing exists for it — no populator, no spec, never
considered.

**What a populator buys, tested against the docs HTML:**

- **Queryable catalog** — weak benefit. The docs pages are read by humans and
  converted to Confluence by the publisher; nobody refactors them programmatically
  or asks "where is this used across pages."
- **Structural drift / uniformity** — argues against. These pages are
  hand-authored prose-bearing documents whose value is in being shaped to their
  content, not to a template. Imposing banner/section conformance on them would
  manufacture drift rows that are not problems — drift-as-noise, the opposite of
  the "drift means a real, actionable problem" standard. A full structural HTML
  spec is not recommended.
- **Cross-reference resolution** — the one benefit with teeth. The docs JS reaches
  into the HTML for IDs and classes (`#btn-tour`, `#section-N`, `.callout-marker`,
  `.mock-*`, `.key-flip-*`), so a JS reference to something that exists nowhere is
  a real bug the catalog could surface. But the dependency is concentrated and
  one-directional.

**What the page sample showed (serverhealth set + home):**

- The home page (`index.html`), narrative pages, and reference pages are
  effectively inert from the JS's perspective. The home page has zero JS-target
  IDs and loads only `nav.js` (which injects breadcrumb nav and reads nothing from
  the page). Narrative pages are static prose. Reference pages carry only the
  `ddl-root` container with `data-schema` / `data-category` that `ddl-loader.js`
  reads (a few attributes, not a class/ID surface).
- The real JS-to-HTML dependency lives almost entirely in the `-cc.html`
  interactive guide pages, which `docs-controlcenter.js` drives (section markers,
  tour/show-all buttons, mock-element highlights, slideout sections).

**Recommendation:** do not build a structural-conformance HTML populator. If
anything is built, it is at most a *minimal extractor* emitting `HTML_ID` and
`CSS_CLASS` DEFINITION rows only — no banners, no section types, no HTML-specific
drift codes — purely so the existing JS resolution closes the loop against the
`-cc.html` pages. Whether even that is worth it depends on the residual
`JS_*_UNRESOLVED` count after the docs CSS is cleaned. That count is the decision
input, and it does not exist yet — which is why this decision is deferred, not
declined.

**Sequencing makes the HTML question answer itself:** clean the CSS, then the JS,
and read the remaining unresolved count. If it is a handful (likely, given how
inert most pages are), accept them as known cross-zone references and skip HTML
entirely. If it is substantial and includes real typos, build the minimal class/ID
extractor and nothing more.

---

## 7. Recommended sequence

1. **Foundation designation (Decision 1).** Register `docs-base.css` as
   `scope_tier = SHELL`; correct CSS spec §4.2. Re-run CSS populator; confirm the
   32 custom-property rows clear and other files' `var()` references resolve SHARED.
2. **CSS files, hardest first.** `docs-controlcenter.css` (256) is the monster but
   the same kind as a big CC page. Then docs-reference, docs-architecture,
   docs-hub, docs-narrative, docs-erd (the last needs full sectioning from zero).
   Group 1 hygiene plus Group 2 selector rewrites; preserve rendered behavior,
   eyeball each page.
3. **JS files, after the CSS.** docs-controlcenter.js, ddl-loader.js, ddl-erd.js,
   nav.js. Group 4 structural fixes (drop the IIFEs, fix listener loops). Doing JS
   after CSS means a chunk of `JS_CSS_CLASS_UNRESOLVED` is already resolved by the
   clean CSS definitions rather than re-done.
4. **Read the residual `JS_*_UNRESOLVED` count.** This is the HTML decision input.
   Decide minimal-extractor vs. accept-and-skip per Section 6.
5. **Spec amendments as they surface.** Beyond the §4.2 fix, capture any small
   docs-zone accommodations the passes reveal (e.g., section TYPEs appropriate to
   docs content). Amend the spec rather than tolerate known drift; no mental
   exception list.

---

## 8. Honest sizing

Smaller than the backlog's "~90 files," but not a one-session sweep. The
selector-discipline work (Group 2) is a meaningful body of careful rewrites, and
`docs-controlcenter.css` alone (256 rows) is a full session. Realistic estimate:
a handful of focused sessions for the CSS, one for the JS, then a short HTML
decision. No hidden spec rewrite, no new zone model. The specs fit; the work is
known-pattern. The only true unknown left is the HTML, and it is a "should we"
question that the CSS/JS work will quantify, not a "how hard" question.

---

## 9. Open decisions captured

| # | Decision | Status | Recommendation |
|---|---|---|---|
| 1 | docs-base.css as shell file | Do first | Register `scope_tier=SHELL`, fix spec §4.2 to name docs-base.css |
| 2 | docs-erd.css full sectioning | Confirm in pass | Mechanical; section into LAYOUT/CONTENT, drop version line |
| 3 | Static HTML extraction | Deferred | No structural populator; decide minimal ID/class extractor after JS pass, based on residual unresolved count |
