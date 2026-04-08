# BDL Action Sequences — Planning Document

**Status:** Design discussion — not yet in development  
**Audience:** Dirk, Matt, Brandon, Claude  
**Created:** April 7, 2026  

> **Disclaimer:** This is a directional planning document, not a specification. The concepts described here represent our current thinking and will evolve as we build. Every planning document we've written has resulted in a different end product due to things discovered along the way — this one will be no different. Use this as a conversation starter and reference point, not a contract.

---

## The Problem

Today the BDL Import wizard handles one action at a time. A user uploads a file, selects a single BDL entity type (e.g., PHONE), maps columns, validates, and submits. If the same file needs to drive multiple BDL operations — say, updating phone numbers AND applying consumer tags AND updating addresses — the user must start over from scratch for each one, re-uploading the same file and re-selecting the identifier column each time.

Brandon's scenario brought this to light: after importing phone numbers from a vendor file, he also needed to tag those consumers in DM to indicate the data had been received. That's a second BDL (CONSUMER_TAG) driven by the same source file, requiring a completely separate import cycle.

## The Concept

Instead of selecting a BDL entity type (a system concept), users select **actions** — what they want to accomplish. Actions are user-friendly descriptions of BDL operations:

- "Add/Update Phone Numbers" → PHONE BDL
- "Add/Update Addresses" → ADDRESS BDL
- "Apply Consumer Tags" → CONSUMER_TAG BDL
- "Apply Account Tags" → ACCOUNT_TAG BDL
- "Update Behavioral Scores" → CONSUMER BDL
- "Update Email Addresses" → CONSUMER BDL

Users can select **multiple actions** in a single session. The system determines which distinct BDL files are needed (multiple actions may map to the same entity type), and walks the user through mapping and validation for each one. All BDLs share the same uploaded source file.

We're calling this a **sequence** for convenience, but it's really a **grouping** — the BDL files are independent imports that happen to share a common source file. If one fails, the others are unaffected.

## Key Design Principle

**This does not replace the existing single-entity flow — it wraps it.** The proven wizard mechanics (staging, validation, XML construction, DM API calls) remain unchanged. A single-action selection flows through exactly the same path as today. Multi-action selections loop through the same path multiple times, once per distinct BDL.

---

## Action Types

Not all actions work the same way. We've identified two patterns:

### File-Mapped Actions
The BDL field values come from columns in the source file. This is how the existing PHONE import works — the user maps "Column B" to `cnsmr_phn_nmbr_txt`, "Column C" to `cnsmr_phn_typ_val_txt`, etc.

**Examples:** Add/Update Phone Numbers, Add/Update Addresses, Update Email Addresses

**Mapping experience:** Full column mapping UI as it exists today.

### Fixed-Value Actions
One or more BDL field values are entered by the user (or pre-defined by the action) rather than mapped from file columns. The identifier still comes from the file, but the "payload" is a fixed value applied uniformly to every row.

**Examples:** Apply Consumer Tags (user enters/selects the tag value), Apply Account Tags

**Mapping experience:** Simplified — confirm identifier column, then enter/select the fixed value(s). No column-to-field mapping needed for the fixed fields.

### Hybrid Possibility
Some actions could be a mix — most fields mapped from the file, but one or two entered manually. This may not be needed initially but the design should not preclude it.

---

## The "Multiple Values, Same BDL" Pattern

A user might select "Apply Consumer Tags" and want to apply three different tags to the same population. Rather than creating three separate CONSUMER_TAG BDL files (each with identical consumer lists), we'd generate a single BDL file where each consumer gets three rows — one per tag value, each with its own `seq_no`.

**Open question for Matt:** Confirm that a single CONSUMER_TAG BDL file can contain multiple `<cnsmr_tag>` elements for the same consumer (different tag values, sequential `seq_no` values). We believe yes based on the XML schema structure, but want to verify.

The UI would support this with an "Add Another Tag" option after entering the first tag value. Each additional tag gets its own entry in a list, and the XML builder multiplies rows accordingly.

---

## Revised Wizard Flow

### Step 1 — Select Environment
Unchanged from today.

### Step 2 — Select Actions
Replaces the current entity type card selection. Presents a checklist of available actions, segmented by level (Consumer Actions / Account Actions). Users check the actions they want to perform.

**Permissions:** Admin tier sees all defined actions. Department-scoped users see only actions granted via `Tools.AccessConfig`.

**After selection:** An info panel summarizes: *"Your selections will generate 3 BDL files. Click Next to proceed to file upload."* This prepares the user for multiple mapping rounds.

**Actions grouped by BDL:** The action list would be organized under their parent BDL entity types. All consumer-level tag actions appear together, all phone actions together, etc. This provides structure without requiring users to know the underlying BDL type names.

### Step 3 — Upload File
Unchanged from today. One file upload for the entire grouping.

### Step 4 — Map Columns (per BDL, linear)
The user walks through mapping one BDL at a time: *"Mapping 1 of 3: Phone Numbers."*

- Each BDL gets its own identifier selection (pre-populated if same level as previous, but user confirms)
- File-mapped actions: full mapping UI as today
- Fixed-value actions: simplified panel — confirm identifier, enter/select fixed values (e.g., tag name via typeahead search)
- **Staging happens after each individual mapping** — not batched at the end. This staggers the table creation and avoids a single large operation if multiple BDLs are selected.
- Each BDL gets its own staging table (existing naming convention: `Staging.BDL_{entity}_{user}_{timestamp}`)

### Step 5 — Validate (all BDLs)
All staging tables exist at this point. Validation runs for each BDL in sequence: *"Validating 1 of 3: Phone Numbers."*

Same accordion-style issue cards as today, but scoped per BDL. User resolves issues for BDL 1, then moves to BDL 2, etc.

### Step 6 — Review & Execute
Shows all BDLs in the grouping with individual summary cards. One Jira ticket field covers the entire grouping (if provided, each BDL gets its own AR log companion). Execute processes each BDL independently — individual success/failure per BDL. One failure does not halt the others.

---

## AccessConfig Changes

### Current Structure
`Tools.AccessConfig` controls entity-level access:

| config_id | department_scope | tool_type | item_key | is_active |
|-----------|-----------------|-----------|----------|-----------|
| 1 | BI | BDL | PHONE | 1 |

`item_key` = entity type. `AccessFieldConfig` chains off `config_id` for field-level whitelist.

### Proposed Changes
Add columns to support action-based selection:

| Column | Type | Purpose |
|--------|------|---------|
| `action_label` | `VARCHAR(100)` | User-friendly action name displayed in the UI checklist |
| `entity_type` | `VARCHAR(50)` | Links to `Catalog_BDLFormatRegistry.entity_type` for catalog/field lookups |

`item_key` becomes the action identifier (e.g., `UPDATE_PHONES`, `TAG_CONSUMER`) instead of the raw entity type. `entity_type` provides the explicit link to the BDL catalog.

**Example rows:**

| config_id | department_scope | tool_type | item_key | action_label | entity_type | is_active |
|-----------|-----------------|-----------|----------|-------------|-------------|-----------|
| 1 | BI | BDL | UPDATE_PHONES | Add/Update Phone Numbers | PHONE | 1 |
| 2 | BI | BDL | TAG_CONSUMER | Apply Consumer Tags | CONSUMER_TAG | 1 |
| 3 | BI | BDL | UPDATE_ADDRESS | Add/Update Addresses | ADDRESS | 1 |

**AccessFieldConfig** continues to chain off `config_id` — field visibility is still per-action, per-department.

**Admin tier** bypasses AccessConfig entirely (same as today) and sees all defined actions. The "all defined actions" list would come from a distinct set of AccessConfig rows or a dedicated reference source — TBD based on implementation.

### Migration Path
Existing AccessConfig rows (e.g., BI/BDL/PHONE) would be updated in place to add the new columns. No new table needed. Existing `AccessFieldConfig` rows remain valid since they key off `config_id`.

---

## Tag Value Entry — Typeahead Search

For actions that require the user to enter a value from a DM reference table (tags being the primary example), we'd provide a typeahead/autocomplete search rather than a dropdown. The tag tables have approximately 1,000 values, making a dropdown impractical.

**Behavior:**
- User types 2-3 characters
- System queries the lookup table dynamically (same lookup infrastructure the validation step already uses)
- Matching values returned with descriptions where available
- User selects from the filtered list
- Selected value is validated against the table (same validation mechanism as today)

**"Add Another" pattern:** After selecting a tag value, an "Add Another Tag" link appears. Each additional tag creates another entry in a list. The XML builder generates one row per consumer per tag in the output BDL.

---

## Open Questions for Matt

1. **Multi-tag same file:** Can a single CONSUMER_TAG BDL file contain multiple tag elements for the same consumer with different tag values? (Believe yes — each would be a separate `seq_no`.)

2. **Consumer + Account mix:** Would there ever be a scenario where a single source file drives both consumer-level and account-level BDLs? If so, the file would need both `cnsmr_idntfr_agncy_id` and `cnsmr_accnt_idntfr_agncy_id` columns. Not needed immediately but worth discussing for future flexibility.

3. **Tag value validation:** Are tag values in the lookup tables case-sensitive? Do we need exact match or case-insensitive?

4. **Additional fixed-value action candidates:** Beyond tagging, are there other BDL operations where the "apply this value to everyone" pattern applies? (e.g., status updates, flag settings)

---

## Relationship to Existing Components

| Component | Impact |
|-----------|--------|
| `Tools.AccessConfig` | DDL change: add `action_label` and `entity_type` columns. Update existing rows. |
| `Tools.AccessFieldConfig` | No changes — still chains off `config_id` |
| `Catalog_BDLFormatRegistry` | No changes — still the source of truth for entity types |
| `Catalog_BDLElementRegistry` | No changes — still drives field definitions |
| `BDL_ImportLog` | May need a grouping identifier to link related imports from the same session |
| `BDLImport-API.ps1` | Entities endpoint evolves to return actions instead of raw entity types. Stage/validate/execute endpoints called per-BDL (no structural change). |
| `bdl-import.js` | Step 2 UI changes (action checklist replaces entity cards). Step 4 gains multi-BDL loop with progress indicator. Step 5/6 gain multi-BDL display. |
| `BDLImport.ps1` | Step 2 HTML changes for action layout |
| `xFACts-Helpers.psm1` | `Build-BDLXml` may need enhancement for row multiplication (multi-tag pattern) |
| `BDL_ImportTemplate` | Templates still work per-entity-type. May need association with actions for smarter template suggestions. |

---

## Implementation Phases (Suggested)

### Phase 1 — Foundation
- AccessConfig DDL changes (`action_label`, `entity_type`)
- Seed initial action definitions
- Step 2 UI: action checklist replaces entity cards
- Single-action flow works identically to today (sequence of one)

### Phase 2 — Multi-Action Grouping
- Multi-action selection with BDL deduplication logic
- Info panel showing BDL count
- Step 4 multi-BDL mapping loop with progress indicator
- Per-BDL staging after each mapping
- Step 5 multi-BDL validation cycle
- Step 6 multi-BDL review and independent execution
- Import grouping identifier on `BDL_ImportLog`

### Phase 3 — Fixed-Value Actions
- Simplified mapping panel for fixed-value actions
- Typeahead tag search with lookup validation
- "Add Another" pattern for multi-value same-BDL
- Row multiplication in XML builder

### Phase 4 — Polish
- Template integration with action-based workflow
- Admin UI for action management (Applications & Integration page)
- Promote to Production flow for multi-BDL groupings

---

## Items NOT in Scope

- CDL Import pipeline (separate effort)
- Payment Import pipeline (separate API flow)
- Consumer/Account CRUD operations (individual UI forms)
- Case-level BDL imports (not currently used)
