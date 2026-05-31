# CC Session Summary 21 — CSS Populator Conversion, Shared-Library Conformance, FK Single-Query Migration

## Session focus

Continuation of the four-populator realignment from Session 20. This session converted the
CSS populator to the table-driven zone/scope model and brought it into CC_PS_Spec conformance,
completed the long-standing `xFACts-AssetRegistryFunctions.ps1` conformance pass (the original
Session 20 target), began an incremental migration to a single Object_Registry query across the
populator family, set a clean terminology boundary between "anchor" and "shell," and cleared the
last drift on the resolver.

Net result: CSS populator converted and conformant; shared functions library conformant; FK
single-query migration landed on two of four populators (CSS, PS); CC_CSS_Spec terminology
aligned; resolver clean. Two stale carry-over items from Sessions 19/20 were correctly closed.
No context compaction occurred until late in the session (one compaction during the CSS
conversion; work continued cleanly afterward).

---

## 1. CSS populator — table-driven conversion + spec conformance

`Populate-AssetRegistry-CSS.ps1` was converted following the PS populator pattern from Session 20,
then brought into full CC_PS_Spec structural conformance. Starting drift ~109 rows, ending at 11
(all expected — see §7).

**Track A — table-driven zone/scope/shell:**
- Zone, scope, and shell designation now come from `Object_Registry` via
  `Get-ObjectRegistryZoneScopeMap`, per file. Deleted `Get-CssZone`, the
  `$SharedFiles`/`$CcSharedFiles`/`$DocsSharedFiles` lists, and the hardcoded anchor-file
  constants.
- The shell file (the FOUNDATION/CHROME-bearing shared file) is identified by
  `scope_tier = SHELL`. Live data confirmed `cc-shared.css` carries `scope_tier = SHELL`;
  legacy `engine-events.css` is SHARED-but-not-shell.
- Shared definition maps generalized to by-zone hashtables (the JS-sibling shape), so a third
  zone works without new code.
- Added `FILE_NOT_REGISTERED` (operational/pipeline drift, populator-only — not a CSS content
  rule, mirroring the PS precedent) for files on disk absent from `Object_Registry`.

**Track B — CC_PS_Spec conformance:**
- Header rebuilt: `.COMPONENT` added, `Version:` removed, fenced in-header CHANGELOG removed.
- Dedicated `CHANGELOG: CHANGE HISTORY` section with trimmed entries.
- All `# ===` dividers converted to spec `<# #>` banners in canonical §4.2 order; FILE
  ORGANIZATION list matches the banners verbatim.
- All executable code consolidated into one `EXECUTION: SCRIPT EXECUTION` section with
  `# -- Label --` sub-section markers (§13.2). Three- and four-dash inline pseudo-banners
  (which would fire `FORBIDDEN_INLINE_BANNER` / `MALFORMED_SUBSECTION_MARKER`) fixed; step
  labels inside function bodies became plain leading comments.
- OVERRIDES section type removed from the populator (the spec had already dropped it in a prior
  session; the populator was catching up). CSS now recognizes 5 section types: FOUNDATION,
  CHROME, LAYOUT, CONTENT, FEEDBACK_OVERLAYS.
- `$CssVisitor` reclassified as an immutable `$script:CssVisitor` constant and relocated into the
  CONSTANTS region (it was sitting in a FUNCTIONS section, firing WRONG_DECLARATION_SECTION /
  MISPLACED_DECLARATION).
- `$env:NODE_PATH` moved from CONSTANTS to EXECUTION (§9.3 — work-as-it-runs, not a file-scope
  declaration), clearing FORBIDDEN_SCOPE_QUALIFIER.
- Per-declaration leading purpose comments added; trailing comments moved to leading; comment
  bloat trimmed.

---

## 2. Shared functions library — spec conformance

`xFACts-AssetRegistryFunctions.ps1` (shared-library role) was the original Session 20 target,
deferred when that session pivoted to the classification model. Completed this session. Starting
drift ~41 rows, ending at 0.

- Header rebuilt to the shared-library role: `Version:` removed, fenced CHANGELOG removed,
  `.COMPONENT Tools.Utilities` added (see §4 — the value was an error caught on re-run), `.NOTES`
  with File Name / Location / FILE ORGANIZATION list added.
- CHANGELOG moved to a dedicated section with all 12 entries preserved but trimmed.
- 13 `# ===` dividers converted to `FUNCTIONS:` banners (all 13 sections are pure function
  groups). FILE ORGANIZATION list matches the 14 banners (CHANGELOG + 13 FUNCTIONS) verbatim.
- 15 `# ---- Pass N ----` subsection markers (step labels inside `Get-BannerInfo` and
  `Get-PSFileHeaderInfo` bodies) converted to plain leading comments.
- Blank-line runs collapsed.
- `Test-PrefixValueIsValid` left untouched (see §3).

---

## 3. Closed carry-over item: `Test-PrefixValueIsValid` cc-removal (superseded)

Session 19 deferred "remove the `cc`-acceptance enforcement from `Test-PrefixValueIsValid`" to the
AssetRegistryFunctions work. On review this session, that instruction was found to be
**PS-frame tunnel vision** and is closed as superseded, not executed.

- `Test-PrefixValueIsValid` is a SHARED validator used by all four populators.
- Session 19 reasoned that `cc` is unreachable as a PS prefix (true — PS prefixes are page
  prefixes or `(none)`), so the line `if ($val -eq 'cc') { return $true }` never fires for PS.
  But it is **load-bearing for CSS/JS**, where `cc` is the chrome prefix declared by
  FOUNDATION/CHROME/shell-file banners. This acceptance was deliberately added in Session 4
  (§11.1.8) to clear 19 false-positive `MALFORMED_PREFIX_VALUE` rows.
- Removing it would help nothing for PS (the line never fires there) and would regress CSS/JS.
- The PS-side intent was already fully achieved in Session 19: `cc` was removed from PS spec
  §5.1 and from the PS populator's descriptive text. Nothing further is needed.

Decision: leave the function untouched. The reasoning got lost between summaries (Session 19
framed it in a PS-only frame; Session 20 carried it forward by reference without re-examining it
against the CSS/JS requirement).

---

## 4. Object_Registry FK single-query migration (steps 1–2 of 3)

Both the CSS and PS populators were loading two Object_Registry maps per run:
`Get-ObjectRegistryZoneScopeMap` (zone/scope classification) and `Get-ObjectRegistryMap`
(object_name -> registry_id, for FK resolution at bulk insert). Two round trips to the same
table. This was migrated toward a single query, incrementally:

- **Step 1 (done):** `Get-ObjectRegistryZoneScopeMap` extended to also return `RegistryId`, so it
  returns `object_name -> @{ RegistryId; Zone; Scope; ScopeTier }`. Additive — existing callers
  reading only Zone/Scope/ScopeTier are unaffected.
- **Step 2 (done for CSS and PS):** Both dropped their `Get-ObjectRegistryMap` call and now make
  one Object_Registry query. Each carries a small transitional shim at its bulk-insert call that
  projects the combined map down to the flat `object_name -> registry_id` shape the bulk insert
  still expects.
- **Step 3 (pending — final cleanup):** Once JS and HTML are also migrated, update
  `Invoke-AssetRegistryBulkInsert` to accept the combined shape directly, delete all four shims,
  and delete `Get-ObjectRegistryMap`. This is the only flag-day moment and it lands last, when it
  is mechanical.

**The gating seam:** `Invoke-AssetRegistryBulkInsert` takes `-ObjectRegistryMap` as
`object_name -> registry_id`. That is why each populator carries a projection shim instead of
passing the combined map straight through. The shims are load-bearing transitional glue — do not
"tidy" them away before step 3.

**Component-name finding:** while conforming the shared library, `.COMPONENT` was first set to
`ControlCenter.AssetRegistry` (a string from old header prose, never a registered
`Component_Registry.component_name`). The re-run flagged `INVALID_COMPONENT_VALUE`. The correct,
registered value for the whole populator family is **`Tools.Utilities`** (confirmed against the PS
and CSS populators). Corrected. Use `Tools.Utilities` on JS and HTML from the start.

---

## 5. Terminology boundary: "anchor" vs "shell"

The word "anchor" had become overloaded across recent sessions — used both for the base file row
(`CSS_FILE` / `JS_FILE` / `PS_FILE`) and for the FOUNDATION/CHROME-bearing shared file. A boundary
was set and applied:

- **"anchor" = the base file row, always and only.**
- **"shell" = the FOUNDATION/CHROME-bearing shared file (`scope_tier = SHELL`), always.**

Applied across `CC_CSS_Spec.md` and `Populate-AssetRegistry-CSS.ps1`:
- CSS spec: all "anchor file" references → "shell file" (incl. the §4.2 heading "Anchor files" →
  "Shell files"); drift code `ANCHOR_SECTION_INVALID_PREFIX` → `SHELL_SECTION_INVALID_PREFIX`;
  added a §4.2 note that the shell file is identified by `scope_tier = SHELL`.
- CSS populator: drift code renamed in `$DriftDescriptions` and the `Add-DriftCode` call;
  "anchor file" descriptive comments → "shell file"; base-row "anchor" usages left untouched.

The CSS spec carries no amendment history by design (living document, always current state). The
catalog re-run after deploy carries the new code name; since the table was freshly truncated, no
historical-row migration was needed.

JS and HTML should use `scope_tier = SHELL` and "shell" terminology from the start, and their
specs (when written/aligned) should never reintroduce "anchor file."

---

## 6. Resolver — last drift cleared

`Resolve-AssetRegistryReferences.ps1` reported 5 rows
(`FORBIDDEN_DOCBLOCK_IN_STANDALONE` + `MISSING_FUNCTION_PURPOSE_COMMENT` on each of its 5
functions). Root cause: the file was built recently and was compliant under the old model, but the
Session 20 classification change placed standalone scripts in their own container that uses
single-line purpose comments rather than docblocks (PS spec §8.4). The drift was the model
catching up to the file, not a regression.

Fix: replaced each function's comment-based-help docblock with a single-line `#` purpose comment
on the line directly above the declaration (using the synopsis text each docblock already
carried). Kept `[CmdletBinding()]` (permitted under §8.4) and `param()`. The file-header
`.SYNOPSIS` / `.PARAMETER Execute` are correct for a standalone header and were left alone.
Resolver now clean (0 rows) and confirmed running correctly against the new architecture
(correctness review was satisfied in Session 20).

---

## 7. Files delivered this session

| File | Notes |
|---|---|
| `Populate-AssetRegistry-CSS.ps1` | Table-driven conversion + full spec conformance + FK single-query migration + anchor→shell rename. ~109 → 11 drift. |
| `Populate-AssetRegistry-PS.ps1` | FK single-query migration (shim). Retains its known ~7 expected rows. |
| `xFACts-AssetRegistryFunctions.ps1` | Full spec conformance + `RegistryId` added to the zone/scope map. ~41 → 0. |
| `Resolve-AssetRegistryReferences.ps1` | 5 docblocks → single-line purpose comments. 5 → 0. |
| `CC_CSS_Spec.md` | anchor→shell terminology + drift code rename. Living document, no amendment history kept. |
| `CC_Populator_Streamlining_Opportunities.md` | Updated to current state. Its open items are folded into §9 below; this doc can be retired once §9 is the live reference. |

All `.ps1` files: BOM-free, pure ASCII, uniform CRLF, single trailing newline. `CC_CSS_Spec.md`
keeps its existing LF / UTF-8 encoding and legitimate `§` / `—` / `≥` characters (markdown, not
PowerShell).

Note: all files were statically validated (block-comment pairing, FILE ORGANIZATION match,
section order, function count, encoding) but not parser-run — no `pwsh` in the working
environment. The deploy/run loop is the real validation.

---

## 8. End-of-session drift state

Refactored-file drift snapshot (TotalRows / NonCompliantRows). Almost all remaining drift is
expected or known-temporary.

| File | Total | Non-compliant | Notes |
|---|---|---|---|
| Backup-API.ps1 | 99 | 0 | clean |
| backup.css | 301 | 0 | clean |
| backup.js | 437 | 5 | queued cross-file overlay/slideout migration |
| Backup.ps1 | 191 | 10 | queued cross-file migration + known-temporary shims |
| cc-shared.css | 719 | 0 | clean |
| cc-shared.js | 264 | 3 | queued |
| replication-monitoring.css | 286 | 0 | clean |
| replication-monitoring.js | 250 | 0 | clean |
| ReplicationMonitoring-API.ps1 | 40 | 0 | clean |
| ReplicationMonitoring.ps1 | 218 | 4 | known |
| Populate-AssetRegistry-CSS.ps1 | 557 | 11 | expected: 6 Write-Host + 5 cross-populator duplicate functions |
| Populate-AssetRegistry-PS.ps1 | 834 | 7 | expected: 5 Write-Host + 2 cross-populator duplicate functions |
| xFACts-AssetRegistryFunctions.ps1 | 281 | 0 | clean |
| Resolve-AssetRegistryReferences.ps1 | 117 | 0 | clean |
| xFACts-CCShared.psm1 | 544 | 41 | queued structural refactor |

The two populators' non-compliant rows are entirely the accepted buckets (Write-Host, parked
platform-wide; and cross-populator duplicate functions, tracked in §9). No authoring drift.

---

## 9. Carry-forward to-do list (folded in from the streamlining doc)

The next session's lead item is the **JS populator** (the next table-driven conversion). The rest
are tracked here so the carry-forward lives in one current place.

### 9.1 Next populator: JS (lead item)

Convert `Populate-AssetRegistry-JS.ps1` to the table-driven model and full spec conformance, same
pattern as CSS:
- Zone/scope/shell from `Object_Registry` via `Get-ObjectRegistryZoneScopeMap`; delete
  `Get-JsZone`, hardcoded scan roots, and the locally re-declared shared-file lists (JS currently
  re-declares the CSS shared lists — converting kills that manual-sync hazard).
- Use the single-query FK path from the start: call the combined
  `Get-ObjectRegistryZoneScopeMap` (which now carries `RegistryId`), drop any
  `Get-ObjectRegistryMap` call, and add the projection shim at the bulk-insert call. Do not wire
  in a `Get-ObjectRegistryMap` call that would just be removed.
- Use `scope_tier = SHELL` and "shell" terminology from the start; never reintroduce "anchor
  file." `cc-shared.js` carries `scope_tier = SHELL`.
- Use `.COMPONENT Tools.Utilities`.
- Then HTML (same treatment).

### 9.2 Duplicate function definitions (lift to shared library)

Cross-populator duplicate-function drift. The duplicate set is mostly the **web-asset trio
(CSS/JS/HTML)**, plus `Format-SingleLine` which is also in PS:
- `Format-SingleLine` — pure utility, safest first lift (also in PS).
- `Add-FileHeaderRow`, `Add-HtmlIdRow`, `Add-CommentBannerRow` — CSS/JS/HTML emitters.
Lift the genuinely identical ones into `xFACts-AssetRegistryFunctions.ps1`, delete local copies,
update call sites. Caution: the row emitters call per-populator row constructors
(`New-CssRow` / `New-JsRow` / `New-HtmlRow`) — settle the row-construction seam before lifting
emitters (pass the constructor in, or route through a shared `New-AssetRegistryRow`). Verify
byte-for-byte body equivalence before lifting; any divergence is itself a finding.

### 9.3 FK migration step 3 (after all four populators migrated)

Update `Invoke-AssetRegistryBulkInsert` to accept the combined-map shape directly; delete the four
projection shims; delete `Get-ObjectRegistryMap`. The only flag-day moment; lands last.

### 9.4 Write-Host disposition (parked, platform-wide)

`FORBIDDEN_WRITE_HOST` on the populators is accepted drift. Revisit as part of the spec-as-data
effort when the Write-Host-vs-Write-Log question is settled platform-wide. Single coordinated
decision across all standalone scripts, not per-populator.

### 9.5 Universal anchor-row split — INTENDED; optional uniformity tweak (not a blocker)

`CC_Catalog_Pipeline_Working_Doc.md` carried this as deferred work: treat `CSS_FILE` /
`JS_FILE` / `PS_FILE` / `HTML_FILE` as pure-anchor rows with a separate `FILE_HEADER` row. The
catalog shows the split is present and the behavior is **intended**, but **conditional on header
recognizability**:

- The `FILE_HEADER` row keys off whether the parser can *recognize* a header block at all (for PS,
  a `<# ... #>` block at line 1) — structural recognition, not validity.
- **Recognizable block present** → `FILE_HEADER` row is emitted, and any *content* drift
  (`INVALID_COMPONENT_VALUE`, `FORBIDDEN_CHANGELOG_IN_HEADER`, `MALFORMED_NOTES_FIELD`,
  `MISSING_COMPONENT_DECLARATION`, etc.) attaches to that row. Examples: `backup.js`,
  `Backup-API.ps1`, `Collect-B2BExecution.ps1`, `Collect-BackupStatus.ps1`.
- **No recognizable block** → no `FILE_HEADER` row; `MALFORMED_FILE_HEADER` ("No `<# #>` / `/* */`
  block found") lands on the `*_FILE` anchor instead. Examples: `admin.js`,
  `applications-integration.js`, `Admin.ps1`, `BatchMonitoring.ps1`.

So the rule is: "can I see a header?" gates the row; "is the header correct?" gates the drift on
it. This is what was wanted, so the working-doc item is essentially done in intent.

**Optional refinement (not a blocker for anything):** consider whether the truly uniform end state
should be "always emit a `FILE_HEADER` row — a degenerate/empty one when no block is recognized —
so every file has a consistent two-row shape and `MALFORMED_FILE_HEADER` always lives on the header
row rather than sometimes on the anchor." That is a small per-populator mechanism tweak (emit the
header row unconditionally, attach the not-found drift to it), not a redesign. It does not block the
JS conversion or anything else; it can be picked up whenever convenient, or declined if the
current conditional shape is preferred. (Separately: `*_FILE` and `FILE_HEADER` counts also differ
because minified library files like `chart.min.js` and HTML-host files emit a `*_FILE` anchor with
no `FILE_HEADER` — a legitimate difference independent of the tweak above.)

### 9.6 Queued cross-file migrations (pre-existing, not this session's family)

- `xFACts-CCShared.psm1` structural refactor (41 rows).
- Backup overlay/slideout cross-file migration (Backup.ps1 / backup.js / cc-shared.* — 5 rows on
  backup.js, part of Backup.ps1's 10).
- Page migrations resume once the populator family is fully realigned (per Session 17/18:
  migrating on a misaligned pipeline compounds drift).

---

## 10. Next session boot sequence

1. Fetch `manifest.json?v=<cache-buster>` from GitHub.
2. Verify Project Knowledge has the current anchor docs: `CC_PS_Spec.md`, `CC_JS_Spec.md`,
   `CC_Session_Summary_21.md` (this document), `xFACts_Development_Guidelines.md`.
3. Fetch `Populate-AssetRegistry-JS.ps1` (the conversion target), `Populate-AssetRegistry-CSS.ps1`
   (the converted reference pattern), and `xFACts-AssetRegistryFunctions.ps1` (the shared
   library, now carrying `RegistryId`).
4. Confirm the full pipeline re-ran clean after this session's deploys before starting JS.
5. Convert JS following §9.1.

---

## 11. Notes for consolidation

When this summary is consolidated:
- The anchor/shell terminology boundary is durable platform vocabulary — record it.
- `.COMPONENT Tools.Utilities` as the populator-family component is a durable fact.
- The FK single-query migration plan and the duplicate-function lift are active engineering
  items — they survive in §9 until done, then become CHANGELOG entries on the affected files.
- `CC_Populator_Streamlining_Opportunities.md` can be retired once §9 here is the live reference.
- `CC_Catalog_Pipeline_Working_Doc.md`'s "universal anchor-row refactor" item is done in intent
  (§9.5): the conditional split is the wanted behavior. An optional uniformity tweak (always emit a
  `FILE_HEADER` row, even when no header block is recognized) remains available but is not a
  blocker; close or annotate the working-doc item accordingly.
- This document itself gets deleted once its content is consolidated.
