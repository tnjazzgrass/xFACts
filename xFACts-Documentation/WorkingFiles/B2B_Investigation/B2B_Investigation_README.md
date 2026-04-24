# B2B Investigation

This folder holds the chronological investigation record for the B2B (Sterling B2B Integrator) module rebuild. Each step has its own subfolder containing the query, results, and findings document.

## Navigation

**Start here:**
- `../Planning/B2B_Roadmap.md` — the authoritative investigation tracker. Go here first to understand current state, what's been decided, and what's next.

**Step-by-step findings (in order):**

| Step | Topic | Status | Folder |
|---|---|---|---|
| 01 | b2bi Database Catalog | ✅ Complete | `Step_01_Database_Catalog/` |
| 02 | Retention and Archive | ✅ Complete | `Step_02_Retention_and_Archive/` |
| 03 | Workflow Universe | ✅ Complete | `Step_03_Workflow_Universe/` |
| 04 | WF_INACTIVE | ✅ Complete | `Step_04_WF_INACTIVE/` |
| 05 | CORRELATION_SET | ✅ Complete | `Step_05_Correlation_Set/` |

**Archived historical docs (reference only, not authoritative):**
- `Roadmap_v1_pre_investigation.md` — the pre-investigation Roadmap, preserved for audit trail
- `../Roadmap_v1_pre_investigation.md` — alternate location if above is not available

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
2. Archived docs (`B2B_ArchitectureOverview.md`, `B2B_Module_Planning.md`, etc.) — reference only, "trust but verify"
3. Any earlier statements not captured in the above — do not rely on

**Update policy:**
- Findings docs are frozen once the step closes (subsequent discoveries go into new steps, not edits to old findings)
- Roadmap is living and gets refreshed as investigation progresses
- Archived docs get deprecation headers but are not rewritten
