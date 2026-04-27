# DmOps — Consumer-Level Archive Working Document

Master working document for the unified consumer archive build. Single source of truth covering design, current state, test results, and outstanding work. Temporary doc — retires once the build is operational and rolled into permanent documentation.

**Last meaningful update:** 2026-04-26, after the 11-batch test campaign on DM-TEST-APP.

---

## 1. Why We Pivoted

### The Account-Level Problem

The original account-level archive process (TA_ARCH-driven, 117-step delete sequence) tested cleanly through 800+ batches and was on the verge of production rollout. Final UI validation revealed a structural flaw the FK chain analysis could not have surfaced.

**The distributed payment scenario:** When a consumer makes a payment that gets distributed across multiple accounts (a routine occurrence — e.g., a $50 payment splitting $25 to each of two accounts), DM stores it as one row in `cnsmr_pymnt_jrnl` (consumer-level, full $50) plus one row in `cnsmr_accnt_pymnt_jrnl` per receiving account ($25 each).

The account-level archive correctly deletes the account-level financial transactions for archived accounts but leaves the consumer-level `cnsmr_pymnt_jrnl` row intact — including the full $50 amount. If only one of two receiving accounts is archived, the surviving account is now linked to a journal claiming $50 but only $25 of corresponding activity exists. **The DM UI rejects this state and refuses to display the consumer's financial activity.**

There is no clean fix at the account level — adjusting the journal amount falsifies a financial record, deleting it is impossible while a non-archived account still references it, and DM has no "split the journal" operation. The journal is atomic by design.

### The Resolution

Move the archive driver from account-level to consumer-level. A consumer becomes archive-eligible only when **all** of their accounts qualify. When that condition is met, the consumer is archived in full — every account, every transaction, every consumer-level record including `cnsmr_pymnt_jrnl`. There is no mismatch state because there is no surviving account to mismatch with.

This also restructures archiving to mean "delete consumers who have nothing left worth keeping" rather than "delete aged accounts," which is what archiving should structurally mean for a debt collection platform.

### Population Impact

- Previous TA_ARCH-driven population: ~20M accounts (~9.5M consumers, with ~14M of those accounts on partial-eligibility consumers we couldn't safely process).
- New TC_ARCH-driven population: ~14M accounts on consumers where every account qualifies.
- Net reduction: ~6M accounts excluded from initial wave (they remain on consumers with at least one ineligible account; picked up when the stragglers eventually age out).

---

## 2. The Model

### Tagging Strategy

**TA_ARCH (account tag) — unchanged.** Existing nightly DM job continues applying TA_ARCH to accounts meeting age and payment-history retention criteria. Tag remains policy-correct on its own merits — it simply stops being our process driver.

**TC_ARCH (consumer tag) — new, deployed.** Separate DM job evaluates each consumer and applies TC_ARCH when every account on the consumer carries TA_ARCH. Catch-up pass complete; ~14M target population currently tagged. Job runs nightly after the TA_ARCH job. New TA_ARCH-tagged accounts cascade naturally into TC_ARCH eligibility on the same nightly cycle. The job does not re-audit consumers already carrying TC_ARCH — that's xFACts' responsibility at runtime.

TC_ARCH is informational and low-priority — no operational impact on a consumer's day-to-day handling in DM. Purely a marker for the xFACts archive process.

### Runtime Re-Verification

TC_ARCH is point-in-time. Between the apply pass and when the archive process picks a tagged consumer up, new accounts can merge into the consumer (new business loads, account splits, manual activity). Any new account arrives without TA_ARCH, which immediately invalidates the consumer's TC_ARCH eligibility — but the tag remains in place until xFACts detects the change and removes it.

**Every batch must re-verify each TC_ARCH consumer at the moment of processing.** For each excepted consumer:

1. Unconditionally remove from current batch (first action — guaranteed even if subsequent best-effort writes fail)
2. Soft-delete the TC_ARCH row in `cnsmr_Tag` (best-effort)
3. Write an AR event to `cnsmr_accnt_ar_log` noting the tag removal (best-effort)
4. Append to `Archive_ConsumerExceptionLog` with confirmation flags

The batch processes whatever consumers pass the check. No backfill — if 200 of 10,000 candidates fail re-verification, the batch processes 9,800 and the 200 are released back to the DM job for future re-tagging once their account state changes.

### Re-Verification Query Pattern (Pattern B — Eligibility Logic Mirroring)

The runtime check uses the same eligibility logic the TC_ARCH apply-job uses (count of consumer's accounts equals count of those accounts carrying active TA_ARCH), inverted to find consumers in the candidate batch who *no longer* satisfy that condition. Any future changes to TC_ARCH eligibility can be made in one place (the apply-job) and the re-verification query updated to match without behavioral drift.

The query returns, in a single result set per batch, `cnsmr_id` + `wrkgrp_id` + `cnsmr_idntfr_agncy_id` for each excepted consumer — no per-consumer round-trips needed.

### Tag Removal — Direct SQL Path

Direct SQL UPDATE + INSERT is the chosen path:

- **Not API/DM Job:** API calls slow at scale; DM Jobs require explicit triggering and are slower still.
- **Not BDL:** Stacking small BDLs per batch creates a mess and adds latency.
- **Direct SQL:** Two operations per excepted consumer (UPDATE the tag row + INSERT the AR event), both targeting tables with proper indexing — fast and predictable.

### AR Event Format

Standard internal-comment-style entry to `cnsmr_accnt_ar_log`:

- `cnsmr_id` — the consumer
- `cnsmr_accnt_id` — implicitly NULL (consumer-level event)
- `actn_cd` — `CC` (internal comment), resolved from GlobalConfig at startup
- `rslt_cd` — `CC`, resolved from GlobalConfig at startup
- `wrkgrp_id` — current `cnsmr.wrkgrp_id` at detection (joined into re-verification query)
- `cnsmr_accnt_ar_log_crt_usr_id` — service account user_id, resolved from GlobalConfig at startup
- `cnsmr_accnt_ar_mssg_txt` — message text from GlobalConfig
- `upsrt_dttm` — `GETDATE()`
- `upsrt_soft_comp_id` — `113` (xFACts software component, hardcoded)
- `upsrt_trnsctn_nmbr` — `0`
- `upsrt_usr_id` — same service account user_id

CC/CC pairing excludes this event from outbound client-facing reporting — appropriate for internal retention-management actions.

### Tag Soft-Delete UPDATE

Mirrors the row state the apply-job creates, with audit fields incremented:

- `cnsmr_tag_sft_delete_flg = 'Y'`
- `upsrt_dttm = GETDATE()`
- `upsrt_trnsctn_nmbr = upsrt_trnsctn_nmbr + 1`
- `upsrt_soft_comp_id = 113`
- `upsrt_usr_id` — service account user_id from GlobalConfig

Filter: `WHERE cnsmr_id = @cnsmr_id AND tag_id = @tcArchTagId AND cnsmr_tag_sft_delete_flg = 'N'` — scoped to the active TC_ARCH row only.

### Parameterization Design

GlobalConfig holds human-readable values; the script resolves them to internal IDs at startup via single-query lookups. Keeps the Admin UI legible (`'CC'`, `'sqlmon'`) and lets operations team update values without code changes.

| setting_name | initial value | lookup table | match column | resolved column | active filter |
|---|---|---|---|---|---|
| `tag_removal_actn_cd` | `CC` | `dbo.actn_cd` | `actn_cd_shrt_val_txt` | `actn_cd` (smallint) | `actn_cd_actv_flg = 'Y'` |
| `tag_removal_rslt_cd` | `CC` | `dbo.rslt_cd` | `rslt_cd_shrt_val_txt` | `rslt_cd` (smallint) | `rslt_cd_actv_flg = 'Y'` |
| `tag_removal_user` | `sqlmon` | `dbo.usr` | `usr_usrnm` | `usr_id` (bigint) | `usr_actv_flg = 'Y'` |
| `tag_removal_msg_txt` | `Consumer archive tag removed - ineligible account(s) detected` | (no lookup) | — | — | — |

Plus one runtime-resolved value (no GlobalConfig entry — TC_ARCH is the fixed tag this script always operates on):

| Cached value | lookup table | match column | resolved column | active filter |
|---|---|---|---|---|
| `$Script:TcArchTagId` | `dbo.tag` | `tag_shrt_nm` = `'TC_ARCH'` | `tag_id` (bigint) | `tag_actv_flg = 'Y'` |

All five lookups happen at startup. Failed lookups (misconfigured short value, deleted user, missing tag) cause fail-fast exit before opening the persistent connection.

### Unified Delete Sequence — BIDATA Timing

The unified script runs both the account-level and consumer-level delete sequences in the same batch. BIDATA P→C migration sits between them — not at the start, not at the end:

- **Not at start:** If migration runs first and the OLTP delete fails, the next 1am BIDATA build repopulates P from OLTP (account still exists). C now duplicates P. UNION view shows duplicates. Reporting integrity broken.
- **Not at end:** If consumer-level deletes succeed but BIDATA migration fails, the consumer is gone from OLTP with no reporting record migrated. Account history is lost forever. Worst case.
- **In the middle:** Account-level deletes complete first, removing accounts from OLTP. BIDATA migrates the financial snapshot to C — safe because the next BIDATA build won't regenerate P rows for accounts no longer in OLTP. If consumer-level deletes subsequently fail, the consumer is in a recoverable "near-shell" state. Retry can complete the consumer-level work without compromising BIDATA integrity.

---

## 3. Current State of the Build

### Execute-DmConsumerArchive.ps1 — DEPLOYED

Built, deployed to `E:\xFACts-PowerShell\` on FA-SQLDBB, and validated through 11 batches against DM-TEST-APP. 3,068 lines, 159KB.

**Main execution flow (Steps 1–13, sequential):**

| Step | Description |
|---|---|
| 1 | Configuration & pre-flight (abort flag, target instance, ServerRegistry, GlobalConfig, batch size, BIDATA build pre-flight, startup lookup resolution) |
| 2 | Open persistent connections (target always; BIDATA only if executing) |
| 3 | Select batch (retry-load OR new TC_ARCH selection) |
| 4 | Create core temp tables, populate `#archive_batch_consumers` |
| 5 | Runtime re-verification (skipped on retry) |
| 6 | Account expansion, materialize account-level temp tables, create BatchLog row |
| 7 | Account-level deletes (Phase 1 UDEFs `AU*` + Phase 2 orders `A1`–`A117`) |
| 8 | BIDATA P→C migration (orders `AB1`–`AB4`) with anonymization & purge flags |
| 9 | Materialize consumer-level temp tables (`#shell_*`) |
| 10 | Consumer-level deletes (Phase 1 UDEFs `CU*` + Phase 2 orders `C1`–`C110`, includes `C86` Step-Update for cross-consumer suspense reference cleanup) |
| 11 | Finalize batch log + Teams alert (on failure) |
| 12 | Continuation check (SingleBatch / abort / BIDATA build / schedule) |
| 13 | Cleanup, session summary, orchestrator callback |

**Order prefix scheme:** Account-level UDEFs `AU1+`, account Phase 2 `A1`–`A117`, BIDATA `AB1`–`AB4`, consumer UDEFs `CU1+`, consumer Phase 2 `C1`–`C110`. Single namespace via prefix; halves can evolve independently without renumbering each other; `BatchDetail.delete_order` queryable by prefix (`WHERE delete_order LIKE 'A%'`).

**Preview mode behavior:** Without `-Execute`, the script is **console + log file output only — zero database writes anywhere**. Logging functions (`New-BatchLogEntry`, `Update-BatchLogEntry`, `Write-BatchDetail`, `Write-ConsumerLog`, `Write-ExceptionLog`) early-return when `$script:XFActsExecute` is false and emit a `[Preview]` console line describing what they would have written. Step 5 re-verification still queries to identify exceptions for accurate preview reporting but skips the UPDATE/INSERT writes against crs5_oltp. Step 8 BIDATA migration is entirely skipped. Step 5's `DELETE FROM #archive_batch_consumers` runs unguarded — it operates on a session-private temp table required so subsequent count queries reflect post-re-verification batch composition.

`$script:XFActsExecute` is set by `Initialize-XFActsScript` (in `xFACts-OrchestratorFunctions.ps1`) and is the canonical platform-wide preview flag. No parallel state variables.

**No duplication of OrchestratorFunctions.** All shared functions (`Get-SqlData`, `Invoke-SqlNonQuery`, `Write-Log`, `Send-TeamsAlert`, `Complete-OrchestratorTask`, etc.) are leveraged from the dot-sourced module. Functions defined locally in the script are DmOps-specific (persistent connection management, deletion sequence orchestration, BIDATA migration, runtime re-verification) and don't duplicate platform infrastructure.

**Switches:**

- `-Execute` — enable real writes; default is preview
- `-SingleBatch` — run exactly one batch and exit
- `-BatchSize <N>` — override GlobalConfig batch size; sets `schedule_mode='Manual'`
- `-NoAnonymize` — skip PII anonymization on BIDATA C tables (purge flags still set)
- `-TargetInstance <server>` — override GlobalConfig target server, bypass ServerRegistry enable check
- `-ChunkSize <N>` — override default chunk size for chunked DELETE/UPDATE
- `-TaskId`, `-ProcessId` — orchestrator callback parameters

### Phase 1 Infrastructure — DEPLOYED

All deployed to production AVG-PROD-LSNR / xFACts:

- **`DmOps.Archive_ConsumerExceptionLog`** table (no FK to BatchLog; `batch_id` retained as audit context only — mirrors `ShellPurge_ExclusionLog` pattern). Columns: `exception_id`, `batch_id`, `cnsmr_id`, `cnsmr_idntfr_agncy_id`, `detected_dttm`, `tag_removed`, `ar_event_written`.
- **`DmOps.Archive_BatchLog.exception_count`** column added (`INT NOT NULL DEFAULT 0`).
- **Four GlobalConfig entries** under `module_name='DmOps'`, `category='Archive'`: `tag_removal_actn_cd`, `tag_removal_rslt_cd`, `tag_removal_user`, `tag_removal_msg_txt`. All with `data_type='VARCHAR'` and `description` populated per platform standards.
- **Object_Registry + Object_Metadata** baselines for `Archive_ConsumerExceptionLog` and the new BatchLog column.

### Settled Design Decisions

- **TC_ARCH selection** trusts the tag at selection time (TOP-N from `cnsmr_Tag` where `tag_id=$tcArchTagId AND cnsmr_tag_sft_delete_flg='N'`). Step 5 does the rigorous eligibility re-verification.
- **Account expansion** drops the TA_ARCH filter — at consumer level, archive everything the consumer owns regardless of account-level tag state.
- **`batch_size_used` semantics:** for new batch = `consumer_count + exception_count` post-re-verification; for retry = `BatchConsumerIds.Count`. BatchLog created AFTER re-verification, so this always reflects actual candidate count.
- **All-excepted batch** finalizes as Success with `consumer_count=0`, `exception_count=N`, `bidata_status=Skipped`. Loop continues.
- **Retry path** loads from `Archive_ConsumerLog` and skips Step 5 entirely — consumers in ConsumerLog already passed re-verification once and are past the point of no return. Uses `'Retry'` schedule_mode.
- **BIDATA failure halts the batch** — consumer-level deletes (Steps 9/10) skipped, leaving the consumer in recoverable near-shell state. **No mid-batch abort** — abort only between full batches.
- **Re-expansion is mandatory** after Step 5 trims consumers. Re-runs account expansion against the trimmed `#archive_batch_consumers` to avoid archiving accounts of excluded consumers.
- **Exceptions handled sequentially** per excepted consumer (UPDATE cnsmr_Tag + INSERT cnsmr_accnt_ar_log + log to ExceptionLog) — set-based not justified given expected modest volume.
- **No FK from `Archive_ConsumerExceptionLog` to `Archive_BatchLog`** — mirrors `ShellPurge_ExclusionLog` pattern; `batch_id` retained as audit context only; allows exception rows to outlive their originating batch if needed.

---

## 4. Test Campaign Results (DM-TEST-APP, 2026-04-26)

11 batches executed. **Zero failures, zero exceptions, zero `tables_failed` across the entire run.**

| batch_id | size | consumers | accounts | rows | duration | bidata |
|---:|---:|---:|---:|---:|---:|---|
| 1 | 10 | 10 | 11 | 1,380 | 4:01 | Success* |
| 2 | 100 | 100 | 167 | 20,189 | 0:58 | Success |
| 3 | 5000 | 5,000 | 11,595 | 1,344,969 | 20:47 | Success |
| 4 | 5000 | 5,000 | 8,189 | 931,950 | 6:03 | Success |
| 5 | 5000 | 5,000 | 9,803 | 975,446 | 5:47 | Success |
| 6 | 5000 | 5,000 | 6,221 | 704,194 | 4:06 | Success |
| 7 | 5000 | 5,000 | 10,655 | 1,066,216 | 7:57 | Success |
| 8 | 5000 | 5,000 | 7,980 | 881,874 | 6:06 | Success |
| 9 | 5000 | 5,000 | 7,446 | 834,119 | 4:52 | Success |
| 10 | 5000 | 5,000 | 9,599 | 1,028,210 | 5:53 | Success |
| 11 | 5000 | 5,000 | 13,447 | 1,303,935 | 8:56 | Success |

*Batch 1 BIDATA AB1 took 172s due to missing indexes — see Lessons Learned below.

### Key Findings

**Throughput.** Batches 4–11 settled into 2,200–2,900 rows/sec, 0.05–0.10 seconds per consumer. Consistent. At this rate, an 8-hour full-mode window archives ~240,000 consumers/night with batch_size 5000 — a useful planning baseline for production schedule tuning.

**Accounts-per-consumer ranged 1.22–2.69** across batches, correlating with rows-per-consumer. Outliers (5+ accounts/consumer) would indicate unusually heavy consumers and would slow that batch significantly. Worth watching in production.

**Batch 3 was the slow one** (20:47 vs ~5–8 min average) — first batch at size 5000 after warmup batches. Buffer cache cold start, plan compilation, possible stat updates triggered by the larger volume. Subsequent 5000-batches at similar volumes ran 3-4× faster. Production's first nightly batch will likely show this same pattern, then settle.

**C53 is the binding throughput constraint.** `cnsmr_accnt_ar_log` consumer-level delete consumed 678 seconds (54% of batch 3) deleting 378K rows. Accepts that ~75% of AR log events are consumer-level (no specific account), so consumer-level cleanup necessarily handles 3-4× the rows of account-level. Per-row performance is reasonable for a heavily-indexed parent table. **Not a bug; not optimizable without architectural change. Inform production capacity planning.**

**Top time consumers across batches** (typical pattern from batch 3):

| Order | Table | Notes |
|---|---|---|
| C53 | cnsmr_accnt_ar_log | Consumer-level — dominant cost |
| A66 | cnsmr_accnt_ar_log | Account-level |
| C110 | cnsmr | Terminal — many FK references checked |
| A67 | cnsmr_accnt_bal | |
| A117 | cnsmr_accnt | Terminal |
| A68 | cnsmr_accnt_bckt_bal_rprtng | Heavy row count |
| C10 | cnsmr_Tag | |
| A22 | cnsmr_Accnt_Tag | |

These ~8 orders account for ~73% of typical batch duration. Everything else is noise.

**A63 has constant overhead floor.** `agnt_crdtbl_actvty_crdt_assctn` Pass 1 via ar_log takes 5–15 seconds regardless of how few rows match (1–8 rows in production samples). Investigation showed the optimizer correctly chose a 49K-page index scan over 100K nested-loop seeks — defensible plan choice given the temp table cardinality. The purpose-built index `FA_ncl_idx_for_arc_agnt_crdtbl_actvty_cnsmr_accnt_ar_log_id` exists; no missing-index issue. ~10s/batch × 48 batches/night = 8 minutes total. **Accepted as-is; not worth optimizing.**

### Lessons Learned

**BIDATA missing-index incident (Test environment, 2026-04-26).** Batch 1's AB1 took 172s migrating 11 rows. Investigation: BIDATA Daily Build on DM-TEST-APP failed earlier that day on the GenAccountTbl build step (`Could not allocate space for object 'dbo.SORT temporary run storage'… filegroup is full` — Error 1105). The build pattern is DROP INDEX → bulk load → CREATE INDEX; the CREATE INDEX phase ran out of sort temp space and aborted, leaving the BIDATA tables as heaps. Subsequent migrations against heap tables required full table scans. After Dirk freed disk space and re-ran the build, AB1 dropped to sub-second range (8.6s for 11,595 rows in batch 3). **No code change needed.** Worth keeping in mind: the script's pre-flight check at startup sees `BIDATA pre-flight: build completed today (status: Failed)` at DEBUG level — could be promoted to WARN or a hard-stop in future iteration (see Outstanding).

**Preview-mode bug discovered and fixed mid-session.** Initial unified script propagated a latent bug from the legacy DmArchive/ShellPurge scripts where logging functions wrote to audit tables regardless of preview mode. Corrected to console-only with `$script:XFActsExecute` guards in every logging function. Legacy scripts were not updated — they're not currently in use and will be retired anyway.

---

## 5. Outstanding

### Phase 1 Completion (deployment follow-up)

Items required to put the unified script into production rotation:

- [ ] **System_Metadata version bump** for `DmOps.Archive` component (Admin UI). Notes: pivot from account-level to consumer-level archive; new unified script `Execute-DmConsumerArchive.ps1` replaces account-level `Execute-DmArchive.ps1`; adds runtime TC_ARCH re-verification with tag soft-delete + AR event for excepted consumers; adds `Archive_ConsumerExceptionLog` table; legacy script archived to Reference. Component description updated to reflect consumer-level model.
- [ ] **Object_Metadata + Object_Registry** for `Execute-DmConsumerArchive.ps1` (separate deployment script, generated AFTER this design is locked — never bundle with implementation).
- [ ] **Move legacy archive script** from `E:\xFACts-PowerShell\Execute-DmArchive.ps1` to `E:\xFACts-PowerShell\Reference\Execute-DmArchive_AccountLevel.ps1`.
- [ ] **ProcessRegistry entry** for `Execute-DmConsumerArchive.ps1` — Pattern 3 (time-based with polling). `dependency_group=10` (collectors). `script_path = 'Execute-DmConsumerArchive.ps1'` (filename only, no path).
- [ ] **CC page touch-ups** — `DmOperations.ps1`, `DmOperations-API.ps1`, `dm-operations.css`, `dm-operations.js`. Cosmetic adjustments reflecting Archive as primary process and ShellPurge as peripheral. Add exception log display section. Lifetime-totals math may need adjustment.
- [ ] **Documentation page rewrites** — `dmops.html`, `dmops-arch.html`. Reflect the consumer-level model.
- [ ] **`.\Generate-DDLReference.ps1 -Execute`** — regenerate JSON after schema changes settle.
- [ ] **Production batch sizing decision** — start at 5000 (validated in test). Tune via GlobalConfig as production data accumulates.
- [ ] **Production schedule windows** — reuse existing 7am–11pm pattern (full evenings/weekends, reduced business hours, blocked overnight). The 2-hour buffer to BIDATA's 1am rebuild remains sufficient.

### Open Decisions

These need a discussion before they're either built or dropped:

- [ ] **Test-BidataBuildInProgress recheck between Steps 7 & 8.** Currently the BIDATA build status is checked once at Step 1 startup. In production with full batch sizes, Step 7 (account-level deletes) will run long enough that the BIDATA Daily Build could kick off mid-batch. A recheck before Step 8 would let us bail to "BIDATA: Skipped" cleanly rather than fight contention. Defensive code change. Low risk, high value. **Recommend implementing.**
- [ ] **BIDATA build "Failed status" handling at startup.** Today the script logs `BIDATA pre-flight: build completed today (status: Failed)` at DEBUG and proceeds. Three options: (A) hard-stop with a GlobalConfig acknowledgment flag to override, (B) bump log level to WARN so it's visible but proceeds, (C) leave alone. Recommend B as minimal-change.
- [ ] **BIDATA Test environment refresh** alongside the planned crs5_oltp clone refresh. Test BIDATA had a build failure due to filegroup space — likely accumulated cruft over time. Sized-correctly fresh BIDATA paired with the OLTP clone resets that surface area.

### Phase 2 — Step Necessity Audit (post-production)

Once unified flow is producing data, walk both delete sequences against actual production behavior to identify steps that have never deleted a row across all batches. Trim where FK chain confirms removability.

- [ ] Account-level sequence audit (~117 steps). Identify zero-row steps from `Archive_BatchDetail` historical data.
- [ ] Consumer-level sequence audit (~110 steps). Same zero-row identification.
- [ ] FK validation for removal candidates via `sys.foreign_keys`.
- [ ] Trim and redeploy. Bump System_Metadata version.

### Phase 3 — Shell Purge Exclusion Review (post-production)

Validate which of Shell Purge's seven exclusion reasons remain meaningful for naturally-occurring shells once the unified archive is producing data. Note: the `dcmnt_rqst` exclusion check is currently commented out in production `Execute-DmShellPurge.ps1` — do not re-enable without explicit decision.

- [ ] Volume analysis per exclusion reason.
- [ ] Per-reason validation against current data state.
- [ ] Trim or expand exclusions based on findings.
- [ ] **ShellPurge preview-mode fix** — same latent bug fixed in the unified script also exists in `Execute-DmShellPurge.ps1` (logging functions write regardless of preview flag). Address as separate task when ShellPurge is touched.

---

## 6. Reference Files

| File | Location | Status |
|---|---|---|
| `Execute-DmConsumerArchive.ps1` | `E:\xFACts-PowerShell\` | **Deployed, validated** (3,068 lines) |
| `Execute-DmArchive.ps1` (legacy) | `E:\xFACts-PowerShell\` | **Pending move** to `Reference\Execute-DmArchive_AccountLevel.ps1` |
| `Execute-DmShellPurge.ps1` | `E:\xFACts-PowerShell\` | Unchanged. Continues handling naturally-occurring shells. Preview-mode fix pending under Phase 3. |
| `xFACts-OrchestratorFunctions.ps1` | `E:\xFACts-PowerShell\` | Unchanged. Provides `$script:XFActsExecute`, `Initialize-XFActsScript`, and all shared platform functions. |
| `DmOperations.ps1` | `E:\xFACts-ControlCenter\scripts\routes\` | Cosmetic touch-ups pending |
| `DmOperations-API.ps1` | `E:\xFACts-ControlCenter\scripts\routes\` | Cosmetic touch-ups pending |
| `dm-operations.css` | `E:\xFACts-ControlCenter\public\css\` | Cosmetic touch-ups pending |
| `dm-operations.js` | `E:\xFACts-ControlCenter\public\js\` | Cosmetic touch-ups pending |
| `dmops.html` | `E:\xFACts-ControlCenter\public\docs\pages\` | Rewrite pending |
| `dmops-arch.html` | `E:\xFACts-ControlCenter\public\docs\pages\arch\` | Rewrite pending |
| `Archive_BatchLog` / `BatchDetail` / `ConsumerLog` / `Schedule` | `DmOps` schema | Unchanged. `Archive_BatchLog.exception_count` column added this initiative. |
| `Archive_ConsumerExceptionLog` | `DmOps` schema | **Deployed** |
| `ShellPurge_*` tables | `DmOps` schema | Unchanged |

---

## 7. GlobalConfig Reference (DmOps.Archive)

Existing entries (carry forward unchanged from prior account-level archive):

- `target_instance` — server hosting crs5_oltp
- `bidata_instance` — server hosting BIDATA database
- `batch_size` — consumers per batch, full mode
- `batch_size_reduced` — consumers per batch, reduced mode
- `chunk_size` — rows per delete chunk (default 5000)
- `archive_abort` — emergency shutoff (0=normal, 1=stop)
- `alerting_enabled` — Teams alerts (1=on, 0=suppress)
- `bidata_build_job_name` — SQL Agent job name to monitor

New entries deployed this initiative:

- `tag_removal_actn_cd` — short value resolved to `actn_cd` (default `CC`)
- `tag_removal_rslt_cd` — short value resolved to `rslt_cd` (default `CC`)
- `tag_removal_user` — username resolved to `usr_id` (default `sqlmon`)
- `tag_removal_msg_txt` — AR event message text (default `Consumer archive tag removed - ineligible account(s) detected`)
