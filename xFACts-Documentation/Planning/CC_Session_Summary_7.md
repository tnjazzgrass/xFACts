# CC Session Summary — CSS Spec Gap Closure and Populator Alignment Wrap

**Date:** 2026-05-23
**Focus:** Identified and resolved 17 gaps in `CC_CSS_Spec.md` (file header shape, banner shape, blank-line discipline, `@media` rules, `@keyframes` rules, `:root` rules, pseudo-element ordering, file-level discipline, trailing newline). Updated the populator to enforce the new rules with seven new drift codes plus broadened `MISSING_PURPOSE_COMMENT` scope. Discovered and fixed a populator false-positive on `MISSING_BLANK_LINE_SEPARATOR` that fired on every spec-compliant purpose-comment + construct pair. Brought `backup.css` and `cc-shared.css` to Category-A compliance (every drift signal that can be resolved without touching JS or HTML files is cleared).

**Disposition:** CSS populator alignment complete. Two CSS files (backup, cc-shared) carry only Category-B drift remaining — `PREFIX_MISMATCH` and `UNDEFINED_CLASS_USAGE` rows on the compound modifier tokens. Category-B resolution requires coordinated CSS + JS + HTML changes and is deferred to the cross-file refactor initiative that follows HTML and JS populator alignments. Next session opens on the HTML populator.

---

## Context entering the session

Prior session ended with the CSS populator emitting first-pass drift on the two refactored files (backup.css and cc-shared.css). The user's observation that the spec did not actually mandate everything a fresh-file author would need to produce a compliant file led to a comprehensive gap audit.

The session opened on the user's directive: gaps are not deferred to backlog; every gap gets a decision now, and the spec encodes the answer. The prior approach of bundling deferred items as "future amendments" was rejected as the reason for slow progress.

---

## 1. Spec gap resolution

17 gaps walked through one at a time, each posed as a single question with options. Every gap resolved with a rule mandate or an explicit "no rule, author's choice" statement.

### 1.1 File header and banner shape (Gaps 1, 2, 8, 9)

The §2 file-header template and §3 section-banner template were shown as content blocks without the `/*` and `*/` delimiters or the framing `=` rule lines explicit in the diagram. A fresh-file author had to assemble the actual shape from prose rules.

**Resolution:** File header and section banner use the same comment shape. `/*` followed by a space and exactly 76 `=` characters on line 1; interior lines indented three spaces; closing line of three spaces, exactly 76 `=` characters, a space, and `*/`. Section banners additionally include an interior `-` separator line of three spaces and exactly 76 `-` characters between the title line and the description block.

Both §2 and §3 template diagrams now show the complete shape including delimiters and rule lines.

### 1.2 Within-type section ordering (Gap 3)

§4 governs section type ordering (FOUNDATION → CHROME → LAYOUT → CONTENT → OVERRIDES → FEEDBACK_OVERLAYS). The spec did not say what determines the order of multiple sections of the same type (multiple CONTENT sections, multiple CHROME sections, etc.).

**Resolution:** Author's choice, no rule. CSS cascade matters and an override section may need to follow a section it overrides. Strict alphabetical ordering would risk inverting the cascade. §4.1 carries an explicit single sentence stating this.

### 1.3 Blank-line discipline (Gaps 4, 5)

The spec's existing `EXCESS_BLANK_LINES` rule capped blank-line count at 1 between top-level constructs but did not state a lower bound.

**Resolution:** Exactly one blank line between every two adjacent top-level constructs. Zero is drift (`MISSING_BLANK_LINE_SEPARATOR`), two or more remains `EXCESS_BLANK_LINES`. Top-level constructs include the file header, every section banner, every class definition, every variant, every pseudo-element rule, every sub-section marker, every `@media` block, every `@keyframes` block, and the `:root` block. Sub-section markers obey the same rule.

The principle behind the resolution: define one rule, apply it everywhere, even across spec files when possible.

### 1.4 Chrome registry deferral (Gap 6)

The CSS spec lacked a chrome-identifier reference equivalent to the HTML §13 and JS §16 chrome tables. A path forward was discussed (Path 1: spec §13; Path 2: SQL registry table maintained manually; Path 3: populator-maintained derivation from the anchor file).

**Resolution:** Deferred. Path 3 is the most pragmatic long-term answer but its scope spans all four specs and the four populators. Adding a §13 chrome class table to the CSS spec right now would just be undone when the registry initiative arrives. The CSS populator continues to read shared classes from cc-shared.css directly during its Pass 1 scan, which is acceptable in the interim. HTML §13 and JS §16 stay as-is until the registry initiative.

### 1.5 File-kind uniformity (Gap 7)

Whether anchor files and page files need different file-header treatment.

**Resolution:** No amendment. The spec is uniform across file kinds. The header template's content fields adapt to whichever kind the file is; no structural difference.

### 1.6 Trailing newline (Gap 10)

The spec did not say whether the file should end with a trailing newline.

**Resolution:** File ends with `}` followed by exactly one newline (`\n`). Drift code: `MISSING_TRAILING_NEWLINE`. POSIX convention plus version-control friendliness.

### 1.7 Within-rule formatting (Gap 11)

The spec did not mandate declaration-line shape, brace placement, indent width, or trailing semicolons inside rule bodies.

**Resolution:** No amendment beyond the existing `FORBIDDEN_COMPOUND_DECLARATION`. The catalog does not depend on within-rule formatting; the parser handles formatting variations identically. Spec stays focused on structural drift, not stylistic drift. Formatters exist if uniform style becomes a separate concern.

### 1.8 `@media` rules (Gap 12)

`@media` was mentioned only via the forbidden-patterns table footnote. No explicit handling in the spec.

**Resolution:** `@media` blocks may appear inside any section. Wrapped rules are subject to all other spec rules. Every `@media` block is preceded by a purpose comment. An `@media` block is a top-level construct subject to the blank-line rule. New §12 documents this; existing §12 (Forbidden patterns) renumbered to §14.

### 1.9 Empty sections (Gap 13)

The spec did not say whether a section banner with no content beneath it was permitted.

**Resolution:** Forbidden. Drift code: `EMPTY_SECTION`. Every section banner must be followed by at least one cataloguable construct before the next banner or end-of-file.

### 1.10 `:root` block (Gap 14)

§10 governed custom property tokens but not the `:root` block construct itself.

**Resolution:** Exactly one `:root` block per file (`DUPLICATE_ROOT_BLOCK` for more). `:root` preceded by a purpose comment (existing `MISSING_PURPOSE_COMMENT` extends to cover it). Sub-section markers permitted inside `:root` as group labels.

### 1.11 Construct ordering within a class (Gaps 15, 16)

§6 governed class definitions but did not order pseudo-element rules, variants, and the base class relative to each other within a single class.

**Resolution:** Base class definition → pseudo-element rules → pseudo-class variants. Drift codes: `PSEUDO_ELEMENT_OUT_OF_ORDER`, `VARIANT_BEFORE_BASE`. Within-section ordering of distinct base classes is author's choice (the cascade reason from Gap 3 applies here too).

### 1.12 `@keyframes` purpose comment (Gap 18)

`@keyframes` blocks did not require a preceding purpose comment.

**Resolution:** Required. Existing `MISSING_PURPOSE_COMMENT` extends to cover them. Unified rule: every named top-level construct (class definition, `:root`, `@keyframes`, `@media`) carries a purpose comment. One umbrella drift code covers all four.

### 1.13 Spec audit findings during corrections pass

Two issues caught by the user during the spec rewrite:
- A duplicate bullet in §7.1 about class-on-class compound rules (appeared twice in succession).
- 25 references to "§12" inside the §15 drift code reference table that should have been "§14" after the §12 (`@media`) and §13 (file-level discipline) renumbering pushed the forbidden-patterns section from §12 to §14.

Both fixes captured in the final spec delivery.

---

## 2. Populator changes

`Populate-AssetRegistry-CSS.ps1` updated to enforce every new spec rule. Final file is 2547 lines.

### 2.1 New drift codes (seven)

| Code | Pass | Attaches to |
|---|---|---|
| `MISSING_BLANK_LINE_SEPARATOR` | Pass 3 | CSS_FILE row |
| `EMPTY_SECTION` | Pass 3 | COMMENT_BANNER row |
| `MISSING_TRAILING_NEWLINE` | Pass 3 | CSS_FILE row |
| `DUPLICATE_ROOT_BLOCK` | Pass 2 (visitor) | CSS_RULE row for the second+ `:root` |
| `PSEUDO_ELEMENT_OUT_OF_ORDER` | Pass 3 | CSS_CLASS DEFINITION row of the pseudo-element |
| `VARIANT_BEFORE_BASE` | Pass 3 | CSS_VARIANT DEFINITION row |
| `UNDEFINED_CLASS_USAGE` | (already landed prior session) | Compound USAGE rows |

### 2.2 Broadened existing code

`MISSING_PURPOSE_COMMENT` description text and detection scope now cover four construct kinds, not just class definitions:
- Class definitions (already)
- `:root` block (new)
- `@keyframes` blocks (new)
- `@media` blocks (new)

### 2.3 Visitor and Pass 3 additions

- **`:root` handling** in the rule visitor: presence-check on preceding comment; per-file count tracking via `$script:fileMeta[file].RootLines`; second-and-subsequent `:root` rules fire `DUPLICATE_ROOT_BLOCK`.
- **`@keyframes` purpose-comment check** added to the existing at-rule handler.
- **`@media` row emission**: previously `@media` produced no row and was a transparent walker pass-through. Now emits one `CSS_RULE` row per `@media` block to host the new `MISSING_PURPOSE_COMMENT` check. Wrapped rules continue to emit their own rows independently. Signature is `@media <params>`; parent_atrule label preserved on child rows.
- **Pass 3 blank-line check** rewritten — see §2.5.
- **Pass 3 empty-section check**: scans each file's section list against the set of cataloguable rows in each section's body line range.
- **Pass 3 trailing-newline check**: reads the file's final byte and fires the drift if not 0x0A. Handles both LF and CRLF line endings.
- **Pass 3 ordering checks**: per-file map of `class_name → {base_line, pseudo_element_lines[], variant_lines[]}` built during the row-walk; fires `PSEUDO_ELEMENT_OUT_OF_ORDER` and `VARIANT_BEFORE_BASE` on any rows whose positions violate the base → pseudo-elements → variants order.

### 2.4 New shared helper

`Test-HasPrecedingPurposeComment` centralizes the "is the comment immediately preceding line N a real purpose comment (not a banner)" check. Replaces inline scan logic in three Pass 2 sites: class rule emission, `:root` handling, `@keyframes` handling, and `@media` handling. The existing rule-handler inline scan was refactored to use this helper for consistency.

### 2.5 `MISSING_BLANK_LINE_SEPARATOR` bug fix

First preview after deployment showed the check firing on every spec-compliant file because PostCSS represents purpose comments as separate top-level AST nodes. The initial check compared every adjacent pair of raw AST nodes, so a compliant `/* purpose */ \n .foo { }` pattern (mandated by §6.1) fired as "two adjacent top-level constructs with no blank line."

**Fix:** the check now builds a list of *logical units*. A non-banner comment with a non-comment node immediately below it (gap exactly one line) forms one logical unit. Banner comments remain their own units. Blank-line discipline is compared between logical units, not between every pair of raw AST nodes. Verified against four scenarios:

1. Compliant pattern (purpose comment + rule + blank + purpose comment + rule): two units, gap of 2 → OK.
2. Touching rules (purpose comment + rule + purpose comment + rule, no blank): two units, gap of 1 → fires drift.
3. Banner followed by purpose-commented rule: banner is its own unit, then rule is a second unit, one blank line between → OK.
4. Standalone rule with no purpose comment: rule is its own unit; missing-comment drift fires separately.

---

## 3. Spec drift outcome

Drift signal across the two refactored files after all populator changes and the Category-A file rewrites:

**backup.css:** 31 rows of drift remaining (the missing purpose comment on the `@media` block cleared this session). Every remaining row is `PREFIX_MISMATCH` and `UNDEFINED_CLASS_USAGE` on compound modifier USAGE rows.

**cc-shared.css:** 39 rows of drift remaining (the missing purpose comments on `:root` and the four `@keyframes`, the missing blank lines in the WebKit scrollbar block, and the missing-trailing-newline drift all cleared this session). Every remaining row is `PREFIX_MISMATCH` (and `UNDEFINED_CLASS_USAGE` on the LOCAL ones) on compound modifier USAGE rows.

Total drift across both files: 70 rows, all Category-B.

All remaining drift is Category-B (see §4).

---

## 4. Category-A vs Category-B drift classification

A distinction surfaced and named this session. Two categories of drift on the refactored CSS files:

**Category A — resolvable inside the CSS file alone.** The CSS file is rewritten; no other file needs to change; the running platform continues to function identically. The new spec rules landed this session generate Category-A drift initially, which the file rewrites cleared. Examples this session: missing purpose comment on `:root`, `@keyframes`, `@media`; WebKit scrollbar rules touching each other without blank lines or purpose comments.

**Category B — requires coordinated cross-file rewrite.** The CSS file can be rewritten to add prefixed sibling modifier classes (`.cc-open`, `.cc-disabled`, `.cc-active`, etc.), but every JS file that does `classList.add('open')` would also need updating, and every HTML emission point that emits `class="cc-slide-panel open"` would also need updating. Doing the CSS half in isolation breaks the running platform.

The session's working principle on Backup-page functionality: existing pages must remain functional through the populator-by-populator work. The Backup page is the only page currently consuming cc-shared.css and the new shared helpers. Renaming modifier tokens in cc-shared.css without also touching cc-shared.js and the Backup-emitting HTML would break slide panels, modals, engine card status colors, the connection banner, and the active nav-link highlight on the Backup page. So Category B stays put until the cross-file refactor initiative.

The Category-B inventory in the CSS populator output is the input for that initiative: every `PREFIX_MISMATCH` row on a compound USAGE names a modifier token that needs to become a prefixed sibling class.

---

## 5. CSS file rewrites delivered

### 5.1 backup.css

Single Category-A change: purpose comment added above the `@media (max-width: 1200px)` block at the bottom of the LAYOUT section. The comment reads `/* Collapses the two-column layout to a single vertical stack at narrow viewport widths. */`. Everything else unchanged.

### 5.2 cc-shared.css

Multiple Category-A changes:
- Purpose comment added above `:root` block.
- Purpose comments added above each of the four `@keyframes` blocks (`pulse`, `spin`, `page-refresh-spin`, `ccModalFadeIn`).
- WebKit scrollbar block rewritten: four separate rules now each carry their own purpose comment with blank lines between them. The previous `/* -- Dark scrollbars (WebKit) -- */` sub-section marker is removed (the four individual purpose comments now do the work; the marker added no information beyond what the selectors and individual comments convey).

Everything else unchanged. The Firefox scrollbar block's sub-section marker (`/* -- Dark scrollbars (Firefox) -- */`) is retained as the comment for its single rule.

---

## 6. Working principle reinforced this session

> Define rules in the spec by mandating what we want, not by accommodating what existing files do.

The user reinforced this several times during the gap walkthrough — most pointedly when an early gap question framed itself as "should we look at what cc-shared.css does?" The answer is: no. The spec mandates what is correct; existing files conform to the spec, not the other way around. When the user did confirm a rule by saying "you can look at cc-shared.css in this case because the file happens to match what I want," they were explicit that the decision was already made — the file just illustrated the already-decided rule.

This principle should carry into the HTML, JS, and PS spec work as it comes up.

---

## 7. Files modified this session

### 7.1 Spec

| File | Status | Notes |
|---|---|---|
| `CC_CSS_Spec.md` | DELIVERED | Complete rewrite incorporating all 17 gap resolutions; section renumbering for new §12 (`@media`) and §13 (file-level discipline); duplicate compound bullet removed from §7.1; all `§12` references in §15 corrected to `§14`. 334 lines. |

### 7.2 Populator

| File | Status | Notes |
|---|---|---|
| `Populate-AssetRegistry-CSS.ps1` | DELIVERED | Seven new drift codes, broadened `MISSING_PURPOSE_COMMENT` scope, new `:root`/`@keyframes`/`@media` checks, Pass 3 file-level discipline checks, ordering checks, new shared helper `Test-HasPrecedingPurposeComment`, blank-line bug fix. 2547 lines. CHANGELOG entry expanded to document the fix. |

### 7.3 CSS files

| File | Status | Notes |
|---|---|---|
| `backup.css` | DELIVERED | Category-A fix only: purpose comment added above the `@media (max-width: 1200px)` block. |
| `cc-shared.css` | DELIVERED | Category-A fixes: purpose comments on `:root` and four `@keyframes`; WebKit scrollbar block restructured into four logical units with individual purpose comments. |

---

## 8. Next session plan

**Primary focus:** HTML populator alignment.

The CSS populator alignment is complete. Per the established sequence (CSS → HTML → JS → PS), HTML is next.

### 8.1 Audit framing — adjusted for HTML

The CSS audit framing was: *"Given just the spec, could a fresh-file author build a new CSS file that fully conforms?"* That question worked because CSS files are bounded source artifacts with a clear "where does it start, where does it end" shape, and the spec already prescribed strong file-level structure (file header, section banners, FILE ORGANIZATION list).

HTML is different. HTML in this platform isn't authored as `.html` files. It is emitted by PowerShell route files (`Backup.ps1` and similar) and helper modules (`xFACts-CCShared.psm1`, `xFACts-Helpers.psm1`). The HTML "file" doesn't exist as a discrete source artifact — it's the runtime output of PowerShell string emission. So the "file organization" component doesn't translate; there's no FILE ORGANIZATION list because there's no file.

What does exist is **markup contracts**:
- **Page-level markup contract** — what every CC page's emitted HTML must contain (`data-page`, `data-prefix`, the `#cc-page-error-banner` placeholder, the connection banner placeholder, etc.)
- **Element-level markup contract** — how chrome classes are applied to elements, what `data-action-*` attributes look like, what IDs are valid
- **Dispatch contract** — the `data-action-<event>` family that JS reads at runtime

The audit question for HTML is therefore reframed:

> **"Given the spec, can a route author emit HTML from PowerShell that satisfies every contract the platform requires? Are there gaps where the author would have to guess, infer, or copy from an existing file?"**

Same methodology — walk through the spec section by section, find what's missing, decide each gap as a mandate — but the gaps will be different in *kind*: contract completeness rather than file structure.

### 8.2 Specific audit angles for HTML

Concrete categories of gap to look for, paralleling the CSS gap categories but adjusted for the markup-contract framing:

- **Element-level structure mandates.** What elements MUST appear in every page's emission? What attributes must they carry? Where does the spec leave a gap that a route author might miss?
- **Attribute shape mandates.** When emitting `class="cc-section cc-slide-table fill"`, what's the order, what's the syntax, are there mandates about combining shared and page-local classes? When emitting an ID, what's the prefix rule?
- **Dispatch contract mandates.** What `data-action-<event>` attribute shapes are valid? When can a page emit one vs. when not? What's the relationship between the value of `data-action-click` and the JS dispatch table key?
- **Chrome integration mandates.** What's required of any page that uses `cc-slide-panel`, `cc-modal-overlay`, etc.? Is there a contract for "if you emit this class, you must also emit this corresponding attribute, ID, or sibling element"?
- **Bootloader integration mandates.** What does every page-level emission need to contain so the bootloader can route correctly? Is the contract fully spec'd, or are there assumed-but-unstated requirements?

### 8.3 What's different about the populator-side alignment

The CSS populator alignment was mostly self-contained: each new check looked at one CSS file at a time, with limited reference to other files. The HTML populator alignment will be different.

The HTML populator processes PowerShell route files, finds the HTML emission sites, parses the embedded HTML, and catalogs elements and attributes. The drift signals it surfaces are *runtime contract* violations: missing required attributes, invalid `data-action` values, classes referenced in HTML that don't exist in CSS, etc. Many of these checks involve **cross-file resolution against the CSS and JS catalogs**.

So the populator alignment work has a different feel than CSS:
- Less about "is this file structurally correct?"
- More about "does this emission satisfy the cross-spec contract?"

The cross-spec coupling is tighter for HTML than for CSS. CSS files are mostly self-contained; an HTML emission depends on what CSS defines and what JS expects.

### 8.4 Expectation calibration

Two things worth being mentally prepared for going into the HTML session:

**Possibly fewer raw gaps than CSS.** The HTML spec has likely already been amended more than the CSS spec was, because HTML drift was the impetus for the bootloader work and the action-dispatch redesign. The audit might surface a different *category* of gaps — "this rule exists but doesn't say what happens at the edge case where X" — rather than the structural-rule omissions the CSS audit surfaced.

**The HTML audit may touch the JS spec.** Because of the dispatch contract coupling, if the HTML spec says one thing about `data-action-*` and the JS spec says another, we'll need to resolve the inconsistency — same as Session 5 where the chrome dispatch table naming was inconsistent between specs. The HTML session might end up touching the JS spec lightly even though JS isn't the focus.

### 8.5 Working pattern carried over from CSS session

1. Read the HTML spec end-to-end with the §8.1 audit question in mind.
2. Identify every gap.
3. Resolve each gap as a mandate, never as a backlog item.
4. Update the populator to enforce the new rules.
5. Verify against the existing HTML emissions (route files and helper-module emitters).
6. Bring the Category-A drift on emitted HTML down to zero by spec-compliant rewrites where possible.

The HTML populator's Category-B equivalent will surface — class references in HTML that depend on coordinated CSS+JS changes. Same principle: surface the work but don't break the running Backup page.

---

## 9. Pending future work (not in scope for next session)

### 9.1 Chrome registry initiative (Gap 6 deferred)

Path 3 is the recommended approach: a populator-maintained `dbo.Chrome_*_Registry` (table name TBD) populated by scanning anchor files for chrome identifiers (CSS classes, custom property tokens, keyframes; JS dispatch tables, hook suffixes; HTML chrome IDs, data attributes, action values). The registry becomes the cross-spec contract anchor that the HTML and JS populators validate page references against. Replaces the current per-spec §13/§16 lists in the HTML and JS specs.

Initiated as a dedicated initiative after all four populators are aligned and stable, so the design covers the four chrome contracts uniformly.

### 9.2 Category-B cross-file refactor on chrome modifier tokens

Every `PREFIX_MISMATCH` and `UNDEFINED_CLASS_USAGE` drift row on a compound USAGE in cc-shared.css and backup.css represents a modifier token that needs to be promoted to a prefixed sibling class. The work touches:
- cc-shared.css: new `.cc-<modifier>` base classes
- cc-shared.js: every `classList.add/remove/toggle/contains('<modifier>')` call
- Helper modules (`xFACts-CCShared.psm1`, `xFACts-Helpers.psm1`): every HTML emission with raw modifier classes
- Route files (`Backup.ps1` and similar): every HTML emission with raw modifier classes
- Page CSS files (currently just backup.css): compound rules referencing the prefixed siblings
- Page JS files (currently just backup.js): `classList` calls referencing the new prefixed names

Real coordinated initiative. Scoped after HTML and JS populators are aligned, because their drift output names the cross-file references that need to change.

### 9.3 BDL Import populator family Object_Metadata enrichment

OQ-INIT-3 in `CC_Initiative.md`. Deferred until all four populators are in production and the orchestrator is wrapped.

### 9.4 HTML and PS populator Object_Metadata enrichment

Baselines in. Full enrichment with `data_flow` and `design_note` rows deferred until the populator family is stable.

---

## 10. Files in /mnt/user-data/outputs at session end

- `CC_CSS_Spec.md` — full corrected spec (334 lines)
- `Populate-AssetRegistry-CSS.ps1` — full updated populator (2547 lines)
- `backup.css` — Category-A spec-compliant rewrite (704 lines)
- `cc-shared.css` — Category-A spec-compliant rewrite (1478 lines)
- `xFACts-AssetRegistryFunctions.ps1` — from prior in-session delivery; no changes this round
