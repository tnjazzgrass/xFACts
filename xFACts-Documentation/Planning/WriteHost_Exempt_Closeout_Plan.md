# Write-Host / Exempt-Branch Closeout — Plan

**Status:** Active. Temporary companion doc; delete once the closeout is complete and
the permanent spec edits have landed.
**Created:** 2026-06-14

---

## Purpose

Track the staged plan for retiring `Write-Host` in favor of the `Write-Console` helper
family, and for determining whether the "exempt file" concept can be eliminated entirely.
The spec amendments are gated on two facts we do not yet know for certain. This doc holds
the plan, the gates, and the staged edits so nothing lands prematurely.

---

## What is already proven (done, not gated)

- The three console helpers exist in `xFACts-OrchestratorFunctions.ps1` and work:
  `Write-Console` (single line; covers bare, colored, `-NoNewline`, and `-f` expression
  shapes), `Write-ConsoleBanner` (framed banner; optional color, optional `=`/`-` rule
  char; 76-wide to match the structural section-banner width), `Write-ConsoleRule`
  (single 76-wide rule).
- Populator behavior validated: converted calls catalog as clean `PS_FUNCTION_CALL` rows
  with `component_name = Write-Console*`, `scope = SHARED`, no drift. No populator change
  was needed to *recognize* the helpers (Approach B — they resolve as ordinary shared
  function calls, consistent with how `Write-Log` is treated).
- Two files converted to zero drift as proof:
  - `Populate-AssetRegistry-PS.ps1` (5 `Write-Host` -> 5 `Write-Console`; the `-NoNewline`
    same-line case preserved).
  - `Execute-DmConsumerArchive.ps1` (24 `Write-Host` -> 4 `Write-ConsoleBanner` + 4
    `Write-Console`; all `Write-Log` preserved; two hidden Unicode box-drawing rule lines
    incidentally fixed to ASCII).

---

## The two gates

Nothing below the "Gated" line is touched until BOTH are confirmed true.

### Gate 1 — Both Start scripts can refactor to the spec cleanly
`Start-xFACtsOrchestrator.ps1` and `Start-ControlCenter.ps1` each refactor to **zero drift**,
or to only a small amount of drift that falls into an existing or new "temporary drift"
bucket already understood and scheduled (consistent with other temporary-drift items
currently in flight). Refactors are done to COPIES first, scanned, and the catalog read
to confirm.

Preliminary finding (Start-xFACtsOrchestrator.ps1, inspection only, not yet refactored):
all observed drift is conventional pre-spec debt with known remediations — embedded
CHANGELOG in header, `Version:` field, `.EXAMPLE` blocks, a DEPLOYMENT REMINDERS block
with inline `===` rules, missing `.COMPONENT`, all 26 sections in the old `# ===`
line-comment style, and the write-host calls. Nothing structural appears to resist the
spec. This supports (but does not yet prove) that the file is not genuinely "special."

### Gate 2 — The refactored Start scripts actually run
After Gate 1, perform a test swap of the refactored file(s) into place and restart the
relevant service(s) to confirm they run normally in refactored form with no functional
regression. (Start-xFACtsOrchestrator.ps1 = NSSM orchestrator service; Start-ControlCenter.ps1
= the Pode web server for the entire CC zone — high blast radius, treat with care.)

If both gates resolve true: the "special / exempt" justification is disproven, the exempt
concept can be eliminated, and the full set of spec + populator edits below is safe to land.

---

## Object_Registry reclassification (pending Gate 1/2)

Current state: both files are `zone = exempt, scope = exempt, scope_tier = NULL`.

Intended end state (to be CONFIRMED against `xFACts_Platform_Registry.md` before any
registry write — do not set on assumption):
- `Start-xFACtsOrchestrator.ps1` -> `zone = standalone`. scope/scope_tier TBD
  (working hypothesis: `scope = LOCAL, scope_tier = NULL`, since standalone scripts
  consume shared functions rather than export them — verify against the registry doc).
- `Start-ControlCenter.ps1` -> `zone = cc` (it is the CC web-server bootstrap; belongs
  with the other CC files). scope/scope_tier TBD — verify.

---

## Spec edits

### Safe to land now (NOT gated) — additive only
- **§15 — establish the console helpers as blessed.** `Write-Log` remains the durable
  output lane. `Write-Console` / `Write-ConsoleBanner` / `Write-ConsoleRule` are the
  sanctioned ephemeral console-output mechanism for standalone (and where applicable
  shared-library) files. This is additive and true regardless of the gates.

### Gated on Gate 1 + Gate 2 — the "absolute ban" half
- **§15 / §15.1 — make `Write-Host` absolutely forbidden; remove the exemption table.**
  Only correct once both Start files are proven conformant AND running. Until then the
  exemption table stays as-is.
- **§16 — forbidden-patterns table.** Drop the "except exempt files" qualifier from the
  `Write-Host` row.
- **§17 — drift-code table.** `FORBIDDEN_WRITE_HOST` description loses the
  "Start-xFACtsOrchestrator.ps1 entry-point script is exempt" clause.

---

## Populator edits (gated on Gate 1 + Gate 2)

In `Populate-AssetRegistry-PS.ps1`:
- Remove the `$WriteHostExemptFiles` list and the `-notcontains $name` guard at the
  `^Write-Host$` dispatch site, so `Write-Host` is flagged everywhere with no exception.
- Update the `FORBIDDEN_WRITE_HOST` entry in `$DriftDescriptions` to match the amended §17.

Note: removing the guard causes `Start-xFACtsOrchestrator.ps1` to begin showing write-host
drift until it is converted — which is the correct signal, and is why the populator edit is
gated behind the file conversions rather than landing first.

---

## Discussion doc cleanup (do with the gated batch)

`WriteHost_Retention_Discussion.md` (Planning/) is an "open options" doc. Once the gated
edits land, replace its body with a short "RESOLVED — see CC_PS_Spec §15" pointer so the
question is not re-litigated in a future session.

---

## Staging decision (open)

Two viable ways to land the spec edits:
- **All-at-once on confirmation:** hold every spec edit until Gates 1 and 2 pass, then land
  the full batch (additive + absolute-ban) together with the populator edits.
- **Incremental:** land the additive §15 helper-blessing now (it is ungated), then land the
  absolute-ban half + populator edits once the gates pass.

Leaning: land the additive §15 piece now (it is already proven and unblocks documenting the
helpers), and hold the absolute-ban half + populator + reclassification as one gated batch.
To be decided.

---

## Sequence checklist

- [x] Build console helpers; prove on populator + archive (DONE)
- [ ] Refactor `Start-xFACtsOrchestrator.ps1` to a copy; scan; confirm drift outcome (Gate 1a)
- [ ] Refactor `Start-ControlCenter.ps1` to a copy; scan; confirm drift outcome (Gate 1b)
- [ ] Test-swap + service restart for each; confirm normal operation (Gate 2)
- [ ] Confirm Object_Registry target values against `xFACts_Platform_Registry.md`
- [ ] Land spec edits (staging per decision above)
- [ ] Land populator edits (remove exemption; update drift description)
- [ ] Apply Object_Registry reclassification
- [ ] Resolve `WriteHost_Retention_Discussion.md`
- [ ] Delete this companion doc
