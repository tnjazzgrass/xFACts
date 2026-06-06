<#
.SYNOPSIS
    Renders the Client Portal consumer/account lookup Control Center page.

.DESCRIPTION
    Page route for the Client Portal, an internal-staff lookup tool that
    presents a streamlined light-themed window into Debt Manager consumer and
    account data. Emits the page shell, the standard Control Center chrome
    (header bar, refresh info, and banner chrome), and the four page views
    (search, results, consumer detail, account detail) as static containers
    populated client-side. All portal data is loaded via the Client Portal API
    against the crs5_oltp read replica.

.COMPONENT
    Tools.ClientPortal

.NOTES
    File Name : ClientPortal.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\ClientPortal.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this file, most recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-06  Migrated to CC file-format specs. Header converted to CBH block;
#             CHANGELOG moved to a dedicated section. Chrome reshelled to cc-*
#             (cc-header-bar/cc-header-right/cc-refresh-info); body now
#             cc-section-tools with data-cc-page/data-cc-prefix; banner chrome
#             via $bannerHtml; assets switched to cc-shared.css plus the page
#             stylesheet, and the page script tag replaced by the shared
#             cc-shared.js bootloader tag. Page-local ids/classes reprefixed
#             clp-. Inline onclick handlers replaced with data-action-click
#             dispatch. The light-themed portal content area is preserved as
#             page-local clp- classes (a deliberate single-page design, kept
#             page-local per the CSS spec rather than mapped to dark chrome).
#             The lookup-status readout moved from the header into page content.
#             Transitional CCShared import shim added as the first scriptblock
#             statement.
# 2026-05-05  Removed engine-events.css link. The Phase 4 chrome standardization
#             introduced shared rules that overrode the portal's light theme
#             inside the dark shell; reverted to the standalone light form.
# 2026-04-29  Phase 3d of dynamic nav: replaced the hardcoded nav block with the
#             Get-NavBarHtml helper. Page H1, subtitle, and browser tab title
#             render from the nav registry via Get-PageHeaderHtml and
#             Get-PageBrowserTitle.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers GET /client-portal. Performs the page access check, renders the
   chrome shell, and emits the four portal views (search, results, consumer
   detail, account detail) as static containers. All portal data, navigation
   between views, and rendering are handled client-side by the page module.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/client-portal' -Authentication 'ADLogin' -ScriptBlock {
    Import-Module -Name 'E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1' -Force -DisableNameChecking

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/client-portal'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/client-portal') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/client-portal'
    $headerHtml   = Get-PageHeaderHtml   -PageRoute '/client-portal'
    $browserTitle = Get-PageBrowserTitle -PageRoute '/client-portal'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/client-portal.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body class="cc-section-tools" data-cc-page="client-portal" data-cc-prefix="clp">
$navHtml

    <div class="cc-header-bar">
        <div>
            $headerHtml
        </div>
        <div class="cc-header-right">
            <div class="cc-refresh-info">
                <span class="cc-live-indicator"></span>
                <span>Live</span> | Updated: <span id="cc-last-update" class="cc-last-updated">-</span>
                <button class="cc-page-refresh-btn" data-action-click="cc-page-refresh" title="Refresh all data">&#8635;</button>
            </div>
        </div>
    </div>

    $bannerHtml

    <div id="clp-page-search" class="clp-portal-page clp-active">
        <div class="clp-section">
            <div class="clp-section-header">
                <h2 class="clp-section-title">Search Consumers</h2>
                <span id="clp-lookup-status" class="clp-lookup-status">Loading lookups...</span>
            </div>
            <div class="clp-section-body">
                <div class="clp-search-form">
                    <div class="clp-search-row">
                        <div class="clp-search-field">
                            <label class="clp-field-label">Search By</label>
                            <select id="clp-search-type" class="clp-select">
                                <option value="cnsmr_accnt_crdtr_rfrnc_id_txt">Client Account Number</option>
                                <option value="cnsmr_phn_nmbr_txt">Phone Number</option>
                                <option value="cnsmr_idntfr_hshd_ssn_txt">SSN</option>
                                <option value="cnsmr_nm_lst_txt">Consumer Name</option>
                                <option value="cnsmr_idntfr_agncy_id">FA Consumer Number</option>
                                <option value="cnsmr_accnt_idntfr_agncy_id">FA Account Number</option>
                            </select>
                        </div>
                        <div class="clp-search-field clp-search-field-grow">
                            <label class="clp-field-label">Search Term</label>
                            <input type="text" id="clp-search-term" class="clp-input" placeholder="Enter search value..." autocomplete="off" data-action-keydown="clp-search-on-enter">
                        </div>
                        <div class="clp-search-field">
                            <label class="clp-field-label">Client Filter <span class="clp-field-hint">(optional)</span></label>
                            <div class="clp-client-filter-wrap">
                                <input type="text" id="clp-client-filter" class="clp-input" placeholder="Creditor or group name..." autocomplete="off" data-action-input="clp-resolve-client-filter">
                                <span id="clp-client-filter-count" class="clp-filter-count clp-hidden"></span>
                            </div>
                        </div>
                        <div class="clp-search-field clp-search-field-btn">
                            <label class="clp-field-label">&nbsp;</label>
                            <button id="clp-search-btn" class="clp-btn-primary" data-action-click="clp-do-search">Search</button>
                        </div>
                    </div>
                    <p class="clp-search-tip">Tip: Use * for all results, or prefix wildcard (e.g., Smi* for names starting with &quot;Smi&quot;). Client filter accepts any creditor or group short name.</p>
                </div>
            </div>
        </div>
    </div>

    <div id="clp-page-results" class="clp-portal-page">
        <div class="clp-section">
            <div class="clp-section-header">
                <h2 class="clp-section-title">Search Results</h2>
                <div class="clp-section-controls">
                    <span id="clp-results-summary" class="clp-results-summary"></span>
                    <button class="clp-btn-back" data-action-click="clp-show-search">&#8592; New Search</button>
                </div>
            </div>
            <div class="clp-section-body clp-section-body-table">
                <div id="clp-results-loading" class="clp-loading clp-hidden">Searching...</div>
                <div id="clp-results-table" class="clp-scroll-container"></div>
            </div>
        </div>
    </div>

    <div id="clp-page-consumer" class="clp-portal-page">
        <div class="clp-breadcrumb">
            <button class="clp-btn-back" data-action-click="clp-show-results">&#8592; Back to Results</button>
        </div>

        <div class="clp-detail-card" id="clp-consumer-header">
            <div class="clp-detail-card-loading">Loading consumer...</div>
        </div>

        <div class="clp-section">
            <div class="clp-tab-bar">
                <button class="clp-tab-btn clp-active" data-action-click="clp-switch-consumer-tab" data-action-clp-tab="clp-consumer-accounts">Accounts</button>
                <button class="clp-tab-btn" data-action-click="clp-switch-consumer-tab" data-action-clp-tab="clp-consumer-demographics">Demographics</button>
                <button class="clp-tab-btn" data-action-click="clp-switch-consumer-tab" data-action-clp-tab="clp-consumer-phones">Phone Numbers</button>
                <button class="clp-tab-btn" data-action-click="clp-switch-consumer-tab" data-action-clp-tab="clp-consumer-events">Events</button>
                <button class="clp-tab-btn" data-action-click="clp-switch-consumer-tab" data-action-clp-tab="clp-consumer-outreach">Outreach</button>
            </div>
            <div class="clp-tab-content">
                <div id="clp-consumer-accounts" class="clp-tab-panel clp-active">
                    <div class="clp-loading">Loading accounts...</div>
                </div>
                <div id="clp-consumer-demographics" class="clp-tab-panel">
                    <div class="clp-loading">Loading addresses...</div>
                </div>
                <div id="clp-consumer-phones" class="clp-tab-panel">
                    <div class="clp-loading">Loading phones...</div>
                </div>
                <div id="clp-consumer-events" class="clp-tab-panel">
                    <div class="clp-events-controls">
                        <label class="clp-toggle-label">
                            <span>Show System Notes</span>
                            <button class="clp-toggle-switch" id="clp-consumer-events-toggle" data-action-click="clp-toggle-consumer-events">
                                <span class="clp-toggle-knob"></span>
                            </button>
                        </label>
                    </div>
                    <div id="clp-consumer-events-list">
                        <div class="clp-loading">Loading events...</div>
                    </div>
                </div>
                <div id="clp-consumer-outreach" class="clp-tab-panel">
                    <div class="clp-loading">Loading documents...</div>
                </div>
            </div>
        </div>
    </div>

    <div id="clp-page-account" class="clp-portal-page">
        <div class="clp-breadcrumb">
            <button class="clp-btn-back" data-action-click="clp-back-to-consumer">&#8592; Back to Consumer</button>
        </div>

        <div class="clp-detail-card" id="clp-account-header">
            <div class="clp-detail-card-loading">Loading account...</div>
        </div>

        <div class="clp-financial-summary" id="clp-account-financials">
        </div>

        <div class="clp-section">
            <div class="clp-tab-bar">
                <button class="clp-tab-btn clp-active" data-action-click="clp-switch-account-tab" data-action-clp-tab="clp-account-transactions">Financial Transactions</button>
                <button class="clp-tab-btn" data-action-click="clp-switch-account-tab" data-action-clp-tab="clp-account-events">Events</button>
                <button class="clp-tab-btn" data-action-click="clp-switch-account-tab" data-action-clp-tab="clp-account-outreach">Outreach</button>
            </div>
            <div class="clp-tab-content">
                <div id="clp-account-transactions" class="clp-tab-panel clp-active">
                    <div class="clp-loading">Loading transactions...</div>
                </div>
                <div id="clp-account-events" class="clp-tab-panel">
                    <div class="clp-events-controls">
                        <label class="clp-toggle-label">
                            <span>Show System Notes</span>
                            <button class="clp-toggle-switch" id="clp-account-events-toggle" data-action-click="clp-toggle-account-events">
                                <span class="clp-toggle-knob"></span>
                            </button>
                        </label>
                    </div>
                    <div id="clp-account-events-list">
                        <div class="clp-loading">Loading events...</div>
                    </div>
                </div>
                <div id="clp-account-outreach" class="clp-tab-panel">
                    <div class="clp-loading">Loading documents...</div>
                </div>
            </div>
        </div>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@
    Write-PodeHtmlResponse -Value $html
}