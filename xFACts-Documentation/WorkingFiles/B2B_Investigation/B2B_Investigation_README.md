# B2B Investigation

This folder holds the chronological investigation record for the B2B (Sterling B2B Integrator) module rebuild. Each step has its own subfolder containing the query, results, and findings document.

## Navigation

**Start here:**
- `../../Planning/B2B_Roadmap.md` — the authoritative investigation tracker. Go here first to understand current state, what's been decided, and what's next. **Read the "Next Session — Start Here" section at the top of the Roadmap before beginning any new session.**

**Step-by-step findings (in order):**

| Step | Topic | Status | Folder |
|---|---|---|---|
| 01 | b2bi Database Catalog | ✅ Complete | `Step_01_Database_Catalog/` |
| 02 | Retention and Archive | ✅ Complete | `Step_02_Retention_and_Archive/` |
| 03 | Workflow Universe | ✅ Complete | `Step_03_Workflow_Definition_Catalog+Active_Inventory/` |
| 04 | WF_INACTIVE | ✅ Complete | `Step_04_WF_INACTIVE/` |
| 05 | CORRELATION_SET | ✅ Complete | `Step_05_CORRELATION_SET/` |
| 06 | FA_CLIENTS_MAIN Anatomy | 🎯 Next up | `Step_06_MAIN_Anatomy/` *(to be created)* |

**Archived historical material (reference only, not authoritative):**

Under `Legacy/`:
- `B2B_Roadmap_V1.md` — the pre-investigation Roadmap
- `B2B_ArchitectureOverview.md`, `B2B_Module_Planning.md`, `B2B_Reference_Queries.md`, `B2B_ProcessAnatomy_NewBusiness.md` — pre-investigation markdown docs (each carries a deprecation header)
- `B2BInvestigate-*.ps1`, `B2BScheduleTimingXml*.ps1`, etc. — legacy investigation PowerShell scripts

## Per-step folder structure

Each step folder contains three files:

| File | Purpose |
|---|---|
| `Step_NN_Query.sql` | The exact SQL run — reproducible |
| `Step_NN_Results.txt` | Raw results from running the query |
| `Step_NN_Findings.md` | Synthesis, interpretation, open questions, implications |

## Document philosophy

These are **working documents** intended to inform the eventual build of a comprehensive B2B monitoring module. They are not the final documentation — once the module is built, proper HTML documentation will be authored from this material.

**Hierarchy of trust:**
1. Roadmap + Step Findings — authoritative investigation state
2. Legacy docs (under `Legacy/`) — reference only, "trust but verify," headers attached
3. Any earlier statements not captured in the above — do not rely on

**Update policy:**
- Findings docs are frozen once the step closes (subsequent discoveries go into new steps, not edits to old findings)
- Roadmap is living and gets refreshed as investigation progresses
- Legacy docs retain their deprecation headers but are not rewritten

## Upcoming step — what to know

**Step 6 — FA_CLIENTS_MAIN Anatomy** is the next step and must be executed in a single session with full context. MAIN is the most important workflow in Sterling at FAC, and two previous investigation passes got it wrong. See the "Next Session — Start Here" section of the Roadmap for scope, approach, and required context reading.
