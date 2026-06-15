# xFACts — Carry-Forward (open items only)

Everything completed this session is recorded in System_Metadata (components
Tools.Utilities, ControlCenter.Shared, Engine.Orchestrator). This list is only
work still to do.

## 1. xFACts-OrchestratorFunctions.ps1 — full spec refactor (own session)

Component: Engine.Orchestrator. Shared-library/module-role file, never spec-refactored
(~46 drift rows at last baseline). This is its own focused session.

Includes, specifically:
- The 5 residual Write-Host calls that remain after the console-helper carve-out:
  - 4 genuine convertible calls (in Initialize-XFActsScript and Complete-OrchestratorTask)
    -> convert to Write-Console.
  - Write-Log itself calls Write-Host for its console portion. DECISION NEEDED:
    (a) add Write-Log to the sanctioned console-helper list, or (b) have Write-Log call
    Write-Console internally so only the 3 true helpers contain raw Write-Host.
    Lean: (b) — keeps a single Write-Host boundary.
- The rest of the file's spec conformance (header, sections, docblocks, etc.) — full pass.

## 2. Start-xFACtsOrchestrator.ps1 — graceful-shutdown block (same session as #1)

The one carried structural-drift row. The Register-EngineEvent / Register-ObjectEvent
calls arm shutdown handlers at load time, interleaved between function definitions, so the
block carries MISSING_SECTION_BANNER (+ possible ordering code). Conforming it means moving
the handler-arming into an EXECUTION section, which changes WHEN the handlers arm
(load-time -> execution-time). Gate 2 confirmed the block's BEHAVIOR is intact (clean
stop/restart) but did NOT test whether moving it is safe. Resolve in the orchestrator
session — same file family, same restart-test posture: restructure, restart, observe
shutdown fires correctly, confirm the carried row clears. Do not attempt without a live
restart test.

## 3. Generate-DDLReference.ps1 — third Write-Log collision (observed)

Generate-DDLReference.ps1 also defines a local Write-Log (the duplicate set was
Start-xFACtsOrchestrator + Generate-DDLReference + xFACts-OrchestratorFunctions, all
standalone zone). Now that Start-xFACtsOrchestrator's local copy is renamed to
Write-EngineLog, this file still collides with the shared Write-Log. Needs the same
divergent-rename-or-consolidate treatment in a future pass. Not urgent; record only.
