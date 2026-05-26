# CC Session Summary 14 — Backup Page Full Refactor and Drift Triage

*Session date: 2026-05-26.*

---

## 1. Session focus

Fourteenth session in the CC File Format Standardization initiative. This session executed the first full-page refactor under the new four-spec regime, bringing the Backup page from partial migration to spec compliance across all four file types: CSS, JS, page route (PS), and API route (PS). It also performed surgical fixes on the shared `xFACts-CCShared.psm1` module needed to support the page's runtime behavior, and triaged the post-deploy drift report to separate real source-file issues from populator bugs and spec-vs-implementation divergence.

The session deliverables are seven files representing the new state of the Backup page and its shared dependencies, plus a comprehensive drift triage that establishes the resolution path for every remaining drift signal.

---

## 2. What landed

### 2.1 Backup page files — full refactor

Four page-side files brought to spec compliance, plus shared infrastructure updates:

**`backup.css`** — 772 lines from 703. 31 PREFIX_MISMATCH and UNDEFINED_CLASS_USAGE rows addressed via compound modifier renames plus 23 new standalone definitions. Two stale chrome-class text references updated in file header narrative and DETAIL MODAL CONTENT banner.

**`backup.js`** — 1294 lines. INIT_MISPLACED fix (FUNCTIONS: PAGE BOOT → FUNCTIONS: INITIALIZATION). Dispatch table keys renamed to bkp- prefix (all 7 keys). All `data-action-click="..."` HTML emissions renamed (5 code-emission + 3 docstring). Page-local class strings in HTML emissions renamed. Coupled internal-comparison strings updated. CC-shared classList operations renamed (`open`, `hidden`, `expanded` → cc-prefixed, 8 sites). Drift-triage follow-up: `dataset.actionType` → `dataset.bkpType` (handler for `data-action-bkp-type`); `dataset.retentionType` → `dataset.bkpRetentionType` (handler and JS-emitted markup for `data-action-bkp-retention-type`).

**`Backup-API.ps1`** — 1046 lines from 1040. `.NOTES` block gained required File Name and Location fields per spec §2.1. ROUTE banner converted from `# === ... # ===` line-comment block form to `<# ... #>` block-comment form per spec §3 (byte-perfect: line 1 = `<# ` + 76 `=`; closing = 3 spaces + 76 `=` + ` #>`; interior lines indented 3 spaces; description block + `Prefix: (none)` line). Two trailing comments at lines 152-153 moved to lead-line position. Three Windows-1252 byte 0x97 em-dashes replaced with ASCII `--`. Trailing CRLF added. File now pure ASCII (0 non-ASCII bytes), no BOM, proper CRLF discipline (1046/1046).

**`Backup.ps1`** — 338 lines from 288. UTF-8 BOM stripped. Three `§` (U+00A7) replaced with `Section ` at lines 12, 33, 106. `.NOTES` block: added File Name and Location fields. Both banners (CHANGELOG and ROUTE) converted from `# === ... # ===` to `<# ... #>` block-comment form with proper Description and Prefix lines. CHANGELOG banner renamed `CHANGELOG` → `CHANGELOG: CHANGE HISTORY` per spec §4.4 singleton-name rules. New 2026-05-26 CHANGELOG entry added at top describing all changes. HTML class string updates in the here-string: 4× `cc-engine-bar disabled` → `cc-engine-bar cc-disabled`; 1× `cc-modal-overlay hidden` → `cc-modal-overlay cc-hidden`; 1× `cc-modal wide` → `cc-modal cc-wide`; 2× `cc-slide-panel wide` → `cc-slide-panel cc-wide`. data-action-click updates: 1× `modal-close-on-overlay` → `bkp-modal-close-on-overlay`; 1× `modal-close` → `bkp-modal-close`; 4× `slideout-close` → `bkp-slideout-close`. Drift-triage follow-up: `.NOTES` FILE ORGANIZATION entry updated `CHANGELOG` → `CHANGELOG: CHANGE HISTORY` (verbatim banner-title match per spec §2.1); swapped order of `cc-page-error-banner` and `cc-connection-banner` (connection now precedes error per HTML spec §2.4-2.5); added blank line between `</title>` and `<link backup.css>`, and between the two `<link>` lines per HTML spec §3.1; renamed `data-action-type="local"` / `"network"` → `data-action-bkp-type` (4 occurrences) per HTML spec §7.4 argument-attribute prefix rules. Second 2026-05-26 CHANGELOG entry added at the very top describing the triage follow-up.

### 2.2 Shared infrastructure files

**`cc-shared.css`** — 1561 lines from 1462. 39 compound modifier renames: every rightmost token now cc- prefixed. Includes nav-link `active` → `cc-active`, page-h1 section accents → `cc-section-*`, header-bar `has-center` → `cc-has-center`, refresh-btn `spinning` → `cc-page-refresh-spinning` (collision-avoiding), engine-row `ws-disconnected` → `cc-ws-disconnected`, engine-card `card-warning/critical` → `cc-card-*`, engine-bar states (`idle/running/overdue/critical/disabled`) → `cc-*`, engine-countdown `cd-overdue` → `cc-cd-overdue`, connection-banner states → `cc-*`, slide-overlay/panel/auto-height `open` → `cc-open`, slide-panel `wide/xwide` → `cc-wide/cc-xwide`, modal-overlay `hidden` → `cc-hidden`, modal `medium/wide` → `cc-medium/cc-wide`, and several others. Round 2 added 33 standalone modifier definitions per spec §7.1 (every compound participant requires standalone single-class rule).

**`cc-shared.js`** — 1744 lines from 1763. 6 JS_HTML_ID_UNRESOLVED drift rows resolved: `cc_getEngineElements` simplified (bare-ID fallback removed), `cc-engine-popup` and `cc-idle-overlay` converted from ID-based to class-based selectors. Class-name string updates: `'spinning'` → `'cc-page-refresh-spinning'` (3 sites), barCls/cardCls state machine, `'ws-disconnected'` → `'cc-ws-disconnected'` (2 sites), connection banner classNames (4 sites). Internal `cc_engineConnectionState` values left unchanged (program logic).

**`xFACts-CCShared.psm1`** — 2778 lines from 2774, plus BOM strip = -3 bytes net. Surgical pass only. Four functional class-string substitutions: 3× `' active'` → `' cc-active'` in `Get-NavBarHtml`; 1× `" section-$sectionKey"` → `" cc-section-$sectionKey"` in `Get-PageHeaderHtml`. Four explanatory comment/docstring updates. UTF-8 BOM stripped (was at byte 0, restoring web_fetch compatibility). The structural refactor of this file (113 drift rows, 17 codes) was scoped out of this session and deferred to a dedicated follow-up.

---

## 3. Locked decisions and principles reinforced

### 3.1 Spec is sole authority

The session reinforced the principle that the four CC specs are the sole authority on file shape. Where source files diverge from spec, the remedy is "rewrite to comply." Where the spec is silent on a question that comes up during refactor, the question is decided and the spec is amended. The populators implement what the spec says; if the populator disagrees with the spec, the populator is wrong.

### 3.2 Full-page refactor pattern

All four files for a page (CSS, JS, page PS1, API PS1) are refactored together in a single session arc. Deferring any one file creates inconsistent state where the page works but doesn't lint clean. This is the pattern for future pages.

### 3.3 Banner shape per CC_PS_Spec §3

PowerShell section banners use `<# ... #>` block-comment syntax (not `# === ... # ===` line-comment blocks). Byte-perfect shape:
- Line 1: `<# ` + exactly 76 `=` characters
- Title line: 3 spaces + `<TYPE>: <NAME>`
- Separator: 3 spaces + exactly 76 `-` characters
- Description: 3 spaces + description text (1-5 sentences)
- Prefix line: 3 spaces + `Prefix: <value>`
- Closing line: 3 spaces + exactly 76 `=` characters + ` #>`

### 3.4 Singleton banner NAMEs

Spec §4.4 fixes the NAME for singleton section types:
- `CHANGELOG: CHANGE HISTORY`
- `IMPORTS: SCRIPT DEPENDENCIES`
- `PARAMETERS: SCRIPT PARAMETERS`
- `INITIALIZATION: SCRIPT INITIALIZATION`
- `EXECUTION: SCRIPT EXECUTION`
- `ROUTE: PAGE PATH` (page-route)
- `ROUTE: API ENDPOINTS` (api-route)
- `EXPORTS: MODULE EXPORTS`

### 3.5 `.NOTES` field structure per CC_PS_Spec §2.1

`.NOTES` contains exactly three fields in this order: File Name, Location, FILE ORGANIZATION list. The FILE ORGANIZATION list contains verbatim banner titles (each `<TYPE>: <NAME>`) in order, no numbering, no annotations.

### 3.6 CHANGELOG entries are immutable history

CHANGELOG entries are dated historical records of what was done on a specific date. Old entries are not edited to reflect later state changes, even when they describe states that no longer exist. New entries get added at the top for new sessions' work.

### 3.7 File encoding discipline

Source files: pure ASCII (no non-ASCII bytes), no BOM, CRLF line endings for `.ps1`/`.psm1`, LF line endings for `.css`/`.js` (matching the `public/` folder convention), trailing newline. The `§` character specifically must not appear in source — it breaks GitHub binary-detection and `web_fetch` retrieval. Use `Section ` instead.

### 3.8 Hybrid prefix convention for action attributes (HTML spec §7)

Page-local action dispatch keys carry the page prefix (`bkp-modal-close`, `bkp-slideout-close`). Chrome dispatch keys carry `cc-` prefix (`cc-page-refresh`). Argument attributes use the form `data-action-<prefix>-<arg-name>` where `<prefix>` matches the parent action's prefix.

### 3.9 Block-comment syntax reserved (CC_PS_Spec §3.2)

`<# ... #>` block-comment syntax is reserved for three forms: file header, section banners, function docblocks. All other commentary uses `#` line comments.

---

## 4. Drift triage — resolution paths for remaining 15 rows

Post-deploy drift report flagged 15 rows. Each was categorized and assigned to a resolution path.

### 4.1 Group 1 — Populator bugs (next session)

Four bugs in two files. None require source-file changes; all four are populator-side fixes that will clear the corresponding drift signals on re-run.

**`Populate-AssetRegistry-PS.ps1`:**

1. **`MALFORMED_PREFIX_VALUE` on every `(none)` banner.** The `Add-CommentBannerRow` function calls `Test-PrefixValueIsValid -Prefix $Section.Prefix` without the `-AllowNoneSentinel` switch. The shared helper has a switch specifically designed to keep `(none)` valid for PS callers (the PS spec keeps `(none)` for the seven prefix-less section types per §5.1-5.2). Fix: add the switch. Also update the stale drift-context wording "neither a 3-char lowercase prefix nor (none)" — the 3-char constraint was retired 2026-05-22.

2. **`PREFIX_REGISTRY_MISMATCH` will fire on `(none)` banners after #1 is fixed.** The mismatch check fires when a banner declares `(none)` and the file's `cc_prefix` is non-null. But per spec §5.2, sections without prefix-bearing identifiers (CHANGELOG, IMPORTS, PARAMETERS, INITIALIZATION, EXECUTION, ROUTE, EXPORTS) always declare `Prefix: (none)` regardless of the file's registered `cc_prefix`. Fix: add carve-out skipping the mismatch check when the section type is one of these seven.

3. **`FORBIDDEN_VERSION_IN_CHANGELOG` over-matches.** Current regex catches any dotted-numeral triple including spec section references like "Section 11.2.4." Spec intent (§7.2 "No version numbers in entries") is to prohibit file-version tracking via CHANGELOG, not to ban references to spec section numbers. Fix: tighten regex to require explicit version markers — e.g., `\b[vV]\d+(\.\d+){1,2}\b` or `\b[Vv]ersion\s+\d+(\.\d+){1,2}\b`.

**`xFACts-AssetRegistryFunctions.ps1` (in `Get-PSFileHeaderInfo`):**

4. **`FORBIDDEN_CHANGELOG_IN_HEADER` false positive.** Detection regex `^\s*CHANGELOG\b` matches the literal word "CHANGELOG" anywhere in the header body, including inside the FILE ORGANIZATION list in `.NOTES` (which is required to contain `CHANGELOG: CHANGE HISTORY` as a section title per spec §2.1). Fix: when scanning the header body for forbidden content, skip lines inside the FILE ORGANIZATION block.

### 4.2 Group 2 — Spec-vs-implementation divergence (future cross-file migration)

The HTML spec (`CC_HTML_Spec.md`) defines a forward-state shape for engine cards and overlay constructs that differs from what `cc-shared.css`, `cc-shared.js`, and every page emission currently use. Seven drift signals are flagged by this divergence: `MALFORMED_ENGINE_CARD` (×4), `MALFORMED_MODAL_STRUCTURE` (×1), `MALFORMED_SLIDEOUT_STRUCTURE` (×2), `OVERLAY_BLOCK_NON_CONTIGUOUS` (×2). All real, all known, all deferred.

**Engine card divergence:**
- Spec says: outer `cc-card-engine` class, `cc-engine-bar` (no `cc-disabled` modifier), `cc-engine-cd` with content `--`.
- Implementation says: outer `cc-engine-card` class, `cc-engine-bar cc-disabled` (with disabled-state compound modifier), `cc-engine-countdown` with content `&nbsp;`.

**Modal divergence:**
- Spec says: `cc-modal-overlay > cc-dialog > cc-dialog-header/body/actions` (nested dialog with unified class family).
- Implementation says: `cc-modal-overlay > cc-modal > cc-modal-header/body` (legacy two-level structure).

**Slideout divergence:**
- Spec says: single `cc-slide-overlay > cc-dialog` (nested).
- Implementation says: `cc-slide-overlay` + sibling `cc-slide-panel` (two-element pattern).

Resolution requires a coordinated cross-file migration session touching: HTML spec (to lock the chosen shape), `cc-shared.css` (rename selectors), `cc-shared.js` (rename class assignments), every page using engine cards/modals/slideouts (rename markup emissions), and the HTML populator (validate the chosen shape). This is the largest of the three remaining buckets and should be planned as its own focused session.

### 4.3 Group 3 — Real source-file drift (resolved this session)

Five issues identified and fixed in `Backup.ps1` and `backup.js`:

1. **`FILE_ORG_MISMATCH`** — `.NOTES` FILE ORGANIZATION entry updated `CHANGELOG` → `CHANGELOG: CHANGE HISTORY` to match the banner title verbatim per spec §2.1.
2. **`MALFORMED_PAGE_SHELL_ORDER`** — swapped order of `cc-page-error-banner` and `cc-connection-banner` placeholders (connection-banner now precedes page-error-banner per HTML spec §2.4-2.5).
3. **`MALFORMED_PAGE_SHELL_WHITESPACE`** — added one blank line between `</title>` and `<link backup.css>`, and between `<link backup.css>` and `<link cc-shared.css>` per HTML spec §3.1.
4. **`UNKNOWN_EVENT_TYPE` + `ACTION_PREFIX_MISMATCH` (×4)** — renamed `data-action-type="local"` / `data-action-type="network"` → `data-action-bkp-type="local"` / `data-action-bkp-type="network"` (4 occurrences) per HTML spec §7.4 argument-attribute prefix rules. Updated `bkp_closeRetentionSlideout` handler in `backup.js` to read `target.dataset.bkpType`.
5. **Consistency follow-up (not flagged by populator)** — renamed `data-retention-type` to `data-action-bkp-retention-type` in JS-emitted markup at `bkp_renderRetentionCard` and updated `bkp_openRetentionDetail` handler to read `target.dataset.bkpRetentionType`. The original wasn't flagged because the HTML populator scans `.ps1` source, not JS-emitted HTML; fix applied for consistency with the same-pattern fix in #4.

### 4.4 Group 4 — Known temporary drift (intentional, documented)

Two drift signals that are migration scaffolding, intentionally accepted, and will clear when the platform-wide xFACts-Helpers → xFACts-CCShared migration completes:

- **`MISPLACED_IMPORT` at line 143** of `Backup.ps1` — the explicit `Import-Module 'xFACts-CCShared.psm1'` inside the route scriptblock shadows the auto-loaded xFACts-Helpers for this route's execution. Documented in both `.DESCRIPTION` and the 2026-05-18 CHANGELOG entry. Removed when `Start-ControlCenter.ps1` loads `xFACts-CCShared.psm1` at startup and `xFACts-Helpers.psm1` is deleted.
- **`MISSING_RBAC_CHECK_PAGE`** — `Get-UserAccess` is at line 145, not the first statement (line 143 is the Import-Module). Same root cause; clears when the Import-Module line is removed.

---

## 5. Files delivered this session

| File | Lines | Notes |
|---|---|---|
| `cc-shared.css` | 1561 | 39 compound modifier renames + 33 standalone definitions |
| `cc-shared.js` | 1744 | Class-string updates + ID→class selector conversions |
| `backup.css` | 772 | 31 PREFIX_MISMATCH renames + 23 standalones |
| `backup.js` | 1294 | Dispatch keys, HTML emissions, argument-attribute renames |
| `xFACts-CCShared.psm1` | 2778 | Surgical pass: 4 class-string subs + BOM strip |
| `Backup-API.ps1` | 1046 | Banner→`<#...#>`, .NOTES fields, em-dashes→ASCII, trailing-comments fixed |
| `Backup.ps1` | 338 | BOM strip, §→Section, both banners→`<#...#>`, .NOTES fields, 14 HTML renames, 2 CHANGELOG entries, triage fixes |

All files: pure ASCII, no BOM, proper line-ending discipline (CRLF for `.ps1`/`.psm1`, LF for `.css`/`.js`), trailing newline.

---

## 6. End-of-session drift state

Backup catalog rows after Group 3 fixes: **15 drift rows total**, all categorized:

- **4 populator bugs** (Group 1) — clear on next populator run after fixes ship
- **9 spec-vs-implementation divergence** (Group 2) — defer to cross-file migration session
- **2 known temporary drift** (Group 4) — clear when platform-wide module migration completes

No Group 3 (real source-file) drift remaining on Backup.

---

## 7. Next session focus

### 7.1 Primary deliverable: `xFACts-CCShared.psm1` structural refactor

Full structural alignment of `xFACts-CCShared.psm1` to the CC_PS_Spec. Surgical pass this session addressed only the class-string substitutions needed for the Backup page; the structural drift is now the focal item.

**Scope:** 113 drift rows across 17 codes, including:
- `MISSING_SECTION_BANNER` (functions outside any banner)
- `MISSING_DOCBLOCK` on all 35+ functions
- `MISSING_CMDLETBINDING`
- `FORBIDDEN_FREESTANDING_COMMENT_BLOCK`
- `MALFORMED_SUBSECTION_MARKER` (20 instances)
- `DUPLICATE_FUNCTION_DEFINITION` (cross-file dupes with xFACts-Helpers.psm1)
- `FORBIDDEN_TRAILING_COMMENT` (6 instances)
- 1× `Write-Host` call
- 2× `Build-` unapproved verb
- `ConvertFrom-DBNull` declared but not exported
- `Get-AccessDeniedHtml` inline `<style>` block + inline style attribute
- Hex literals in embedded CSS
- 2 top-level `$script:` variables missing purpose comments + section banners
- 2 `EXCESS_BLANK_LINES`

Plus 2057 non-ASCII body characters across 6 unique chars to normalize:
- U+2500 `─` ×671 (box-drawing dividers, also `FORBIDDEN_BOX_DRAWING_BANNER` drift)
- U+2014 `—` ×12 (em-dashes in comment prose)
- U+00A7 `§` ×1
- U+2190 `←` ×1
- U+2192 `→` ×1
- BOM (U+FEFF) was stripped this session

### 7.2 Secondary deliverable: Populator bugs (Group 1)

Four fixes in two files. Detailed in §4.1 above. All small, well-scoped, isolated changes.

### 7.3 Tertiary candidates (as time permits)

- Earlier populator findings deferred from Session 13/14:
  - `UNDEFINED_CLASS_USAGE` not firing on `cc-shared.css` internal compound modifier rows
  - `MALFORMED_ACTION_KEY` not firing on unprefixed page-side dispatch keys in JS
- Cross-file migration planning for Group 2 (engine-card and overlay shape divergence). Not the migration itself — that needs its own session — but a working doc capturing the decision: which shape wins (spec's forward state or current implementation), and the scope of files that need to change.

### 7.4 Session boot sequence

1. Fetch `manifest.json?v=<cache-buster>` from GitHub
2. Verify Project Knowledge has the current anchor docs:
   - `CC_PS_Spec.md`
   - `CC_Session_Summary_14.md` (this document)
   - `xFACts_Development_Guidelines.md`
3. Fetch `xFACts-CCShared.psm1` from session 14 outputs (the post-surgical-pass version)
4. Fetch `Populate-AssetRegistry-PS.ps1` and `xFACts-AssetRegistryFunctions.ps1` for the populator fixes
5. Confirm scope: are we doing both structural refactor AND populator bugs in the same session, or splitting?

---

## 8. End-of-session state, in one sentence

**Backup page is fully spec-compliant for everything within source-file authority; 15 remaining drift signals are categorized into 4 populator bugs (Group 1, next session), 9 spec-vs-implementation divergence rows (Group 2, cross-file migration session), and 2 known temporary migration-scaffolding signals (Group 4, clear when xFACts-Helpers → xFACts-CCShared platform migration completes).**
