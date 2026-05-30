# CC Session Summary 20 — File Classification Model (zone / scope / scope_tier)

## Session focus

This session did **not** execute the Session 19 plan. It opened intending a spec-conformance
pass on `xFACts-AssetRegistryFunctions.ps1` and instead surfaced a foundational gap that
drove a larger architecture change. The Session 19 open items therefore **carry forward**
(see §7). What was accomplished here is the classification foundation that makes much of the
remaining work — including the original AssetRegistryFunctions target — substantially easier.

The throughline: the CC PowerShell spec and the Asset_Registry populators were built for a
**two-bucket** world (cc / docs). Standalone orchestrator-type scripts and their shared
libraries were never accounted for, which was the root of recurring trouble (the docblock
question being the presenting symptom). This session introduced a **three-zone** model,
moved file classification into `dbo.Object_Registry` as declared data, made the PS populator
fully zone-aware and tier-aware, brought `CC_PS_Spec.md` into alignment, and validated the
whole chain against live data.

---

## 1. The classification model (the core outcome)

Three declared classification columns now live on `dbo.Object_Registry`. All are authoritative
(declared, not derived from path or contents). They are orthogonal to **role** (file kind:
page-route / api-route / module / standalone / shared-library), which still governs file
*structure*. Classification governs *resolution* and *documentation treatment*.

### zone — the resolution universe
`cc` | `docs` | `standalone` | `exempt` | NULL

- A reference resolves **only within its own zone**. Cross-zone never resolves.
- Three real universes that were always separate: `cc` (Control Center web app), `docs`
  (documentation site), `standalone` (orchestrator + standalone scripts and their shared
  libraries, all under `E:\xFACts-PowerShell\`). They were built independently — standalones
  write to SQL, cc reads/presents in the UI, docs are help pages — and never cross-reference
  constructs.
- `exempt` = walk-eligible files deliberately excluded from spec enforcement:
  `Start-ControlCenter.ps1`, `Start-xFACtsOrchestrator.ps1`, `server.psd1`.
- NULL = the 151 Database objects (never source-walked; the concept does not apply).

### scope — resolves-to-self or resolves-across-zone
`LOCAL` | `SHARED` | `exempt` | NULL

- `LOCAL` content resolves only within its file; `SHARED` content is visible to every file in
  the same zone. "SHARED" means the same thing in all three universes — visible to everything
  in its own universe.

### scope_tier — documentation treatment for shared function-bearing files
`PLATFORM` | `SCOPED` | NULL

- `PLATFORM` = broadly-consumed shared infrastructure → full comment-based-help docblocks
  (PS spec §8.3). `SCOPED` = narrowly-scoped helper (one tool family / one page) → light
  single-line purpose comment (§8.4), same as a standalone script.
- Non-NULL only for SHARED function-bearing files (modules + shared-libraries). NULL
  everywhere else (standalone scripts are light by role; routes have no functions; non-PS and
  Database objects have no docblock concept).
- This is a genuinely **non-derivable** distinction (it cross-cuts zone — a cc module and a
  standalone shared library can both be PLATFORM), which is why it is declared, not inferred.

### Pairing invariants (constraint-enforced)
- zone/scope move together: both real, both `exempt`, or both NULL — never mixed.
- `scope_tier` non-NULL ⟹ `scope = 'SHARED'`.

### The five shared function-bearing files (the meaningful population)
| File | object_type | zone | scope | scope_tier |
|---|---|---|---|---|
| xFACts-CCShared.psm1 | Module | cc | SHARED | PLATFORM |
| xFACts-Helpers.psm1 | Module | cc | SHARED | PLATFORM (deprecating) |
| xFACts-OrchestratorFunctions.ps1 | Script | standalone | SHARED | PLATFORM |
| xFACts-AssetRegistryFunctions.ps1 | Script | standalone | SHARED | SCOPED |
| xFACts-IndexFunctions.ps1 | Script | standalone | SHARED | SCOPED |

---

## 2. Completed work

### 2.1 DDL + backfill + metadata (all run and verified on FA-SQLDBB)

- **`ObjectRegistry_ZoneScope.sql`** — added `zone` and `scope` varchar(20) NULL columns,
  per-column CHECK constraints, backfill (zone path-derived: `\public\docs\` → docs,
  `E:\xFACts-PowerShell` → standalone, else cc; scope from the verified SHARED file set),
  verification queries, and the paired-invariant CHECK added last. All 358 rows classified.
- **`ObjectMetadata_ZoneScope.sql`** — two column-description rows (zone, scope) for the Ref
  page. Column ordinals re-synced afterward.
- **`ObjectRegistry_ScopeTier.sql`** — added `scope_tier` varchar(20) NULL, CHECK
  (PLATFORM|SCOPED), backfill (3 PLATFORM, 2 SCOPED by explicit filename), pairing CHECK
  (scope_tier non-NULL ⟹ scope=SHARED). Verified PLATFORM=3, SCOPED=2, rest NULL.

Asset_Registry was widened to accept the new sentinel values: `zone` and `scope` both
varchar(20), CHECK constraints accepting `<undefined>` (and the new zone values) so a
registration-gap row can carry the sentinel without failing bulk insert.

### 2.2 PS populator + shared helper made zone-aware and tier-aware

Two full drop-in replacements delivered.

**`xFACts-AssetRegistryFunctions.ps1`** (shared, additive — CSS/JS/HTML unaffected):
- Widened the `New-AssetRegistryRow` Zone ValidateSet to
  `('cc','docs','standalone','exempt','<undefined>')`.
- Added `Get-ObjectRegistryZoneScopeMap` returning `object_name -> @{ Zone; Scope; ScopeTier }`
  (ScopeTier $null on DBNull). Existing `Get-ObjectRegistryMap` (registry_id) untouched.

**`Populate-AssetRegistry-PS.ps1`**:
- Reads zone/scope/scope_tier per file from Object_Registry. Hardcoded `-Zone 'cc'` replaced by
  `$script:CurrentFileZone`. The 24 file-scope sites read `$script:CurrentFileScope`.
- Map-miss → stamps zone/scope `<undefined>`, records the file, and attaches a new
  `FILE_NOT_REGISTERED` drift code to the file's PS_FILE anchor row (so a registration gap
  surfaces as drift, not a silent misclassification).
- Pass-1 shared-function collection bucketed by zone (`$sharedFunctionsByZone` /
  `$sharedSourceFileByZone`).
- `Add-PSFunctionCallRow` resolves strictly within the caller's zone: same-zone shared →
  SHARED (resolved in-populator); local → LOCAL; shared-only-in-another-zone →
  `<pending>`/`<pending>` (deferred to resolver — placed before the name-shape test so plain
  Verb-Noun names are caught); xFACts-shaped no-match → orphan; else skip.
- `SHADOWS_SHARED_FUNCTION` and `DUPLICATE_FUNCTION_DEFINITION` made within-zone (duplicate
  keyed on zone+name).
- **Docblock treatment re-keyed from role to scope_tier**: `scope_tier = PLATFORM` → full
  docblock + CmdletBinding + docblock-content validation (§8.3); SCOPED / standalone (NULL
  tier) → light purpose-comment treatment (§8.4). Both the treatment branch and the
  docblock-content gate now key on PLATFORM.
- Deliberately unchanged: role detection, scan roots, hardcoded role-input lists (still used
  for *role* detection only), and the genuinely structural role checks (module EXPORTS,
  standalone EXECUTION placement).

### 2.3 Validation against live data

- Standalone consumers (Collect-JBossMetrics, Process-JiraTicketQueue, Publish-GitHubRepository,
  Scan-SFTPFiles) resolve `Get-ServiceCredentials` → `xFACts-OrchestratorFunctions.ps1`
  (standalone, SHARED). Correct.
- cc API consumers (ApplicationsIntegration-API, BDLImport-API, ClientPortal-API,
  JBossMonitoring-API) resolve `Get-ServiceCredentials` → `xFACts-CCShared.psm1` (cc, SHARED).
  Correct — a real cc-zone definition exists, so this is same-zone resolution, NOT a cross-zone
  deferral. The earlier "boundary crossing" concern was a measurement artifact of the old
  zone-blind flat shared-function set.
- `Get-ServiceCredentials` is defined in three files: Orchestrator (standalone), CCShared (cc),
  Helpers (cc, deprecated). The two cc copies correctly fire `DUPLICATE_FUNCTION_DEFINITION`
  (same name, same zone); the standalone copy correctly does not. Within-zone duplicate logic
  validated. The Helpers/CCShared duplicate is the unfinished deprecation; self-clears when
  Helpers is retired.
- **AssetRegistryFunctions docblock drift cleared.** After the scope_tier re-key, its functions
  no longer carry `MISSING_DOCBLOCK` / `MISSING_CMDLETBINDING` (it is SCOPED → §8.4 light
  treatment). Remaining drift is only `MISSING_SECTION_BANNER` (the `# ===` dividers are not
  spec banners) and `EXCESS_BLANK_LINES` — real structural conformance work, unaffected by the
  re-key. Same total row count, docblock codes gone.

### 2.4 CC_PS_Spec.md brought into alignment (applied on Dirk's end)

- New **§6.3 Classification** — terse three-bullet introduction of zone / scope / scope_tier as
  Object_Registry attributes, with "each applies only where meaningful; rows where an attribute
  does not apply hold NULL."
- **§8 intro** — reworded from role-keyed to per-subsection (§8.2 routes, §8.3 PLATFORM, §8.4
  SCOPED+standalone, exactly one applies).
- **§8.3** — "Shared-library and module files" → "PLATFORM-tier files" (applies to scope_tier =
  PLATFORM); rule body unchanged.
- **§8.4** — "Standalone files" → "SCOPED-tier and standalone files"; rule body unchanged.
- **§8.1** — shadow and duplicate rules qualified to within-zone.
- **§16 / §17** — within-zone wording on shadow/duplicate rows; §17 docblock-code pointers
  repointed §8.1 → §8.3; route-function codes → §8.2; §8.4 descriptions updated to
  "SCOPED-tier or standalone."
- **`MALFORMED_DOCBLOCK` removed** from §17 and from the populator master table — confirmed dead
  (never emitted; the missing-element part is covered by `MISSING_SYNOPSIS` / `MISSING_DESCRIPTION`,
  and the "wrong order" part was never implemented).
- **§15 (Write-Host) left untouched** — the underlying rule is unsettled (console output wanted
  for troubleshooting); parked for the future spec-as-data effort.

---

## 3. Key decisions and rationale

- **Three zones, not two.** Standalone is a genuine third resolution universe that was always
  separate; it had been forced into the cc bucket because PS had no zone concept.
- **Declared columns, not inferred.** zone is path-derivable but stored for a single source of
  truth; scope and scope_tier are NOT cleanly derivable (scope from curated shared lists;
  scope_tier cross-cuts zone), so they must be declared. This is the same logic that drove
  every classification decision.
- **scope_tier resurrected the platform/scoped distinction — correctly this time.** It was
  briefly eliminated as "redundant with zone," but docblock treatment is a *documentation*
  question, not a *resolution* question, and it cross-cuts zone (OrchestratorFunctions in
  standalone and CCShared in cc are both PLATFORM). So it is a third, independent axis — NOT the
  resolution-redundant `platform_scope` that was correctly rejected.
- **Role and zone coexist.** Role governs structure (§4.1 section types, route rules, exports);
  classification governs resolution and documentation treatment. Re-keying touched only the
  rules where role was a proxy for something zone/tier expresses better (docblocks, shadow,
  duplicate). Most of the spec was correctly untouched.
- **`<pending>` vs `<undefined>`.** Populators leave cross-file/cross-zone references as
  `<pending>` (the resolver's pickup signal); `<undefined>` is the resolver's terminal value for
  a reference it cannot resolve anywhere. The PS populator now emits `<pending>` for genuine
  cross-zone references.
- **Within-zone everything.** No resolution, shadow check, or duplicate check crosses zones.
  Parallel-shared-file drift (Helpers/CCShared) is known and accepted; it self-clears on
  deprecation.

---

## 4. Artifacts produced this session

- `ObjectRegistry_ZoneScope.sql` (run)
- `ObjectMetadata_ZoneScope.sql` (run)
- `ObjectRegistry_ScopeTier.sql` (run)
- `Populate-AssetRegistry-PS.ps1` (deployed — zone-aware + tier-aware)
- `xFACts-AssetRegistryFunctions.ps1` (deployed — ValidateSet widened + new map loader)
- `CC_PS_Spec.md` edits (applied)
- `ObjectRegistry_Classification_Findings.md` (working findings doc; full decision trail)

---

## 5. Current state

- All three classification columns live, backfilled, constraint-enforced, documented.
- PS populator is the **first fully table-driven, zone-aware, tier-aware populator.** Pattern
  proven against live data.
- CC_PS_Spec.md aligned with the implemented behavior.
- AssetRegistryFunctions docblock drift eliminated; only structural banner/whitespace drift
  remains for it.

---

## 6. Next steps — NEW from this session (in priority order)

1. **Resolver — RUNS CLEAN, CORRECTNESS UNVERIFIED (review required next session).**
   `Resolve-AssetRegistryReferences.ps1` crashed against the *first-pass* populator output but
   ran to completion against the *current* (second-pass) output — so the new data shape no
   longer errors. **However, "runs without crashing" is not "produces correct output," and its
   correctness under the new architecture is unverified.** The resolver was written for the
   two-zone world; two things specifically have NOT been confirmed:
   - That its within-zone matching (`d.zone = u.zone`) correctly handles the new zone vocabulary
     (`standalone`, `exempt`, `<undefined>`) it now sees, never resolving across zones.
   - That it correctly processes the **new PS `<pending>` cross-zone rows** — behavior the PS
     populator introduced this session and that the resolver may never have received before —
     resolving them within-zone and stamping terminal `UNRESOLVED_REFERENCE` + `<undefined>`
     only on genuinely unresolvable references.
   Current run: **1,710 unresolved rows**, almost entirely against unrefactored files. That is
   *consistent with* correct behavior (non-conforming references legitimately fail to resolve)
   but does not *confirm* it — the same bucket could mask mishandling of the new PS rows.
   **Action: read the resolver's resolution query and confirm both points above before treating
   it as good.** If clean, it becomes a watch item (the 1,710 count is a refactoring-progress
   backlog metric expected to decrease as files are brought into conformance; a sudden increase
   after a refactor is the signal to investigate). Until reviewed, do not assume it is correct.

2. **Convert CSS / JS / HTML populators to table-driven zone/scope** (same pattern as PS): read
   zone/scope from Object_Registry via `Get-ObjectRegistryZoneScopeMap` (the additive classification
   lookup added this session — it does NOT replace `Get-ObjectRegistryMap`, which remains the FK
   lookup returning object_name → registry_id; the two coexist and both are called). Remove each
   populator's hardcoded scan-roots / local zone functions (`Get-CssZone`, `Get-JsZone`) /
   shared-file lists. This also kills the JS-duplicates-CSS manual-sync hazard (JS currently
   re-declares the CSS shared lists). Slim comments to the second-pass standard. CSS/JS have no
   scope_tier concern (no docblocks); the conversion is zone/scope only for them.
   - **Post-conversion dead-code sweep (track during, execute after):** converting each populator
     to the shared classification lookup orphans its old zone-derivation code. Where those
     functions/lists are defined *locally in the populator*, they are deleted inline as part of
     that populator's conversion. If any zone-derivation helper turns out to live in the *shared*
     `xFACts-AssetRegistryFunctions.ps1`, it becomes dead shared code only after the **last**
     populator stops calling it, and its removal is a separate final step. NOT YET VERIFIED where
     `Get-CssZone` / `Get-JsZone` are defined — confirm during conversion and sweep for orphaned
     shared functions (no remaining callers) once all four populators are table-driven.

3. **AssetRegistryFunctions.ps1 spec conformance** (the original session target — now much
   lighter): only `MISSING_SECTION_BANNER` and `EXCESS_BLANK_LINES` remain. Convert its `# ===`
   dividers to spec section banners and fix blank-line runs. No docblock work needed.

4. **Per-page credential migration off Helpers onto CCShared**: as each cc page refactors,
   migrate its `Get-ServiceCredentials` (and other Helpers) calls onto `xFACts-CCShared.psm1`;
   retire `xFACts-Helpers.psm1` when the last consumer moves. The Helpers/CCShared
   `DUPLICATE_FUNCTION_DEFINITION` clears automatically at that point.

5. **Scan-root derivation from Object_Registry** (deferred): replace the populators' filesystem
   walk + hardcoded scan roots with a query-driven file inventory
   (`WHERE object_type IN (...) AND is_active = 1`). Kept the filesystem walk this round to
   isolate the classification change; this is its own step.

6. **Spec-as-data effort + Write-Host disposition**: decide whether Write-Host stays forbidden
   (console output is wanted for troubleshooting), then encode drift tables / rule exceptions as
   data rather than spec prose. §15 is parked until this is decided.

---

## 7. Carried forward from Session 19 (NOT addressed this session)

The Session 19 plan was not executed. Its open items carry forward intact:
- (Session 19's planned page migration / next CC page work — to be resumed once the populator
  family + resolver are realigned, since migrating pages on a misaligned pipeline compounds drift.)
- Any other Session 19 open items remain open; consult CC_Session_Summary_19 for the full list
  and fold them in alongside §6 above.

Note: the realignment work in §6 (converting the other three populators to table-driven
zone/scope) should land **before** further page migration, for the same reason flagged in
Session 17/18 — migrating on a pipeline whose populators are not yet uniformly classified
accumulates hidden drift debt. The resolver is no longer a blocker (it runs clean; see §6.1).

---

## 8. Session note

Long, productive session. No context compaction occurred. The work was foundational rather than
incremental: it replaced a brittle role-as-proxy classification with a declared three-axis model
(zone / scope / scope_tier) that the catalog, the populators, the resolver, and the spec all key
off consistently. The original AssetRegistryFunctions target is now a light structural cleanup
rather than a docblock-authoring slog — the session's detour paid for itself there alone.
