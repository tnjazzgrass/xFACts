# xFACts Legacy Toolkit Migration Catalog

**Status:** Draft — Code Review Complete (Full Export)  
**Audience:** Dirk, Matt  
**Purpose:** Inventory all functionality in the legacy Access DB toolkit ("External Frost-Arnett Co Transaction Services for Debt Manager") and plan its migration into the xFACts Control Center.

---

## Background

The legacy xFACts toolkit is a shared Access database (~91 MB) on the network, built in VBA. It provides DM administrative operations, REST API execution, BDL file processing, and financial batch services. The primary user base is the Applications Team (Matt and team). The tool requires users to open the Access DB each session, manually prepare data (copy/paste into columns, set defaults per row), and click buttons to execute operations.

### Code Analysis Scope

| Source | Count | Description |
|--------|-------|-------------|
| Standalone VBA modules | 4 | bdl_code (11 functions), pay_code (8 functions), Utilities (14 functions), fee_code (1 stub) |
| Form code-behind | 126 | Full export of all Access form event procedures |
| **Total VBA files analyzed** | **130** | Complete codebase |

### ODBC Connections (Linked Table Manager)

| Description | Server | Driver | Linked Tables |
|-------------|--------|--------|---------------|
| APP_PROD_LSNR | avg-prod-lsnr | SQL Native Client 11.0 | `x_pay_btch_prd` → `dbo.cnsmr_pymnt_btch` |
| Prod Applications | avg-prod-lsnr | SQL Native Client 11.0 | `dbo.tx_split_100_accnts`, `dbo.vw_tx_split_100` |
| PROD_Applications | avg-prod-lsnr | ODBC Driver 17 | `dbo.vw_xfacts_accnt_smmry`, `dbo.vw_xfacts_ar_events`, `dbo.vw_xfacts_cnsmr_accnts`, `dbo.vw_xfacts_cnsmr_smmry` |
| Staging | avg-stage-lsnr | SQL Native Client 11.0 | `x_pay_btch_stg` → `dbo.cnsmr_pymnt_btch` |
| TEST DB | dm-test-app | SQL Native Client 11.0 | `x_pay_btch_tst` → `dbo.cnsmr_pymnt_btch` |

**Additional ADODB connections in Utilities module:**

| Variable | Server | Database | Purpose |
|----------|--------|----------|---------|
| `con` | avg-prod-lsnr | Applications | Production DM queries |
| `cong` | avg-stage-lsnr | Applications | Staging DM queries |
| `cont` | (test server) | Applications | Test DM queries |

### Why Migrate

- **Availability:** Requires opening a shared Access DB; no web access, no concurrent-safe usage
- **Manual prep:** Heavy manual data preparation for each operation (copy/paste into columns, set defaults per row)
- **No audit trail:** Basic `toolUse` table logs function name, env, user, date — no parameter detail or outcome tracking
- **No monitoring:** Functions only run when someone has the DB open
- **Fragile:** VBA codebase; multiple versions in same folder; hardcoded server names and file paths throughout
- **No RBAC:** Anyone with network access to the file can use any function
- **No validation:** Most functions don't validate input data before building XML and posting to DM
- **Hardcoded credentials:** API credentials stored in `APIDeets` and `xtsCred` tables; auth passed via form fields
- **Brittle response parsing:** File registry ID extracted via `Mid(response, 46, 6)` — breaks if response format changes

### Migration Goals

- Replace all active legacy functions with xFACts Control Center equivalents
- Add RBAC-controlled access per function
- Add full audit logging via `dbo.API_RequestLog` and function-specific tracking tables
- Add environment targeting (Test/Stage/Production) via `dbo.ServerRegistry`
- Streamline data preparation with file upload, column mapping, and validation UI
- Enable unattended/scheduled execution where appropriate
- Use `dbo.Credentials` / `dbo.CredentialServices` for API authentication
- Parse API responses properly (JSON parsing, not positional string extraction)

---

## Code Review Findings Summary

### Universal Pattern — BDL Functions

Every BDL function in `bdl_code` follows an identical 13-step pattern:

1. Look up current user from `xtsUsers` table
2. Select environment (test/stage/prod) → sets `fileLoc` (UNC path to dmfs) and `envURL` (DM REST base URL)
3. Get filename from the Access form (typically includes a JIRA ticket number prefix)
4. Create an empty file on the dmfs share via `DoCmd.TransferText`
5. Query a local Access table for unprocessed rows (`WHERE bdl_proc = 'N' AND bdl_usr = '...'`)
6. Build XML header with hardcoded BDL structure (namespace, transaction type, count, date)
7. Loop through rows and build XML elements — element names are hardcoded per function
8. Write XML to the file on the dmfs share
9. `POST /fileregistry` with filename and `BDL_IMPORT` type → extract `reg_id` from response
10. `POST /fileregistry/{reg_id}/bdlimport` to trigger the import
11. Mark rows as processed (`bdl_proc = 'Y'`) in the local Access table
12. Log to `toolUse` table
13. Show MsgBox confirmation

**This is exactly the workflow the BDL Import Module design replaces** — with file upload instead of manual data entry, catalog-driven XML construction instead of hardcoded element names, proper validation, and full audit logging.

### Universal Pattern — Payment/Financial Functions

Every payment function in `pay_code` follows a similar but distinct pattern:

1. Select environment → sets `fileLoc` (UNC path to `dmfs\import\payments\`) and `envURL`
2. Query local Access `payment_info` table for unprocessed rows (filtered by user and type code)
3. Build payment XML using the DM payment import schema (different from BDL schema)
4. Write XML to `dmfs\import\payments\`
5. `POST /consumerfinancialimportbatches` to register the payment file
6. `POST /consumerfinancialimportbatches/{id}/post` to trigger posting
7. Mark rows as processed
8. Log to `toolUse`

**Key difference from BDL:** Payment files use a completely different XML schema (`consumer-payment-import-job` with CRSoftware namespace) and a different API flow. This is NOT a BDL import — it's DM's payment import pipeline.

### REST API Functions — Three Categories

The full form export reveals three distinct categories of direct REST API calls:

**Category 1: Scheduled Job Triggers** — Fire-and-forget calls to `/scheduledjobs/{JOB_NAME}` or `/jobs/{JOB_NAME}/execute`. No request body. Some hit all three app servers, some hit one. Some have cooldown periods.

**Category 2: Consumer CRUD Operations** — Targeted operations against specific consumers: merge, split, hold, update, post AR events, manage notices, manage tags, delete phones, remove mail returns. These require consumer identifiers as input and return operation results.

**Category 3: Generic API Caller** — A freeform form (`Call REST API Detail`) where the user specifies the HTTP method, URL path, and optional body. This is a developer/debug tool.

---

## Complete DM REST API Surface

This is the complete set of DM REST API endpoints used by the legacy toolkit, extracted from all 130 VBA files.

### Scheduled Job Triggers

No request body. POST to trigger DM's built-in scheduled processes manually.

| Button | Endpoint | Method | Server Target | Cooldown | Notes |
|--------|----------|--------|--------------|----------|-------|
| Refresh Drools | `/scheduledjobs/REFRESH_DROOLS` | POST | All 3 app servers | None | Reloads business rules engine on each JBoss instance |
| Release Notices | `/scheduledjobs/RELEASE_DOC_REQUESTS` | POST | Single server | 5 minutes | Triggers notice/document release processing |
| Balance Sync | `/scheduledjobs/UPDATE_BALANCES` | POST | Single server | 60 minutes | Recalculates account balances for flagged accounts |

### Job Execution

POST to execute specific named jobs. Some are parameterized.

| Button | Endpoint | Method | Notes |
|--------|----------|--------|-------|
| Request Valid | `/jobs/JC_CBVAL/execute` | POST | Credit bureau validation job |
| Request Valid | `/jobs/JC_CRVAL/execute` | POST | Creditor validation job |
| Request Valid | `/jobs/JC_CYVAL/execute` | POST | Cycle validation job |
| Launch Jobs | `/jobs/{job_name}/execute` | POST | Generic — user specifies job name on form |

**Note:** "Request Valid" fires all three validation jobs in sequence from a single button click. "Launch Jobs" is a generic launcher where the user types the job code.

### Consumer Operations

These require consumer identifiers and operate on specific consumer/account records. They are the core "tools" functionality.

| Endpoint Pattern | Method | Button | Input Required | Notes |
|-----------------|--------|--------|---------------|-------|
| `/consumers/{id}/merge` | POST | Merge Consumers | Source consumer ID, target consumer ID, linked account list | Loops through batch with 1-second delay between calls |
| `/consumers/{id}/split` | POST | Split Account / Fix +100 | Consumer agency ID | Complex: queries DM for accounts, groups into ~91-account batches, API call per batch with 2-second delays |
| `/consumers/{id}/hold` | POST | Hold Consumer | Consumer ID, hold parameters | Places consumer on hold status |
| `/consumers/{id}/arevents` | POST | Post AR Event | Consumer ID, AR event JSON body | Posts accounts receivable event |
| `/consumers/{id}/noticerequests` | POST | (Send Notice) | Consumer ID, notice details | Creates a notice request for a consumer |
| `/consumers/{id}/noticerequests/{noteId}` | DELETE | (Cancel Notice) | Consumer ID, notice request ID | Cancels a pending notice request |
| `/consumers/{id}/phones/{phoneId}` | DELETE | (Delete Phone) | Consumer agency ID, phone ID | Removes a phone record |
| `/consumers/{id}/addressmailreturn` | DELETE | Delete Mail Returns | Consumer ID or agency ID | Removes mail return flag. Also exists as BDL variant (B8). |
| `/consumers/{id}/assigntags` | POST | (Assign Tags) | Consumer agency ID, tag data | Assigns tags to a consumer |
| `/consumers/{id}/unassigntags` | POST | (Remove Tags) | Consumer agency ID, tag data | Removes tags from a consumer |
| `/consumers/{id}` | PUT | (Update Consumer) | Consumer agency ID, consumer JSON | Updates consumer master record |
| `/consumers/{id}/address` | PUT | (Update Address) | Consumer ID, address JSON | Updates consumer address |

### File Pipeline Endpoints

These are used by the BDL, Payment, and New Business file import functions.

| Endpoint | Method | Pipeline | Notes |
|----------|--------|----------|-------|
| `/fileregistry` | POST | BDL & Payment | Register a file for import. Body: `{fileName, fileType}` where fileType is `BDL_IMPORT` or `PAYMENT_IMPORT` |
| `/fileregistry/{id}/bdlimport` | POST | BDL | Trigger BDL import for a registered file |
| `/consumerfinancialimportbatches` | POST | Payment | Register a payment import file |
| `/consumerfinancialimportbatches/{id}/post` | POST | Payment | Trigger posting of a payment batch |
| `/newbusinessbatch/newbusinessbatch` | POST | New Business | Submit a new business file (auto-triggers on registration) |

### Other Endpoints

| Endpoint | Method | Notes |
|----------|--------|-------|
| `/blaze/promoterules` | POST | Stage environment only — promotes Blaze decision rules. Not used in production. |
| `http://fa-jira.fac.local:8080/rest/api/2/issue` | POST | Jira ticket creation — **already replaced by xFACts Jira pipeline** |

### Generic API Caller

The `Call REST API Detail` form provides a freeform interface where the user specifies HTTP method, URL path, and optional JSON body. This is a developer/debug tool, not a named operation. The xFACts equivalent would be an admin-only API testing panel.

---

## Complete Function Inventory

### BDL Updates Screen (bdl_code module)

All functions: BDL file generation → fileregistry → bdlimport. File written to `\\{server}\dmfs\import\bdl\`.

| # | Function Name | Legacy Button | BDL Transaction Type | XML Element | Access Source Table | Companion File | Notes |
|---|--------------|---------------|---------------------|-------------|-------------------|----------------|-------|
| B1 | PostAccntTags | Account Tags | CONSUMERACCOUNT | `cnsmr_accnt_tag` (CONSUMER_ACCOUNT_TAG) | `bdl_accnt_tag` | — | Simple: agency_id, tag_shrt_nm, optional assign_dt and order_nmbr |
| B2 | PostCnsmrTags | Consumer Tags | CONSUMER | `cnsmr_tag` (CONSUMER_TAG) | `bdl_cnsmr_tag` | AR Events file (second BDL) | Posts two BDL files: tags + AR events for same records |
| B3 | PostRegFUDPs | Reg F UDPs | CONSUMERACCOUNT | `cnsmr_accnt_udp` (UDEFCREDITORTRANHIST) | `bdl_regf_udp` | — | UDP fields: serv_bal_due, pay_amt, fee_amt, int_amt, note_bal (all optional except serv_bal_due) |
| B4 | ReturnAccounts | Return Accounts | CONSUMERACCOUNT | `cnsmr_accnt_tag` (CONSUMER_ACCOUNT_TAG) | `bdl_accnt_rtrn` | AR Events file (second BDL) | Posts TWO tags per account (TA_CSRET + reason code from form dropdown) + AR event file |
| B5 | PostAccntUpdts | Account Info | CONSUMERACCOUNT | `cnsmr_accnt` (CONSUMERACCOUNT) | `bdl_cnsmr_accnt_data` | — | Dynamic field iteration — reads ALL non-bdl_ columns from table definition. Supports NULL keyword for nullify_fields. Most flexible function. |
| B6 | PostAddrUpdts | Address Updates | CONSUMER | `cnsmr_addr` (CONSUMER_ADDRESS) | `bdl_cnsmr_addr` | — | Address fields + optional phone block (conditional on phone data presence) |
| B7 | PostPhnUpdts | Phone Update | CONSUMER | `cnsmr_phn` (PHONE) | `bdl_cnsmr_phn` | — | Phone number, type, consent fields |
| B8 | RemoveMailReturns | Delete Mail Returns (REST screen) | CONSUMERACCOUNT | `cnsmr_accnt_tag` (CONSUMER_ACCOUNT_TAG) | `bdl_del_mail_rtn` | — | Removes mail return tags — uses `remove_tag="true"` attribute. Also has a direct API variant via DELETE `/consumers/{id}/addressmailreturn` |
| B9 | PostCnsmrUpdts | Consumer Info | CONSUMER | `cnsmr` (CONSUMER) | `bdl_cnsmr_data` | — | Dynamic field iteration like PostAccntUpdts — reads all non-bdl_ columns, supports nullify |
| B10 | ImportPaySchedules | Pay Schedules | CONSUMERACCOUNT | `cnsmr_accnt_pymnt_schdl` (CNSMR_ACCNT_PYMNT_SCHDL) | `bdl_pymnt_schdl` | — | Payment schedule entity with nested schedule_entry elements. Uses `import_as_user_name` from logged-in user. |
| B11 | ImportNB | Creditor Fees (create acct) | New Business XML (NOT BDL) | `<consumer>` / `<staging-account>` | `crdtr_fee_dm_accnt` | — | **NOT a BDL import.** Uses New Business XML schema and `POST /newbusinessbatch/newbusinessbatch`. Written to `dmfs\import\newbusiness\`. |

**Key Observations:**
- B5 (PostAccntUpdts) and B9 (PostCnsmrUpdts) use **dynamic field iteration** — the closest pattern to the generic BDL Import Module.
- B2 (Consumer Tags) and B4 (Return Accounts) generate **two BDL files per execution** — a companion file pattern the Import Module needs to support.
- B8 exists in both BDL and direct API forms — the team uses whichever is more appropriate for the volume.
- B11 is **NOT BDL** — it's a New Business import and belongs in a separate pipeline.

### Financial Batch Services Screen (pay_code module)

All functions: Payment XML file generation → consumerfinancialimportbatches → post. File written to `\\{server}\dmfs\import\payments\`.

| # | Function Name | Legacy Button | Payment Type Code | Access Source Table | Notes |
|---|--------------|---------------|------------------|-------------------|-------|
| F1 | PostPayments | Post Payments | PAY | `payment_info` (xType='PAY') | Groups by consumer. Multi-account payment support. Includes memo codes, payment methods, locations. |
| F2 | PostBulkPays | Bulk Payments | PAY | `payment_info` (xType='PAY') | Bulk variant — one consumer-payment per account. |
| F3 | PostAdjustments | Post Adjustments | ADJ | `payment_info` (xType='ADJ') | ADJUSTMENT bucket-transaction-type. Per-account adjustment amounts. |
| F4 | PlacementAdj | Placement Charges | PLACEMENT | `payment_info` | PLACEMENT bucket-transaction-type. |
| F5 | ReplaceBalances | Balance Replace | RPY | `payment_info` | Complex: reverses existing balance then places new balance. Two-pass: reversal file then replacement file. |
| F6 | PostReversals | (not on visible screen) | REV | `payment_info` (xType='REV') | Payment reversal processing. |
| F7 | ZeroBalOut | (not on visible screen) | Zero balance | `payment_info` | Zeroes out account balances. Complex multi-step with DM queries. |
| F8 | PostCPays | (not on visible screen) | CPJ | `payment_info` | CPJ payment posting. |

**Key Observations:**
- ALL Financial functions use DM's **Payment Import** pipeline — NOT BDL.
- The `payment_info` Access table is the universal staging table with `xType` discriminator.
- Several functions are multi-step generating multiple files.

### Special Services (Utilities module)

| # | Function Name | Legacy Button | Mechanism | Notes |
|---|--------------|---------------|-----------|-------|
| S1 | PostVOAppARs | VOApps Results | BDL | AR event records. Uses `CONSUMER_ACCOUNT_AR_LOG` transaction type. |
| S2 | BCBSpay | BCBS Pay Files | Payment Import | BCBS-specific payments. Combines payments (BCP) and adjustments (BCA) in single file. |
| S3 | runCBRupdt | CBR Process | BDL | Credit bureau reporting updates. Updates `cb_rpt_accnt_stts_val_txt` and `cb_lst_rprtd_dt`. |
| S4 | Interest_Writeoff | Interest Write-Off (calc) | Local calculation only | **No API/BDL call.** Calculates amounts across accounts. Prep step for intWO. |
| S5 | intWO | Interest Write-Off (post) | Payment Import | Posts calculated write-off amounts as payment reversals + replacements. |
| S6 | INTreWO | Interest re-write-off | Payment Import | Variant of intWO. |
| S7 | PostPaymentsX | High Volume variant | Payment Import | Extended PostPayments for "too many accounts" scenario. Uses ADODB to query DM directly. |
| S8 | PostCheckPays | Check payments | Payment Import | Check-specific payment processing. |
| S9 | NewCredAcct | Creditor Fees (create) | New Business XML | Creates creditor fee accounts via `POST /newbusinessbatch/newbusinessbatch`. |

### REST API Direct Calls

#### Scheduled Job Triggers (from form code-behind)

| # | Legacy Button | DM Endpoint | Server Target | Cooldown | Notes |
|---|--------------|-------------|--------------|----------|-------|
| R1 | Refresh Drools | `POST /scheduledjobs/REFRESH_DROOLS` | All 3 app servers (sequential) | None | Reloads Drools/Blaze business rules on each JBoss instance |
| R2 | Release Notices | `POST /scheduledjobs/RELEASE_DOC_REQUESTS` | Single server | 5 min | Triggers notice/document release processing |
| R3 | Balance Sync | `POST /scheduledjobs/UPDATE_BALANCES` | Single server | 60 min | Recalculates balances for flagged accounts. Normally runs on internal DM timer (15-30 min interval); this is "run it now" for testing |
| R4 | Request Valid | `POST /jobs/JC_CBVAL/execute`, `POST /jobs/JC_CRVAL/execute`, `POST /jobs/JC_CYVAL/execute` | Single server | None | Fires 3 validation jobs in sequence from one button: credit bureau, creditor, and cycle validation |
| R5 | Launch Jobs | `POST /jobs/{job_name}/execute` | Single server | None | Generic job launcher — user types the job code name |

#### Consumer Operations (from form code-behind + Utilities module)

| # | Legacy Button | DM Endpoint | Method | Input | Notes |
|---|--------------|-------------|--------|-------|-------|
| R6 | Merge Consumers | `/consumers/{sourceId}/merge` | POST | Source/target consumer IDs, linked account list | Loops through batch with 1-second delay |
| R7 | Split Account / Fix +100 | `/consumers/{id}/split` | POST | Consumer agency ID | Complex: queries DM views → groups into ~91-account batches → API per batch with 2-second delays |
| R8 | Hold Consumer | `/consumers/{id}/hold` | POST | Consumer ID | Places consumer on hold |
| R9 | Post AR Event | `/consumers/{id}/arevents` | POST | Consumer ID, AR event JSON | Posts accounts receivable event |
| R10 | (Send Notice) | `/consumers/{id}/noticerequests` | POST | Consumer ID, notice details | Creates notice request |
| R11 | (Cancel Notice) | `/consumers/{id}/noticerequests/{noteId}` | DELETE | Consumer ID, notice request ID | Cancels pending notice |
| R12 | (Delete Phone) | `/consumers/{id}/phones/{phoneId}` | DELETE | Consumer agency ID, phone ID | Removes phone record |
| R13 | Delete Mail Returns | `/consumers/{id}/addressmailreturn` | DELETE | Consumer ID | Direct API variant (also has BDL variant B8) |
| R14 | (Assign Tags) | `/consumers/{id}/assigntags` | POST | Consumer agency ID, tag data | Assigns tags via API |
| R15 | (Remove Tags) | `/consumers/{id}/unassigntags` | POST | Consumer agency ID, tag data | Removes tags via API |
| R16 | (Update Consumer) | `/consumers/{id}` | PUT | Consumer agency ID, consumer JSON | Updates consumer master record |
| R17 | (Update Address) | `/consumers/{id}/address` | PUT | Consumer ID, address JSON | Updates consumer address |

#### Other API Operations

| # | Function | Endpoint | Notes |
|---|---------|----------|-------|
| R18 | Post Pay Batch | `/consumerfinancialimportbatches/{id}/post` | Manual trigger to post a specific payment batch by ID |
| R19 | Post BDL | `/fileregistry/{id}/bdlimport` | Manual trigger to import a specific registered BDL file by ID |
| R20 | Jira Ticket | `http://fa-jira.fac.local:8080/rest/api/2/issue` | **Already replaced by xFACts Jira pipeline** |
| R21 | Generic API Caller | User-specified URL and method | Developer/debug tool — freeform REST API call form |
| R22 | Blaze Promote Rules | `/blaze/promoterules` | Stage environment only — not used in production |
| R23 | SOAP API Caller | User-specified SOAP URL | Legacy SOAP interface — developer tool |

### Admin Screen Functions (from Form_frm_adm_main code-behind)

| # | Legacy Button | Mechanism | What It Actually Does |
|---|--------------|-----------|----------------------|
| A1 | Users | Local Access DB | User management within the toolkit: add users (`xtsUsers` table), assign roles, view users, remove users. **Not DM users — toolkit-local.** Irrelevant for migration (xFACts RBAC replaces this). |
| A2 | Clear BDL | Local Access DB | `DELETE *` from all 12 BDL staging tables (`bdl_accnt_rtrn`, `bdl_accnt_tag`, `bdl_addrss_updt`, `bdl_cbr_updt`, `bdl_cnsmr_accnt_data`, `bdl_cnsmr_data`, `bdl_cnsmr_tag`, `bdl_pay_schd_asc`, `bdl_pay_schd_ins`, `bdl_pay_schd_smy`, `bdl_phn`, `bdl_regf_udp`). Clears all prepared-but-unprocessed BDL data. |
| A3 | Clear Pay | Local Access DB | `DELETE *` from `payment_info`. Clears all prepared-but-unprocessed payment data. |
| A4 | Queries | ADODB to DM (live) | Runs `sp_who2`-style active session query against DM database. Populates local `dm_stat_db` table with hostname, session, user, database, status, query text, CPU time, reads, writes, blocker ID. **Partially overlaps with xFACts Server Health (Activity monitoring).** |
| A5 | Validation | — | Opens `frm_req_val` form which fires 3 validation jobs (see R4 above). Same as "Request Valid" on REST APIs screen. |
| A6 | Projects | Local Access DB | Project tracking within the toolkit (`frm_prj_main`, `frm_prj_dtl_main`, `frm_prj_tsk`). **Not DM-related — toolkit-internal project management.** Irrelevant for migration. |
| A7 | Maint Mode | Local Access DB | Sets `maintShutdown` and `maintLocked` flags in local `toolMaint` table. Locks the Access DB to prevent usage during maintenance. **Irrelevant for migration — CC has its own maintenance patterns.** |

### Admin Dashboard Widgets (Form_Load on frm_adm_main)

On form load, the Admin screen queries DM via ADODB and populates local tables for dashboard display:

| Widget | DM View Queried | Local Table | What It Shows | xFACts Coverage |
|--------|----------------|-------------|--------------|----------------|
| Jobs | `vw_stat_jobs` | `dm_stat_jobs` | Pending/Running/Completed counts, last completion time | **Partial — JobFlow module** |
| Strategies | `vw_stat_strtgy` | `dm_stat_strtgy` | Run date, end time, successful/failed/total execution counts | **None — net new** |
| Stalled NB Batches | `vw_stat_batches` | `dm_stat_btch` | Released batches (potential stalls) with file names and account counts | **Partial — BatchOps NB tracking** |
| Stalled BDL Files | `vw_stat_bdl` | `dm_stat_bdl` | Today's BDL files with status, type, record counts | **None — BDL batch tracking is a backlog item** |
| Default Workgroups | `vw_stat_wrkgrp` | `dm_stat_wrkgrp` | 1st Party / 3rd Party workgroup assignment counts | **None — net new** |

---

## Mechanism Classification Summary

| Mechanism | Count | Functions |
|-----------|-------|-----------|
| **BDL Import** (XML → fileregistry → bdlimport) | 12 | B1–B10, S1, S3 |
| **Payment Import** (XML → consumerfinancialimportbatches → post) | 10 | F1–F8, S2, S5, S6, S7, S8 |
| **New Business Import** (XML → newbusinessbatch) | 2 | B11, S9 |
| **DM Scheduled Job Trigger** (POST to scheduledjobs or jobs/execute) | 5 | R1–R5 |
| **Consumer CRUD API** (POST/PUT/DELETE on consumer endpoints) | 12 | R6–R17 |
| **Manual Pipeline Trigger** (trigger existing registered file/batch) | 2 | R18, R19 |
| **Local Calculation Only** | 1 | S4 |
| **Already Replaced by xFACts** | 1 | R20 (Jira) |
| **Developer/Debug Tools** | 3 | R21, R22, R23 |
| **Toolkit-Internal (no migration needed)** | 4 | A1, A6, A7, A2/A3 (data clearing) |
| **Overlaps with existing xFACts** | 2 | A4 (Server Health), A5 (= R4) |
| **Empty Stub** | 1 | fee_code.ChargeCurrFees |

### Three Distinct DM File Pipelines

| Pipeline | File Location | Registration Endpoint | Trigger Endpoint | XML Schema |
|----------|--------------|----------------------|-----------------|------------|
| **BDL Import** | `dmfs\import\bdl\` | `POST /fileregistry` (BDL_IMPORT) | `POST /fileregistry/{id}/bdlimport` | `dm_data` (FICO namespace `http://www.fico.com/xml/debtmanager/data/v1_0`) |
| **Payment Import** | `dmfs\import\payments\` | `POST /consumerfinancialimportbatches` | `POST /consumerfinancialimportbatches/{id}/post` | `consumer-payment-import-job` (CRSoftware namespace `http://www.crsoftwareinc.com/xml/ns/titanium/common/v1_0`) |
| **New Business** | `dmfs\import\newbusiness\` | `POST /newbusinessbatch/newbusinessbatch` | (auto-triggers on registration) | `newbiz` (CRSoftware namespace) |

---

## Architecture Considerations

### What We Now Know

The full code review reveals the toolkit is really **five functional categories**, each with different infrastructure needs:

**1. BDL Import Pipeline (12 functions)** — The largest block. All follow the same pattern. Directly addressed by the BDL Import Module design. Consumed by both Apps team and BI team.

**2. Payment Import Pipeline (10 functions)** — Second largest. All follow the same pattern but with a different XML schema and API flow. Apps team only (for now). Needs its own pipeline module parallel to BDL.

**3. Scheduled Job Triggers (5 functions)** — Simple fire-and-forget API calls. Some with cooldowns, some multi-server. Very lightweight to implement — could be a configuration-driven "Job Trigger" panel.

**4. Consumer CRUD Operations (12 functions)** — The most varied group. Each operation has different inputs, different endpoints, different complexity. Some are simple single-call operations (hold consumer), others are complex multi-step workflows (split account). These need individual UI forms/modals.

**5. DM Monitoring Dashboard (5 widgets)** — Live queries against DM views. Two are partially covered by existing xFACts modules, three are net-new. Could live on the Apps team page or be distributed to existing monitoring pages.

### Tools Schema Recommendation

With the full picture now visible, Option C (Hybrid) is clearly the right approach:

**A `Tools` schema would house:**
- **Shared infrastructure:** Execution log (who ran what, when, against which environment, with what result), throttle/cooldown tracking, environment configuration references
- **BDL pipeline:** Import tracking, templates, entity enablement (the BDL Import Module tables from the design doc)
- **Payment pipeline:** Payment batch tracking, payment templates (Phase 2)
- **Job trigger configuration:** Job definitions, server targeting rules, cooldown periods
- **Consumer operation log:** Audit trail for all consumer CRUD API calls
- **Lookup cache:** Cached DM reference table values for validation

**Existing `Engine.Catalog` tables** (`Catalog_BDLFormatRegistry`, `Catalog_BDLElementRegistry`, future `Catalog_CDLRegistry`, `Catalog_APIRegistry`) could relocate from `dbo` to `Tools` since they're consumed by the tool infrastructure. Deferred until schema is created.

**CC pages consume the Tools schema:**
- **Apps team operations page** → full access to all pipelines + job triggers + consumer CRUD + monitoring dashboard
- **BI departmental page** → BDL import for their entity types + DM query results
- **Future pages** → wire in as needed

### Environment Targeting

All functions hardcode three environments. In xFACts, driven by `dbo.ServerRegistry`:

| Environment | App Server(s) | dmfs Path Pattern | API URL Pattern |
|-------------|-------------|-------------------|----------------|
| Test | dm-test-app | `\\dm-test-app\e$\dmfs\import\{pipeline}\` | `http://dm-test-app:8080/dm-rest-services/api` |
| Stage | dm-stage-app3 | `\\dm-stage-app3\dmfs\import\{pipeline}\` | `http://dm-stage-app:8080/dm-rest-services/api` |
| Production | dm-prod-app, dm-prod-app2, dm-prod-app3 | `\\dm-prod-app3\dmfs\import\{pipeline}\` | `http://dm-prod-app:8080/dm-rest-services/api` |

**Note:** Production has 3 app servers. Some operations (Refresh Drools) hit all three. Others hit just one (typically dm-prod-app for scheduled jobs, dm-prod-app3 for file writes). ServerRegistry entries need to capture both the primary API server and the dmfs write target per environment.

### Cooldown/Throttle Pattern

Three functions have built-in cooldown periods. In xFACts, this would be tracked in the Tools execution log:

| Function | Cooldown | Implementation |
|----------|----------|----------------|
| Release Notices | 5 minutes | Check last execution time before allowing re-run |
| Balance Sync | 60 minutes | Check last execution time before allowing re-run |
| Refresh Drools | None | No throttle needed |

This pattern generalizes: the Tools execution log captures every invocation, and a `min_interval_seconds` column on the job trigger configuration table enforces cooldowns at the API level.

---

## Cross-Reference: Existing xFACts Coverage

| Legacy Function | xFACts Module | Coverage Level | Notes |
|----------------|--------------|---------------|-------|
| Jira Ticket (R20) | Jira pipeline | **Full** | Already replaced. Legacy function can be retired. |
| All B* BDL functions | BDL Import Module (planned) | Design phase | Code review confirms design is aligned |
| Delete Mail Returns (B8/R13) | BDL Import Module (planned) | Design phase | Has both BDL and direct API variants |
| Jobs dashboard (A8 widget) | JobFlow module | Partial | Compare specific metrics — may have gaps |
| Stalled NB Batches (A11 widget) | BatchOps NB tracking | Partial | Compare stall detection logic |
| Active Queries (A4) | Server Health (Activity) | Partial | Access DB does `sp_who2`-style query; xFACts has DMV/XE-based monitoring |
| Request Valid (A5/R4) | None | — | Duplicate of R4; could be added to job triggers |

---

## Items NOT Requiring Migration

| Item | Reason |
|------|--------|
| A1 - Users | Toolkit-internal user management. Replaced by xFACts RBAC. |
| A2 - Clear BDL | Clears Access staging tables. No equivalent needed — xFACts won't stage data in local tables the same way. |
| A3 - Clear Pay | Clears Access staging tables. Same as above. |
| A6 - Projects | Toolkit-internal project tracking. Not DM-related. |
| A7 - Maint Mode | Locks the Access DB. CC has its own maintenance patterns. |
| R20 - Jira Ticket | Already replaced by xFACts Jira pipeline. |
| R22 - Blaze Promote | Stage-only developer tool. Low priority. |
| R23 - SOAP API Caller | Legacy SOAP interface. Developer tool. |
| fee_code.ChargeCurrFees | Empty stub. Never implemented. |

---

## Priority and Phasing Recommendations

### Phase 1: Foundation + BDL Pipeline
- Establish `Tools` schema and shared infrastructure tables
- BDL Import Module (covers 12 functions — the largest single block)
- BI departmental page with BDL import access
- Environment selection infrastructure via ServerRegistry

### Phase 2: Job Triggers + Simple API Operations
- Scheduled job trigger panel (R1–R5) — configuration-driven, lightweight
- Simple consumer operations (Hold Consumer, Post AR Event, etc.)
- Apps team operations page shell

### Phase 3: Payment Pipeline
- Payment Import pipeline (covers 10 functions)
- Financial operations UI with high RBAC restrictions

### Phase 4: Complex Consumer Operations
- Consumer merge workflow (R6) — multi-step with progress tracking
- Account split workflow (R7) — complex multi-step with batching
- Consumer update operations (R16, R17)

### Phase 5: Monitoring Dashboard + New Business
- DM monitoring widgets (Strategies, Workgroups — net new for xFACts)
- New Business import pipeline (2 functions — low volume)
- Generic API caller (admin-only debug tool)

---

## Open Questions (Remaining)

1. **Schema naming** — `Tools` is the working name. Other options: `Ops`, `Toolkit`, `AppOps`. Must be vendor-neutral and future-proof.
2. **Catalog table relocation** — Should `Catalog_BDL*` (and future `Catalog_CDL*`, `Catalog_API*`) move from `dbo.Engine.Catalog` to the new Tools schema? Deferred until schema is created.
3. **Unmapped form functions** — Several forms have functions not clearly mapped to screen buttons (tag assign/unassign, notice send/cancel, phone delete, consumer/address update). Need Matt to confirm which are actively used vs. experimental.
4. **Multi-server targeting** — Refresh Drools hits all 3 servers. Are there other operations that should hit all servers? Need to confirm with Matt.
5. **Validation rules from Access forms** — Some forms have client-side validation (date ranges for Request Valid, etc.) that should be captured for xFACts UI implementation.
6. **DM views** — The Admin dashboard queries `vw_stat_jobs`, `vw_stat_batches`, `vw_stat_bdl`, `vw_stat_strtgy`, `vw_stat_wrkgrp`. Need to confirm these views exist in current DM or if they were custom-created.

---

## Code Review Log

| Date | Reviewer | Scope | Key Findings |
|------|---------|-------|-------------|
| 2026-03-20 | Claude + Dirk | 4 standalone modules (34 functions) | Three distinct file pipelines (BDL, Payment, New Business). All BDL functions follow identical pattern matching Import Module design. |
| 2026-03-20 | Claude + Dirk | Full VBA export (130 files) | Complete DM REST API surface mapped: 3 scheduled job triggers, 12 consumer CRUD operations, 3 file pipeline endpoints, generic API caller. Admin screen fully cataloged — 4 of 7 functions are toolkit-internal (no migration needed). 5 dashboard widgets identified with partial xFACts overlap. Cooldown/throttle pattern documented. |

---

## Version History

| Date | Change |
|------|--------|
| 2026-03-20 | Initial draft from screenshots and discussion |
| 2026-03-20 | Module code review — 4 VBA modules analyzed, mechanism classification complete |
| 2026-03-20 | Full VBA export analysis — all 130 files analyzed, complete DM REST API surface documented, Admin functions classified, dashboard widgets cataloged, items not requiring migration identified |
