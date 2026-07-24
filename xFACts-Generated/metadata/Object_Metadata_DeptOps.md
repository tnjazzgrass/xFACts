# Object_Metadata: DeptOps
Source: dbo.Object_Metadata
Generated: 2026-07-24 04:35:05

## BS_ReviewRequest_Group (Table)

### category #0  [metadata_id: 1691]

Business Services

### description #0  [metadata_id: 39]

Registry of Business Services review request groups from Debt Manager. Tracks which CRS5 user group classifications are monitored and whether automated distribution is enabled for each.

### module #0  [metadata_id: 1587]

DeptOps

### description / created_by #8  [metadata_id: 225]

Who created the group record

### description / created_dttm #7  [metadata_id: 224]

When the group record was created

### description / distribution_enabled #5  [metadata_id: 222]

Whether automated request distribution is active for this group. 1 = enabled, 0 = disabled

### description / dm_group_id #2  [metadata_id: 219]

CRS5 usr_grp_clssfctn_id. Links this record to the source system group

### description / group_id #1  [metadata_id: 218]

Unique identifier for the group record

### description / group_name #3  [metadata_id: 220]

Display name from CRS5 (e.g., 'Insurance (3P)')

### description / group_short_name #4  [metadata_id: 221]

Short identifier from CRS5 (e.g., 'UGFAIN'). Used in dashboard badges and filters

### description / is_active #6  [metadata_id: 223]

Whether this group is actively monitored. 1 = active, 0 = inactive

### description / modified_by #10  [metadata_id: 227]

Who last modified the group record

### description / modified_dttm #9  [metadata_id: 226]

When the group record was last modified

## BS_ReviewRequest_Tracking (Table)

### category #0  [metadata_id: 1692]

Business Services

### description #0  [metadata_id: 59]

Lifecycle tracking table for Business Services review requests collected from Debt Manager (CRS5). One row per review request, synchronized incrementally by the collector script and used by the Control Center dashboard for historical reporting.

### module #0  [metadata_id: 1588]

DeptOps

### description / assigned_user_id #15  [metadata_id: 514]

CRS5 user assigned to process this request (cnsmr_rvw_rqst_assgn_usr_id). NULL when unassigned

### description / assigned_username #16  [metadata_id: 515]

Username of the assigned user (denormalized)

### description / collected_dttm #22  [metadata_id: 521]

When this record was first collected from CRS5

### description / completed_user_id #17  [metadata_id: 516]

User who completed the request. Only populated when soft_delete_flag = 'Y'

### description / completed_username #18  [metadata_id: 517]

Username of the completing user. Only populated when soft_delete_flag = 'Y'

### description / completion_date #19  [metadata_id: 518]

When the request was completed. Only populated when soft_delete_flag = 'Y'

### description / consumer_first_name #7  [metadata_id: 506]

Consumer first name (cnsmr_nm_frst_txt)

### description / consumer_last_name #6  [metadata_id: 505]

Consumer last name (cnsmr_nm_lst_txt)

### description / consumer_number #5  [metadata_id: 504]

Consumer account number (cnsmr_idntfr_agncy_id)

### description / dm_consumer_id #3  [metadata_id: 502]

CRS5 cnsmr_id. The consumer this review request belongs to

### description / dm_last_updated #21  [metadata_id: 520]

CRS5 upsrt_dttm. Timestamp of the last modification in the source system

### description / dm_request_id #2  [metadata_id: 501]

CRS5 cnsmr_rvw_rqst_id. Uniquely identifies the review request in the source system

### description / dm_transaction_number #20  [metadata_id: 519]

CRS5 upsrt_trnsctn_nmbr. Used for incremental sync detection — the collector compares this value to find changed records

### description / group_id #4  [metadata_id: 503]

FK to BS_ReviewRequest_Group. Which review request group this belongs to

### description / request_comment #9  [metadata_id: 508]

Comment entered when the review request was created (cnsmr_rvw_rqst_cmmnt)

### description / request_date #14  [metadata_id: 513]

Date the review request was submitted (cnsmr_rvw_rqst_assgn_dt — misleading CRS5 name)

### description / requesting_user_id #12  [metadata_id: 511]

CRS5 user who submitted the review request (cnsmr_rvw_rqst_cmplt_usr_id — misleading CRS5 name)

### description / requesting_username #13  [metadata_id: 512]

Username of the requesting user (denormalized)

### description / soft_delete_flag #11  [metadata_id: 510]

Whether the request has been completed/closed. 'Y' = completed, 'N' = open

### description / status_code #10  [metadata_id: 509]

CRS5 status code (cnsmr_rvw_rqst_stts_cd). 0 = unassigned, 1 = assigned

### description / tracking_id #1  [metadata_id: 500]

Unique identifier for the tracking record

### description / workgroup #8  [metadata_id: 507]

Consumer's current workgroup short name (wrkgrp_shrt_nm)

## BS_ReviewRequest_User (Table)

### category #0  [metadata_id: 1693]

Business Services

### description #0  [metadata_id: 43]

Roster of users participating in automated review request distribution. Each user is assigned to a specific group with a configurable assignment cap that controls how many open requests they can hold at once.

### module #0  [metadata_id: 1589]

DeptOps

### description / assignment_cap #6  [metadata_id: 266]

Maximum number of open (non-soft-deleted) requests this user should have assigned at any time. Range: 1-500

### description / created_by #9  [metadata_id: 269]

Who created the roster entry

### description / created_dttm #8  [metadata_id: 268]

When the roster entry was created

### description / display_name #4  [metadata_id: 264]

Friendly display name for dashboard and reporting

### description / dm_user_id #2  [metadata_id: 262]

CRS5 usr_id. Used by the distribution script for assignment writes

### description / group_id #5  [metadata_id: 265]

FK to BS_ReviewRequest_Group. Which review request group this user services

### description / is_active #7  [metadata_id: 267]

Whether this user is currently in the distribution rotation. 1 = active, 0 = inactive

### description / modified_by #11  [metadata_id: 271]

Who last modified the roster entry

### description / modified_dttm #10  [metadata_id: 270]

When the roster entry was last modified

### description / user_id #1  [metadata_id: 261]

Unique identifier for the roster entry

### description / username #3  [metadata_id: 263]

CRS5 usr_usrnm. Stored for display and logging
