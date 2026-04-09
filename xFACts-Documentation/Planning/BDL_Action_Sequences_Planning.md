# BDL Action Sequences — Planning Document

**Status:** Partially implemented — core multi-entity flow built, fixed-value UI in progress  
**Audience:** Dirk, Matt, Brandon, Claude  
**Created:** April 7, 2026  
**Last Updated:** April 9, 2026  

> **Disclaimer:** This is a directional planning document, not a specification. The concepts described here represent our current thinking and will evolve as we build. Every planning document we've written has resulted in a different end product due to things discovered along the way — this one will be no different. Use this as a conversation starter and reference point, not a contract.

---

## The Problem

Today the BDL Import wizard handles one action at a time. A user uploads a file, selects a single BDL entity type, maps columns, validates, and submits. If the same file needs to drive multiple BDL operations — say, updating phone numbers AND applying consumer tags — the user must start over from scratch for each one, re-uploading the same file each time.

## The Solution (Implemented Direction)

After discussion with Matt, we chose a simpler approach than originally planned. Instead of creating a separate action registry table with friendly action names, we show entity types directly using the existing `Catalog_BDLFormatRegistry` data. Users can select multiple entity types from the existing card grid (click to toggle select/deselect). Each selected entity goes through its own mapping and validation cycle using the same uploaded file.

**Key simplification:** The `BDL_ActionRegistry` table was designed, built, seeded, and then rolled back entirely. Matt's input was that the people using this tool are knowledgeable users, not agents — they know what entity types are and don't need an abstraction layer mapping "friendly actions" to entity types.

---

## What's Built (April 9, 2026)

### 5-Step Wizard (consolidated from 6)
The wizard was restructured from 6 steps to 5 with a step swap:

1. **Select Environment** — unchanged
2. **Upload File** — moved up from old Step 3 (users should see their data before selecting what to do with it)
3. **Select Entity Types** — multi-select cards with toggle selection, counter banner, moved from old Step 2
4. **Map & Validate** — combined old Steps 4+5 into a single step with per-entity loop
5. **Execute** — tabbed per-entity summary with single Submit All button

### Multi-Select Entity Selection (Step 3)
- Cards are click-to-toggle (select/deselect) instead of single-select
- Instruction banner: "Click entity types to select them for import. You can select multiple."
- Selected count indicator: "3 selected"
- Step completes when at least one entity is selected
- Search/filter still works

### Per-Entity Map & Validate Loop (Step 4)
- `entityStates[]` array holds independent state per selected entity (fields, columnMapping, stagingContext, validationResult, validated flag)
- Progress banner with numbered dots shows position in the entity sequence
- Each entity gets: load fields → map columns → validate cycle
- "Validate [Entity Name]" button within the step (replaces Next for within-step progression)
- On validation pass: 1.5-second transition modal ("Phone Complete ✓ — Moving to Consumer Tag...") then auto-advance
- "Continue to [Next Entity]" button on completed entities
- Back button navigates to previous entity within the loop; entity 1 back → Step 3
- All entity states preserved on back navigation
- Step 4 complete only when ALL entities are validated

### Tabbed Execute (Step 5)
- One tab per entity type with individual summary card
- Single Jira ticket field above tabs (applies to all imports)
- "Submit All (N BDLs)" button processes entities sequentially
- Tab labels get ✓ or ✗ indicators as each completes
- Each entity's result card rendered independently per tab

### action_type on Catalog_BDLFormatRegistry
- `action_type VARCHAR(20)` column added with CHECK constraint: FILE_MAPPED (default), FIXED_VALUE, HYBRID
- CONSUMER_TAG and ACCOUNT_TAG set to FIXED_VALUE
- Entities API returns `action_type` so the JS can route to the appropriate mapping UI
- Admin catalog modal on Apps/Int page shows FIXED VALUE and HYBRID badges on format rows

### Fixed-Value Mapping UI (Step 4 — in progress)
For entities with `action_type = 'FIXED_VALUE'`:
- Different UI rendered instead of the column mapping panels
- Identifier column selector (same as file-mapped — "which column has the agency ID?")
- Direct value entry fields for each non-identifier visible field
- Lookup hint for fields with lookup tables ("Value will be validated against [table]")
- Values stored in `columnMapping` with `__fixed__` prefix keys
- Staging request splits mapping into `mapping` (file columns) and `fixed_values` (user-entered)
- Server adds columns for fixed values and UPDATEs all rows with those values

### Admin Catalog Modal Enhancement
- `ApplicationsIntegration-API.ps1` includes `action_type` in formats query
- New `/api/apps-int/bdl-format/update` endpoint for updating format fields (action_type editable)
- `applications-integration.js` shows FIXED VALUE and HYBRID badges on format rows

---

## Action Types

### FILE_MAPPED (default)
User maps source file columns to BDL fields. This is how PHONE imports work — full column mapping UI with drag-and-drop.

### FIXED_VALUE
User enters values directly rather than mapping from file columns. The identifier comes from the file, but payload values are entered/selected by the user and applied uniformly to every row. Used for tagging operations (CONSUMER_TAG, ACCOUNT_TAG).

### HYBRID (future)
Mix of file-mapped and manually entered fields. Design space reserved but not yet implemented.

---

## Matt's Answers

1. **Multi-tag same file:** Yes, possible. Tags use a repeating pattern where the first tag is associated with the key, then the next sequence is a fully repeating pattern for subsequent tags. They do NOT get contained within the same entry.

2. **Consumer + Account mix:** Theoretically possible, but Matt is not aware of any current processes that mix and match consumer-level and account-level operations in a single file.

3. **Tag value case sensitivity:** Not case sensitive.

4. **Same source column mapped to multiple BDLs:** Pending — Dirk checking with Brandon.

---

## What's Next

### Immediate
- **BDLImport-API.ps1 section replacements** — `f.action_type` in entities queries, `$fixedValues` in stage endpoint (instructions produced, awaiting deployment)
- **Fixed-value mapping end-to-end test** — Test CONSUMER_TAG through the full pipeline (enter tag value, stage with fixed values, validate, execute)
- **Typeahead lookup** — Currently shows a hint; needs actual lookup values for tag fields. The validation infrastructure already queries DM lookup tables — need to surface those values in the fixed-value UI for typeahead search
- **CSS consolidation** — Complete (966 → 561 lines, all duplicates removed, proper section organization matching 5-step flow)

### Follow-Up Items
- Multi-tag "Add Another" pattern — entering multiple tag values for the same entity, generating one row per consumer per tag with sequential `seq_no`
- Promote to Production flow — state variables preserved but not fully wired in the new tabbed execute
- Template integration — templates work per-entity-type; template loading/saving works for the current entity in the loop
- Step guide text refinement
- Version bumps for this session's work
- Object_Metadata for `action_type` column on `Catalog_BDLFormatRegistry`

### Items NOT in Scope
- CDL Import pipeline (separate effort)
- Payment Import pipeline (separate API flow)
- Consumer/Account CRUD Operations (individual UI forms)
- Case-level BDL imports (not currently used)
- DM Monitoring Dashboard widgets
- New Business Import pipeline
