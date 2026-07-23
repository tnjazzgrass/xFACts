# Metadata & Documentation Audit Rules

**Status: LIVING DOCUMENT.** This is the working ruleset for the per-module
`dbo.Object_Metadata` + documentation-page audit rotation. It evolves as the
rotation surfaces new rules and refinements; each module audit may add to or
sharpen it.

**Authority.** Future audit sessions load THIS FILE as the rule authority for the
audit, rather than re-stating the rules from memory. The auto-memory entries
(`metadata-doc-audit`, `no-naming-in-docs`, `no-hardcoded-cadence`,
`docs-current-state-only`, `comment-bloat-inventory`) remain as pointers and
scope/status trackers; the detail lives here.

**Destination.** On completion of the audit rotation, this ruleset is destined
for incorporation into `xFACts_Development_Guidelines.md` as standing DDL /
metadata authoring requirements, so that new objects are built conformant and
future drift is prevented at the source rather than swept later.

---

## 1. Scope and ground truth

- **Component/module scope.** Audit one module (or Object_Registry component)
  at a time. When a schema holds several components (e.g. ServerOps: DBCC,
  Backup, Index, Replication, Disk, Activity), audit only the objects
  Object_Registry classifies under the target component; the rest audit
  separately.
- **Ground truth is the code**, never the generated DDL text. Authority order:
  the collector / build / executor PowerShell, the CC route / API / client JS,
  and the live-table CHECK constraints. The generated DDL JSON and the generated
  metadata `.md` are produced FROM `Object_Metadata`, so they are the thing being
  audited, not evidence about it.
- **Investigation-first.** Read the relevant code end to end before proposing or
  writing any change. Verify column names, enum domains, routing, and behavior
  against code; never assume.

## 2. Object_Metadata rules by property_type

### 2.1 Column descriptions -- RULE 1 (enum content)

A column description carries **purpose only**: one sentence stating what the
value is. It carries **no value lists, no per-value glosses, and no "see status
values" pointer text** -- not even bare value names.

- The `status_value` rows plus the column's CHECK constraint are the **sole
  authority** on the domain. Any list repeated in a description is a second sync
  point that rots. (Proof: `DBCC_ExecutionLog.status` listed four values while
  five existed -- PENDING was missing.)
- The generated reference page renders a column's `status_value` rows adjacent to
  its description, so a pointer like "see Status Values" is noise.
- **NULL semantics** may stay only when non-obvious (e.g. "NULL while still
  running"). Strip computation ("parsed from..."), rationale ("useful for...",
  "avoids joins", "for historical accuracy"), and downstream chains ("combined
  with X to produce Y").
- Fixed numeric encodings that are not modeled as `status_value` rows (e.g. a
  1=Sunday..7=Saturday day-of-week integer) may stay inline as domain semantics;
  they are a fixed convention, not a rotting list.

### 2.2 Companion migration -- RULE 2

Before stripping enum content from a description, verify the column has
`status_value` rows covering those values.

- **If it does**, strip the description outright.
- **If it does not** (inconsistent historical authoring -- it happens), **create
  the missing `status_value` rows** from the stripped glosses in the same script:
  correct `sort_order`, `title` = the value, `content` = the meaning, verified
  against code and the CHECK constraint for accuracy and completeness. Domain
  documentation is **relocated, never destroyed.**
- Worked example (DBCC): `DBCC_ScheduleConfig.check_mode` and `.replica_override`
  had no `status_value` rows; their descriptions were stripped and status_value
  rows were INSERTed (check_mode NONE/PHYSICAL_ONLY/FULL from
  `CK_DBCC_ScheduleConfig_check_mode`; replica_override PRIMARY/SECONDARY from
  `CK_DBCC_ScheduleConfig_replica_override`, NULL being the default described on
  the column).

### 2.3 Object descriptions

1-3 sentences, purpose only. No value/operation lists (same reasoning as RULE 1).

### 2.4 design_note / data_flow

Prose is fine but concise. Correct anything stale. Strip rationale padding and
example names. These are the right home for cross-cutting behavior that has no
single column (e.g. two-tier enable control, claim/queue mechanics).

### 2.5 status_value / query / relationship_note

Verify accuracy; light trim only.

- `status_value`: keep the module's own controlled vocabulary meanings; correct
  any that overreach (e.g. a status described as CHECKDB-specific when it applies
  to every operation).
- `query`: keep the SQL structure but swap named literals for placeholders
  (`'<database_name>'`), per pattern-not-instances (section 4).
- `relationship_note`: verify the described FK/flow still matches code.

## 3. Documentation-current-state rule

All metadata content and doc-page content reflects **current state only** --
never future plans, roadmap intentions, or intended-but-unbuilt behavior stated
as if live. If code and a documented behavior disagree, either correct the docs
to the code, or fix the code to make the behavior current; docs do not sit ahead
of the code. Treat "will", "planned", "intended to", and design-aspiration
phrasing as correction targets. The rare acceptable case is a fix imminent within
the same work effort (docs leading code by hours, not as a standing state).

Reserved-but-unbuilt capability that the schema genuinely permits (e.g. a CHECK
constraint that allows operations no code runs) is documented honestly as
reserved -- one line naming it as unimplemented -- rather than described as
working. Soft-retire the `status_value` rows for the unbuilt values (section 6).

## 4. No-naming / pattern-not-instances

Never name specific modules, callers, consumers, servers, databases, accounts,
or other instances in metadata or doc content, and remove illustrative examples.

- Strip every `(e.g., ...)`, `such as ...`, and `..., etc` clause -- module
  names, project keys, field IDs, ticket keys, trigger values, dates, code
  samples.
- Describe the KIND of value generically: "the module that queued the ticket",
  not "(e.g., JobFlow)".
- **Pattern-not-instances:** where a value's FORMAT is informative, replace the
  named instance with a generic PATTERN or placeholder rather than deleting
  (`'<database_name>'` in a query; "typically <Module>_<Condition>" for a trigger
  format). Name-drop-only examples strip entirely.
- **Keep the module's own controlled vocabulary:** status enums it defines, HTTP
  codes, module-defined sentinels, operation names it implements, the service's
  own identity. These are intrinsic and do not rot.
- **Mockups count.** Real server/database/account names embedded in a CC-guide
  mockup are the no-naming rule in costume -- genericize them. Representative
  durations and counts in a mockup may stay.

## 5. No-hardcoded-cadence / configurable values

Never state specific interval or threshold values as current behavior; nearly
everything is configurable via GlobalConfig / ProcessRegistry, so a hardcoded
number reads as false and goes stale. Rewrite "runs every 5 minutes" ->
"runs on a configurable schedule".

- Also covers **configurable server identities**: generalize a GlobalConfig-
  sourced server name to "the configured source server" (or equivalent).
- **Current-behavior claims only.** Historical color about a retired system is
  exempt. Narrative duration color (e.g. "a full check can run for hours") is
  acceptable; soften the most concrete, staleness-prone assertions ("8-10 hours
  at current data volumes" -> "several hours; compare against its own history").
- **Genuinely-fixed-value exemption (the Teams 2-second precedent).** A value
  that is genuinely hardcoded in code as a real constant keeps its concrete
  number -- documenting a real fixed value accurately is correct, not drift.
  Flag, do not silently delete, UI-label numbers and real in-code windows.

## 6. Soft-delete and the natural key

- Natural key on `Object_Metadata`:
  `(schema_name, object_name, object_type, column_name_key, property_type,
  sort_order)` filtered `is_active = 1`.
- Retire rows via `is_active = 0` (soft delete), **never DELETE**. Soft-retired
  rows preserve domain history (e.g. an operation reserved but not yet built).
- `sort_order` is scoped per (object, column, property_type); each column's
  `status_value` rows number from their own sequence.

## 7. Corrections vs. flags

- **Metadata:** apply unambiguous corrections and trims directly as UPDATEs in
  the deliverable SQL. Report dead/repurposed columns and promotion candidates
  rather than delete-and-forget.
- **Doc pages:** factual mismatches (enum lists, counts, object/column names, UI
  text, a stated behavior contradicted by code) are CORRECTIONS -- fix inline and
  report after. Reserve flag-without-fix for **judgment items**: repurposed/dead
  functionality, structural rewrites, ambiguous intent, or code-vs-doc forks
  where the resolution direction is the user's call.
- **Promotion candidates:** when a description carries genuinely useful rationale
  that does not belong in a terse column description, propose promoting it to a
  `design_note` (INSERT) rather than losing it.
- **Forks:** surface architectural forks (dead-vs-reserved, docs-vs-code) to the
  user; do not silently choose. Where a fork's resolution implies a code change,
  raise a backlog item rather than changing code inside the audit.

## 8. Deliverable: the metadata SQL script

- One step-through `.sql` per module at
  `WorkingFiles/Metadata_Audit/Object_Metadata_Trim_<Module>.sql`.
- Section separators; a header summary of changes; a Section 0 BEFORE snapshot;
  verification `SELECT`s after each section.
- Every statement keyed by `metadata_id` (PK), except `status_value` INSERTs
  (new rows, natural-key-placed).
- **UPDATEs are not commented out** -- the user steps through them in SSMS.
- Stamp `modified_dttm = GETDATE()`, `modified_by = SUSER_SNAME()` on every
  UPDATE (and set them via defaults/values on INSERTs as the table requires).
- **Never execute SQL** against any server. The script is authored for the user
  to review and run in SSMS.
- Byte discipline is **waived** for the provided SQL scripts (they are working
  deliverables, not production xFACts files).

## 9. Documentation-page audit

- Audit **authored/static content only**: the narrative main page, the `-arch`
  page, and the `-cc` page.
- **Do NOT edit** the `-ref` page or any generated block (ERD via `data-schema`
  + `ddl-erd.js`, etc.) -- they regenerate from `Object_Metadata`.
- Doc pages are **pure ASCII + HTML entities** (`&mdash;`, `&ndash;`, `&rarr;`,
  `&amp;`, ...), **CRLF, no BOM**, exactly one trailing CRLF. Preserve this;
  apply file-wide byte normalization to any page touched.
- These doc pages are **NOT governed by the four file-format specs** (PS/CSS/JS/
  HTML) -- those cover CC route pages. `spec-reviewer` validates the wrong spec
  for them; do not run it against them.
- Teaching prose (e.g. an arch-page worked example explaining a comparison) is
  not reference content and may keep a concrete illustrative value where it aids
  understanding; the parallel metadata row still genericizes. Cross-page
  consistency is not required between teaching prose and reference content.

## 10. Byte discipline (delivered xFACts files, not the SQL)

Pure ASCII, no Unicode (no smart quotes, em dashes, ellipses, non-breaking
spaces -- use HTML entities in HTML). CRLF everywhere, no BOM, exactly one
trailing CRLF. Verify byte cleanliness and brace/here-string balance before
delivery. Re-normalize after any scripted edit (Python `.replace()` can strip
CRLF).

## 11. Comment-bloat inventory (standing, observation-only)

While reading module code as audit ground truth, additionally NOTE -- never edit
-- comment bloat, in `WorkingFiles/Comment_Bloat_Inventory.md`.

- One row per code file read as ground truth: file path, date, rough scale,
  dominant offense (rationale blocks / per-line narration / code restating), and
  the observing module-audit.
- Clean files get a "reviewed - clean" row; the inventory doubles as a coverage
  map. Files opened only partially get a "not yet reviewed" placeholder row.
- Bloat = rationale-heavy blocks, per-line narration, or comments restating
  adjacent code. NOT bloat: spec-mandated section banners, one-line
  function-purpose headers.
- Observation only. Comment edits (if ever) happen under a future
  comment-standards effort (backlog), never inside an audit.

---

## Change log

- 2026-07-23 (DBCC audit): document created. RULE 1 (enum descriptions =
  purpose only) supersedes the earlier "keep enum lists" guidance entirely;
  RULE 2 (companion status_value migration) added. Recorded the reserved-
  capability handling, the narrative-duration softening steer, the mockup
  no-naming clarification, and the fork -> backlog convention.
- Prior rules established during the BIDATA (pilot), Teams, and Jira audits:
  ground-truth-is-code, no-naming/pattern-not-instances, no-hardcoded-cadence
  with the Teams 2-second genuinely-fixed-value exemption, docs-current-state-
  only, soft-delete conventions, and the step-through SQL deliverable format.
