# Object_Metadata: DeptOps
Source: dbo.Object_Metadata
Generated: 2026-07-22 05:46:01

## BS_ReviewRequest_Group (Table)

### category #0

Business Services

### description #0

Registry of Business Services review request groups from Debt Manager. Tracks which CRS5 user group classifications are monitored and whether automated distribution is enabled for each.

### module #0

DeptOps

### description / created_by #8

Who created the group record

### description / created_dttm #7

When the group record was created

### description / distribution_enabled #5

Whether automated request distribution is active for this group. 1 = enabled, 0 = disabled

### description / dm_group_id #2

CRS5 usr_grp_clssfctn_id. Links this record to the source system group

### description / group_id #1

Unique identifier for the group record

### description / group_name #3

Display name from CRS5 (e.g., 'Insurance (3P)')

### description / group_short_name #4

Short identifier from CRS5 (e.g., 'UGFAIN'). Used in dashboard badges and filters

### description / is_active #6

Whether this group is actively monitored. 1 = active, 0 = inactive

### description / modified_by #10

Who last modified the group record

### description / modified_dttm #9

When the group record was last modified

## BS_ReviewRequest_Tracking (Table)

### category #0

Business Services

### description #0

Lifecycle tracking table for Business Services review requests collected from Debt Manager (CRS5). One row per review request, synchronized incrementally by the collector script and used by the Control Center dashboard for historical reporting.

### module #0

DeptOps

### description / assigned_user_id #15

CRS5 user assigned to process this request (cnsmr_rvw_rqst_assgn_usr_id). NULL when unassigned

### description / assigned_username #16

Username of the assigned user (denormalized)

### description / collected_dttm #22

When this record was first collected from CRS5

### description / completed_user_id #17

User who completed the request. Only populated when soft_delete_flag = 'Y'

### description / completed_username #18

Username of the completing user. Only populated when soft_delete_flag = 'Y'

### description / completion_date #19

When the request was completed. Only populated when soft_delete_flag = 'Y'

### description / consumer_first_name #7

Consumer first name (cnsmr_nm_frst_txt)

### description / consumer_last_name #6

Consumer last name (cnsmr_nm_lst_txt)

### description / consumer_number #5

Consumer account number (cnsmr_idntfr_agncy_id)

### description / dm_consumer_id #3

CRS5 cnsmr_id. The consumer this review request belongs to

### description / dm_last_updated #21

CRS5 upsrt_dttm. Timestamp of the last modification in the source system

### description / dm_request_id #2

CRS5 cnsmr_rvw_rqst_id. Uniquely identifies the review request in the source system

### description / dm_transaction_number #20

CRS5 upsrt_trnsctn_nmbr. Used for incremental sync detection — the collector compares this value to find changed records

### description / group_id #4

FK to BS_ReviewRequest_Group. Which review request group this belongs to

### description / request_comment #9

Comment entered when the review request was created (cnsmr_rvw_rqst_cmmnt)

### description / request_date #14

Date the review request was submitted (cnsmr_rvw_rqst_assgn_dt — misleading CRS5 name)

### description / requesting_user_id #12

CRS5 user who submitted the review request (cnsmr_rvw_rqst_cmplt_usr_id — misleading CRS5 name)

### description / requesting_username #13

Username of the requesting user (denormalized)

### description / soft_delete_flag #11

Whether the request has been completed/closed. 'Y' = completed, 'N' = open

### description / status_code #10

CRS5 status code (cnsmr_rvw_rqst_stts_cd). 0 = unassigned, 1 = assigned

### description / tracking_id #1

Unique identifier for the tracking record

### description / workgroup #8

Consumer's current workgroup short name (wrkgrp_shrt_nm)

## BS_ReviewRequest_User (Table)

### category #0

Business Services

### description #0

Roster of users participating in automated review request distribution. Each user is assigned to a specific group with a configurable assignment cap that controls how many open requests they can hold at once.

### module #0

DeptOps

### description / assignment_cap #6

Maximum number of open (non-soft-deleted) requests this user should have assigned at any time. Range: 1-500

### description / created_by #9

Who created the roster entry

### description / created_dttm #8

When the roster entry was created

### description / display_name #4

Friendly display name for dashboard and reporting

### description / dm_user_id #2

CRS5 usr_id. Used by the distribution script for assignment writes

### description / group_id #5

FK to BS_ReviewRequest_Group. Which review request group this user services

### description / is_active #7

Whether this user is currently in the distribution rotation. 1 = active, 0 = inactive

### description / modified_by #11

Who last modified the roster entry

### description / modified_dttm #10

When the roster entry was last modified

### description / user_id #1

Unique identifier for the roster entry

### description / username #3

CRS5 usr_usrnm. Stored for display and logging
