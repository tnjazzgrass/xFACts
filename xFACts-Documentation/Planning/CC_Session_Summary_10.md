# CC File Format Standardization — Session 10 Summary

**Focus:** Bring `CC_JS_Spec.md` and `Populate-AssetRegistry-JS.ps1` into final alignment as a standalone, unambiguous reference document and matching enforcement layer. Smoke-test the aligned populator against the live codebase to validate the changes and surface anything to address in subsequent passes.

**Status at close:** Both deliverables shipped to GitHub. Smoke-test confirms new spec rules fire as designed and the populator's drift detection is working at category level. Performance investigation deferred to a dedicated session. Three small issues observed during smoke-test queued for a future overall-drift-output pass.

---

## 1. Scope decisions

The session opened with three goals: spec audit, populator alignment, performance investigation. The performance investigation was deferred to a dedicated session and captured in its own carry-forward document (see §6).

The driving framing for the spec audit:
- The spec must read as a **standalone reference document**. A developer (or Claude) building a new page file from this document alone must be able to produce a spec-compliant file without consulting other sources.
- **Style alignment with CSS and HTML** — rules-only, no rationale, no "why" prose. Session 6 collapsed all three specs to this style; the JS spec had drifted slightly back toward explanatory prose and needed re-tightening.
- **Spec-to-populator contract.** Drift codes referenced in the spec must match drift codes the populator emits, both in identity and in count.
- **No accommodation of legacy state.** The spec describes what every page file should look like going forward; every page will be refactored to match. Drift codes catch deviations and stay in the spec as permanent guard rails — they don't get retired after the refactor pass because they also catch authoring mistakes on new pages.

---

## 2. Spec changes — locked and shipped

All twelve changes below were walked through individually, approved, and integrated into `CC_JS_Spec.md`:

| # | Change |
|---|---|
| 1 | §2 file header template gains the full `/* === ... === */` envelope with 76-char rule lines and 3-space interior indent; §2.1 gains the shape-describing sentence matching CSS §3.1 |
| 2 | §3 banner template gains the same full-envelope shape; §3.1's first bullet consolidates to one sentence describing the shape shared between §2 and §3 |
| 3 | §17 drift code table: `FORBIDDEN_TOP_LEVEL_WRAPPER` split back into `FORBIDDEN_IIFE` and `FORBIDDEN_REVEALING_MODULE` (Session 6 had collapsed them; remediation paths are genuinely different — bare IIFE is an in-file unwrap; revealing-module requires cross-file rewrites — so they remain split). Three additions: `MALFORMED_PREFIX_VALUE`, `MISSING_ENGINE_PROCESSES_DECLARATION`, `MISSING_ENGINE_CARD_FOR_REGISTERED_PROCESS` |
| 4 | §7.2.1 rewritten declaratively — "sole exception" framing and the window-mechanics rationale both removed; the `var` rule for `<prefix>_ENGINE_PROCESSES` now lives positively alongside the `const`-everywhere-else rule, reinforced at three levels (section header, rules bullet, dedicated subsection) so the reader can't miss it |
| 5 | Mandated `FUNCTIONS: INITIALIZATION` banner — §4.1 (page-file table), §11.1 (page boot function rules), §17 (new `INIT_MISPLACED` drift code). The INITIALIZATION banner is the first FUNCTIONS banner and contains only `<prefix>_init`. Parallel structure to the existing `FUNCTIONS: PAGE LIFECYCLE HOOKS` banner |
| 5a | §5.2: stripped the "they are namespaced within the class itself" rationale tail |
| 5b | §6.1: trimmed the "Anonymous functions assigned to const/var..." negative-restatement; kept the positive rule with examples only |
| 5c | §8 intro: struck the second sentence about `cc-shared.js` probing mechanics |
| 5d | §11.3: compressed to a single rule sentence; dropped the mechanism description |
| 5e | §12.1: struck the per-row context paragraph (implementation guidance, not a rule) |
| § header | §7 section header rewritten as bulleted declarative statements covering FOUNDATION (const), CONSTANTS (const except `<prefix>_ENGINE_PROCESSES`), STATE (var). Provides positive framing at the moment the rule is introduced |

**Design principle codified during this session:** consolidate drift codes when they describe *the same fix done the same way*; split when they describe *different fixes or different scopes of fix*. Applied to the IIFE/revealing-module split; flagged as worth revisiting for other consolidations from Session 6 in their respective spec/populator sessions.

**Framing principle codified during this session:** the populator is a permanent enforcement layer, not a cleanup tool. Every drift code stays in the spec forever; the refactor pass empties the catalog for specific codes against today's files but does not retire the codes themselves. New pages must be detected if they deviate from spec, since developers (and Claude) will not always read the spec fully.

---

## 3. Populator changes — locked and shipped

The populator was found to be **substantially closer to the new spec than initially expected**, since the wrapper-split and engine-cards work was done in earlier sessions before Session 6 collapsed the spec back. Only three real gaps needed addressing:

### Gap 1 — `INIT_MISPLACED` detection (new code)
- Added `$InitBannerName = 'INITIALIZATION'` constant parallel to `$HooksBannerName` and `$EngineProcessesBannerName`.
- Added `INIT_MISPLACED` to `$DriftDescriptions`.
- Pre-scan at section-list iteration to find the first FUNCTIONS banner index.
- Added `-IsFirstFunctionsBanner` param to `Add-CommentBannerRow`.
- Three firing points:
  - On `COMMENT_BANNER` row when the INITIALIZATION banner exists but isn't the first FUNCTIONS banner.
  - On `JS_FUNCTION` row when `<prefix>_init` is declared outside INITIALIZATION.
  - On `JS_FUNCTION` row when any function other than `<prefix>_init` is declared inside INITIALIZATION.
- `MISSING_PAGE_INIT` retained as-is — it answers a distinct question ("does the init function exist at all?").

### Gap 2 — `(none)` prefix carve-out elimination
- Removed `$PrefixNoneAllowedSectionTypes = @('IMPORTS', 'CONSTANTS')` constant.
- Simplified `PREFIX_REGISTRY_MISMATCH` block in `Add-CommentBannerRow` from ~60 lines of branching logic with `$isCc`, `$isNone`, `$noneAllowedHere` flags down to ~30 lines of straightforward two-case logic (page file → declare page prefix; `cc-shared.js` → declare `cc`).
- `MALFORMED_PREFIX_VALUE` upstream already rejects `(none)` via the shared `Test-PrefixValueIsValid` helper.

### Gap 3 — Catalog-facing description and context wording
- Updated `MALFORMED_PREFIX_VALUE` description to match the new spec wording.
- Updated the matching drift-context string to drop the stale "3-char lowercase prefix or (none)" phrasing.

### Sweep — spec-section references removed
Recognized during smoke-test prep that the populator was carrying ~50 references to specific spec section numbers (`Section 5.4`, `Section 18.3`, etc.) across comments, drift descriptions, and drift Context strings. Two problems with these:

1. **Drift descriptions and Context strings** end up in the `drift_text` column of the catalog — so stale section references would propagate into the catalog itself, polluting downstream queries and reporting.
2. **Code comments** referencing spec section numbers go stale every time the spec is renumbered, which happens often during the development phase.

The drift code itself is the durable link — when you see `INIT_MISPLACED` in the catalog, the spec is one search away. Comments and descriptions describing *which section* the rule came from add no value to the running code.

Swept all spec-section references from live code (49 references) and from catalog-facing strings (6 description strings + 5 section-divider comments + 1 drift Context string). Changelog history left intact per standing rule that CHANGELOGs are frozen history.

### Net change
- 4222 lines → 4220 lines after all edits and sweeps.
- New behavior: INIT_MISPLACED detection across three firing points.
- Removed behavior: `(none)` prefix carve-out logic (no longer reachable under the new spec).
- Brace/paren balance identical to pre-edit file (verified via diff against original).

---

## 4. Smoke-test results

The full populator pipeline (CSS → HTML → JS) ran successfully against the live codebase with the new JS populator.

### Validated: all new spec rules fired correctly

| Drift code | Occurrences | Reads as |
|---|---|---|
| `MALFORMED_PREFIX_VALUE` | 12 across 4 files | Every banner in the four `*-spec.js` files that declares `Prefix: (none)` — exactly the pattern the new spec eliminated |
| `INIT_MISPLACED` | 1 in `backup.js` | The function-side firing point: `bkp_init` exists but lives in `FUNCTIONS: PAGE BOOT` instead of `FUNCTIONS: INITIALIZATION`. Drift context names the correct required home |
| `MISSING_PAGE_INIT` | 18 across 18 files | 18 of 25 page files have no `<prefix>_init` at all — expected pre-refactor state |
| `FORBIDDEN_IIFE` | 4 across 4 files | Confirmed: `ddl-erd.js`, `ddl-loader.js`, `docs-controlcenter.js`, `nav.js` |
| `FORBIDDEN_REVEALING_MODULE` | 6 across 6 files | Confirmed: `admin.js`, `applications-integration.js`, `bdl-import.js`, `business-intelligence.js`, `client-portal.js`, `platform-monitoring.js` |
| `ENGINE_PROCESSES_MISPLACED` | 14 across 14 files | Files declaring `ENGINE_PROCESSES` at file scope outside any banner |
| `ENGINE_PROCESS_PAGE_MISMATCH` | 3 | Including the two `*-spec.js` files whose page routes legitimately differ from the registered processes' routes |
| `ENGINE_SLUG_JS_MISMATCH` | 2 across 2 files | `dm-operations.js`, `index-maintenance.js` — both pages with engine processes that don't have matching active engine-card rows in `ProcessRegistry` |

The wrapper-split paying off as designed: bare-IIFE vs revealing-module shows at a glance which legacy files need an in-file unwrap (4 IIFE files) vs the heavier cross-file rewrite (6 revealing-module files).

### Drift distribution at category level (top of histogram)

| Drift code | Occurrences | Files affected |
|---|---|---|
| FORBIDDEN_FILE_SCOPE_LINE_COMMENT | 992 | 17 |
| JS_HTML_ID_MALFORMED | 983 | 18 |
| MISSING_SECTION_BANNER | 861 | 19 |
| PREFIX_MISSING | 749 | 18 |
| MISSING_FUNCTION_COMMENT | 618 | 15 |
| MISSING_STATE_COMMENT | 179 | 15 |
| JS_HTML_ID_UNRESOLVED | 156 | 16 |
| HOOK_MISPLACED | 43 | 14 |
| FORBIDDEN_PROPERTY_ASSIGN_EVENT | 28 | 6 |
| MISSING_PAGE_INIT | 18 | 18 |
| SHADOWS_SHARED_FUNCTION | 16 | 10 |
| Everything else | < 20 each | various |

**Reading:** the high-count codes are exactly the categories one would expect against a pre-refactor codebase — prefix discipline not yet applied, banners not yet added, purpose comments missing, file-scope line comments left over from earlier styles, HTML ID naming not yet aligned to the prefix rule. The populator is catching real drift at category level. The numbers are large because the codebase is pre-refactor.

### Aggregate

JS populator processed 29 files, produced 10,633 catalog rows, with 28% carrying at least one drift code. All four `*-spec.js` files surfaced as having Object_Registry registration gaps (same files as the CSS run flagged) — these are draft/spec files that need Object_Registry rows to enable FK linkage.

---

## 5. Three small issues observed during smoke-test — queued for future session

These were captured during smoke-test query review and **deferred to a dedicated drift-output analysis session** that will compare the four populators side by side once they're all aligned with their specs. None of these are blockers; all involve refinement rather than correctness.

### Issue 1 — `ENGINE_SLUG_JS_MISMATCH` covers two distinct conditions

The drift code description says it fires when "an ENGINE_PROCESSES entry's slug value does not match `Orchestrator.ProcessRegistry.cc_engine_slug`." The actual context strings reveal a second condition: the process doesn't exist as an active engine-card row in `ProcessRegistry` at all (so the slug "cannot be validated"). These are different kinds of mismatch with different remediation paths. Candidate split: keep `ENGINE_SLUG_JS_MISMATCH` for actual slug-value mismatches, add new `ENGINE_PROCESS_NOT_REGISTERED` for the "no row to compare against" case.

### Issue 2 — Grammar artifact in `ENGINE_PROCESSES_MISPLACED` context

The drift_text reads: *"'ENGINE_PROCESSES' is declared in outside any section banner; required home is 'CONSTANTS: ENGINE PROCESSES'."* — the "in outside" results from a context-builder template that doesn't fit the "no section" case cleanly. Cosmetic.

### Issue 3 — `JS_HTML_ID_MALFORMED` and `FORBIDDEN_FILE_SCOPE_LINE_COMMENT` are firing very heavily

983 and 992 occurrences respectively. Both *could* be legitimate pre-refactor drift, but the volume warrants a sample-row inspection to confirm there's no over-matching (string literals being misidentified as IDs; in-function line comments being misidentified as file-scope). Spot-check query queued for the dedicated drift-output analysis session.

---

## 6. Performance investigation — deferred

The JS populator's per-file walk time is ~10s/file, vs ~1.4s/file for CSS and ~0.4s/file for HTML. Root-cause diagnosis was done in this session but the actual code changes were deferred to a focused performance session.

Captured in `CC_Populator_Performance_Investigation.md` as a carry-forward roadmap document. Four contributing factors identified, listed roughly in descending order of impact:

1. `Get-SectionForLine` is O(N) linear scan, called once per row emission (~320,000 comparisons per JS run). Shared infrastructure — fix benefits CSS and JS together.
2. The `$JsVisitor` 984-line scriptblock dispatched per AST node — scriptblock invocation overhead is substantially higher than function calls.
3. `PSObject.Properties.Name -contains 'X'` checks in hot paths — defensive null-handling that's not actually needed for well-formed AST nodes.
4. Node subprocess overhead — one process spawn per file (~3s/file in Pass 1).

Plan: tackle 1–3 in a dedicated session, measure after each, and only escalate to 4 if the first three don't bring JS in line with CSS. CSS populator will also benefit from fixes 1 and 3 since they touch shared infrastructure.

---

## 7. Documentation and version control

The following changes are now live on GitHub:

- `xFACts-Documentation/Planning/CC_JS_Spec.md` — revised standalone spec
- `xFACts-PowerShell/Populate-AssetRegistry-JS.ps1` — aligned populator with new INIT_MISPLACED detection
- `xFACts-Documentation/Planning/CC_Populator_Performance_Investigation.md` — carry-forward roadmap for the perf session
- `xFACts-Documentation/Planning/CC_Session_Summary_10.md` — this document

No changes to the populator's runtime behavior beyond the three documented gaps. Smoke-test confirms catalog row counts and drift detection are functioning correctly under the new spec.

---

## 8. Next session direction

**PS spec audit and populator alignment** — the final spec in the four-spec series. The pattern follows what worked for JS in this session:

1. Read `CC_PS_Spec.md` end to end and identify ambiguities, missing rules, or places where the spec doesn't read as standalone.
2. Walk through each item one at a time, deciding what to keep, change, or strike.
3. Apply consistent style with CSS, HTML, and JS specs — rules-only, no rationale, no implementation prose.
4. Reconcile `Populate-AssetRegistry-PS.ps1` against the locked spec — same approach as Session 10's three-gap pattern.
5. Smoke-test the aligned populator. Note any drift-output observations to queue for the dedicated drift-output session.

The PS spec is somewhat different in nature from the other three because PowerShell files contain both code and embedded HTML (in route handlers). The spec already addresses this dual nature; the audit should focus on whether the rules describing each side are clear, complete, and consistent.

**After PS spec/populator alignment**, two parallel tracks open up:

- **Drift-output analysis session** — review the full catalog with all four populators aligned. Tighten categorization, address the three queued issues from this session, look for over-matching or under-matching across populators, and confirm the spec ↔ populator ↔ catalog chain is doing what we want.
- **Performance investigation session** — work through the four optimization tracks in the carry-forward doc, measuring after each.

**Then the long-awaited next phase begins:** the actual file-by-file refactor of the Control Center to conform to the four specs. Catalog drift counts become the burndown metric.

---

## 9. Key learnings — flagged for the standing notes

These came out of this session's framing discussions and may be worth promoting to the standing patterns or "key learnings" docs:

- **Session 6 decisions are revisitable, not set in stone.** Each consolidation gets re-evaluated through the lens "consolidate when codes describe same fix done same way; split when codes describe different fixes or different scopes of fix." The wrapper-split reversal in this session is one example.
- **Drift codes are permanent guard rails, not legacy cleanup signals.** Every code in the spec stays in the spec; the catalog empties for specific codes against specific files post-refactor but the codes themselves never get retired. New pages must be detected if they deviate. This framing was clarified mid-session and should govern future spec/populator consolidation discussions.
- **Spec content rules: rules-only, no "why" prose.** Sneaky little rationales tend to creep back in ("X exists because of Y", "the system probes by Z"). The standard is the rule itself; the *why* lives elsewhere if it lives at all.
- **Populator content rules: no spec-section references.** Stale comment references in code are noise; stale section references in `drift_text` pollute the catalog. The drift code itself is the durable link to the spec.
- **Anchor the spec rule at the moment it's introduced.** When the section header makes a positive declarative statement of the rule (like the rewritten §7 in this session), the rule reinforces itself through the rest of the section rather than requiring the reader to assemble it from negative-framed "X in Y is drift" statements scattered across subsections.
