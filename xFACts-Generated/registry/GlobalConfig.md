# Global Configuration
Source: dbo.GlobalConfig
Generated: 2026-07-22 16:14:17

| module_name | category | setting_name | setting_value | data_type | is_ui_editable | description |
| --- | --- | --- | --- | --- | --- | --- |
| B2B | B2B | b2b_alert_sterling_fault_routing | 1 | ALERT_MODE | True | Alert destination(s) for Sterling-internal failure classifications (0=None,1=Teams,2=Jira,3=Both). |
| B2B | B2B | b2b_alert_workflow_change_routing | 1 | ALERT_MODE | True | Alert destination(s) when a Sterling workflow definition version changes (0=None,1=Teams,2=Jira,3=Both). |
| B2B | B2B | b2b_alerting_enabled | 1 | BIT | True | Master on/off switch for B2B module alerting |
| B2B | B2B | b2b_collect_lookback_days | 3 | INT | True | Number of days back that Collect-B2BPipeline.ps1 scans Integration batch-status rows. |
| B2B | B2B | b2b_inflight_aging_minutes | 720 | INT | True | Minutes an in-flight (status 0) pipeline run may age before Collect-B2BPipeline.ps1 cross-checks it against Sterling runtime state. |
| BatchOps | BDL | bdl_alert_failed_routing | 3 | ALERT_MODE | True | Alert destination(s) when a BDL file reaches FAILED status in File_Registry |
| BatchOps | BDL | bdl_alert_stall_routing | 1 | ALERT_MODE | True | Alert destination(s) when BDL partition processing stalls |
| BatchOps | BDL | bdl_alerting_enabled | 1 | BIT | True | Master on/off switch for all BDL batch alerting |
| BatchOps | BDL | bdl_lookback_days | 7 | INT | True | How many days back xFACts checks DM for BDL file collection |
| BatchOps | BDL | bdl_stall_poll_threshold | 12 | INT | True | Consecutive idle polls with no new partition activity before stall alert |
| BatchOps | NB | nb_alert_queue_wait_no_merge_routing | 1 | ALERT_MODE | True | Alert destination(s) when non-auto-merge batches exceed threshold |
| BatchOps | NB | nb_alert_queue_wait_routing | 3 | ALERT_MODE | True | Alert destination(s) when batches wait in merge queue with no activity |
| BatchOps | NB | nb_alert_release_failed_routing | 3 | ALERT_MODE | True | Alert destination(s) when a batch release fails |
| BatchOps | NB | nb_alert_release_merge_skip_routing | 3 | ALERT_MODE | True | Alert destination(s) when release-merge processing stalls |
| BatchOps | NB | nb_alert_stalled_merge_routing | 1 | ALERT_MODE | True | Alert destination(s) when merge processing stalls |
| BatchOps | NB | nb_alert_unreleased_routing | 1 | ALERT_MODE | True | Alert destination(s) when unreleased batches exceed threshold |
| BatchOps | NB | nb_alert_upload_failed_routing | 3 | ALERT_MODE | True | Alert destination(s) when a batch upload fails |
| BatchOps | NB | nb_alert_upload_stall_routing | 1 | ALERT_MODE | True | Alert destination(s) when batch upload processing stalls |
| BatchOps | NB | nb_alerting_enabled | 1 | BIT | True | Master on/off switch for all NB batch alerting |
| BatchOps | NB | nb_lookback_days | 7 | INT | True | How many days back xFACts checks DM for new business batch collection |
| BatchOps | NB | nb_queue_wait_minutes | 300 | INT | True | Minutes a batch can wait in merge queue before alerting |
| BatchOps | NB | nb_queue_wait_no_merge_minutes | 1440 | INT | True | Minutes a non-auto-merge batch can wait before alerting |
| BatchOps | NB | nb_release_merge_skip_stall_threshold | 24 | INT | True | Consecutive idle polls before release-merge stall alert |
| BatchOps | NB | nb_stall_poll_threshold | 24 | INT | True | Consecutive idle polls before merge stall alert |
| BatchOps | NB | nb_unreleased_minutes | 480 | INT | True | Minutes unreleased before alerting (manual release required) |
| BatchOps | NB | nb_upload_stall_minutes | 120 | INT | True | Minutes in uploading status before upload stall alert |
| BatchOps | PMT | pmt_alert_failed_routing | 1 | ALERT_MODE | True | Alert destination(s) when a payment batch fails |
| BatchOps | PMT | pmt_alert_import_failed_routing | 1 | ALERT_MODE | True | Alert destination(s) when a payment import fails |
| BatchOps | PMT | pmt_alert_partial_routing | 1 | ALERT_MODE | True | Alert destination(s) for partial payment failures |
| BatchOps | PMT | pmt_alert_reversal_failed_routing | 1 | ALERT_MODE | True | Alert destination(s) when a payment reversal fails |
| BatchOps | PMT | pmt_alerting_enabled | 1 | BIT | True | Master on/off switch for all PMT batch alerting |
| BatchOps | PMT | pmt_lookback_days | 7 | INT | True | How many days back xFACts checks DM for payment batch collection |
| BIDATA |  | bidata_build_job_name | BIDATA Daily Build | VARCHAR | False | SQL Agent job name to monitor for the nightly build |
| BIDATA |  | bidata_build_source_server | DM-PROD-REP | VARCHAR | False | Server where the nightly BIDATA build runs |
| BIDATA |  | bidata_build_start_grace_minutes | 15 | INT | True | Minutes after scheduled start before alerting that the build has not started |
| ControlCenter | ApiCache | cache_ttl_default_seconds | 600 | INT | False | Default cache duration for API responses (seconds) |
| ControlCenter | ApiCache.BIDATA | cache_ttl_bidata_step_count_seconds | 43200 | INT | True | Cache TTL (12 hours) for the BIDATA Daily Build job step count. |
| ControlCenter | ApiCache.ClientRelations | cache_ttl_regf_queue_seconds | 300 | INT | False | Cache duration for Client Relations Reg F queue data (seconds) |
| ControlCenter | Connection | refresh_idle_timeout_seconds | 240 | INT | True | Seconds of inactivity before dashboard pauses and shows idle overlay |
| ControlCenter | Connection | refresh_reconnect_grace_seconds | 60 | INT | True | Seconds to show reconnecting banner before displaying an error |
| ControlCenter | RBAC | rbac_audit_verbosity | all | VARCHAR | False | What access checks to log: denials_only or all |
| ControlCenter | RBAC | rbac_enforcement_mode | enforce | VARCHAR | False | Access control mode: disabled, audit (log only), or enforce (block) |
| ControlCenter | Refresh | refresh_b2b_seconds | 10 | INT | True | B2B Pipeline page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_backup_seconds | 5 | INT | True | Backup Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_batch_seconds | 5 | INT | True | Batch Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_bdl-import_seconds | 20 | INT | True | Polling interval in seconds for the BDL Import History panel |
| ControlCenter | Refresh | refresh_bidata_seconds | 30 | INT | True | BIDATA Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_businessservices_seconds | 60 | INT | True | Business Services page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_clientrelations_seconds | 1800 | INT | True | Client Relations page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_dbcc-operations_seconds | 5 | INT | True | DBCC Operations page refresh live window interval (seconds) |
| ControlCenter | Refresh | refresh_fileops_seconds | 30 | INT | True | File Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_indexmaintenance_seconds | 5 | INT | True | Index Maintenance page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_jboss_monitoring_seconds | 60 | INT | True | Auto-refresh interval for the JBoss Monitoring page |
| ControlCenter | Refresh | refresh_jobflow_seconds | 10 | INT | True | JobFlow Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_replication_seconds | 10 | INT | True | Replication Monitoring page live window refresh interval (seconds) |
| ControlCenter | Refresh | refresh_serverhealth_seconds | 5 | INT | True | Server Health page refresh live window interval (seconds) |
| DeptOps | ApplicationsIntegration | cooldown_balance_sync_seconds | 3600 | INT | True | Minimum seconds between Balance Sync executions per environment |
| DeptOps | ApplicationsIntegration | cooldown_release_notices_seconds | 300 | INT | True | Minimum seconds between Release Notices executions per environment |
| DeptOps | BS_ReviewRequest | bs_default_assignment_cap | 100 | INT | True | Default max assignments for new distribution users |
| DeptOps | BS_ReviewRequest | bs_distribution_enabled | 1 | BIT | True | Master on/off switch for automated review request distribution |
| DmOps | Archive | alerting_enabled | 0 | BIT | True | Master switch for archive alerting |
| DmOps | Archive | archive_abort | 0 | BIT | True | Emergency shutoff. Overrides schedule and enabled flag |
| DmOps | Archive | batch_size | 5000 | INT | True | Number of consumers per batch during full-mode schedule windows |
| DmOps | Archive | batch_size_reduced | 500 | INT | True | Number of consumers per batch during reduced-mode schedule windows |
| DmOps | Archive | bidata_build_job_name | BIDATA Daily Build | VARCHAR | True | SQL Agent job name for the BIDATA Daily Build |
| DmOps | Archive | bidata_instance | DM-TEST-APP | VARCHAR | True | SQL Server instance hosting the BIDATA database for BIDATA operations |
| DmOps | Archive | chunk_size | 5000 | INT | True | Maximum rows per DELETE operation (deleted in chunks of this size) |
| DmOps | Archive | tag_removal_actn_cd | CC | VARCHAR | True | Action code short value used for archiving exceptions |
| DmOps | Archive | tag_removal_msg_txt | Consumer archive tag removed - ineligible account(s) detected | VARCHAR | True | AR event message text for archiving exceptions |
| DmOps | Archive | tag_removal_rslt_cd | CC | VARCHAR | True | Result code short value used for archiving exceptions |
| DmOps | Archive | tag_removal_user | sqlmon | VARCHAR | True | DM username for archiving exceptions |
| DmOps | Archive | target_instance | DM-TEST-APP | VARCHAR | True | SQL Server instance hosting crs5_oltp for archive processing |
| DmOps | Archive | target_workgroups | BOTH | VARCHAR | True | Which archive workgroup(s) to process: WFAARCH1 (1P), WFAARCH3 (3P), or BOTH. |
| DmOps | ShellPurge | alerting_enabled | 1 | BIT | True | Master switch for shell purge alerting |
| DmOps | ShellPurge | batch_size | 100000 | INT | True | Number of shell consumers per batch during full-mode schedule windows |
| DmOps | ShellPurge | batch_size_reduced | 1000 | INT | True | Number of shell consumers per batch during reduced-mode schedule windows |
| DmOps | ShellPurge | chunk_size | 5000 | INT | True | Maximum rows per DELETE operation (deleted in chunks of this size) |
| DmOps | ShellPurge | shell_purge_abort | 0 | BIT | True | Emergency shutoff. Overrides schedule and enabled flag |
| DmOps | ShellPurge | target_instance | AVG-PROD-LSNR | VARCHAR | True | SQL Server instance hosting crs5_oltp for shell purge processing |
| FileOps | Detection | cda_base_path | \\kingkong\dpbackup\Client_Data_Archive | VARCHAR | True | UNC path to Client Data Archive (fallback location) |
| JBoss | Admin | dm_sharepoint_active_server | DM-PROD-APP2 | VARCHAR | False | Currently active DM app server in the SharePoint navigation link. |
| JBoss | Admin | management_api_url | http://dm-prod-app:9990/management | VARCHAR | False | JBoss Management API base URL on the domain controller |
| JBoss | App | alerting_enabled | 0 | BIT | True | Master on/off switch for DmOps alerting |
| JBoss | App | api_timeout_seconds | 30 | INT | True | Timeout in seconds for JBoss Management API REST calls |
| JBoss | App | http_base_path | /CRSServicesWeb/ | VARCHAR | True | URL path appended to server name for HTTP responsiveness. |
| JBoss | App | http_timeout_seconds | 10 | INT | True | HTTP request timeout for HTTP responsiveness calls |
| JBoss | App | snapshot_retention_days | 90 | INT | True | Days to retain App_Snapshot history |
| JobFlow | Monitoring | StallThreshold | 6 | INT | True | Consecutive idle polls before JobFlow process stall alert |
| JobFlow | Monitoring | ValidationRetryEnabled | 1 | BIT | True | Enable automatic retry of missed flow validations |
| Orchestrator |  | orchestrator_drain_mode | 0 | INT | False | Drain mode: stops new process launches while in-flight ones finish |
| Orchestrator | Engine | heartbeat_interval_seconds | 60 | INT | True | Seconds between orchestrator engine heartbeats |
| ServerOps | Activity_DMV | dmv_alerting_enabled | 1 | BIT | True | Master on/off switch for all DMV-based alerting |
| ServerOps | Activity_DMV | dmv_retention_days | 90 | INT | True | Days to keep DMV snapshot data |
| ServerOps | Activity_DMV | incident_hadr_spike_critical_ms | 5000000 | INT | True | AG sync wait spike threshold for critical incidents (milliseconds) |
| ServerOps | Activity_DMV | incident_hadr_spike_warning_ms | 500000 | INT | True | AG sync wait spike threshold for warning incidents (milliseconds) |
| ServerOps | Activity_DMV | incident_memory_grants_threshold | 5 | INT | True | Pending memory grants threshold for incidents |
| ServerOps | Activity_DMV | incident_ple_critical_threshold | 100 | INT | True | Page life expectancy threshold for critical incidents |
| ServerOps | Activity_DMV | incident_ple_warning_threshold | 300 | INT | True | Page life expectancy threshold for warning incidents |
| ServerOps | Activity_DMV | incident_zombie_warning_threshold | 500 | INT | True | Zombie connection count threshold for warning incidents |
| ServerOps | Activity_DMV | threshold_blocked_sessions_crisis | 10 | INT | True | Blocked sessions: crisis threshold |
| ServerOps | Activity_DMV | threshold_blocked_sessions_critical | 5 | INT | True | Blocked sessions: critical threshold |
| ServerOps | Activity_DMV | threshold_blocked_sessions_warning | 1 | INT | True | Blocked sessions: warning threshold |
| ServerOps | Activity_DMV | threshold_buffer_cache_crisis | 80 | INT | True | Buffer cache hit ratio: crisis threshold (%) |
| ServerOps | Activity_DMV | threshold_buffer_cache_critical | 95 | INT | True | Buffer cache hit ratio: critical threshold (%) |
| ServerOps | Activity_DMV | threshold_buffer_cache_warning | 99 | INT | True | Buffer cache hit ratio: warning threshold (%) |
| ServerOps | Activity_DMV | threshold_hadr_sync_critical_ms | 5000000 | INT | True | AG sync wait: critical threshold (milliseconds) |
| ServerOps | Activity_DMV | threshold_hadr_sync_warning_ms | 500000 | INT | True | AG sync wait: warning threshold (milliseconds) |
| ServerOps | Activity_DMV | threshold_lazy_writes_crisis | 100 | INT | True | Lazy writes/sec: crisis threshold |
| ServerOps | Activity_DMV | threshold_lazy_writes_critical | 50 | INT | True | Lazy writes/sec: critical threshold |
| ServerOps | Activity_DMV | threshold_lazy_writes_warning | 20 | INT | True | Lazy writes/sec: warning threshold |
| ServerOps | Activity_DMV | threshold_memory_grants_crisis | 10 | INT | True | Pending memory grants: crisis threshold |
| ServerOps | Activity_DMV | threshold_memory_grants_critical | 5 | INT | True | Pending memory grants: critical threshold |
| ServerOps | Activity_DMV | threshold_memory_grants_warning | 1 | INT | True | Pending memory grants: warning threshold |
| ServerOps | Activity_DMV | threshold_open_trans_crisis | 10 | INT | True | Idle open transactions: crisis threshold |
| ServerOps | Activity_DMV | threshold_open_trans_critical | 5 | INT | True | Idle open transactions: critical threshold |
| ServerOps | Activity_DMV | threshold_open_trans_idle_minutes | 5 | INT | True | Minutes idle with open transaction before counting |
| ServerOps | Activity_DMV | threshold_open_trans_warning | 1 | INT | True | Idle open transactions: warning threshold |
| ServerOps | Activity_DMV | threshold_ple_crisis | 100 | INT | True | Page life expectancy: crisis threshold |
| ServerOps | Activity_DMV | threshold_ple_critical | 300 | INT | True | Page life expectancy: critical threshold |
| ServerOps | Activity_DMV | threshold_ple_warning | 1000 | INT | True | Page life expectancy: warning threshold |
| ServerOps | Activity_DMV | threshold_tempdb_used_pct_crisis | 95 | INT | True | tempdb Pressure card: data-file percent used at or above which status is Crisis. |
| ServerOps | Activity_DMV | threshold_tempdb_used_pct_critical | 85 | INT | True | tempdb Pressure card: data-file percent used at or above which status is Critical. |
| ServerOps | Activity_DMV | threshold_tempdb_used_pct_warning | 70 | INT | True | tempdb Pressure card: data-file percent used at or above which status is Warning. |
| ServerOps | Activity_DMV | threshold_waits_pct_crisis | 75 | INT | True | Active Waits card: percent of active sessions waiting at or above which status is Crisis. |
| ServerOps | Activity_DMV | threshold_waits_pct_critical | 50 | INT | True | Active Waits card: percent of active sessions waiting at or above which status is Critical. |
| ServerOps | Activity_DMV | threshold_waits_pct_warning | 25 | INT | True | Active Waits card: percent of active sessions waiting at or above which status is Warning. |
| ServerOps | Activity_DMV | threshold_zombie_count_crisis | 800 | INT | True | Zombie connections: crisis threshold |
| ServerOps | Activity_DMV | threshold_zombie_count_critical | 500 | INT | True | Zombie connections: critical threshold |
| ServerOps | Activity_DMV | threshold_zombie_count_warning | 200 | INT | True | Zombie connections: warning threshold |
| ServerOps | Activity_DMV | threshold_zombie_idle_minutes | 60 | INT | True | Minutes idle before a JDBC session counts as a zombie |
| ServerOps | Activity_XE | aghealth_alert_critical_error_routing | 1 | ALERT_MODE | True | Alert destination(s) for AG severity 16+ errors |
| ServerOps | Activity_XE | aghealth_alert_state_change_routing | 1 | ALERT_MODE | True | Alert destination(s) for AG state changes |
| ServerOps | Activity_XE | aghealth_retain_raw_xml | 1 | BIT | True | Keep raw XML data for AG health events |
| ServerOps | Activity_XE | blocked_process_retain_raw_xml | 1 | BIT | True | Keep raw XML data for blocked process events |
| ServerOps | Activity_XE | xe_alerting_enabled | 1 | BIT | True | Master on/off switch for all XE-based alerting |
| ServerOps | Backup | alert_threshold_aws_pending_min | 30 | INT | True | Minutes before a pending AWS upload triggers an alert |
| ServerOps | Backup | alert_threshold_network_pending_min | 30 | INT | True | Minutes before a pending network copy triggers an alert |
| ServerOps | Backup | aws_bucket_name | faitdbredgate | VARCHAR | False | AWS S3 bucket name for backup uploads |
| ServerOps | Backup | aws_path_prefix | xFACts | VARCHAR | False | Folder prefix within the AWS S3 bucket |
| ServerOps | Backup | aws_upload_max_retries | 2 | INT | True | Maximum retry attempts for failed AWS uploads |
| ServerOps | Backup | network_backup_root | \\fa-sqldbb\g$\BACKUP\xFACts | VARCHAR | False | Network share root path for backup copies |
| ServerOps | Backup | network_copy_max_retries | 2 | INT | True | Maximum retry attempts for failed network copies |
| ServerOps | DBCC | dbcc_alerting_enabled | 1 | BIT | True | Master on/off switch for DBCC alerting |
| ServerOps | DBCC | dbcc_extended_logical_checks | 0 | BIT | True | Enable EXTENDED_LOGICAL_CHECKS (Only relevant with check_type = FULL) |
| ServerOps | DBCC | dbcc_max_dop | 4 | INT | True | MAXDOP for DBCC CHECKDB execution |
| ServerOps | Disk | default_threshold_pct | 20.00 | DECIMAL | True | Default free space alert threshold for new drives (%) |
| ServerOps | Disk | snapshot_retention_days | 90 | INT | True | Days to keep disk space snapshot history |
| ServerOps | Disk | space_request_buffer_pct | 5.00 | DECIMAL | True | Extra % above threshold when calculating Jira space requests |
| ServerOps | Disk | stale_data_minutes | 90 | INT | True | Minutes without new data before showing stale warning |
| ServerOps | Disk | warning_buffer_pct | 2.00 | DECIMAL | True | Extra % above threshold to flag drives as approaching limit |
| ServerOps | Index | index_default_maxdop | 0 | INT | True | Default parallelism for rebuilds (0 = server default) |
| ServerOps | Index | index_default_operation | REBUILD | VARCHAR | True | Default rebuild method: REBUILD or REORGANIZE |
| ServerOps | Index | index_deferral_base_score | 5 | INT | True | Priority score for indexes deferred fewer times than threshold |
| ServerOps | Index | index_deferral_max_score | 10 | INT | True | Priority score for indexes deferred at or above threshold |
| ServerOps | Index | index_deferral_threshold | 5 | INT | True | Deferral count that triggers maximum priority score |
| ServerOps | Index | index_execute_abort | 0 | BIT | True | Emergency stop: finish current index then halt rebuilds |
| ServerOps | Index | index_frag_high_score | 20 | INT | True | Priority score for severely fragmented indexes (60%+) |
| ServerOps | Index | index_frag_low_max | 30 | INT | True | Upper fragmentation bound for low range (%) |
| ServerOps | Index | index_frag_low_score | 10 | INT | True | Priority score for lightly fragmented indexes (15-30%) |
| ServerOps | Index | index_frag_med_max | 60 | INT | True | Upper fragmentation bound for medium range (%) |
| ServerOps | Index | index_frag_med_score | 15 | INT | True | Priority score for moderately fragmented indexes (30-60%) |
| ServerOps | Index | index_fragmentation_threshold | 15.00 | DECIMAL | True | Minimum fragmentation % to qualify for maintenance |
| ServerOps | Index | index_lock_timeout_seconds | 300 | INT | True | Seconds to wait for a lock before skipping an index |
| ServerOps | Index | index_maintenance_priority_1_score | 40 | INT | True | Priority score for Critical maintenance priority databases |
| ServerOps | Index | index_maintenance_priority_2_score | 25 | INT | True | Priority score for High maintenance priority databases |
| ServerOps | Index | index_maintenance_priority_3_score | 15 | INT | True | Priority score for Normal maintenance priority databases |
| ServerOps | Index | index_max_deferrals_before_alert | 5 | INT | True | Deferrals before alerting about a perpetually skipped index |
| ServerOps | Index | index_min_page_count | 1000 | INT | True | Minimum index size to qualify for maintenance (~8MB) |
| ServerOps | Index | index_overrun_tolerance_minutes | 15 | INT | True | Grace period for in-progress rebuild past window end (minutes) |
| ServerOps | Index | index_page_large_score | 30 | INT | True | Priority score for large indexes (100K+ pages) |
| ServerOps | Index | index_page_medium_max | 100000 | INT | True | Upper page count bound for medium indexes |
| ServerOps | Index | index_page_medium_score | 20 | INT | True | Priority score for medium indexes (10K-100K pages) |
| ServerOps | Index | index_page_small_max | 10000 | INT | True | Upper page count bound for small indexes |
| ServerOps | Index | index_page_small_score | 10 | INT | True | Priority score for small indexes (1K-10K pages) |
| ServerOps | Index | index_rescan_interval_days | 2 | INT | True | Minimum days between rescans of the same index |
| ServerOps | Index | index_scan_abort | 0 | BIT | True | Emergency stop: abort fragmentation scanning after current batch |
| ServerOps | Index | index_scan_batch_check_size | 50 | INT | True | Indexes to scan between abort/time-limit checks |
| ServerOps | Index | index_scan_interval_minutes | 2880 | INT | True | Minimum minutes between full fragmentation scan runs |
| ServerOps | Index | index_scan_pages_per_second | 120000 | INT | True | Estimated scan speed for timeout calculation (pages/sec) |
| ServerOps | Index | index_scan_skip_rebuilt_days | 3 | INT | True | Days to skip scanning recently rebuilt indexes |
| ServerOps | Index | index_scan_time_limit_minutes | 0 | INT | True | Maximum scan duration in minutes (0 = no limit) |
| ServerOps | Index | index_scan_timeout_base_seconds | 300 | INT | True | Minimum timeout per index during scanning (seconds) |
| ServerOps | Index | index_seconds_per_page_offline | 0.00020 | DECIMAL | True | Time estimate factor for offline rebuilds (seconds per page) |
| ServerOps | Index | index_seconds_per_page_online | 0.0004 | DECIMAL | True | Time estimate factor for online rebuilds (seconds per page) |
| ServerOps | Index | index_sync_interval_minutes | 1440 | INT | True | Minimum minutes between index discovery runs |
| ServerOps | Index | index_wait_low_priority_minutes | 15 | INT | True | Minutes an online index rebuild waits at low priority for its lock before aborting. Online/Enterprise only. |
| ServerOps | Index | stats_max_days_stale | 60 | INT | True | Force statistics update if older than this many days |
| ServerOps | Index | stats_min_rows | 1000 | INT | True | Minimum table row count for statistics maintenance |
| ServerOps | Index | stats_modification_pct_threshold | 10 | DECIMAL | True | Row modification % that triggers statistics update |
| ServerOps | Index | stats_respect_schedule | 0 | BIT | True | Restrict statistics updates to maintenance windows only |
| ServerOps | Index | stats_sample_pct | 10 | INT | True | Statistics sampling rate (0 = full scan) |
| ServerOps | Index | stats_update_interval_minutes | 1440 | INT | True | Minimum minutes between statistics update runs |
| ServerOps | Index | stats_update_timeout_seconds | 900 | INT | True | Command timeout in seconds for UPDATE STATISTICS operations. |
| ServerOps | Replication | replication_agent_down_alert_minutes | 5 | INT | True | Minutes replication agent can be down before alerting |
| ServerOps | Replication | replication_alerting_enabled | 0 | BIT | False | Master on/off switch for replication alerting |
| ServerOps | Replication | replication_latency_critical_ms | 120000 | INT | True | Latency threshold for critical alert (milliseconds) |
| ServerOps | Replication | replication_latency_warning_ms | 30000 | INT | True | Latency threshold for warning alert (milliseconds) |
| ServerOps | Replication | replication_queue_critical_threshold | 50000 | INT | True | Undistributed commands threshold for critical alert |
| ServerOps | Replication | replication_queue_warning_threshold | 5000 | INT | True | Undistributed commands threshold for warning alert |
| ServerOps | Replication | replication_tracer_interval_minutes | 5 | INT | True | Minutes between latency measurement checks |
| ServerOps | Replication | replication_tracer_wait_seconds | 15 | INT | True | Seconds to wait for latency results after posting tracer |
| Shared |  | AGListenerName | AVG-PROD-LSNR | VARCHAR | False | Always On Availability Group listener name for crs5_oltp |
| Shared |  | AGName | DMPRODAG | VARCHAR | False | Availability Group name for primary/secondary detection |
| Shared | Credentials | master_passphrase | P0w3rSh3LL-M@5t3R | VARCHAR | False | Master passphrase for decrypting service-specific passphrases |
| Shared | Monitoring | SourceReplica | SECONDARY | VARCHAR | False | Which AG replica to query for source data (PRIMARY or SECONDARY) |
| Teams | AlertFailures | alert_failure_lookback_days | 3 | INT | True | Days to look back when showing failed alerts on Admin page |
| Teams | Retry | teams_retry_max_attempts | 3 | INT | True | Max delivery retries before marking an alert as permanently failed |
| Tools | Operations | bdl_promote_cooldown_seconds | 300 | INT | True | Countdown timer in seconds before the Promote to Production button activates |
| Tools | Portal | crs5_portal_query_timeout_seconds | 60 | INT | True | Command timeout in seconds for Client Portal queries against crs5_oltp |
