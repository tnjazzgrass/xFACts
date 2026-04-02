# xFACts Client Portal — Planning Document

**Module:** Tools
**Component:** Portal
**Target:** xFACts Control Center page
**Data Source:** crs5_oltp (read-only)
**Access:** Internal FA staff via CC ADLogin authentication + RBAC
**Priority:** Elevated — evaluating ahead of BDL Import steps 5-6

---

## 1. Background & Motivation

A client-facing portal is being developed externally by contractors in Azure using React with connectivity to DM via DM APIs. However, internal confidence in the contractor build is low, and the scope has grown more complex than the original requirements warranted. Meanwhile, a self-contained HTML prototype was built internally that correctly implements the financial calculations, data relationships, and UI flow — and has been well received by department heads.

This planning document scopes the effort to build a Control Center version of that prototype. The CC version would serve internal FA staff who need to look up consumer and account data quickly, especially for larger consumers where the production DM UI has timeout issues. All queries are read-only against crs5_oltp. No new xFACts database tables are required.

---

## 2. Portal Flow

The portal follows a linear drill-down pattern:

```
Search → Results List → Consumer Detail → Account Detail
```

Each level has a back-navigation link to the previous level. No deep-linking or browser history management needed for initial release.

---

## 3. Pages & Tabs

### 3.1 Search Page

Single search form with two controls:

- **Search By** dropdown: Client Account Number, Phone Number, SSN, Consumer Name, FA Consumer Number
- **Search Term** text input

Search executes server-side against crs5_oltp. Wildcard support: `*` for all, `M*` for prefix matching.

SSN search will require the decrypt function — this can be deferred to a later phase if the decrypt mechanism isn't readily available.

### 3.2 Results List

Table displaying matching consumers with columns:

| Column | Source |
|--------|--------|
| Status | Consumer tag (tag_typ_id = 115), active non-soft-deleted |
| Consumer Number | cnsmr.cnsmr_idntfr_agncy_id |
| Name | cnsmr.cnsmr_nm_lst_txt, cnsmr_nm_frst_txt |
| Creditor | First creditor from cnsmr_accnt → crdtr |
| # of Accounts | Count of cnsmr_accnt rows for consumer |
| Total Balance | Sum of cnsmr_accnt_bal where bal_nm_id = 7 (InvoiceBalance) |

Status displayed as a colored pill/badge (ACT/green, BNK/orange, ATY/red, PIF/blue, etc.) driven by the tag table's display and color fields.

Click "View" to navigate to Consumer Detail.

### 3.3 Consumer Detail

Header card showing consumer demographics (name, consumer number, DOB, email, SSN).

**Five tabs:**

#### 3.3.1 Accounts Tab (default)

Table of accounts for this consumer with columns: Status, Client Account Number, Creditor, Patient/Regarding, Placement Date, Service Date, Total Paid, Current Balance.

Totals row at bottom showing aggregate Total Paid and Total Balance Owed.

Click "View" on any account to navigate to Account Detail.

#### 3.3.2 Demographics Tab (Addresses)

Card-per-address showing address lines, city/state/zip, status (Valid/Invalid). Invalid addresses and mail returns displayed in red with return code and date if applicable.

#### 3.3.3 Phone Numbers Tab

Card-per-phone showing formatted phone number, type (Home/Work/Cell/Fax/VOIP), and status. Only non-soft-deleted phones displayed (cnsmr_phn_sft_dlt_flg = 'N'). Invalid and Do Not Call numbers displayed in red.

#### 3.3.4 Events Tab (AR Log)

Chronological event cards showing Action Code, Result Code, timestamp, message text, and user. Toggle switch to show/hide system notes (filtered by rslt_cd_class_assctn where rslt_cd_class_id = 41 for CRPortal events).

#### 3.3.5 Outreach Tab (Documents)

Document cards showing template name, description, and date. Filtered to status = 5 (sent) documents only. Links through dcmnt_rqst → dcmnt_tmplt_vrsn → dcmnt_tmplt for display names.

### 3.4 Account Detail

Header card showing account identifiers, dates, creditor, and three financial summary boxes (Original Balance, Total Paid, Current Balance).

**Three tabs:**

#### 3.4.1 Financial Transactions Tab (default)

Table of transactions with columns: Date, Bucket, Type, Location, Amount. Filtered to transaction types 2 (Payment), 3 (Adjustment), 5 (Settlement), 9 (Reversal). **Filtered to reportable buckets only** per crdtr_bckt.crdtr_bckt_rprtbl_flg.

#### 3.4.2 Events Tab

Same format as consumer events tab, but filtered to account-specific events only (cnsmr_accnt_id populated).

#### 3.4.3 Outreach Tab

Account-level documents. Joins through dcmnt_rqst_sbjct_rcrd (entty_assctn_cd = 3 for account-level, NULL elgblty_rsn for eligible accounts) → dcmnt_rqst (status = 5) → dcmnt_tmplt_vrsn → dcmnt_tmplt.

---

## 4. Financial Calculation Logic

These calculations are critical and must match the prototype exactly.

### 4.1 Current Balance (InvoiceBalance)

```sql
-- Per account
SELECT cnsmr_accnt_bal_amnt 
FROM cnsmr_accnt_bal 
WHERE cnsmr_accnt_id = @acctId AND bal_nm_id = 7

-- Returned accounts always display $0.00 for InvoiceBalance
-- regardless of stored value
```

### 4.2 Total Paid (per account)

```sql
-- Sum of payment-related transactions in REPORTABLE buckets only
SELECT SUM(t.cnsmr_accnt_trnsctn_amnt)
FROM cnsmr_accnt_trnsctn t
INNER JOIN crdtr_bckt cb 
    ON cb.bckt_id = t.bckt_id 
    AND cb.crdtr_id = t.crdtr_id
WHERE t.cnsmr_accnt_id = @acctId
  AND t.bckt_trnsctn_typ_cd IN (2, 3, 5, 9)   -- Payment, Adjustment, Settlement, Reversal
  AND cb.crdtr_bckt_rprtbl_flg = 'Y'
```

### 4.3 Total Paid (consumer aggregate)

Sum of per-account Total Paid across all accounts for the consumer.

### 4.4 Total Balance Owed (consumer aggregate)

Sum of InvoiceBalance (bal_nm_id = 7) across all accounts for the consumer, with returned accounts contributing $0.00.

### 4.5 Reportable Bucket Filtering

The crdtr_bckt table determines which financial buckets are visible per creditor. This filtering applies to both the transaction display AND the Total Paid calculation. If a bucket is not reportable for a creditor, transactions in that bucket are excluded from all financial displays.

---

## 5. Data Layer — crs5_oltp Tables

### 5.1 Primary Data Tables

| Table | Purpose | Key Columns |
|-------|---------|-------------|
| cnsmr | Consumer master | cnsmr_id, cnsmr_idntfr_agncy_id, name, DOB, email, SSN |
| cnsmr_accnt | Account master | cnsmr_accnt_id, cnsmr_id, crdtr_id, dates, flags |
| cnsmr_addrss | Consumer addresses | cnsmr_id, address lines, city/state/zip, status |
| cnsmr_phn | Consumer phones | cnsmr_id, number, type, status, soft delete flag |
| cnsmr_accnt_trnsctn | Financial transactions | cnsmr_accnt_id, bckt_id, type, amount, date, location |
| cnsmr_accnt_ar_log | Activity/event log | cnsmr_id, cnsmr_accnt_id, action, result, message, user, date |
| cnsmr_accnt_bal | Account balances | cnsmr_accnt_id, bal_nm_id, amount |
| cnsmr_tag | Consumer-level tags | cnsmr_id, tag_id, assign date, soft delete flag |
| cnsmr_accnt_tag | Account-level tags | cnsmr_accnt_id, tag_id, assign date, soft delete flag |
| crdtr | Creditor master | crdtr_id, crdtr_nm, crdtr_shrt_nm |
| crdtr_bckt | Creditor bucket reportability | crdtr_id, bckt_id, crdtr_bckt_rprtbl_flg |
| dcmnt_rqst | Document requests | dcmnt_rqst_id, date, template version, subject consumer, status |
| dcmnt_rqst_sbjct_rcrd | Document-to-account links | dcmnt_rqst_id, subject entity (account), eligibility, association code |

### 5.2 Lookup Tables

| Table | Purpose |
|-------|---------|
| bal_nm | Balance type names (8 types) |
| actn_cd | Action code descriptions |
| rslt_cd | Result code descriptions |
| ref_addrss_stts_cd | Address status values |
| bckt | Financial bucket names |
| ref_bckt_trnsctn_typ_cd | Transaction type descriptions |
| usr | User ID to username mapping |
| ref_phn_stts_cd | Phone status values |
| ref_phn_typ_cd | Phone type values |
| ref_pymnt_lctn_cd | Payment location values |
| tag | Tag definitions with type, display text, and color |
| dcmnt_tmplt_vrsn | Document template versions (crosswalk) |
| dcmnt_tmplt | Document template names and descriptions |
| rslt_cd_class | Result code class definitions |
| rslt_cd_class_assctn | Result code to class associations |

### 5.3 Lookup Caching Strategy

Lookup tables are small and rarely change. The API should cache these on first request and serve from cache on subsequent calls. A simple approach: load all lookups into a single API endpoint (`/api/client-portal/lookups`) that the page fetches once on load. This avoids repeated round-trips for static reference data.

---

## 6. Performance Considerations

### 6.1 cnsmr_accnt_ar_log

This is the 2.4 billion row table from the DmOps work. Querying it for a single consumer or account by indexed columns (cnsmr_id, cnsmr_accnt_id) should perform well. The API should always filter by consumer/account — never scan the full table.

### 6.2 Consumer Search

Search by Client Account Number, FA Consumer Number, and FA Account Number should hit indexed columns directly. Name search may require a LIKE pattern which could be slower on very common names. Consider limiting result set size (e.g., TOP 100) to prevent runaway queries.

### 6.3 Financial Calculations

Total Paid calculations involve joining cnsmr_accnt_trnsctn with crdtr_bckt. For consumers with many accounts and heavy transaction history, this could be expensive if done per-account in a loop. The API should compute this in a single query with GROUP BY rather than N+1 calls.

---

## 7. CC Architecture

### 7.1 File Structure

| File | Purpose |
|------|---------|
| ClientPortal.ps1 | Route — page rendering |
| ClientPortal-API.ps1 | API endpoints — all data access |
| client-portal.css | Dark theme styles |
| client-portal.js | Client-side rendering, search, navigation, formatting |

### 7.2 API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| /api/client-portal/lookups | GET | All lookup table data (cached) |
| /api/client-portal/search | GET | Consumer search with type and term parameters |
| /api/client-portal/consumer/:id | GET | Consumer header + summary data |
| /api/client-portal/consumer/:id/accounts | GET | Account list with balances and status |
| /api/client-portal/consumer/:id/addresses | GET | Consumer addresses |
| /api/client-portal/consumer/:id/phones | GET | Consumer phones (non-deleted) |
| /api/client-portal/consumer/:id/events | GET | Consumer-level AR log entries |
| /api/client-portal/consumer/:id/documents | GET | Consumer-level outreach documents |
| /api/client-portal/account/:id | GET | Account detail with financial summary |
| /api/client-portal/account/:id/transactions | GET | Account transactions (reportable buckets) |
| /api/client-portal/account/:id/events | GET | Account-level AR log entries |
| /api/client-portal/account/:id/documents | GET | Account-level outreach documents |

### 7.3 Connection

All queries run against crs5_oltp on AVG-PROD-LSNR secondary DM-PROD-REP if we want to offload to the AG secondary for read-only queries — worth discussing). Uses existing Get-SqlData helpers with the appropriate server/database parameters.

### 7.4 Access Control

RBAC via existing CC ADLogin authentication. The portal page would be added to the DeptOps or similar departmental section. Access controlled by the same role mechanism used by other CC pages.

### 7.5 Navigation Gateway

A link/card to the Client Portal would be added to departmental pages in the CC, similar to how BDL Import is accessed. This provides a natural entry point for staff who are already working in the CC.

---

## 8. UI Approach

### 8.1 Dark Theme Adaptation

The prototype uses Tailwind with a light theme and FA brand colors (#003366 navy, white backgrounds). The CC version will use the established dark theme palette (dark backgrounds, muted text, accent colors for status badges). The layout structure — search form, results table, detail cards with tabs — translates directly.

### 8.2 Status Badges

Consumer and account status badges use colored pills driven by the tag table. The tag table includes `display` (badge text like ACT, PIF, BNK, RTN) and `color` (green, blue, orange, red, etc.) fields. These map to CSS classes in the CC theme.

### 8.3 Tab Navigation

Consumer detail has 5 tabs, account detail has 3. Standard CC tab pattern (border-bottom highlight on active tab). Tab content loads via API calls when the tab is selected — no need to preload all tabs.

---

## 9. Build Phases

### Phase 1: Foundation + Search (Session 1)

- Create route file (ClientPortal.ps1) with page shell
- Create API file (ClientPortal-API.ps1) with search and lookup endpoints
- Build search page UI (search type dropdown, search term input, submit)
- Build results list with consumer status badges
- Implement lookup caching
- CSS file with dark theme layout

**Deliverable:** Working search → results flow

### Phase 2: Consumer Detail (Session 2)

- Consumer header card with demographics
- Accounts tab with balance calculations (InvoiceBalance, Total Paid with reportable bucket filtering)
- Demographics tab (addresses with status coloring)
- Phone Numbers tab (with soft-delete filtering and status display)
- Events tab with CRPortal filter toggle
- Outreach tab (documents)
- Consumer-level financial aggregates (Total Balance Owed, Total Paid)

**Deliverable:** Full consumer detail view with all 5 tabs

### Phase 3: Account Detail + Polish (Session 3)

- Account header card with financial summary boxes
- Financial Transactions tab with reportable bucket filtering
- Account Events tab
- Account Outreach tab (document-to-account linking)
- Return date display for returned accounts
- RBAC integration
- Departmental page gateway links
- Testing with production data

**Deliverable:** Complete portal ready for internal use

---

## 10. Deferred Items

- **SSN search with decrypt:** Requires integration with the DM decrypt function. Can be added once the mechanism is understood.
- **Creditor filtering:** The prototype has an allowedCreditorIds concept for restricting visible accounts to specific creditors. This is relevant for the external client-facing portal but may not be needed for the internal CC version where staff see all creditors. Defer unless requested.
- **Export/print:** No export capability in initial release. Could add CSV export for transaction lists if requested.
- **Login page:** The prototype has a mock login page. The CC version doesn't need this — authentication is handled by ADLogin at the CC level.

---

## 11. Open Questions

1. **Query target:** Should portal queries run against AVG-PROD-LSNR (primary) or DM-PROD-REP (AG secondary)? The secondary would offload read traffic from the primary, but adds a dependency on replication lag being acceptable for portal freshness.

DM-PROD-REP. Secondary only - lag is minimal in our environment and not an issue for this purpose

2. **Module/component classification:** Does this belong under DeptOps (since it's departmental tooling), or does it warrant its own module? The data is all DM consumer/account data, but the tool serves an operational role.

This is going to be Tools

3. **Result set limits:** Should search results be capped (e.g., TOP 100) to prevent expensive queries on very broad searches? The prototype allows `*` to return all consumers.

Potentially a cap, yes. Maybe we could do some kind of "more" option to return the next 100 or something? We'll have to see how painful it actually is first I think

4. **SSN decrypt:** What is the decrypt mechanism? Is it a SQL function, a DM API call, or a CLR assembly? This determines how/when SSN search gets implemented.

This is a function that lives in our DBA database we could leverage
