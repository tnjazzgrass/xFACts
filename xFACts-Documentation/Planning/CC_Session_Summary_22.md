# CC Session Summary 22

## 1. Session focus

Continuation of the CC File Format Initiative, picking up after Session 21 (CSS
populator conversion). This session closed out the remaining populator-family
engineering items — the FK flag-day, the duplicate-function resolution, the
HTML populator's final drift cleanup — and then built the Asset Registry
pipeline orchestrator. It ended by finding and fixing a regression in the HTML
and JS populators' FK linkage, and establishing a trustworthy wall-clock
baseline for the full pipeline.

A destructive encoding-corruption incident occurred mid-session (a BOM-removal
utility) and is documented in §9 as a hard lesson, not as deliverable work.

---

## 2. HTML populator — final drift cleanup

The HTML populator (`Populate-AssetRegistry-HTML.ps1`) was taken from 32 drift
rows down to its known-bucket floor (6 `FORBIDDEN_WRITE_HOST` + 2 cross-populator
duplicates). Genuine items fixed:

- All trailing comments moved to leading position (5 in the SCRIPT-SCOPE STATE
  block, 5 inside function bodies). Each `$script:` context variable given its
  own purpose comment.
- 8 functions given single-line purpose comments (`ConvertTo-HtmlTokens`,
  `Get-AttributesFromToken`, `Split-StaticClassTokens`, `Get-OverlayIdInfo`,
  `Get-EventFromDataActionName`, `Invoke-OverlayPostWalkValidation`,
  `Invoke-EngineCardValidation`, `Invoke-PageChromeValidation`).
- 3 constants/variables given individual leading comments (`$ChromeIdSlugPrefixes`,
  `$ActionPermittedOverlayClasses`, `$script:dedupeKeys`).
- The Orchestrator ProcessRegistry Load sub-marker corrected to stand alone.
- `$ErrorActionPreference` moved out of INITIALIZATION into its own
  `CONSTANTS: EXECUTION PREFERENCES` section, matching the PS populator pattern.
- `Parse-RootVariableFromExpression` renamed to `Get-RootVariableFromExpression`
  (approved-verb fix), definition + 3 call sites.

---

## 3. FK flag-day (Session 21 §9.3 — CLOSED)

The transitional FK scaffolding was removed across all five files in a single
coordinated change.

- `Invoke-AssetRegistryBulkInsert` (in `xFACts-AssetRegistryFunctions.ps1`) made
  strict: it now reads `.RegistryId` off the combined zone/scope map
  (`file_name -> @{ RegistryId; Zone; ... }`) instead of treating each value as a
  flat int.
- All four populators repointed `-ObjectRegistryMap` to their combined map
  variable and deleted their projection shims.
- `Get-ObjectRegistryMap` deleted entirely (confirmed dead: the helper file is
  scoped only to the populators and the resolver, both checked). Stale references
  to it reworded.

**Per-file map variable (durable detail — they differ):**
- HTML and CSS use `$script:zoneScopeMap`.
- JS and PS use `$objectZoneScopeMap`.

This difference is the root of the §6 regression — see there.

---

## 4. Duplicate-function resolution (Session 21 §9.2 — CLOSED)

Five `DUPLICATE_FUNCTION_DEFINITION` collisions were analyzed. Only **one** was a
true copy-paste duplicate; the other four were name-collisions of genuinely
different per-populator functions.

- `Format-SingleLine` (CSS + PS) — byte-identical, no dependencies. **Lifted** into
  `xFACts-AssetRegistryFunctions.ps1` (COMMENT TEXT CLEANUP section). Local copies
  deleted from CSS and PS by hand.
- `Add-FileHeaderRow`, `Add-CommentBannerRow`, `Add-HtmlIdRow`, `Invoke-Ps/PSParse`
  — NOT liftable. The emitters each call their own per-populator row factory
  (`New-CssRow` / `New-JsRow`), and `Invoke-Ps/PSParse` are two different
  implementations (different parse method, return shape, logging) sharing a
  case-insensitive name. **Renamed** instead.

**Naming rule adopted (informal, no spec change):** the natural-owner populator
keeps the base name; borrowers get a language prefix; co-equal pairs both get
prefixed. No doubled names (`PsPsParse`, `HtmlHtmlId` avoided).

- `Invoke-PsParse` (HTML) -> `Invoke-HtmlPsParse`; PS keeps `Invoke-PSParse`.
- `Add-HtmlIdRow` — HTML keeps base name (natural owner); CSS -> `Add-CssHtmlIdRow`,
  JS -> `Add-JsHtmlIdRow`.
- `Add-FileHeaderRow` (co-equal CSS/JS) -> `Add-CssFileHeaderRow` / `Add-JsFileHeaderRow`.
- `Add-CommentBannerRow` (co-equal CSS/JS) -> `Add-CssCommentBannerRow` / `Add-JsCommentBannerRow`.

Result: all four populators reached clean-except-Write-Host. Drift acceptance was
explicitly reaffirmed as never an option — name collisions get fixed, only
genuinely irreducible cases (Write-Host) stay as known buckets.

---

## 5. Asset Registry pipeline orchestrator (NEW)

Built `Invoke-AssetRegistryPipeline.ps1` — a fire-and-forget orchestrator modeled
on `Invoke-DocPipeline.ps1` for the contract only (the doc pipeline is
unrefactored and is NOT a style reference). Built fully spec-conformant as a
standalone script.

**Design (all confirmed with Dirk):**
- Params: `-Execute` (switch, passed through as `-Execute:$Execute` like the
  populators), `-StepsJson` (comma-separated stage keys), `-FullRun` (switch,
  gates the truncate), `-StatusFile`.
- The four populators have NO cross-dependencies (the resolver owns all cross-file
  resolution — that is why it exists; HTML<->JS references are circular). So the
  populators run in **parallel** via `Start-Process -PassThru` (no `-Wait`), joined
  by polling `.HasExited`. The resolver runs once after the join.
- **Failure model:** matches doc pipeline — exit 0 = success, 2 = warning
  (continue), other = hard failure. Populators always all run (parallel — cannot be
  recalled). The resolver is gated only on a populator **hard failure**; a warning
  does not gate it.
- **Truncate:** full run only, once before launching anything (`TRUNCATE TABLE
  dbo.Asset_Registry`, `DELETE` fallback, aborts the run if both fail — no false
  success). Selective runs rely on each populator's own per-file-type clear.
- Output via `Write-Log` (Write-Host forbidden in standalone, §15).
- `.COMPONENT Tools.Utilities`. Object_Registry row and the three Object_Metadata
  base rows (description/module/category, module=ControlCenter, category=AdminTools)
  handled by Dirk.

**Two bugs found and fixed during first runs:**
1. `Initialize-XFActsScript -Execute` was malformed — the parameter is `[bool]`,
   not a switch. Fixed by giving the orchestrator its own `[switch]$Execute` and
   passing `-Execute:$Execute` (also resolves the family naming consistency).
2. The truncate `catch` logged SUCCESS even when it failed. Rewritten to abort the
   run if both TRUNCATE and DELETE fail.

**Timing baseline established:** a full parallel run is **~4:51 wall clock**, gated
almost entirely by the JS populator. (An earlier 3:06 run was a fluke; ~4:45–5:00
is the trustworthy number.) Write windows confirmed the populators' DB writes
naturally stagger and do not overlap — **no write contention, no mutex needed**,
confirmed by clean exits across all stages. Output correctness confirmed: 1,710
unresolved references, matching sequential runs exactly.

---

## 6. HTML / JS FK regression (FOUND AND FIXED this session)

After the full pipeline run, `Asset_Registry.object_registry_id` came back **0**
(not NULL) for all HTML and JS rows; correct for CSS and PS.

**Root cause:** "0 not NULL" means the file key was found in the map but
`.RegistryId` returned `$null` -> `[int]$null = 0`. HTML and JS were still passing
the **flat** shim map (`$objectRegistryMap`), not their combined map — the shim
was never deleted in those two files. Correct under the old bulk insert; broken
once the bulk insert went strict (§3).

**How it happened (process lesson):** the FK flag-day shim deletions were done by
Dirk locally on all four populators. Later, the duplicate-function renames for HTML
and JS were delivered as **full-file replacements** built from Claude's in-context
copies — which were the **pre-shim-deletion** versions. Those replacements silently
reintroduced the shim, clobbering Dirk's local fix. CSS (done manually by Dirk) and
PS (no rename needed, never regenerated) survived correct.

**Fix:** deleted the shim from HTML and JS, repointed `-ObjectRegistryMap` to the
combined map (`$script:zoneScopeMap` in HTML, `$objectZoneScopeMap` in JS).
Verified against Dirk's live uploads (not stale copies). Confirmed resolving for
both HTML and JS on the subsequent run.

**Durable process rule (record this):** a full-file replacement asserts authority
over the entire file, including local edits not in Claude's context. Before
delivering a full-file replacement of any file Dirk may have edited locally,
**re-sync to the current version first.** Prefer targeted edits when bounded; a
missed targeted edit is recoverable, a stale-base full replacement destroys local
work. This is the same my-copy-vs-deployed-copy drift that caused multiple problems
this session.

---

## 7. Files delivered this session

- `Populate-AssetRegistry-HTML.ps1` — drift cleanup, `Invoke-HtmlPsParse` rename,
  shim deleted / combined map passed (final, FK-correct).
- `Populate-AssetRegistry-JS.ps1` — `Add-Js*` renames, shim deleted / combined map
  passed (final, FK-correct).
- `xFACts-AssetRegistryFunctions.ps1` — strict `Invoke-AssetRegistryBulkInsert`,
  `Get-ObjectRegistryMap` deleted, `Format-SingleLine` lifted in.
- `Invoke-AssetRegistryPipeline.ps1` — NEW orchestrator (the two bug fixes folded
  in).

(CSS and PS edits — shim deletions, renames, `Format-SingleLine` local deletion —
were done by Dirk by hand and are already deployed.)

---

## 8. End-of-session state

All four populators are standardized, FK-consolidated, dedup'd, and at
clean-except-Write-Host. The FK regression is resolved (all four file types
resolve `object_registry_id` correctly). The pipeline orchestrator runs correctly
and produces a catalog matching sequential runs (1,710 unresolved). `Format-SingleLine`
is shared (CSS<->PS unaffected by the HTML/JS regression).

Known remaining drift: `FORBIDDEN_WRITE_HOST` on the four populators (parked,
platform-wide decision pending); `xFACts-CCShared.psm1` at 41 (intentional mirror
of `xFACts-Helpers` during refactoring — expected by design, clears when one module
retires); page files (Backup, ReplicationMonitoring) carry expected pre-migration
drift.

---

## 9. Encoding-corruption incident (lesson, not deliverable)

A BOM-removal utility (`Remove-Bom.ps1`) was built and run against the whole
`E:\xFACts-PowerShell` tree. It corrupted ~26 files (UTF-8 multi-byte characters —
em-dashes, box-drawing — became Windows-1252 mojibake), surfaced as parse errors
and ~1000 missing catalog rows. Dirk proved it on a copy. **The script is
retracted; never run it again.** Recovery was a clean restore from GitHub.

Lessons: (1) never run a destructive bulk file-rewrite tree-wide without proving it
harmless on a throwaway copy first; (2) ISE-with-BOM actually *prevents* this
particular corruption (the BOM tells ISE the file is UTF-8) — so BOM stripping and
ISE saving work against each other. **BOM strategy decision deferred** — accept BOMs,
or handle stripping at git-commit time, never via ad-hoc rewrite. Do not chase BOM
removal by rewriting files.

---

## 10. Carry-forward to-do (next session — Dirk chooses priority)

### 10.1 Pipeline: incremental per-stage status reporting
The orchestrator's join writes status only after ALL populators exit (batch flip),
so the modal would show all stages "running" for JS's full runtime then snap to
done. Fix the join loop to write the status file as each populator exits
individually, so polling reflects live per-stage progress. NOT a correctness bug —
a UX prerequisite for the modal. Do this first within the pipeline work.

### 10.2 Pipeline: API endpoints
Add `POST /api/admin/asset-registry-pipeline` (launch, fire-and-forget) and
`GET /api/admin/asset-registry-pipeline/status` (poll) to `Admin-API.ps1`, mirroring
the doc-pipeline pair (Admin-API.ps1 ~line 1313 / 1375). Pass `steps`, `full_run`.

### 10.3 Pipeline: Admin modal + tile
Build the five-stage modal (CSS / HTML / JS / PS / resolver as selectable switches
+ run button) and tile in `Admin.ps1` / `admin.css` / `admin.js`, styled to match
the doc-pipeline modal, with on-error `Write-Log` output displayed to screen
(reference admin.js doc-pipeline poll/render ~line 1030–1180). Resolver is a
user-selectable stage for isolated runs.

### 10.4 Page-file refactoring (the actual initiative work)
With the populator family fully realigned, page-at-a-time migration can resume
(Session 17/18: migrating on a misaligned pipeline compounds drift — that blocker is
now cleared). ~24 CC pages to conform to the new specs. **Dirk is explicitly torn
between building the pipeline UI (10.1–10.3) and getting back to this refactoring
work — both are listed so the choice can be made next session.**

### 10.5 JS populator performance (investigation)
Full run is gated by JS (~3 min of a ~5 min run; ~90s parse, ~3 min walk). Prior
sessions already instrumented phases and tried optimizations expecting 50–70% gain —
**netted nothing.** That rules out the obvious; the cost is likely in the walk's
mechanics, not the analysis logic. Next step: sub-phase instrumentation WITHIN the
walk + a bare no-op-walk timing experiment (walk and count nodes, do nothing) to
split traversal cost from per-node-work cost. Suspects: PowerShell `$array +=`
reallocation (O(n^2) accumulation), per-node string slicing, or multi-pass
traversal. Need the JS walk code and the list of optimizations already tried.

### 10.6 Write-Host disposition (parked, platform-wide)
`FORBIDDEN_WRITE_HOST` across the populators. Single coordinated decision across all
standalone scripts (route through Write-Log, or conditional/interactive-only output).
Dirk values console output for interactive runs but most runs are automated — leaning
toward conditional output. Needs design discussion, not a reflexive fix.

### 10.7 Universal anchor-row refactor (Session 21 §9.5 — still deferred)
Treat `CSS_FILE` / `JS_FILE` / (future) `PS_FILE` as pure-anchor rows with a separate
`FILE_HEADER` row. ~30 lines net per CSS/JS populator. Tracked in
`CC_Catalog_Pipeline_Working_Doc.md`. Its own dedicated session.

### 10.8 Queued cross-file migrations (Session 21 §9.6 — pre-existing)
- `xFACts-CCShared.psm1` structural refactor (41 rows; intentional mirror until
  `xFACts-Helpers` retires).
- Backup overlay/slideout cross-file migration (Backup.ps1 / backup.js / cc-shared.*).

### 10.9 BOM strategy decision (from §9)
Decide: standardize UTF-8-with-BOM, or strip at git-commit time. Never via ad-hoc
file rewrite. Low urgency.

### 10.10 Pipeline registration follow-through
Confirm `Invoke-AssetRegistryPipeline.ps1` catalogs clean once its Object_Registry
row is in (PS populator will flag FILE_NOT_REGISTERED until then). Verify the
EXECUTION-body bare-`$` working variables (`$selected`, `$trackers`, etc.) are
treated as execution per §9.3, not flagged as declarations.

---

## 11. Next session boot sequence

1. Fetch `manifest.json?v=<cache-buster>` from GitHub.
2. Verify Project Knowledge has current anchor docs: `CC_PS_Spec.md`, `CC_JS_Spec.md`,
   `xFACts_Development_Guidelines.md`, `CC_Session_Summary_22.md` (this document).
3. Dirk picks the thread: pipeline UI (10.1 -> 10.2 -> 10.3), page refactoring (10.4),
   or JS performance (10.5).
4. For pipeline work: fetch `Invoke-AssetRegistryPipeline.ps1`, `Admin-API.ps1`,
   `Admin.ps1`, `admin.css`, `admin.js`. Start with 10.1 (incremental status) before
   the modal.
5. For page refactoring: fetch the target page's CSS/JS/PS + the relevant specs.
6. For JS performance: fetch `Populate-AssetRegistry-JS.ps1` and confirm what was
   already tried.

**Standing reminder (this session's hard lesson):** before delivering any full-file
replacement of a file Dirk edits locally, re-sync to his current copy first. Stale-base
full replacements silently clobber local edits.

---

## 12. Notes for consolidation

- The per-populator map-variable difference (HTML/CSS `$script:zoneScopeMap`,
  JS/PS `$objectZoneScopeMap`) is a durable detail — record it.
- The duplicate-function naming rule (natural-owner keeps base, borrowers prefixed,
  co-equals both prefixed) is a durable convention, deliberately NOT spec'd.
- FK flag-day (§3) and duplicate resolution (§4) are now CHANGELOG entries on the
  affected files — they can drop out of carry-forward.
- `Invoke-AssetRegistryPipeline.ps1` and its `.COMPONENT Tools.Utilities` are durable
  facts. The ~4:51 JS-gated baseline is the reference timing.
- The full-file-replacement re-sync rule (§6) is a durable process lesson — keep it.
- The Remove-Bom incident (§9) — keep the lesson, the script stays retracted.
- This document is deleted once consolidated.
