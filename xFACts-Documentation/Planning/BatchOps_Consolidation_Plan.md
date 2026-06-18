# BatchOps Consolidation Plan

Anchor doc for two related-but-separable pieces of work, both driven by the
Asset_Registry function fingerprints (shape_hash / body_hash):

1. **AGReplicaRoles platform lift** — extract eight duplicate copies of the
   AG-replica-role lookup (spread across BatchOps, BS-review, DBCC, JobFlow)
   into a single parameterized function in `xFACts-OrchestratorFunctions.ps1`.
   This is platform-tier infrastructure, NOT BatchOps-local.
2. **BatchOps helper** — stand up the first `xFACts-BatchOpsFunctions.ps1`
   helper and extract the genuinely-shared BatchOps-local duplication that was
   previously "papered over" by prefixing copies apart (`bat_BDL`, `bat_NB`,
   etc.) rather than actually sharing them.

Both follow the established principles: spec is sole authority; behavior
preservation outranks drift reduction; full-file or full-function delivery,
verified by structural diff + brace balance + byte discipline before delivery;
fingerprints are descriptive, the values-vs-logic rule decides.

Leave no drift: every duplicate identified here is either extracted, or
consciously retained with a stated reason (the stubs and singletons below).

---

## PART 1 — AGReplicaRoles platform lift (Orchestrator tier)

### Why this is platform-tier, not BatchOps
The AG-replica-role lookup is defined **eight times across four components**.
Folding it into a BatchOps helper would fix three copies and strand the other
five — recreating the same duplication one level up. The correct home is
`xFACts-OrchestratorFunctions.ps1`, alongside `Get-SqlData` and `Write-Log`,
which it calls. That file is dot-sourced by every standalone script, so the
lifted function is immediately available everywhere with no new dot-source line.

This was the original proof-of-concept case for the fingerprinting effort.

### The eight copies

| File | Function name | Registered prefix | shape_hash | body_hash | Reads AGName via |
|---|---|---|---|---|---|
| Collect-BSReviewRequests.ps1 | `Get-AGReplicaRoles` | bsv | c5d13901 | 33ea71b2 | `$Script:Config.AGName` |
| Distribute-BSReviewRequests.ps1 | `Get-AGReplicaRoles` | bsv | 2f23c598 | 8ebb60f1 | `$Script:Config.AGName` |
| Monitor-JobFlow.ps1 | `Get-AGReplicaRoles` | jfm | c5d13901 | 9ec206c8 | `$Script:Config.AGName` |
| Collect-BDLBatchStatus.ps1 | `Get-bat_BDL_AGReplicaRoles` | bat | 2f23c598 | 3d210269 | `$script:Config.AGName` |
| Collect-NBBatchStatus.ps1 | `Get-bat_NB_AGReplicaRoles` | bat | c5d13901 | 7854a6cc | `$script:Config.AGName` |
| Send-OpenBatchSummary.ps1 | `Get-bat_OBS_AGReplicaRoles` | bat | c5d13901 | 7854a6cc | `$script:Config.AGName` |
| Collect-PMTBatchStatus.ps1 | `Get-bat_PMT_AGReplicaRoles` | bat | c5d13901 | 7854a6cc | `$script:Config.AGName` |
| Execute-DBCC.ps1 | `Get-dbc_AGReplicaRoles` | dbc | 531b858b | 5e52beeb | `-AGName` parameter |

Six distinct body hashes, but every difference is cosmetic — whitespace, brace
style, an error-message string, or a docblock. The SQL query, the
roles-hashtable construction, and the PRIMARY/SECONDARY assignment loop are
identical in all eight. There are **no logic divergences** anywhere in the set.
By the values-vs-logic rule this is a clean lift of all eight into one function.

### Design decision: parameterize `-AGName` (confirmed)
Seven copies read `$Script:Config.AGName` from script scope — a hidden coupling
that only works if the caller populated that script-scoped variable first. The
DBCC copy already broke that pattern by taking `-AGName` explicitly. For a
platform-tier function called by many unrelated components, the parameterized
form is correct: the shared function must not silently depend on a
`$Script:Config` it does not own.

**Canonical lifted function:**
```
# Resolves current PRIMARY and SECONDARY replica servers for an availability group.
function Get-AGReplicaRoles {
    param([string]$AGName)
    ...
}
```
Lives in `xFACts-OrchestratorFunctions.ps1`. Calls `Get-SqlData` and `Write-Log`
as same-file siblings (no scope risk — confirmed those are defined in that file
and dot-sourced into every script). Fully self-contained: string in, hashtable
out, no `$Script:Config` dependency.

Exact section banner / purpose-comment / placement to be determined against
`xFACts_PS_Spec.md` at build time (OrchestratorFunctions is the platform-tier
file — confirm whether its functions carry CmdletBinding+docblock per spec 8.3
or single-line comments; match whatever the existing functions in that file
already do, since the spec tier follows the file).

### Caller rewrites (all eight)

Script-scope callers — change bare call to pass the AG name explicitly:

| File | Old call site | New call |
|---|---|---|
| Collect-BSReviewRequests.ps1 | `Get-AGReplicaRoles` (in Initialize-Configuration) | `Get-AGReplicaRoles -AGName $Script:Config.AGName` |
| Distribute-BSReviewRequests.ps1 | `Get-AGReplicaRoles` (in Initialize-Configuration) | `Get-AGReplicaRoles -AGName $Script:Config.AGName` |
| Monitor-JobFlow.ps1 | `Get-AGReplicaRoles` (in Initialize-Configuration) | `Get-AGReplicaRoles -AGName $Script:Config.AGName` |
| Collect-BDLBatchStatus.ps1 | `Get-bat_BDL_AGReplicaRoles` (in Initialize-bat_BDL_Configuration) | `Get-AGReplicaRoles -AGName $script:Config.AGName` |
| Collect-NBBatchStatus.ps1 | `Get-bat_NB_AGReplicaRoles` (in Initialize-bat_NB_Configuration) | `Get-AGReplicaRoles -AGName $script:Config.AGName` |
| Send-OpenBatchSummary.ps1 | `Get-bat_OBS_AGReplicaRoles` (in Initialize-bat_OBS_Configuration) | `Get-AGReplicaRoles -AGName $script:Config.AGName` |
| Collect-PMTBatchStatus.ps1 | `Get-bat_PMT_AGReplicaRoles` (in Initialize-bat_PMT_Configuration) | `Get-AGReplicaRoles -AGName $script:Config.AGName` |
| Execute-DBCC.ps1 | `Get-dbc_AGReplicaRoles -AGName $Config.AGName` (in Resolve-dbc_ConnectionTarget) | `Get-AGReplicaRoles -AGName $Config.AGName` (barely changes — drops prefix) |

Then delete all eight local definitions.

### Bonus finding: this clears live collision drift
The three BS-review-family files (`Collect-BSReviewRequests`,
`Distribute-BSReviewRequests`, `Monitor-JobFlow`) define a bare, un-prefixed
`Get-AGReplicaRoles` and the catalog flags all three with
`DUPLICATE_FUNCTION_DEFINITION` against each other — same name, same zone,
resolves unpredictably at runtime. These were never even prefixed-apart. The
lift deletes all three local defs and the shared Orchestrator function resolves
the collision permanently. (Those three files also carry other drift —
PREFIX_MISSING, MISSING_SECTION_BANNER, MISSING_PARAM_BLOCK, and Monitor-JobFlow
a FORBIDDEN_DOCBLOCK_IN_STANDALONE — which is separate conformance work on those
files, noted but not in scope for the lift itself beyond removing the function.)

### Net for Part 1
8 local definitions removed; 1 shared parameterized function added to
`xFACts-OrchestratorFunctions.ps1`; 8 call sites rewritten. After this,
BatchOps does NOT define or hold an AGReplicaRoles function anywhere — it
consumes the Orchestrator one like every other component.

---

## PART 2 — BatchOps helper (`xFACts-BatchOpsFunctions.ps1`)

### Scope
BatchOps has no helper today. Its cross-file duplicate functions were made
spec-legal by prefixing copies apart (`bat_BDL_`, `bat_NB_`, `bat_PMT_`,
`bat_OBS_`), which cleared DUPLICATE_FUNCTION_DEFINITION but left the same logic
living in N copies. This part stands up the first BatchOps helper and extracts
what is genuinely shared.

The four BatchOps files:
`Collect-BDLBatchStatus.ps1`, `Collect-NBBatchStatus.ps1`,
`Collect-PMTBatchStatus.ps1`, `Send-OpenBatchSummary.ps1`.

### Helper loading / scope (prerequisite to confirm at build)
Follow the established pattern: the new `xFACts-BatchOpsFunctions.ps1`
dot-sources `xFACts-OrchestratorFunctions.ps1` at its top (prior art:
`xFACts-IndexFunctions.ps1`, `xFACts-AssetRegistryFunctions.ps1`). Each of the
four BatchOps scripts then dot-sources the BatchOps helper instead of
OrchestratorFunctions directly; the chain delivers Initialize-XFActsScript /
Write-Log / Get-SqlData transparently into the script's scope.

The extracted functions below reference script-scoped state
(`$script:Config`, `$script:ReadServer`, `$script:PollingIntervalMinutes`) and
ambient functions (`Write-Log`, `Get-SqlData`, `Invoke-Sqlcmd`). Because the
helper is dot-sourced into the calling script's scope (not imported as a module
with its own scope), those `$script:` references continue to bind to the
caller's variables. Confirm this dot-source-into-scope wiring before extraction
— it is what makes the extraction behavior-preserving.

### The extractions (genuinely shared — identical body or value-only diff)

**1. `Get-bat_SourceData` — 3 copies collapse to 1**
Source rows: `Get-bat_BDL_SourceData`, `Get-bat_NB_SourceData`,
`Get-bat_PMT_SourceData`. Same shape (03007a9a) AND byte-identical body
(0c9e55e9) across all three. The only between-copy difference is the `-Timeout`
default in the param block (120 / 60 / 60), which is a parameter default, not
body logic — hence the identical body hash.

NOTE: `Get-bat_OBS_SourceData` (Send-OpenBatchSummary) shares the shape family
but has a different body (48146125, shape 1a7820b1): it omits
`-SuppressProviderContextWarning` and uses timeout 300. Look at it during the
build — if the only differences are the timeout default (parameterizable) and
the suppress-warning switch, fold it in (possibly via a switch parameter or by
standardizing the call). If folding it in would require logic branching, leave
OBS's copy local and extract only the three identical ones. Decide against the
real bytes, not from this summary.

Callers to rewrite (each keeps its existing `-Timeout`/`-Query` arguments;
only the function name changes to `Get-bat_SourceData`):
- BDL: `Get-bat_BDL_SourceData` x8 call sites (CollectNewFiles x1,
  UpdateIncompleteFiles x6, plus the AG-detection path already handled in Part 1)
  — actual `_SourceData` call sites per catalog: CollectNewFiles (1),
  UpdateIncompleteFiles (6) = 7
- NB: `Get-bat_NB_SourceData` call sites: CollectNewBatches (1),
  UpdateIncompleteBatches (2), DetectOrphanedBatches (1), EvaluateAlerts (2) = 6
- PMT: `Get-bat_PMT_SourceData` call sites: CollectNewBatches (1),
  UpdateIncompleteBatches (3) = 4
- OBS: only if folded in — OpenNBBatches (1), OpenPMTBatches (1) = 2
(Confirm exact counts against the catalog usage rows at build; the structural
diff will catch any missed site as an orphaned call.)

**2. `Get-bat_StallDurationText` — 2 copies collapse to 1**
Source rows: `Get-bat_BDL_StallDurationText`, `Get-bat_NB_StallDurationText`.
Same shape (0873ff90) AND byte-identical body (7ced081a). Reads
`$script:PollingIntervalMinutes`, takes `-PollCount`, returns a string. Straight
lift, zero reconciliation.
Callers: BDL EvaluateAlerts (1), NB EvaluateAlerts (2) = 3 call sites.

**3. `Set-bat_BatchStatus` — 2 copies collapse to 1 (value-only diff)**
Source rows: `Step-bat_NB_UpdateStatus`, `Step-bat_PMT_UpdateStatus`. Same shape
(04332e05), DIFFERENT bodies (48376f47 / 5c7d1802) — but the only difference is
a literal string in the WHERE clause: `'Collect-NBBatchStatus'` vs
`'Collect-PMTBatchStatus'`. That difference is a VALUE, so this is extractable
despite the body-hash mismatch (body-identical is sufficient for "extract" but
not necessary; a shape match with only a value differing also qualifies).
Parameterize the collector name:
```
# Marks the BatchOps.Status row for a collector as IDLE with run outcome.
function Set-bat_BatchStatus {
    param(
        [string]$CollectorName,
        [bool]$PreviewOnly = $true,
        [string]$Status = "SUCCESS",
        [int]$DurationMs = 0
    )
    ...  # WHERE collector_name = '$CollectorName'
}
```
Verb note: the source functions use `Step-` (a non-standard verb that exists in
the BatchOps step-function convention). For a shared status-writer, `Set-` is
the approved verb and better describes it. Confirm verb choice against Get-Verb
and the spec's approved-verb handling at build.
Callers to rewrite:
- NB execution: `Step-bat_NB_UpdateStatus -PreviewOnly $previewOnly -Status $finalStatus -DurationMs $totalMs`
  -> `Set-bat_BatchStatus -CollectorName 'Collect-NBBatchStatus' -PreviewOnly $previewOnly -Status $finalStatus -DurationMs $totalMs`
- PMT execution: same shape, `-CollectorName 'Collect-PMTBatchStatus'`
(Only NB and PMT have this function — BDL and OBS do not, confirmed from catalog.)

### Consciously retained — NOT extracted (stated reasons)

**Stubs (keep local, OBS):** `Get-bat_OBS_ActiveNoticeProcessing` and
`Get-bat_OBS_OpenBDLImports` share shape 0fa38a2c but have different bodies.
Both are tiny placeholder functions returning a `[PSCustomObject]` with
`NotMonitored = $true`, differing by the `BatchType` string. They are
intentional distinct stubs that will diverge when real monitoring is
implemented. Merging them would be pointless. Retain.

**Singletons (keep local — unique shape, one-of-a-kind logic):**
- `Get-bat_OBS_OpenNBBatches`, `Get-bat_OBS_OpenPMTBatches` (distinct queries)
- `New-bat_OBS_AdaptiveCard`, `New-bat_OBS_SectionElements` (OBS card builders)
- `Step-bat_BDL_CollectNewFiles`, `Step-bat_BDL_UpdateIncompleteFiles`,
  `Step-bat_BDL_EvaluateAlerts`
- `Step-bat_NB_CollectNewBatches`, `Step-bat_NB_UpdateIncompleteBatches`,
  `Step-bat_NB_DetectOrphanedBatches`, `Step-bat_NB_EvaluateAlerts`
- `Step-bat_PMT_CollectNewBatches`, `Step-bat_PMT_UpdateIncompleteBatches`,
  `Step-bat_PMT_EvaluateAlerts`
- `Initialize-bat_BDL_Configuration`, `Initialize-bat_NB_Configuration`,
  `Initialize-bat_OBS_Configuration`, `Initialize-bat_PMT_Configuration`

On the four `Initialize-*Configuration` functions specifically: they look
superficially alike (all load GlobalConfig, all detect AG roles) but each has a
different config-key set and different defaults — logic and data diverging
together, distinct shape hashes. This is the values-vs-logic rule rejecting a
consolidation: a single parameterized config loader would be a worse artifact
than four readable ones. Retain all four. (Note: each of these will lose its
local AGReplicaRoles call as part of Part 1 — that is the only change they
receive here.)

### Net for Part 2
New file `xFACts-BatchOpsFunctions.ps1` with **3 shared functions**
(`Get-bat_SourceData`, `Get-bat_StallDurationText`, `Set-bat_BatchStatus`),
plus possibly folding OBS SourceData in to make it 3 covering 4 source copies.
Collapses roughly 7-8 local copies into 3 shared. All Step/Initialize/New
singletons and the two OBS stubs stay local by conscious decision.

---

## Sequencing

1. **Part 1 first (AGReplicaRoles lift).** It is independent of the BatchOps
   helper and clears live collision drift across three other files immediately.
   Build the Orchestrator function, rewrite all eight callers, delete eight
   local defs. Verify each touched file (structural diff, brace balance, byte
   discipline). The four BatchOps scripts get their AGReplicaRoles call rewritten
   in this pass.
2. **Part 2 (BatchOps helper).** Confirm dot-source-into-scope wiring. Build
   `xFACts-BatchOpsFunctions.ps1` (itself spec-conformant: banners, single-line
   purpose comments, prefix governance, byte discipline — same standard as the
   DmOps helper). Re-point the four BatchOps scripts' dot-source line to the new
   helper. Extract the 3 shared functions, delete the prefixed-apart locals,
   rewrite call sites. Full-file verified drop-ins.

Both parts: full-file or full-function delivery only, every output verified by
structural diff (only intended changes) + brace/paren balance + byte discipline
before delivery.

## Post-build catalog checks
- Zero `Get-*AGReplicaRoles` LOCAL definitions remain anywhere; one SHARED
  definition in OrchestratorFunctions; all call sites resolve to it as SHARED
  usage rows; the three BS-review DUPLICATE_FUNCTION_DEFINITION flags clear.
- BatchOps: `Get-bat_SourceData` / `Get-bat_StallDurationText` /
  `Set-bat_BatchStatus` exist once in the helper as SHARED; the prefixed-apart
  `_BDL_/_NB_/_PMT_/_OBS_` copies of those are gone; their call sites are SHARED
  usage rows resolving to the helper; zero orphaned old names.

## Session-end
System_Metadata structural version bumps (Admin UI, single pass, one per
affected component): Engine.SharedInfrastructure (OrchestratorFunctions gained
a function), BatchOps (new helper + extractions), and any component whose file
changed in the AGReplicaRoles caller rewrite — ServerOps.DBCC, the BS-review
component(s), JobFlow's component. Confirm exact component_name values against
Component_Registry / Object_Registry at session end (trust the registry over
file headers).
