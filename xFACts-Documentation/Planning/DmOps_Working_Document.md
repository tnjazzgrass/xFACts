# DmOps — Consumer-Level Archive Working Document

Active working document for the DmOps Archive redesign initiated April 25, 2026. This document covers the consumer-level archive model that replaces the prior account-level archive approach. The previous account-level working document has been archived offline as historical reference.

---

## 1. Why We Pivoted

### The Problem

The original account-level archive process (TA_ARCH tag-driven, ~117-step delete sequence) tested cleanly through 800+ batches against DM-TEST-APP and was on the verge of production rollout. Final UI validation revealed a structural flaw the FK chain analysis could not have surfaced.

**The distributed payment scenario:**

When a consumer makes a payment that is distributed across multiple accounts (a routine occurrence — e.g., a $50 payment splitting $25 to one account and $25 to another), DM stores this as:

- One row in `cnsmr_pymnt_jrnl` (consumer-level) — total payment amount: $50
- One row in `cnsmr_accnt_pymnt_jrnl` per account that received a portion — $25 each
- Corresponding `cnsmr_accnt_trnsctn` rows on each receiving account

The account-level archive process correctly deletes all account-level financial transactions for archived accounts. But because the process operates *only at the account level*, it leaves the consumer-level `cnsmr_pymnt_jrnl` row intact — including the full $50 amount.

If only one of the two receiving accounts is archived (the other has not yet aged out of retention), the surviving account is now linked to a `cnsmr_pymnt_jrnl` row claiming a $50 payment, but only $25 of corresponding account-level activity exists. **The DM application UI rejects this state and refuses to display the consumer's financial activity.**

### Why "Just Modify the Journal" Isn't an Option

- Adjusting the journal amount to match what's left would falsify a financial record — likely illegal, certainly inappropriate
- Deleting the journal row is impossible — it's still tied to a live, non-archived account
- There is no clean "split the journal" operation in DM — payment journals are atomic by design

### The Resolution

Move the archive driver from account-level to consumer-level. A consumer becomes archive-eligible only when **all** of their accounts qualify for archiving. When that condition is met, the consumer is archived in full — every account, every account-level transaction, every consumer-level record including `cnsmr_pymnt_jrnl`. There is no mismatch state because there is no surviving account to mismatch with.

This shifts the archive from "delete aged accounts" to "delete consumers who have nothing left worth keeping," which is structurally what archiving should mean for a debt collection platform.

### Population Impact

- Previous TA_ARCH-driven population: ~20M accounts (~9.5M consumers, with ~14M of those accounts on partial-eligibility consumers we can't safely process)
- New TC_ARCH-driven population: ~14M accounts on consumers where every account qualifies
- Net reduction: ~6M accounts excluded from the initial wave (they remain on consumers with at least one ineligible account; they'll be picked up when their stragglers eventually age out)

---

## 2. The New Model

### Tagging Strategy

**TA_ARCH (account tag) — unchanged.** Existing nightly DM job continues applying TA_ARCH to accounts meeting age and payment-history retention criteria. This tag remains policy-correct on its own merits — it simply stops being our process driver.

**TC_ARCH (consumer tag) — new.** A separate DM job evaluates each consumer and applies TC_ARCH when **every account on the consumer carries TA_ARCH**. The TC_ARCH job is currently running ad-hoc (~1.1M consumers tagged so far against the ~14M target population) for a "catch-up" pass. Once the bulk population is tagged, the job moves to a nightly schedule alongside the TA_ARCH job.

TC_ARCH is informational and low-priority — it has no operational impact on a consumer's day-to-day handling in DM. It is purely a marker for the xFACts archive process.

### Runtime Re-Verification (Mandatory)

TC_ARCH is point-in-time. The TC_ARCH apply-job runs nightly after TA_ARCH and tags newly-eligible consumers — new TA_ARCH-tagged accounts cascade naturally into TC_ARCH eligibility on the same nightly cycle. The job does not re-audit consumers already carrying TC_ARCH. Between the apply pass and when the archive process picks a tagged consumer up, new accounts can merge into the consumer (new business loads, account splits, manual activity). Any new account arrives without TA_ARCH, which immediately invalidates the consumer's TC_ARCH eligibility — but the tag remains in place until the archive process detects the change and removes it.

**Every batch must re-verify each TC_ARCH consumer at the moment of processing.** The check is conceptually simple:

```
For each consumer in the candidate batch:
  If any account on this consumer lacks the TA_ARCH tag:
    1. Remove the consumer from this batch (do not process)
    2. Soft-delete the TC_ARCH row in cnsmr_Tag (sft_delete_flg = 'Y' + audit fields)
    3. Write an AR event to cnsmr_accnt_ar_log noting the tag removal
    4. Log the exception to Archive_ConsumerExceptionLog
  Otherwise:
    Consumer proceeds into the batch's delete sequence
```

The batch processes whatever consumers pass the check. No backfill — if 200 of 10,000 candidates fail re-verification, the batch processes 9,800 and the 200 are released back to the DM job for future re-tagging once their account state changes.

### Tag Removal Mechanism

Direct SQL update + insert is the chosen path:

- **Why not API/DM Job:** API calls are slow at scale (potentially hundreds of exceptions per batch in early runs); DM Jobs require explicit triggering and are slower still
- **Why not BDL:** Stacking up small BDLs per batch creates a mess and adds latency
- **Why direct SQL:** Two operations per excepted consumer (UPDATE the tag row + INSERT the AR event), both targeting tables with proper indexing — fast and predictable

### AR Event Format

The removal event is written as a standard internal-comment-style entry to `cnsmr_accnt_ar_log`:

- `cnsmr_id` — the consumer the tag was removed from
- `cnsmr_accnt_id` — implicitly NULL (consumer-level event)
- `actn_cd` — `CC` (internal comment) — resolved from GlobalConfig at startup
- `rslt_cd` — `CC` (internal comment) — resolved from GlobalConfig at startup
- `wrkgrp_id` — the consumer's current `cnsmr.wrkgrp_id` at the moment of detection (joined into the re-verification query, no per-consumer round-trip)
- `cnsmr_accnt_ar_log_crt_usr_id` — service account user_id, resolved from GlobalConfig at startup
- `cnsmr_accnt_ar_mssg_txt` — message text from GlobalConfig
- `upsrt_dttm` — `GETDATE()`
- `upsrt_soft_comp_id` — `113` (xFACts software component, hardcoded)
- `upsrt_trnsctn_nmbr` — `0` (initial insert)
- `upsrt_usr_id` — same service account user_id as `cnsmr_accnt_ar_log_crt_usr_id`

The CC/CC pairing excludes this event from outbound client-facing reporting, which is appropriate — these are internal retention-management actions, not anything clients need to be notified about. The apply-job's own actn_cd/rslt_cd values are irrelevant to the removal logic; the two events do not need to match.

### Re-Verification Query (Pattern B — Eligibility Logic Mirroring)

The runtime check uses the same eligibility logic the TC_ARCH apply-job uses (count of consumer's accounts equals count of those accounts carrying active TA_ARCH), inverted to find consumers in the candidate batch who *no longer* satisfy that condition.

The advantage of mirroring the apply-job logic exactly: any future changes to TC_ARCH eligibility criteria can be made in one place (the apply-job) and the re-verification query can be updated to match without behavioral drift. Behavior between apply and re-verify stays consistent by design.

The query returns, in a single result set per batch:

- `cnsmr_id` — the excepted consumer
- `wrkgrp_id` — pulled from `cnsmr.wrkgrp_id` for the AR event insert
- `cnsmr_idntfr_agncy_id` — for the exception log entry

No per-consumer round-trip is needed — one query produces everything required to process all exceptions in the batch.

Mirrors the row state the apply-job creates, with audit fields incremented appropriately:

- `cnsmr_tag_sft_delete_flg = 'Y'`
- `upsrt_dttm = GETDATE()`
- `upsrt_trnsctn_nmbr = upsrt_trnsctn_nmbr + 1` (incremented from existing value)
- `upsrt_soft_comp_id = 113` (xFACts software component)
- `upsrt_usr_id` — same service account user_id resolved from GlobalConfig

Filter: `WHERE cnsmr_id = @cnsmr_id AND tag_id = @tcArchTagId AND cnsmr_tag_sft_delete_flg = 'N'` — scoped to the active TC_ARCH row only, never affecting any other tag the consumer carries.

### Parameterization Design

GlobalConfig holds human-readable values; the script resolves them to internal IDs at startup via single-query lookups. This keeps the Admin UI legible (`'CC'`, `'sqlmon'`) and lets operations team update values without code changes:

| setting_name | initial value | lookup table | match column | resolved column | active filter |
|--------------|---------------|--------------|--------------|-----------------|---------------|
| `tag_removal_actn_cd` | `CC` | `dbo.actn_cd` | `actn_cd_shrt_val_txt` | `actn_cd` (smallint) | `actn_cd_actv_flg = 'Y'` |
| `tag_removal_rslt_cd` | `CC` | `dbo.rslt_cd` | `rslt_cd_shrt_val_txt` | `rslt_cd` (smallint) | `rslt_cd_actv_flg = 'Y'` |
| `tag_removal_user` | `sqlmon` | `dbo.usr` | `usr_usrnm` | `usr_id` (bigint) | `usr_actv_flg = 'Y'` |
| `tag_removal_msg_txt` | `Consumer archive tag removed - ineligible account(s) detected` | (no lookup) | — | — | — |

Plus one runtime-resolved value (no GlobalConfig entry, since `TC_ARCH` is the fixed tag identifier this script always operates on):

| Cached value | lookup table | match column | resolved column | active filter |
|--------------|--------------|--------------|-----------------|---------------|
| `$Script:TcArchTagId` | `dbo.tag` | `tag_shrt_nm` = `'TC_ARCH'` | `tag_id` (bigint) | `tag_actv_flg = 'Y'` |

All five lookups happen at script startup as part of the standard configuration phase. Failed lookups (misconfigured short value, deleted user, missing tag) cause the script to fail-fast and exit before opening the persistent connection — better to surface configuration problems immediately than to encounter cryptic errors deep in batch processing.

Hardcoded values (no parameterization needed):

- `upsrt_soft_comp_id = 113` — xFACts software component ID, fixed across environments
- `cnsmr_tag_sft_delete_flg = 'Y'` — the action itself

### Unified Delete Sequence

The unified consumer archive runs both the account-level delete sequence (currently in `Execute-DmArchive.ps1` Phase 2, ~117 steps) AND the consumer-level delete sequence (currently in `Execute-DmShellPurge.ps1` Phase 2, ~110 steps) within the same batch.

**Order of execution:**

1. Account-level UDEFs (dynamic discovery)
2. Account-level Phase 2 sequence (orders 1-117) — strips down all account child tables, terminates at `cnsmr_accnt`
3. **BIDATA P→C migration** — migrates the account's financial reporting snapshot to static C tables, applies anonymization and purge flags
4. Consumer-level UDEFs (dynamic discovery)
5. Consumer-level Phase 2 sequence (orders 1-110) — strips down all consumer child tables, terminates at `cnsmr`

After step 2 the consumer is functionally a shell (no accounts). After step 5 the consumer is gone entirely.

### BIDATA Timing — Why In The Middle

BIDATA migration sits between the two delete halves, not at the start and not at the end. The reasoning:

- **Not at the start:** If migration runs first and the OLTP delete sequence subsequently fails, the next 1:00 AM BIDATA build will repopulate the P table from OLTP (the account still exists in OLTP). The C table now has the same row the rebuilt P table re-creates. The UNION view shows duplicates. Reporting integrity is broken.

- **Not at the end:** If the consumer-level delete sequence completes successfully but BIDATA migration fails, the consumer is gone from OLTP entirely with no reporting record migrated. The account history is lost forever. Worst-case outcome.

- **In the middle (chosen):** Account-level deletes complete first, removing accounts from OLTP. BIDATA then migrates the financial snapshot to C — safe to do because the next BIDATA build will not regenerate P rows for accounts that no longer exist in OLTP. If consumer-level deletes subsequently fail, the consumer is in a recoverable "near-shell" state — accounts deleted, BIDATA migrated, consumer record still in place. Retry can complete the consumer-level work without compromising BIDATA integrity.

This is also the simplest mental model: BIDATA's job is to capture the financial record of an *account*. Once accounts are deleted from OLTP, that work is done — migrate immediately, then proceed to consumer cleanup.

---

## 3. Component Scope

### What's New

- **`Execute-DmConsumerArchive.ps1`** — new unified script. Combines TC_ARCH selection, re-verification, account-level deletes, BIDATA migration, and consumer-level deletes into a single batch flow.
- **TC_ARCH consumer tag** — new tag in `cnsmr_Tag`, applied by the new TC_ARCH apply-job that runs nightly in DM JobFlow after the TA_ARCH job. Catch-up pass complete; full ~14M target population currently tagged.
- **`Archive_ConsumerExceptionLog`** — new tracking table. Captures each TC_ARCH removal performed by the runtime re-verification check.
- **TC_ARCH cleanup logic** — runtime re-verification + tag soft-delete + AR event insert (CC/CC), integrated into the batch selection phase

### What's Reused (Largely Unchanged)

- **Account-level delete sequence** (~117 steps, 11 FK-required additions from March 28, retry-aware) — drops in as-is from current `Execute-DmArchive.ps1` Phase 2
- **Consumer-level delete sequence** (~110 steps, March 30 redesign with UPDATE infrastructure for cross-consumer suspense) — drops in as-is from current `Execute-DmShellPurge.ps1` Phase 2
- **BIDATA P→C migration** — atomic INSERT/DELETE pattern, count validation, transaction-wrapped, anonymization with per-table SET clauses, purge flag updates — unchanged from current archive script
- **Failed batch retry** — ConsumerLog-based reseed, `batch_retry` / `retry_batch_id` columns, `Retry` schedule_mode — unchanged from current archive script
- **Schedule infrastructure** — `Archive_Schedule` table (7×24 hourly grid, blocked/full/reduced), abort flag, GlobalConfig-driven batch sizing with in-flight refresh — unchanged
- **Persistent SqlConnection + temp table architecture** — single connection per session, materialized intermediate ID tables, temp table joins (no IN clause limits) — unchanged
- **Logging infrastructure** — Archive_BatchLog, Archive_BatchDetail, Archive_ConsumerLog write patterns — unchanged
- **Teams alerting** — Send-TeamsAlert integration with alerting_enabled GlobalConfig toggle — unchanged
- **66 FK supporting indexes** already deployed against crs5_oltp (41 for account-level, 25 for consumer-level) — all still applicable, no changes needed
- **DM Operations CC page** — existing page (DmOperations.ps1, DmOperations-API.ps1, dm-operations.css, dm-operations.js) — mostly carries forward unchanged. Cosmetic touch-ups needed to reflect that Archive is now the primary process and ShellPurge is the peripheral one

### What's Untouched

- **`Execute-DmShellPurge.ps1`** — stays exactly as-is. Its scope narrows (no longer the primary cleanup mechanism for archive-produced shells), but it still handles ~6.4M existing shells already in WFAPURGE plus ongoing shells from natural sources (new-business loads, consumer merges, etc.)
- **Shell purge tables** (`ShellPurge_BatchLog`, `ShellPurge_BatchDetail`, `ShellPurge_ConsumerLog`, `ShellPurge_Schedule`, `ShellPurge_ExclusionLog`) — unchanged
- **Shell purge exclusion logic** — unchanged for now. The exclusion checks are a defense for the "we're processing opportunistically with limited context" model, which still applies for naturally-occurring shells. The Phase 3 deliverable revisits this once the unified archive is producing data.
- **Archive component tables** (`Archive_BatchLog`, `Archive_BatchDetail`, `Archive_ConsumerLog`, `Archive_Schedule`) — unchanged. Names still fit (still archiving — just at consumer-level now). Possible additions: a column on Archive_BatchLog to track exception counts per batch (TBD).

### What's Archived

- **`Execute-DmArchive.ps1`** — moves to `xFACts-PowerShell/Reference/Execute-DmArchive_AccountLevel.ps1`. Preserved as reference for the account-level approach. Not deleted — there's potential value in revisiting account-level archiving down the road with different driving logic.
- **Old `DmOps_Working_Document.md`** — removed from Planning/, archived offline.

---

## 4. Integration Points

### TC_ARCH Apply-Job

- **Owner:** DM JobFlow (job created and deployed by Dirk)
- **Mechanism:** DM Job that evaluates consumer eligibility (all accounts have TA_ARCH and the consumer doesn't already carry TC_ARCH) and inserts/activates the TC_ARCH row in `cnsmr_Tag`
- **Schedule:** Runs nightly, after the TA_ARCH apply-job. New TA_ARCH-tagged accounts cascade naturally into TC_ARCH eligibility on the same nightly cycle. The job does not re-audit consumers already carrying TC_ARCH — that's xFACts' responsibility at runtime.
- **State:** Catch-up pass complete; full ~14M target population tagged
- **xFACts dependency:** None at the orchestration layer. The job runs independently in DM JobFlow. xFACts queries `cnsmr_Tag` for active TC_ARCH rows during batch selection.

### Archive_ConsumerExceptionLog

xFACts-side audit trail for consumers that were selected as TC_ARCH-tagged but failed runtime re-verification (one or more accounts lack TA_ARCH). Volume is expected to be modest in steady state — the tag was accurate when the apply-job ran; the consumer simply changed afterward (typically a new account merging in).

Proposed columns:

| Column | Type | Notes |
|--------|------|-------|
| `exception_id` | BIGINT IDENTITY | Primary key |
| `batch_id` | BIGINT | FK to Archive_BatchLog (the batch that detected the exception) |
| `cnsmr_id` | BIGINT | The consumer removed from the batch |
| `cnsmr_idntfr_agncy_id` | VARCHAR | Standard audit field |
| `detected_dttm` | DATETIME | When xFACts detected the state change |
| `tag_removed` | BIT | Confirmation the cnsmr_Tag soft-delete succeeded |
| `ar_event_written` | BIT | Confirmation the AR event insert succeeded |

Single, well-defined reason exists ("at least one account on this consumer lacks TA_ARCH"), so no per-row reason column is needed. The two confirmation bits remain because they are operationally meaningful — if either fails, that consumer needs manual attention.

DDL design will be finalized once the unified script's selection flow is implemented.

### Shell Purge Boundary

Two distinct populations now:

- **Archive-produced ex-consumers** — fully deleted by the unified consumer archive. Never reach shell purge. Their `cnsmr` record is gone at the end of the same batch that removed their accounts.
- **Naturally-occurring shells** — consumers that became orphaned via routes other than the unified archive (existing 6.4M WFAPURGE backlog from prior history; ongoing daily shells from new-business loads, consumer merges, manual activity). These continue to flow through `Execute-DmShellPurge.ps1` exactly as they do today.

There is no overlap. The unified archive does not need to coordinate with shell purge — they operate on disjoint populations. They do share the same FK indexes and the same target server, but that's true of any two processes hitting crs5_oltp.

---

## 5. Phased Deliverables

### Phase 1 — Build, Deploy, Validate (Current)

The current session and the immediately-following work that gets the unified script into production.

**Settled in design:**
- [x] **TC_ARCH selection query design** — Pattern B (mirror apply-job eligibility logic, inverted to find batch exceptions). Single query returns cnsmr_id + wrkgrp_id + agency_id with no per-consumer round-trips.
- [x] **Re-verification query design** — Same query as selection; the result identifies consumers no longer meeting eligibility.
- [x] **AR event format** — CC/CC actn/rslt pair, parameterized via GlobalConfig with startup lookups. Message text and service account user also parameterized.
- [x] **Tag soft-delete UPDATE format** — Audit field increments confirmed; service account user from GlobalConfig.

**Remaining work for Phase 1:**

- [ ] **Phase 1 prerequisites deployment script** — `Archive_ConsumerExceptionLog` table DDL + four `GlobalConfig` INSERT rows + verification queries that resolve the four lookups to confirm setup is correct
- [ ] **Execute-DmConsumerArchive.ps1** — Build, integrate dot-sourced functions, validate against test environment
- [ ] **Move legacy archive script** — Relocate `Execute-DmArchive.ps1` to `Reference/Execute-DmArchive_AccountLevel.ps1`
- [ ] **ProcessRegistry entry** — Register Execute-DmConsumerArchive.ps1 with the orchestrator. Pattern 3 (time-based with polling) — same as BIDATA monitoring
- [ ] **Existing GlobalConfig review** — Existing DmOps.Archive entries (target_instance, bidata_instance, batch_size, batch_size_reduced, chunk_size, alerting_enabled, archive_abort, bidata_build_job_name) carry forward unchanged. The four new tag-removal entries are added by the prerequisites script.
- [ ] **Batch sizing** — Start small (5K-10K consumers) given the unified delete sequence does materially more work per batch than the account-level archive did. Tune up via GlobalConfig once real numbers come in.
- [ ] **Schedule windows** — Reuse existing 7am-11pm pattern (full evenings/weekends, reduced business hours, blocked overnight). The 2-hour buffer to BIDATA's 1am rebuild is still sufficient.
- [ ] **Failed batch retry validation** — Confirm the retry path (ConsumerLog-based reseed) works through the now-longer unified sequence. The path is structurally unchanged but covers more ground per retry.
- [ ] **Object_Metadata generation** — Once the design is implemented and verified, generate Object_Metadata + Object_Registry inserts as a follow-up deployment step (per platform convention, never bundled with DDL)
- [ ] **CC page touch-ups** — Cosmetic adjustments to DM Operations page reflecting Archive as primary, ShellPurge as peripheral. Add a section for the exception log. Lifetime-totals math may need adjustment.
- [ ] **Documentation page rewrites** — `dmops.html` and `dmops-arch.html` updated to reflect the consumer-level model.

### Phase 2 — Step Necessity Audit

Once the unified flow is running and producing data, walk both delete sequences against actual production behavior to identify steps that have never deleted a row across all batches. Candidates for removal — but only after data confirms the FK chain doesn't strictly require them.

- [ ] **Account-level sequence audit** — All ~117 steps in the inherited Phase 2 sequence. Identify zero-row steps from `Archive_BatchDetail` historical data.
- [ ] **Consumer-level sequence audit** — All ~110 steps in the inherited Phase 2 sequence (formerly Shell Purge Phase 2). Same zero-row identification.
- [ ] **FK validation for removal candidates** — For each candidate, verify via `sys.foreign_keys` that no FK constraint requires the step to fire.
- [ ] **Trim and redeploy** — Remove confirmed-unnecessary steps. Update component documentation. Bump System_Metadata version.

The goal is a streamlined sequence with no extras — every step earns its place by either deleting rows in observed practice or being structurally required by FK constraints.

### Phase 3 — Shell Purge Exclusion Review

Once the unified archive is producing data, validate which of Shell Purge's seven exclusion reasons remain meaningful for naturally-occurring shells. The unified archive should leave no exclusion-eligible state behind for its own consumers (it deletes everything), but historical shells already in WFAPURGE and naturally-arriving shells from merges/loads may still encounter these conditions.

- [ ] **Volume analysis** — How many naturally-occurring shells trigger each exclusion reason in steady state?
- [ ] **Per-reason validation** — For each exclusion (cnsmr_pymnt_jrnl, dcmnt_rqst, agnt_crdtbl_actvty, agnt_crdtbl_actvty_via_smmry, agnt_crdt, bnkrptcy, schdld_pymnt_smmry, sspns_unresolved_cross_consumer): is the underlying concern still real, or has the data state changed such that the exclusion is no longer needed?
- [ ] **Trim or expand exclusions** — Adjust the Shell Purge exclusion check array based on findings. Update component documentation.

The goal is alignment between Shell Purge's exclusion logic and the actual edge cases the data produces — no defensive checks that never fire, no missing checks that could let unsafe deletions through.

---

## 6. Reference Files

| File | Location | Status |
|------|----------|--------|
| Execute-DmConsumerArchive.ps1 | `E:\xFACts-PowerShell\` | **To be built** |
| Execute-DmArchive.ps1 (legacy) | `E:\xFACts-PowerShell\Reference\` | **To be relocated** (currently at `E:\xFACts-PowerShell\`) |
| Execute-DmShellPurge.ps1 | `E:\xFACts-PowerShell\` | Unchanged |
| DmOperations.ps1 | `E:\xFACts-ControlCenter\scripts\routes\` | Cosmetic touch-ups pending |
| DmOperations-API.ps1 | `E:\xFACts-ControlCenter\scripts\routes\` | Cosmetic touch-ups pending |
| dm-operations.css | `E:\xFACts-ControlCenter\public\css\` | Cosmetic touch-ups pending |
| dm-operations.js | `E:\xFACts-ControlCenter\public\js\` | Cosmetic touch-ups pending |
| dmops.html | `E:\xFACts-ControlCenter\public\docs\pages\` | Rewrite pending |
| dmops-arch.html | `E:\xFACts-ControlCenter\public\docs\pages\arch\` | Rewrite pending |
| Archive_BatchLog / BatchDetail / ConsumerLog / Schedule | DmOps schema | Unchanged |
| ShellPurge_BatchLog / BatchDetail / ConsumerLog / Schedule / ExclusionLog | DmOps schema | Unchanged |
| Archive_ConsumerExceptionLog | DmOps schema | **To be created** |

---

## 7. Version Bumps (Pending)

The following version bumps will be entered via the Admin UI as work proceeds. None applied yet.

**Module: DmOps → Component: DmOps.Archive**
*Pending:* Pivot from account-level to consumer-level archive. New script Execute-DmConsumerArchive.ps1 unifies account-level + consumer-level delete sequences into a single batch flow driven by TC_ARCH consumer tag. Adds runtime TC_ARCH re-verification with tag soft-delete + AR event for excepted consumers. Adds Archive_ConsumerExceptionLog table. Existing account-level Execute-DmArchive.ps1 archived to Reference for potential future revival. Component description updated to reflect consumer-level model.

**Module: DmOps → Component: DmOps.ShellPurge**
*No change planned.* ShellPurge continues as peripheral process for naturally-occurring shells.

**Module: ControlCenter → Component: ControlCenter.DmOperations**
*Pending (Phase 1):* CC page cosmetic adjustments reflecting Archive as primary process and ShellPurge as peripheral. Add exception log display section. Documentation page rewrites.
