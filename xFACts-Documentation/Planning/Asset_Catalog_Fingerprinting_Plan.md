# Asset Catalog Fingerprinting & Shared-Function Consolidation Plan

**Status:** Planning / working document (temporary; not retained after implementation)
**Scope (initial):** PowerShell (`PS`) functions. Extends to any like-typed asset
(CSS classes, JS literals/functions, HTML structures) once proven on PS.
**Authoritative anchor for:** the "promotion to shared" / chrome-streamlining
initiative for the standalone PowerShell zone, and the extract-vs-helper-vs-local
standard that comes out of it.

---

## 1. Problem statement

Asset_Registry is meant to be a comprehensive catalog of *what exists* across every
xFACts file, so that duplication and inconsistency can be surfaced and the files
streamlined (shared chrome for CSS/JS, shared function helpers for PS) instead of
every page/script carrying its own one-off declarations.

The catalog cannot currently surface "promotion to shared" candidates reliably,
for two reasons:

1. **Name-based search requires already knowing the name.** Finding the eight
   copies of `AGReplicaRoles` required a `LIKE '%AGReplicaRoles%'` query with a
   mid-string wildcard - i.e. the stem had to be known in advance. There is no way
   to ask "show me everything that is duplicated" without already knowing what to
   look for.

2. **Prefixing has been used to silence duplicate-function drift.** During the
   spec-conformance refactor, colliding functions were given unique names
   (module prefix, and in BatchOps a per-lane designator) to clear
   `DUPLICATE_FUNCTION_DEFINITION`. That clears the drift but, for *true*
   duplicates, hides the correlation: the catalog's own duplicate signal goes
   quiet even though the duplication still exists.

The duplication is real and systemic (see Section 2 evidence), and - critically -
it is **near-duplicate drift, not byte-identical copy-paste.** A naive exact match
would under-report it badly.

---

## 2. Evidence gathered (this session)

All figures are real query/sample results, not estimates.

### 2.1 BatchOps function inventory (Query 1, four files)

The four BatchOps scripts (`Collect-NBBatchStatus`, `Collect-PMTBatchStatus`,
`Collect-BDLBatchStatus`, `Send-OpenBatchSummary`) share a skeleton of parallel
per-lane helpers. Stems that repeat across lanes:

| Stem (lane stripped) | Copies | Distinct signatures | Min lines | Max lines |
|---|---|---|---|---|
| `Get-AGReplicaRoles` | 4 | 4 | 29 | 44 |
| `Get-SourceData` | 4 | 4 | 17 | 19 |
| `Initialize-Configuration` | 4 | 4 | 68 | 137 |
| `Step-EvaluateAlerts` | 3 | 3 | 217 | 1209 |
| `Step-UpdateIncompleteBatches` | 2 | 2 | 238 | 293 |
| `Step-UpdateStatus` | 2 | 2 | 28 | 28 |
| `Step-CollectNewBatches` | 2 | 2 | 195 | 196 |
| `Get-StallDurationText` | 2 | 2 | 9 | 11 |

### 2.2 Key reading of the evidence

- **Line-count spread on every cluster** (e.g. AGReplicaRoles 29-44,
  Configuration 68-137) proves these are **not** byte-identical. They are
  variations on a theme - same operation, drifted implementations / different
  coupling. An *exact* hash would put them in different buckets and report zero
  duplicates.
- **A few pairs are near-identical** and are the cheapest exact wins:
  `Step-UpdateStatus` (28/28) and `Step-CollectNewBatches` (195/196).
- **`AGReplicaRoles` crosses module boundaries** (Query 3): it appears in
  BatchOps, ServerOps.DBCC, JobFlow, and DeptOps.BusinessServices - so it is a
  **platform**-tier duplicate, while most of the BatchOps cluster stays inside
  BatchOps (**module**-tier). One module demonstrates both tiers at once.

### 2.3 Fingerprint proof-of-method (this session, on real bodies)

Two `AGReplicaRoles` bodies were fingerprinted in a scratch environment: the bare
`Get-AGReplicaRoles` from `Monitor-JobFlow.ps1` (44 lines, `$Script:Config.AGName`,
no `param()`) and the refactored `Get-bat_NB_AGReplicaRoles` from
`Collect-NBBatchStatus.ps1` (prefixed, lowercase `$script:`, with empty `param()`).

- **Exact, whitespace-normalized hash:** did NOT match (different SQL whitespace,
  scope casing, `param()`).
- **Naive shape hash (identifiers/literals normalized):** did NOT match - solely
  because the NB version has an empty `param()` line and the JobFlow version does
  not.
- **Spec-aware shape hash (empty `param()` and `[CmdletBinding()]` stripped before
  hashing):** **MATCHED** (identical hash). The prefix, the lane, the scope
  casing, and the SQL whitespace all normalized away.

This produced the three findings in Section 3.

---

## 3. Proven findings (drive the design)

1. **Viability: confirmed.** Catalog metadata (module, file, signature, line span)
   plus a body fingerprint identifies duplicates and their scope without parsing
   whole files and without knowing function names in advance.

2. **Prefixing does not cloud the fingerprint - do NOT strip prefixes to "fix" it.**
   The fingerprint reads behavior, not names; the declaration line (and thus the
   prefix/lane) is dropped before hashing. Module prefixes (`bat`, `dbc`, `bid`,
   `jbm`, ...) and lane designators are invisible to it. Un-prefixing would only
   re-introduce runtime `DUPLICATE_FUNCTION_DEFINITION` collisions for zero
   analytical gain.

3. **The normalization MUST be spec-aware (the non-obvious requirement).** It must
   canonicalize away spec-conformance scaffolding - empty `param()`,
   `[CmdletBinding()]`, docblocks, single-line purpose comments, trailing-comment
   placement - so that a function hashes identically before and after refactor.
   **Corollary (monotonicity):** a naive fingerprint gets *worse* as we refactor,
   because refactoring adds scaffolding a naive hash treats as difference, so the
   duplicate set would shrink artificially. Only a spec-aware fingerprint is
   stable across the refactor and trustworthy.

---

## 4. Design: two fingerprints

Two complementary hashes, both computed by the populator at parse time and stored
on the function's Asset_Registry row.

### 4.1 `body_hash` - exact (build first; quick win)

Normalize whitespace and strip comments + declaration line, then hash. Catches
true copy-paste duplicates (e.g. the 28/28 `Step-UpdateStatus` pair). Cheap,
unambiguous, low risk. Ships first as an immediate win.

### 4.2 `shape_hash` - structural skeleton (primary deliverable)

Spec-aware normalization, then hash:

1. Drop the `function <name>` declaration line (prefix/lane-proof).
2. Drop docblocks and `#` purpose/section comments.
3. **Strip spec-conformance scaffolding:** empty `param()`, `[CmdletBinding(...)]`.
4. Collapse whitespace.
5. Blank out string / here-string / numeric literals -> tokens (`STR`, `N`).
6. Normalize `$variable` identifiers -> `VAR`.
7. Hash the result.

This is the tool that matches the **near-duplicate drift** that actually exists in
the codebase (Section 2.2). It is **candidate-surfacing, human-confirmed** - never
an autonomous "merge these" trigger. It favors recall: surface everything worth a
human look.

### 4.3 Open design question: normalization aggressiveness

Too loose -> everything collapses to "function that calls Get-SqlData and returns."
Too tight -> drift defeats it. The exact rule set (e.g. does positional variable
order matter? are comparison operators normalized?) needs tuning against a broader
sample. **Decide in implementation, not now.** The proof-of-method normalization in
Section 2.3 is a starting point, not the final spec.

---

## 5. The tier-routing standard

Once functions carry fingerprints, consolidation routing is computed from the
catalog, not judged by hand.

### 5.1 Core rule

1. **Group by fingerprint** (`shape_hash` for candidates; confirm with `body_hash`
   and human review).
2. For each multi-member cluster, compute **`COUNT(DISTINCT module)`** from the
   existing module/component classification.
3. Route by **module spread** (NOT file count):

   | Module spread | Tier | Home |
   |---|---|---|
   | Spans > 1 module | **Platform** | platform shared layer (`xFACts-OrchestratorFunctions.ps1`) |
   | Exactly 1 module, > 1 file | **Module** | that module's helper file (e.g. `xFACts-DmOpsFunctions.ps1`) |
   | 1 file (or appears once) | **Local** | stays where it is |

### 5.2 Tier is determined by module spread, not file count

A duplicate shared between two *singleton* modules (one script each) is still
**platform** - because no single module owns it. The singletons refactored this
session (ServerOps.Replication, ServerOps.DBCC, BIDATA, JBoss) can therefore hold
platform duplicates even though each module has one file. (`AGReplicaRoles` in
DBCC is exactly this case.)

### 5.3 Prefixing is not a tier

Module prefixing is the **false-positive de-collision tactic** for genuinely
different code that happens to share a name. It is never the resolution for a true
duplicate. Using a prefix (or lane) to silence drift on a real duplicate is the
anti-pattern this initiative corrects.

### 5.4 Lane-designator corollary

Lane designators (`_NB_`, `_PMT_`, `_BDL_`, `_OBS_`) were added in BatchOps to
clear collisions. Post-consolidation they are resolved **per-function**, by the
same machinery:

- **Same across lanes** (fingerprint match) -> the lane masked a duplicate ->
  consolidate to one module-prefixed function in the module helper; **lane
  dissolves** (e.g. `Get-bat_AGReplicaRoles`).
- **Different across lanes, unique bare name** -> **strip the lane**; it was
  redundant (the catalog already records `file_name`). No collision results.
- **Different across lanes AND collides on bare name** -> **keep the lane**; it is
  doing real collision-avoidance for genuinely distinct code (candidate:
  `Step-bat_*_UpdateStatus`).

**Principle to enshrine:** a lane designator is justified only by an actual
same-name collision against genuinely different code. If stripping it produces no
collision, it was redundant and should go. Never use a lane to disguise a
duplicate.

### 5.5 Watch item: parent-module tier

`component_name` encodes a parent (e.g. `ServerOps.DBCC`, `ServerOps.Replication`).
A duplicate spanning two sub-modules of one parent *might* warrant a parent-module
helper rather than full platform promotion. Do **not** pre-build this tier; watch
for it in the data and decide if it earns its place.

---

## 6. Module-helper-per-module as the standard

The likely standard: **when multiple scripts in a module share a function, that
function moves to a module-scoped helper file**, rather than per-script local
copies (inconsistent) or blanket platform promotion (wrong for module-specific
behavior).

This **ratifies existing precedent** rather than inventing anything:

- `xFACts-IndexFunctions.ps1` (ServerOps.Index) - the original module helper.
- `xFACts-AssetRegistryFunctions.ps1` (Tools.Utilities) - the populators' helper.
- `xFACts-DmOpsFunctions.ps1` (DmOps) - the most recent.

Three working precedents establish the pattern. The only module that took the
prefix-only path instead is **BatchOps** - so adopting this standard requires
**one retrofit (BatchOps), not wholesale backtracking.**

**Cost acknowledged:** each helper is another file to catalog, load (dot-source
order), and keep in sync. The tier rule keeps this honest - a helper is justified
by cluster size (the catalog measures it); a single 3-line duplicate between two
files may not earn a whole helper file.

**Open item for session 1:** confirm how the existing helpers are registered
(component, `cc_prefix` vs NULL) against the Platform Registry, so any *new*
module helper is built spec-consistently (does a new helper's functions carry the
module prefix, or is the helper a NULL-prefix shared-library-style component?).
Use DmOps/Index/AssetRegistry as the templates.

---

## 7. Consequences for already-refactored files

- The four singletons refactored this session (ReplicationHealth, DBCC,
  BIDATABuild, JBoss) are now **prefix-disguised**. Their bodies are unchanged
  (functional equivalence was verified at refactor time), so the fingerprint will
  surface their platform duplicates automatically - **but they must be included in
  the fingerprint re-pass**; they are not exempt just because format conformance is
  done.
- Prefixing-ahead-of-fingerprinting did **not** hide duplicates (the hash sees
  through prefixes). Its only cost: at consolidation, a prefixed local copy gets
  **replaced by a call to the extracted shared function** - an edit consolidation
  would require anyway. No extra re-pass was created by prefixing.
- **Do not reverse any prefixing or lane designation pre-emptively.** Lanes are
  resolved per-function at consolidation per Section 5.4.

---

## 8. Sequenced implementation plan

**Session 1 (next) - build the capability, no file refactors expected:**

1. Read the populator pair (`Populate-AssetRegistry-PS.ps1`,
   `xFACts-AssetRegistryFunctions.ps1`) and `xFACts_Development_Guidelines.md` +
   `xFACts_Platform_Registry.md`. Ground all schema/registration specifics in
   source - do not assume column names or types.
2. Design the Asset_Registry schema change: `body_hash` (exact) and `shape_hash`
   (spec-aware structural). Confirm column names/types against the real table and
   the Development Guidelines before any DDL (per standing rule: validate new DB
   objects against guidelines; DDL one object at a time).
3. Implement `body_hash` in the populator first (quick win).
4. Implement and tune `shape_hash` normalization (Section 4.2/4.3) against a
   broader sample.
5. Re-run the populator across the PS zone to stamp fingerprints.

**Session 2+ - route and consolidate:**

6. Run the grouping query: group by fingerprint -> `COUNT(DISTINCT module)` ->
   tiered duplicate worklist (platform / module / local), every cluster routed
   automatically.
7. Confirm module-helper registration mechanics; write the tier-routing standard
   (Sections 5 & 6) into `xFACts_Development_Guidelines.md` once methodology is
   locked.
8. **Pilot consolidations** (prove both routes):
   - **Platform pilot: `AGReplicaRoles`.** Confirm behavioral equivalence of the
     variants first (29 vs 44 lines - the BDL copy may be a trimmed variant; pick
     the canonical full implementation), parameterize as needed (the DBCC variant
     already takes `[String]$AGName`), extract to the platform shared layer,
     replace all local/prefixed copies with calls.
   - **Module pilot: a BatchOps cluster** (e.g. `Get-SourceData` or
     `Initialize-Configuration`). Extract to a new BatchOps module helper; resolve
     lanes per Section 5.4.
9. Resume the remaining ~20 standalone refactors **with the catalog routing each
   duplicate** - so multi-script modules get their helper extractions instead of
   prefix-disguised local copies.

**Why this order:** the next standalones are multi-script modules (high likelihood
of module-scoped clusters). Refactoring them prefix-first would create exactly the
BatchOps-style mess we are about to formalize a fix for. Building the fingerprint
first lets the catalog tell us the tier before we touch those files.

---

## 9. Scope extension (post-PS)

The same two-hash approach generalizes to any like-typed asset the populator already
catalogs: CSS class/declaration bodies, JS function/literal bodies, HTML structural
blocks. The normalization rules differ per type (CSS has no `param()`; JS has its
own scaffolding), but the model - exact hash + structural hash, group, route by
spread - is identical. PS is the proving ground; generalize once the PS loop is
proven end-to-end.

---

## 10. Open questions parked for session 1 (do not invent answers)

- Exact Asset_Registry schema change (column names, types, nullability).
- Populator integration point (where in the parse the hashes are computed/stored).
- `shape_hash` normalization aggressiveness (final rule set + tuning sample).
- Module-helper registration (component classification, `cc_prefix` vs NULL) for
  new helpers, grounded against the Platform Registry and existing helpers.
- Whether the parent-module tier (5.5) is needed (data-driven; defer).
