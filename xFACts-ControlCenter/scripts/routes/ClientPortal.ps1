# ============================================================================
# xFACts Control Center - Client Portal Page
# Location: E:\xFACts-ControlCenter\scripts\routes\ClientPortal.ps1
# 
# Consumer/account lookup tool for internal FA staff. Provides search,
# consumer detail (5 tabs), and account detail (3 tabs) against crs5_oltp.
# Accessible via gateway cards on departmental pages — no main nav entry.
#
# CSS: /css/client-portal.css
# JS:  /js/client-portal.js
# APIs: ClientPortal-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: Tools.Operations)
# ============================================================================

Add-PodeRoute -Method Get -Path '/client-portal' -Authentication 'ADLogin' -ScriptBlock {

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/client-portal'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/client-portal') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $adminGear = if ($ctx.IsAdmin) {
        '<span class="nav-spacer"></span><a href="/admin" class="nav-link nav-admin" title="Administration">&#9881;</a>'
    } else { '' }

    $navHtml = if ($access.IsDeptOnly) {
        @"
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/client-portal" class="nav-link active">Client Portal</a>
    </nav>
"@
    } else {
        @"
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/server-health" class="nav-link">Server Health</a>
        <a href="/jobflow-monitoring" class="nav-link">Job/Flow Monitoring</a>
        <a href="/batch-monitoring" class="nav-link">Batch Monitoring</a>
        <a href="/backup" class="nav-link">Backup Monitoring</a>
        <a href="/index-maintenance" class="nav-link">Index Maintenance</a>
        <a href="/dbcc-operations" class="nav-link">DBCC Operations</a>
        <a href="/bidata-monitoring" class="nav-link">BIDATA Monitoring</a>
        <a href="/file-monitoring" class="nav-link">File Monitoring</a>
        <a href="/replication-monitoring" class="nav-link">Replication Monitoring</a>
        <a href="/jboss-monitoring" class="nav-link">JBoss Monitoring</a>
        <a href="/dm-operations" class="nav-link">DM Operations</a>
        <span class="nav-separator">|</span>
        <a href="/departmental/business-services" class="nav-link">Business Services</a>
        <a href="/departmental/business-intelligence" class="nav-link">Business Intelligence</a>
        <a href="/departmental/client-relations" class="nav-link">Client Relations</a>
    </nav>
"@
    }

    $navHtml = $navHtml.Replace('</nav>', "$adminGear</nav>")

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Client Portal - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/client-portal.css">
</head>
<body>
    $navHtml
    
    <div class="header-bar">
        <div>
            <h1>Client Portal</h1>
            <p class="page-subtitle">Consumer &amp; Account Lookup</p>
        </div>
        <div class="header-right">
            <span id="lookup-status" class="lookup-status">Loading lookups...</span>
        </div>
    </div>
    
    <div id="connection-error" class="connection-error"></div>
    
    <!-- ================================================================ -->
    <!-- SEARCH PAGE                                                      -->
    <!-- ================================================================ -->
    <div id="page-search" class="portal-page active">
        <div class="section">
            <div class="section-header">
                <h2>Search Consumers</h2>
            </div>
            <div class="section-body">
                <div class="search-form">
                    <div class="search-row">
                        <div class="search-field">
                            <label>Search By</label>
                            <select id="search-type">
                                <option value="cnsmr_accnt_crdtr_rfrnc_id_txt">Client Account Number</option>
                                <option value="cnsmr_phn_nmbr_txt">Phone Number</option>
                                <option value="cnsmr_idntfr_hshd_ssn_txt">SSN</option>
                                <option value="cnsmr_nm_lst_txt">Consumer Name</option>
                                <option value="cnsmr_idntfr_agncy_id">FA Consumer Number</option>
                                <option value="cnsmr_accnt_idntfr_agncy_id">FA Account Number</option>
                            </select>
                        </div>
                        <div class="search-field search-field-grow">
                            <label>Search Term</label>
                            <input type="text" id="search-term" placeholder="Enter search value..." autocomplete="off">
                        </div>
                        <div class="search-field">
                            <label>Client Filter <span class="field-hint">(optional)</span></label>
                            <div class="client-filter-wrap">
                                <input type="text" id="client-filter" placeholder="Creditor or group name..." autocomplete="off">
                                <span id="client-filter-count" class="filter-count hidden"></span>
                            </div>
                        </div>
                        <div class="search-field search-field-btn">
                            <label>&nbsp;</label>
                            <button id="search-btn" onclick="Portal.doSearch()">Search</button>
                        </div>
                    </div>
                    <p class="search-tip">Tip: Use * for all results, or prefix wildcard (e.g., Smi* for names starting with &quot;Smi&quot;). Client filter accepts any creditor or group short name.</p>
                </div>
            </div>
        </div>
    </div>
    
    <!-- ================================================================ -->
    <!-- RESULTS PAGE                                                     -->
    <!-- ================================================================ -->
    <div id="page-results" class="portal-page">
        <div class="section">
            <div class="section-header">
                <h2>Search Results</h2>
                <div class="section-controls">
                    <span id="results-summary" class="results-summary"></span>
                    <button class="back-btn" onclick="Portal.showSearch()">&#8592; New Search</button>
                </div>
            </div>
            <div class="section-body section-body-table">
                <div id="results-loading" class="loading hidden">Searching...</div>
                <div id="results-table" class="portal-scroll-container"></div>
            </div>
        </div>
    </div>
    
    <!-- ================================================================ -->
    <!-- CONSUMER DETAIL PAGE                                             -->
    <!-- ================================================================ -->
    <div id="page-consumer" class="portal-page">
        <div class="portal-breadcrumb">
            <button class="back-btn" onclick="Portal.showResults()">&#8592; Back to Results</button>
        </div>
        
        <!-- Consumer Header Card -->
        <div class="detail-card" id="consumer-header">
            <div class="detail-card-loading">Loading consumer...</div>
        </div>
        
        <!-- Consumer Tabs -->
        <div class="section">
            <div class="tab-bar">
                <button class="tab-btn active" data-tab="consumer-accounts" onclick="Portal.switchConsumerTab(this)">Accounts</button>
                <button class="tab-btn" data-tab="consumer-demographics" onclick="Portal.switchConsumerTab(this)">Demographics</button>
                <button class="tab-btn" data-tab="consumer-phones" onclick="Portal.switchConsumerTab(this)">Phone Numbers</button>
                <button class="tab-btn" data-tab="consumer-events" onclick="Portal.switchConsumerTab(this)">Events</button>
                <button class="tab-btn" data-tab="consumer-outreach" onclick="Portal.switchConsumerTab(this)">Outreach</button>
            </div>
            <div class="tab-content">
                <div id="consumer-accounts" class="tab-panel active">
                    <div class="loading">Loading accounts...</div>
                </div>
                <div id="consumer-demographics" class="tab-panel">
                    <div class="loading">Loading addresses...</div>
                </div>
                <div id="consumer-phones" class="tab-panel">
                    <div class="loading">Loading phones...</div>
                </div>
                <div id="consumer-events" class="tab-panel">
                    <div class="events-controls">
                        <label class="toggle-label">
                            <span>Show System Notes</span>
                            <button class="toggle-switch" id="consumer-events-toggle" onclick="Portal.toggleConsumerEvents()">
                                <span class="toggle-knob"></span>
                            </button>
                        </label>
                    </div>
                    <div id="consumer-events-list">
                        <div class="loading">Loading events...</div>
                    </div>
                </div>
                <div id="consumer-outreach" class="tab-panel">
                    <div class="loading">Loading documents...</div>
                </div>
            </div>
        </div>
    </div>
    
    <!-- ================================================================ -->
    <!-- ACCOUNT DETAIL PAGE                                              -->
    <!-- ================================================================ -->
    <div id="page-account" class="portal-page">
        <div class="portal-breadcrumb">
            <button class="back-btn" onclick="Portal.backToConsumer()">&#8592; Back to Consumer</button>
        </div>
        
        <!-- Account Header Card -->
        <div class="detail-card" id="account-header">
            <div class="detail-card-loading">Loading account...</div>
        </div>
        
        <!-- Financial Summary Boxes -->
        <div class="financial-summary" id="account-financials">
        </div>
        
        <!-- Account Tabs -->
        <div class="section">
            <div class="tab-bar">
                <button class="tab-btn active" data-tab="account-transactions" onclick="Portal.switchAccountTab(this)">Financial Transactions</button>
                <button class="tab-btn" data-tab="account-events" onclick="Portal.switchAccountTab(this)">Events</button>
                <button class="tab-btn" data-tab="account-outreach" onclick="Portal.switchAccountTab(this)">Outreach</button>
            </div>
            <div class="tab-content">
                <div id="account-transactions" class="tab-panel active">
                    <div class="loading">Loading transactions...</div>
                </div>
                <div id="account-events" class="tab-panel">
                    <div class="events-controls">
                        <label class="toggle-label">
                            <span>Show System Notes</span>
                            <button class="toggle-switch" id="account-events-toggle" onclick="Portal.toggleAccountEvents()">
                                <span class="toggle-knob"></span>
                            </button>
                        </label>
                    </div>
                    <div id="account-events-list">
                        <div class="loading">Loading events...</div>
                    </div>
                </div>
                <div id="account-outreach" class="tab-panel">
                    <div class="loading">Loading documents...</div>
                </div>
            </div>
        </div>
    </div>
    
    <script src="/js/client-portal.js"></script>
</body>
</html>
"@

    Write-PodeHtmlResponse -Value $html
}