# CC Session Summary 8 — HTML Spec Gap Audit and Populator Alignment Plan

## Session focus

Eighth session in the CC File Format Standardization initiative. Following the CSS→HTML→JS→PS populator alignment sequence established in Session 7, this session opened the HTML phase. Rather than going straight to populator alignment, the session audited the HTML spec for gaps first — same shape as the CSS spec audit that produced Session 7's clean deliverables.

The session deliverables are the rewritten `CC_HTML_Spec.md` and the new `CC_HTML_Populator_Alignment_Plan.md`. The populator rewrite itself was deliberately deferred to the next session to protect against rushed work in a depleted context. The alignment plan exists specifically so the next session has a clear entry point and doesn't need to re-read 5,500+ lines of populator code before starting work.

---

## What landed

### Deliverable 1 — `CC_HTML_Spec.md` (full rewrite)

Complete drop-in replacement of the prior spec. 393 lines (down from 583). Integrates all 17 gap resolutions decided during this session's audit plus four amendments added at session end. The spec is now rules-only — definitional intro sentences remain where needed to make the rules interpretable, but explanatory text and rationale have been removed.

### Deliverable 2 — `CC_HTML_Populator_Alignment_Plan.md` (new working doc)

Cheat-sheet for the next session's populator rewrite. Sections cover:

- §1 Populator structure map (~5,500 lines, 20 sections)
- §2 Drift code reconciliation (retired, retained, new — with rationale per code)
- §3 Overlay validation rewrite scope (the biggest single change)
- §4 Class and ID name renames (where the populator currently disagrees with the spec)
- §5 New validators needed (11 functions, plain-English summaries)
- §6 Trouble spots (whitespace-discipline implementation, PS AST inspection, cross-spec ownership, coordinated CSS dependencies)
- §7 Recommended sequence of changes for next session
- §8 Files to fetch at next session start
- §9 Resolved decisions to apply during the rewrite
- §10 Platform-wide implications worth tracking
- §11 What the plan deliberately doesn't cover

This document is the next session's primary navigation aid. It is NOT a code spec; it tells next session where the work is and what the rules are. The session doing the work reads the populator's actual code at the relevant sections.

---

## 17-gap resolution roster

The HTML spec audit identified 17 gaps. Each was resolved during this session with explicit decisions. Roll-up table for the record:

| Gap | Topic | Resolution |
|---|---|---|
| 1 | Page-shell element ordering | New §1.2 consolidates ordering for `<head>` and `<body>` |
| 2 | Page-shell blank-line discipline | Exactly one blank line between adjacent mandated elements. Drift: `MALFORMED_PAGE_SHELL_WHITESPACE` |
| 3 | `</body>` and `</html>` exemption | Structural closing tags exempt from blank-line rule |
| 4 | Overlay block as page-shell position | Overlay block is an optional mandated structural position between page-specific content and `<script>` |
| 5 | Attribute order on mandated elements | Attributes appear in template-shown order. Drift: `MALFORMED_ATTRIBUTE_ORDER` |
| 6 | `<body>` class attribute scope | `cc-section-<key>` plus optional `cc-*` chrome classes; page-prefixed classes forbidden. Drift: `FORBIDDEN_PAGE_PREFIXED_BODY_CLASS` |
| 7 | `data-*` ownership framing | Reframe around platform-owned (`data-cc-*`) vs page-owned (`data-<prefix>-*`); §13 gains closed-set table |
| 8 | Argument attribute prefix | Args carry parent action's prefix. Drift: `ARGUMENT_PREFIX_MISMATCH` |
| 9 | Action value dispatch resolution | §7.2 sufficient as-is; no spec change |
| 10 | Overlay construct structure | Nested for all three; one purpose comment per construct above outer element; unified `cc-dialog-*` internal class family; "overlay" terminology universal |
| 11 | Overlay contiguous-block scope | Only whitespace + purpose comments between constructs; internal order author's choice. Drift: `OVERLAY_BLOCK_NON_CONTIGUOUS` |
| 12 | Helper definition | Helper = function in `xFACts-CCShared.psm1`; route files emit HTML inline only |
| 12.1 | Route-local helper functions | Forbidden. Drift: `FORBIDDEN_ROUTE_LOCAL_HELPER` |
| 13 | Helper-emitted IDs | §5.1 closed set is authoritative for all chrome IDs including helper-emitted. Drift: `HELPER_EMITS_UNREGISTERED_ID` |
| 14 | Substitution variable contract | Mandated names + mandated helper sources for `$browserTitle`, `$navHtml`, `$headerHtml` |
| 15 | Section dividers and inline annotations | Author's choice outside mandated positions; overlay block carve-out stands |
| 16 | Distinct actions vs discriminator args | Both patterns valid; author's choice on design |
| 17 | Action attributes on non-interactive elements | Restricted to interactive elements + closed carve-out for three overlay container classes. Drift: `ACTION_ON_NON_INTERACTIVE_ELEMENT` |

---

## End-of-session spec amendments

Four additional drift codes added to spec §14 after the 17 gap resolutions, resulting from the populator analysis surfacing real-world conditions that the spec was silent on:

| Code | Rule | Why |
|---|---|---|
| `ENGINE_SLUG_REGISTRY_MISMATCH` | §2.3 | Engine card on a page whose slug isn't in `ProcessRegistry`. Catches broken cards. |
| `MISSING_ENGINE_CARD_REGISTRATION` | §2.3 | `ProcessRegistry` row exists but has NULL data. Catches incomplete registry entries. |
| `MISSING_SHARED_SCRIPT_TAG` | §3.2 | Page has no `<script>` tag at all. Catches page-can't-function-at-all case. |
| `UNEXPECTED_SCRIPT_TAG` | §3.2 | More than one `<script>` tag. Catches duplicated references. |

All four were retired codes in the alignment plan's first pass; they're retained in the second pass after spec amendments restored them.

---

## Working principles reinforced this session

Several principles were stated explicitly and need to carry forward.

### The spec is authoritative; code conforms to it

Files that drift from the spec are rewritten to match. The spec is never amended to accommodate existing code. Earlier-spec drift in deployed files (Backup, Admin) is expected and addressed by the rewrite passes, not by retroactive spec relaxation.

### One right way per construct

Where the audit found multiple valid patterns for the same goal, the resolution chose one. Some resolutions (Gap 16) admitted multiple patterns where the choice was a real application-design question outside the spec's scope, but where the question was "how should this construct look in spec-conformant markup," the spec settled on a single answer.

### Rules, not rationale

The spec is rules-only. Definitional intro sentences are allowed where they make rules interpretable. Explanatory text on WHY a rule exists belongs in working docs and session summaries, not in the spec. Comments in source files do NOT reference the spec; spec authority is implicit.

### No spec references in source files. ASCII only.

Two related rules established late in this session:

- Source file comments do not reference the spec. The spec is the source of truth; comments describe what the code does, not which spec rule it enforces. This applies to all source files in the platform — PowerShell, JavaScript, CSS, HTML inside route ScriptBlocks — and going forward, to anything new.
- Source files contain ASCII characters only. The `§` symbol specifically is non-ASCII UTF-8 and causes GitHub to misidentify the file as binary, making it non-fetchable via `web_fetch` and `raw.githubusercontent.com`. This was a recurring operational problem and is now structurally prohibited. Working documentation (`.md` files) is exempt — `§` is acceptable there.

### One thing at a time

Decisions were made one at a time throughout the session. Each gap was raised individually, options stated, decision locked, then next gap. Bundled questions are easier for the assistant to write but harder for the user to evaluate; the one-at-a-time rhythm produces better decisions. This continues to be the working pattern.

### Surfacing trouble spots honestly

Where implementations are non-trivial or risky, the analysis flags them with options and recommendations. The trouble spots in alignment plan §6 (whitespace-discipline implementation, coordinated CSS dependencies, expected drift on Backup) are real concerns that the next session needs to be aware of, not artifacts of overcautious analysis.

---

## Next session focus

### Primary deliverables

1. **HTML populator rewrite** (`Populate-AssetRegistry-HTML.ps1`). Full drop-in replacement aligned to the new spec per the alignment plan. The plan's §7 provides the recommended sequence. ~5,500 lines of populator code with substantial rewriting in the overlay validation section and additions for ~11 new validators.

2. **Backup partial rewrite — Path 1** (`Backup.ps1`). Brings Backup to Category-A compliance against the new spec for everything that DOESN'T depend on the `cc-shared.css` coordinated rewrite. This includes: page-shell whitespace and attribute order, body class structure, substitution variable assignments per Gap 14, action value prefixing per Gap 8, argument attribute prefix matching per Gap 8, action element restrictions per Gap 17, ASCII-only cleanup, and removal of any spec-section comment references. The overlay constructs in Backup CANNOT be rewritten in this session because that requires `cc-shared.css` to carry the new unified `cc-dialog-*` class family. Backup will continue to carry known drift on its overlay constructs until the cross-file refactor initiative addresses cc-shared.css.

### Session boot sequence

1. Fetch the manifest URL with a fresh cache-buster (`https://raw.githubusercontent.com/tnjazzgrass/xFACts/main/manifest.json?v=<random>`).
2. Fetch the current `Populate-AssetRegistry-HTML.ps1` via the manifest.
3. Fetch `Backup.ps1`.
4. Fetch `xFACts-AssetRegistryFunctions.ps1` (confirm no shared infrastructure changes are needed for the new validators).
5. Confirm `CC_HTML_Spec.md` (new) and `CC_HTML_Populator_Alignment_Plan.md` are in Project Knowledge.

### Entry-point principle

Read the alignment plan before reading the populator. The plan's structure map (§1) tells you where the work is so you can navigate the 5,500-line populator efficiently. Do not start by reading the populator front-to-back.

### Open questions to resolve before populator work — NONE

This was a deliberate effort in the closing rounds of this session. All section-9 open questions from the alignment plan's first draft were resolved this session:

- HTML populator owns the variable-assignment check (no PS populator coordination needed).
- ASCII-only and no-spec-references rules are locked in.
- Engine card registry-validation codes stay in the populator (added to spec §14).
- Script tag count codes stay in the populator (added to spec §14).
- `MALFORMED_PAGE_SHELL_WHITESPACE` is implemented as planned (no relaxation).

Next session opens with: spec is locked, alignment plan is the roadmap, no decisions blocking implementation work.

---

## Cross-file refactor initiative — current standing

Session 7 §9.2 established the cross-file refactor initiative as the home for coordinated changes touching CSS + JS + HTML simultaneously. This session adds material to that bucket.

**Currently parked in the initiative:**

- `cc-shared.css` rewrite to migrate `cc-modal-*` and `cc-slide-panel-*` separate families to the unified `cc-dialog-*` family from Gap 10. This is the largest pending item. Touches every overlay-using page; coordinates with `cc-shared.js` overlay click-handler logic; required before Backup's overlay constructs can be rewritten to Category-A compliance.
- Helper module audit. Confirm `xFACts-CCShared.psm1` emits only chrome IDs from the closed set in spec §5.1.

**Not parked in this initiative (handled by next session):**

- HTML populator rewrite (this session's alignment plan covers it).
- Backup Category-A compliance for non-overlay constructs (Path 1 — same session as populator).

---

## Backlog items added this session

### `xFACts_Development_Guidelines.md` updates needed

Two rules established this session should be codified in the Development Guidelines so they propagate platform-wide:

- No spec references in source files. The spec is the source of truth; comments describe what the code does.
- Source files are ASCII only. Specifically, the `§` symbol is prohibited because it breaks GitHub's text-file detection.

This is a future session's work, not blocking on populator alignment.

### Other populators have similar cleanup pending

`Populate-AssetRegistry-CSS.ps1`, `Populate-AssetRegistry-JS.ps1`, and `Populate-AssetRegistry-PS.ps1` likely contain `§` symbols and spec-section comment references. Not a forced sweep — cleaned up the next time each file is touched for substantive work.

---

## Files created this session

- `/mnt/user-data/outputs/CC_HTML_Spec.md` — rewritten spec, ready to commit to repo
- `/mnt/user-data/outputs/CC_HTML_Populator_Alignment_Plan.md` — populator rewrite cheat-sheet for next session
- `/mnt/user-data/outputs/CC_Session_Summary_8.md` — this document

Old `CC_HTML_Spec.md` should be moved to `xFACts-Documentation/Planning/WorkingFiles/Old_HTML_Spec_v7.md` (or similar archival path) before the new spec lands at `xFACts-Documentation/Planning/CC_HTML_Spec.md`. Same archival pattern as the CSS spec.

The alignment plan lives at `xFACts-Documentation/Planning/CC_HTML_Populator_Alignment_Plan.md` and is consumed by next session, then archived after the populator rewrite completes.
