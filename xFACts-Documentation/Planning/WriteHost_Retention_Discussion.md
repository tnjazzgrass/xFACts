# Write-Host Retention — Discussion Notes

**Status:** Open / in discussion. Not yet decided. Captured at end of session so the
next session starts from the viable paths rather than re-deriving them.

**Context:** This has come up at the end of several sessions. This is the first session
where a viable path (a `Write-Console` wrapper) actually emerged, so it's worth writing
the options down.

---

## The problem

The PowerShell spec mandates `Write-Log` and forbids `Write-Host`
(`FORBIDDEN_WRITE_HOST`). That rule was correct for the context it was written in, but
it's now firing against a legitimate use it didn't account for.

**Why the ban exists:** When the specs were written, much of "what to allow / forbid"
was drawn from the **CC zone** (route and API files). In a route/API file there's no
real use for `Write-Host` — those files don't run interactively at a console, so banning
it was natural and lossless.

**Why it doesn't fit the standalone zone:** A standalone `.ps1` (e.g.
`Execute-DmConsumerArchive.ps1`) *is* run manually — for testing, troubleshooting,
preview runs. In that mode, real-time colored console output is genuinely useful
(progress narration, batch banners, the session summary, the PREVIEW-MODE notice). The
`Write-Host` calls aren't sloppy debug prints; they're intentional operator-facing UX.

So the tension is: **the console output has real value, but only in the standalone zone.**
The struggle has been how to retain it without making the spec overly permissive (which
would erode the zero-ambiguity property the specs exist to guarantee — "acceptable drift"
as a standing habit defeats the point of drift codes meaning *real, actionable* problems).

**Current state:** `Execute-DmConsumerArchive.ps1` is the first standalone refactored to
spec; its 24 `Write-Host` calls are being carried as *temporary acceptable drift* pending
this decision. The populators also currently carry some `Write-Host` drift. So this
decision affects the whole standalone-zone refactor effort, not just one file.

---

## Options considered

### Option 1 — Relegate Write-Host to a dedicated section — REJECTED

The idea was to permit `Write-Host` only within a segregated console-output section.

**Why it fails:** Most `Write-Host` calls live *inside functions*, narrating that
function's work at the moment it happens (e.g. progress from inside a delete loop). They
can't be relocated to a section at the bottom of the file — they'd fire at the wrong time,
divorced from the work they describe. Only the top-level EXECUTION calls (startup banner,
session summary, preview notice) could move, which is a minority of them. A
*location*-based rule therefore can't work; only a *pattern*-based one could, which is
more populator complexity for less benefit. **Off the table.**

### Option 2 — Pair every console line with a log line — COOLED ON

Spec would require that wherever `Write-Host` appears, a corresponding `Write-Log` also
appears, so nothing console-only escapes the durable record.

**Concerns:** Requires populator code to recognize/permit the pairing — likely a lot of
detection logic. Also doesn't cleanly handle pure-decoration lines (the `====` separators,
blank `Write-Host ""`) that have no meaningful log equivalent. The *intent* (every operator
-visible status is also logged) is reasonable, especially for a destructive process, but
the enforcement cost is high. Note: the intent can be folded into Option 3 instead (see
the console-plus-log variant), which is simpler than a pairing rule.

### Option 3 — A sanctioned console wrapper (`Write-Console`) — VIABLE / LEADING

Introduce one function that does what `Write-Host` does, with the same ergonomics, living
in a shared location (Orchestrator is the natural home — console output is platform-generic
plumbing, not module-specific):

```powershell
function Write-Console {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
}
```

Then `Write-Host "..." -ForegroundColor Cyan` becomes `Write-Console "..." 'Cyan'`. The
console output is **identical** — same text, colors, real-time behavior. But the spec rule
becomes **absolute**: `Write-Host` is forbidden, full stop, no exceptions — because nothing
needs it anymore. The capability is preserved through a blessed mechanism instead of the
banned primitive.

**Why this is spec-pure:** The whole point of the spec is zero ambiguity. "`Write-Host`
forbidden with 24 standing exceptions" is ambiguous. "`Write-Host` forbidden absolutely,
`Write-Console` is the blessed way to print" is unambiguous — a reader (human or Claude)
sees `Write-Console` and knows it's allowed, sees `Write-Host` and knows it's wrong. Rule
stays rigid; nothing is lost.

**Costs / things to handle:**
- Mechanical conversion across every standalone using `Write-Host` (scriptable;
  the catalog's `PS_WRITE_HOST` rows across standalone files give the exact blast radius).
- The wrapper must faithfully cover the real call shapes in use: bare `Write-Host ""`,
  `-ForegroundColor`, and `-NoNewline` if used anywhere. Must be faithful or console UX
  degrades.

**Sub-decision — console-only vs console-plus-log:**
- **Console-only** (leading recommendation): `Write-Console` is a faithful `Write-Host`
  replacement; `Write-Log` remains the separate, deliberate "this matters for the record"
  call. Rationale: console output and the log are *different intents* — console is
  ephemeral run-time narration for a watching human; the log is the durable audit trail.
  Keeping them separate but both sanctioned keeps the distinction clean and avoids the
  decoration-line problem. Spec then reads: "`Write-Log` for durable output, `Write-Console`
  for console output, never `Write-Host`." Two clear lanes, one absolute ban.
- **Console-plus-log**: `Write-Console` writes to host *and* calls `Write-Log`, folding in
  the Option-2 instinct so every status line is durably captured. Costs: must handle
  decoration/whitespace-only lines (skip logging them) so the log isn't spammed. Possibly
  worth it specifically for destructive processes (e.g. the archive) where "every status the
  operator saw should also be in the log" is defensible.

---

## New angle worth weighing: zone-scoped rules

The root realization this session: the ban was **inherited from CC-zone reasoning and
applied platform-wide**, but the use case only exists in the standalone zone. That suggests
a legitimate alternative framing — make the rule **zone-aware** rather than absolute:

- CC zone (route/api/module): `Write-Host` forbidden (no use case — unchanged).
- Standalone zone: `Write-Host` permitted (or permitted only via `Write-Console`).

This is worth considering because the spec already reasons in zones, and "this rule is
correct for CC but mis-fits standalone" is exactly the kind of thing zone-scoping is for.
It could combine with Option 3 (e.g. `Write-Host` banned in CC, `Write-Console` mandated
in standalone) or stand alone (simply permit `Write-Host` in the standalone zone).

Open question: does permitting it (even zone-scoped) reintroduce ambiguity the wrapper
approach avoids? The wrapper keeps *one* absolute rule platform-wide; zone-scoping keeps
the rule rigid but *different per zone*. Both are defensible; they trade "one rule
everywhere" against "no conversion work."

---

## Where it stands / next steps

- **Leading path:** Option 3 (`Write-Console` wrapper), console-only variant — most
  spec-pure, preserves the capability, keeps the ban absolute. Open sub-decision:
  console-only vs console-plus-log (lean console-only; reconsider for destructive scripts).
- **Alternative worth a look:** zone-scoped rule (permit in standalone zone), possibly
  combined with the wrapper.
- **Rejected:** Option 1 (can't relocate in-function calls). **Cooled:** Option 2
  (populator complexity; decoration-line problem).

**To decide next session:**
1. Wrapper vs zone-scoping vs both.
2. If wrapper: console-only vs console-plus-log.
3. Where the wrapper lives (Orchestrator is the natural home) and its name.
4. Faithful coverage of real `Write-Host` call shapes before any conversion.

**Blast-radius query (run before committing to a conversion):** count/inspect
`PS_WRITE_HOST` rows across all standalone-zone files in `Asset_Registry` to see how many
scripts and calls a wrapper conversion would touch.

**Whatever is chosen:** the goal is that a clean populator run means *clean* — not "clean
except for the N Write-Host rows we've agreed to ignore." Standing acceptable drift erodes
the zero-ambiguity property the specs exist to provide.
