# ============================================================================
# xFACts Control Center - Client Portal Page
# Location: E:\xFACts-ControlCenter\scripts\routes\ClientPortal.ps1
#
# Consumer/account lookup tool for internal FA staff. Provides search,
# consumer detail (5 tabs), and account detail (3 tabs) against crs5_oltp.
# Accessible via gateway cards on departmental pages — no main nav entry.
#
# CSS: /css/client-portal.css, /css/engine-events.css
# JS:  /js/client-portal.js
# APIs: ClientPortal-API.ps1
#
# Version: Tracked in dbo.System_Metadata (component: Tools.Operations)
#
# CHANGELOG
# ---------
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page H1, subtitle, and browser tab title
#             now render from RBAC_NavRegistry via Get-PageHeaderHtml and
#             Get-PageBrowserTitle. Dropped the $access.IsDeptOnly branching
#             since Get-NavBarHtml already filters nav items by user
#             permissions. Added engine-events.css link to the head — the
#             dynamic nav now relies on the shared CSS for nav-bar/nav-link
#             styling, which this page previously did not load.
# ============================================================================

Add-PodeRoute -Method Get -Path '/client-portal' -Authentication 'ADLogin' -ScriptBlock {

    # --- RBAC Access Check ---
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/client-portal'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/client-portal') -StatusCode 403
        return
    }

    # --- User context (used by helper for nav rendering) ---
    $ctx = Get-UserContext -WebEvent $WebEvent

    # --- Render dynamic nav bar and page header from RBAC_NavRegistry ---
    $navHtml      = Get-NavBarHtml      -UserContext $ctx -CurrentPageRoute '/client-portal'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/client-portal'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/client-portal'

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>
    <link rel="stylesheet" href="/css/client-portal.css">
    <link rel="stylesheet" href="/css/engine-events.css">
</head>
<body>
$navHtml

    <div class="header-bar">
        <div>
            $headerHtml
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