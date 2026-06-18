# ServerOps.Index — Next-Session Conformance Plan

Anchor doc for the ServerOps.Index refactor. Starting state: all five files
unrefactored. The shared helper already exists and is already consumed
correctly, so this is overwhelmingly a **spec-conformance** pass, not a
consolidation pass. One genuine consolidation (`Get-AGPrimary`) rides along.

Source of truth for everything below: `xFACts_PS_Spec.md`. Confirmed: the
`ServerOps.Index` component (and its helper) is registered with
`cc_prefix = idx`, so every top-level function in all five files carries the
`idx_` prefix on the noun.

---

## The five files

| File | Role | Object_Registry id |
|---|---|---|
| `xFACts-IndexFunctions.ps1` | shared-library (scope SHARED) | 101 |
| `Execute-IndexMaintenance.ps1` | standalone | 99 |
| `Scan-IndexFragmentation.ps1` | standalone | 98 |
| `Sync-IndexRegistry.ps1` | standalone | 97 |
| `Update-IndexStatistics.ps1` | standalone | 100 |

---

## What is ALREADY correct (do not touch the wiring)

The shared helper holds six SHARED functions, and the four standalone scripts
already call them as SHARED usage rows resolving back to the helper. This is
the clean-extraction signature. No re-extraction needed for any of these:

- `Get-EffectiveSchedule`
- `Get-AvailableMinutes`
- `Get-MaxWeekdayWindow`
- `Get-IndexesForWindow`
- `Test-IsExtendedWindow`
- `Test-AbortRequested`

These six are consumed across Execute / Scan / Update correctly. The only
change they need is conformance (prefix + banner + docblock->comment), NOT
relocation.

---

## The ONE consolidation: `Get-AGPrimary`

`Get-AGPrimary` is defined **twice** — in `Execute-IndexMaintenance.ps1`
(lines 107-129) and `Update-IndexStatistics.ps1` (lines 100-120). Same
shape_hash AND same body_hash = byte-identical logic. Flagged
`DUPLICATE_FUNCTION_DEFINITION` on both.

Values-vs-logic test: nothing varies between the two copies. Clean lift, zero
parameterization.

**Action (coordinated with the prefix pass — see note):**
1. Lift one copy into `xFACts-IndexFunctions.ps1` as `Get-idx_AGPrimary`
   (prefixed, single-line purpose comment, no docblock — it never had one).
2. Delete both local definitions.
3. Rewrite the two call sites:
   - `Execute-IndexMaintenance.ps1` line 360: `Get-AGPrimary -ListenerName $serverName`
     -> `Get-idx_AGPrimary -ListenerName $serverName`
   - `Update-IndexStatistics.ps1` line 320: `Get-AGPrimary -ListenerName $db.sql_instance`
     -> `Get-idx_AGPrimary -ListenerName $db.sql_instance`

**Coordination note:** Do NOT prefix the two local copies in place — that
would make both `Get-idx_AGPrimary` and they'd STILL collide
(DUPLICATE_FUNCTION_DEFINITION persists). The prefix and the lift happen as
one move: prefix-and-lift to the helper, delete both locals. This is the
PREFIX_MISSING + DUPLICATE_FUNCTION_DEFINITION coordination rule.

---

## The conformance drift (touches nearly every function)

Every function in all five files carries a stack of drift. Categories:

### 1. PREFIX_MISSING — every function
Component prefix is `idx`. Every top-level function noun gets the `idx_`
prefix. This is a **cross-file rename**: when a SHARED helper function is
renamed, every caller in every file changes in lockstep or you get
ORPHAN_FUNCTION_CALL. Full rename map below.

### 2. MISSING_SECTION_BANNER — every function
None of these files have section banners. Each needs `FUNCTIONS: <NAME>`
banner(s) per spec section 3 (76-char `=` and `-` rules, description block,
`Prefix: idx` line). Group functions into sensible banners (e.g. the helper
might use `FUNCTIONS: SCHEDULE RESOLUTION`, `FUNCTIONS: WINDOW SELECTION`,
`FUNCTIONS: ABORT CONTROL` — to be decided when building, against the spec).

### 3. FORBIDDEN_DOCBLOCK_IN_STANDALONE — all six helper functions
The helper functions carry full comment-based-help docblocks
(.SYNOPSIS/.DESCRIPTION/.PARAMETER). SCOPED-tier/standalone files forbid these
(spec section 8.4). Convert each docblock to a single-line `#` purpose comment
directly above the declaration. The `.SYNOPSIS` line is already a clean source
for that comment — the catalog's purpose_description column captured it for
each (e.g. "Resolves the effective maintenance schedule for a database at a
specific hour.").

### 4. MISSING_FUNCTION_PURPOSE_COMMENT — every function
Same fix as #3, applied everywhere: one `#` line above each function stating
its purpose.

### 5. UNAPPROVED_VERB — `Calculate-PriorityScore` only
`Calculate` is not an approved PowerShell verb. Rename to an approved verb AND
add the prefix. Candidate: `Get-idx_PriorityScore` (Get is approved and fits a
function that computes and returns a score) or `Measure-idx_PriorityScore`.
Decide against Get-Verb when building. This is in `Scan-IndexFragmentation.ps1`
(definition lines 108-166), with one call site at line 696. Local function
(not shared), so the rename is single-file: definition + that one call site.

---

## Full function rename map

### Shared helper (`xFACts-IndexFunctions.ps1`) — renames cascade to all callers
| Current | New | Caller files to update |
|---|---|---|
| `Get-EffectiveSchedule` | `Get-idx_EffectiveSchedule` | Execute (x2), helper-internal (x2, inside Get-AvailableMinutes) |
| `Get-AvailableMinutes` | `Get-idx_AvailableMinutes` | Execute (x1) |
| `Get-MaxWeekdayWindow` | `Get-idx_MaxWeekdayWindow` | Execute (x1) |
| `Get-IndexesForWindow` | `Get-idx_IndexesForWindow` | Execute (x1) |
| `Test-IsExtendedWindow` | `Test-idx_IsExtendedWindow` | Execute (x1) |
| `Test-AbortRequested` | `Test-idx_AbortRequested` | Execute (x2), Scan (x3) |
| `Get-AGPrimary` (NEW, lifted) | `Get-idx_AGPrimary` | Execute (x1), Update (x1) |

NOTE on the helper-internal calls: `Get-AvailableMinutes` calls
`Get-EffectiveSchedule` twice (catalog parent_function = Get-AvailableMinutes,
lines 386 and 402). Those two call sites are INSIDE the helper and must be
renamed too.

### Local functions (single-file renames)
| File | Current | New | Call sites |
|---|---|---|---|
| Scan | `Calculate-PriorityScore` | `Get-idx_PriorityScore` (verb TBD vs Get-Verb) | line 696 (x1) |
| Execute | `Get-AGPrimary` | (lifted to helper as `Get-idx_AGPrimary` — see consolidation) | line 360 |
| Update | `Get-AGPrimary` | (lifted to helper — delete local) | line 320 |

---

## Execution approach

Five full-file replacements, each verified the same way DmOps was:
structural diff against the real uploaded bytes (only intended changes appear),
brace/paren balance, byte discipline (no BOM, pure ASCII, CRLF, single
trailing newline). The cross-file renames make this a lockstep operation — a
rename that misses one call site produces ORPHAN_FUNCTION_CALL, which is
exactly the silent-breakage class full-file replacement + diff verification
catches.

Suggested sequence:
1. Confirm Component_Registry prefix = idx for the helper's component (done —
   confirmed this session, but re-verify the row at build time).
2. Build the helper first (it gains Get-idx_AGPrimary and all its own
   conformance fixes), so the renamed SHARED names exist before callers
   reference them.
3. Build the four standalone scripts, each updating: local-function
   conformance, the SHARED call-site renames, and (Execute + Update) the
   Get-AGPrimary local-definition deletions.
4. Post-build catalog check: zero PREFIX_MISSING, zero MISSING_SECTION_BANNER,
   zero FORBIDDEN_DOCBLOCK_IN_STANDALONE, zero DUPLICATE_FUNCTION_DEFINITION,
   zero UNAPPROVED_VERB, zero ORPHAN_FUNCTION_CALL across all five files.

## Session-end
System_Metadata version bump for the ServerOps.Index component (structural
change — banners, renames, consolidation), via Admin UI, one bump.

## What this is NOT
This is not a re-extraction. The shared layer is already correctly wired. Do
not move the six already-shared functions out of the helper or re-point any
already-SHARED usage row. The only relocation is Get-AGPrimary (local->shared).
Everything else is conformance applied in place.
