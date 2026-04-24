# Step 6B — BPML Bulk Extraction

**Status:** ✅ Complete
**Date:** 2026-04-24
**Purpose:** Locate and extract the BPML XML source for every target workflow
definition identified in Step 6A. BPML is the authoritative structural source
for what each workflow can do — downstream sub-steps (6C, 6D) read these files
directly instead of inferring structure from runtime data.

---

## Summary of change

- **Discovered** the b2bi storage model for BPML XML (not previously documented in Step 1 catalog)
- **Extracted** 429 latest-version BPMLs to disk, organized by workflow family
- **Established** the `Step_06B_Extract_BPMLs.ps1` extraction tool for repeatable extraction as b2bi evolves

---

## Storage model verified

BPML is stored indirectly via a handle-to-blob pattern, parallel to how
`SCHEDULE.TIMINGXML` references `DATA_TABLE`:

```
WFD               ←── workflow definition metadata (2,467 rows, 1,433 distinct WFD_IDs)
 └── (WFD_ID, WFD_VERSION)
       └── WFD_XML      ←── thin 4-column lookup (2,466 rows)
            └── XML column = DATA_ID handle (nvarchar(255))
                 └── DATA_TABLE (shared blob store, 49,995 rows)
                      └── DATA_OBJECT = gzip-compressed payload (image, ≤2GB)
                           └── Java serialization preamble + BPML XML
```

Key properties:

- **No pagination.** Every BPML handle resolves to exactly one DATA_TABLE row at `PAGE_INDEX = 0`. Confirmed across all 2,466 WFD_XML rows.
- **Gzip compressed.** Every blob starts with magic bytes `0x1F 0x8B` (gzip). Confirmed across samples spanning all workflow families.
- **Binary preamble.** After gzip decompression, a variable-length (6-32 byte) Java serialization wrapper precedes the XML. The wrapper must be stripped to yield valid XML.
- **Total compressed volume:** 192,602 bytes (~193 KB) for all 429 extracted BPMLs.
- **Total decompressed XML volume:** 656,139 bytes (~640 KB). Compression ratio 3.41x.

### WFD_XML structure

| Column | Type | Notes |
|---|---|---|
| `WFD_ID` | int | Joins to WFD |
| `WFD_VERSION` | int | Joins to WFD; part of composite key |
| `XML` | nvarchar(255) | Handle (NOT content) — joins to `DATA_TABLE.DATA_ID` |
| `GBMDATA` | nvarchar(255) | Secondary handle, often NULL; likely points to graphical BP designer data; not required for BPML reconstruction |

### DATA_TABLE structure (shared blob store)

| Column | Type | Notes |
|---|---|---|
| `DATA_ID` | nvarchar(255) | Handle; joined by WFD_XML and other tables (TIMINGXML, TRANS_DATA, etc.) |
| `DATA_OBJECT` | image (2GB max) | The actual bytes — for BPML, gzip-compressed XML+preamble |
| `PAGE_INDEX` | int | Always 0 for BPML; designed for pagination but unused in this domain |
| `DATA_TYPE` | int | 2 for BPML (other types not investigated here) |
| `ARCHIVE_FLAG`, `ARCHIVE_DATE` | int, datetime | Purge metadata; both unused for BPML (flag=-1, date=NULL) |
| `WF_ID` | numeric | For BPML rows = -1 (no workflow association); populated for other blob types |
| `REFERENCE_TABLE` | nvarchar(255) | For BPML rows = `'WFD_XML'`; identifies the parent table |

---

## XML prologue variation across BPMLs

BPMLs are not stored with uniform prologues. Three valid XML start patterns were
observed across the extraction population:

1. **Direct root element** (most common): `<process name="...">`
2. **Comment prologue before root**: `<!-- (copyright header, description) -->\n<process name="...">`
3. **XML declaration before root** (not confirmed observed in this extraction, but handled defensively)

This required the extraction logic to scan for the *earliest* of `<?xml`, `<!--`,
or `<process` after the Sterling binary preamble, rather than a single fixed
marker. Two specific BPMLs forced this design:

- **`AFTPurgeArchiveMailboxes`** — IBM/Sterling-shipped workflow with a substantial copyright prologue (`<process>` at offset 1510)
- **`Schedule_SAPTidCleaner`** — Sterling-shipped scheduled workflow with an internal-documentation prologue (`<process>` at offset 575)

---

## Preamble length distribution

After successful extraction, preamble byte-length was recorded per BPML. The
7-byte preamble is the overwhelming norm for FAC-authored BPMLs. Longer
preambles correlate with longer workflow names (likely a Java-serialization
length prefix in the preamble).

| Preamble length | Count | % |
|---:|---:|---:|
| 7 bytes | 404 | 94.2% |
| 9 bytes | 13 | 3.0% |
| 13 bytes | 7 | 1.6% |
| 8 bytes | 2 | 0.5% |
| 12 bytes | 1 | 0.2% |
| 20 bytes | 1 | 0.2% |
| 32 bytes | 1 | 0.2% |
| **Total** | **429** | **100.0%** |

The preamble appears to be a Java object serialization wrapper (based on
discovery samples showing bytes like `ac ed 00 05 74 03 ...`), but the exact
structure was not reverse-engineered. Since the XML itself is self-contained
and well-formed, understanding the preamble is not required for this
investigation.

---

## Extraction target set

Confirmed from Step 6A findings: 429 BPMLs total.

- 413 workflows active in the last 30 days (WF_INST_S ∪ WF_INST_S_RESTORE)
- 17 dormant FA_CLIENTS workflows (run inline inside MAIN; not visible in WF_INST_S)
- Intersection of 1 (one dormant FA_CLIENTS also appears as 30d-active, de-duped via UNION)
- Net: 413 + 17 − 1 = **429**

The 17 dormant FA_CLIENTS WFD_IDs are hardcoded in the extraction query. This is
intentional — they are a discovered constant from Step 6A, not a parameter that
needs to vary between runs.

---

## Output layout on disk

```
Step_06B_BPMLs/
  01_FA_CLIENTS/            (28 files — core pipeline + 17 inline sub-workflows)
  02_FA_FROM/               (104 files — inbound client wrappers)
  03_FA_TO/                 (228 files — outbound client wrappers)
  04_FA_DM/                 (5 files   — DM integration flows)
  05_FA_OTHER/              (31 files  — FA_* without sub-prefix)
  06_FA_Specialized/        (3 files   — FA_B2B, FA_INTEGRATION, FA_CUSTOM, FA_CLA)
  07_Schedule/              (17 files  — Sterling Schedule_* housekeeping)
  08_Sterling_Infra/        (7 files   — TimeoutEvent, Alert, Recover, etc.)
  09_FileGateway/           (2 files)
  11_AFT_FILE_REMOVE/       (2 files)
  12_OTHER/                 (2 files   — unclassified)
  Step_06B_ExtractionLog.txt
  Step_06B_ExtractionManifest.csv
```

Note: folder `10_Mailbox_AS_EDI` is reserved in the family classifier but
contains no active/dormant workflows at FAC (consistent with Step 1's finding
that FAC uses pure BP-execution mode; Mailbox/AS2/AS3/EDIINT features are
installed but inactive).

### Filename convention

`{NAME}__v{WFD_VERSION}.bpml.xml` — double underscore separates the workflow
name from the version marker so parsers can unambiguously split on `__v` even
for names containing single underscores.

### Manifest CSV

One row per BPML with fields:

- `WFD_ID`, `WFD_VERSION`, `NAME`
- `family_folder`, `file_name`, `relative_path`
- `compressed_bytes`, `decompressed_bytes`, `preamble_bytes`
- `data_id` (the DATA_TABLE handle)
- `mod_date`, `edited_by` (Sterling's last-modified metadata)
- `status`, `error` (extraction outcome)

---

## Validation outcome

All 429 BPMLs parse as well-formed XML. All 429 have `<process>` as the root
element, consistent with the IBM Sterling 6.1 BPML specification.

First content spot-check: `FA_CLIENTS_MAIN` v48 decompresses to a 24-child,
590-element BPML with the first five rule names being `AnyMoreDocs?`, `Prep?`,
`PreArchive?`, `Translate?`, `DupCheck?` — these match the rule catalog claimed
in the legacy `B2B_ArchitectureOverview.md`. Full verification of
ArchitectureOverview claims happens in Step 6D.

---

## Implications for the collector

None at this stage — Step 6B is a pure investigation output. The BPML corpus is
the input to Steps 6C, 6D, and 6F. Collector architecture decisions remain
deferred until Step 6G consolidation.

---

## Resolved questions

- **Where is BPML stored?** b2bi.dbo.WFD_XML (thin lookup) → b2bi.dbo.DATA_TABLE (blob store).
- **What format?** gzip-compressed XML with an 6-32 byte Java serialization preamble.
- **Does BPML paginate?** No. One DATA_TABLE row per handle, PAGE_INDEX always 0.
- **How large is the corpus?** ~193 KB compressed, ~640 KB decompressed, 429 files.
- **Are all BPMLs `<process>`-rooted?** Yes — all 429 have `<process>` as the root element.

---

## New questions raised by Step 6B

1. What is the `GBMDATA` handle in WFD_XML? NULL for most rows; suspected graphical BP designer data. Not required for structural analysis but worth understanding for completeness.
2. What are the 587 empty b2bi tables doing? Step 1 identified them but many may be related to Sterling features unused at FAC (File Gateway, EDIINT, etc.). Opportunistic cleanup topic, low priority.
3. Why do some BPMLs have copyright/documentation comment prologues while most don't? Pattern: Sterling-shipped workflows (AFT*, Schedule_* where vendor-authored) have prologues; FAC-authored workflows (FA_*) do not. Not investigation-critical but useful for 6F's light-catalog triage.

---

## Artifacts

Under `WorkingFiles/B2B_Investigation/Step_06_MAIN_Anatomy/Step_06B_BPML_Bulk_Extraction/`:

- `Step_06B_SchemaDiscovery.sql` — the initial 6-query schema discovery
- `Step_06B_ContentVerification.sql` — format/pagination/size verification
- `Step_06B_Extract_BPMLs.ps1` — the extraction tool (v4 final)
- `Step_06B_Findings.md` — this document
- `BPMLs/` — the 429 extracted BPML files organized by family (plus manifest and log)

---

## Document status

**Final for Step 6B.** No further work in this sub-step. Next: Step 6C — Core
Workflow BPML Analysis (deep-read FA_CLIENTS family + representative dispatchers).
