// ============================================================================
// xFACts Control Center - Engine Events (Shared Module)
// Location: E:\xFACts-ControlCenter\public\js\engine-events.js
// Version: 1.1.0
//
// Central WebSocket handler for real-time orchestrator engine indicators.
// Loaded by all pages with engine cards. Each page defines its own
// ENGINE_PROCESSES map before this script initializes.
//
// Page setup:
//   1. Define ENGINE_PROCESSES before loading this script:
//      var ENGINE_PROCESSES = {
//          'Monitor-JobFlow': { slug: 'jobflow' }
//      };
//
//      slug: used for DOM element ID resolution (engine-bar-{slug}, etc.)
//      Countdown intervals are provided by the orchestrator via WebSocket
//      event payload — no hardcoded values needed.
//   2. HTML cards use suffixed IDs for multi-process pages:
//      id="card-engine-{slug}"  id="engine-bar-{slug}"  id="engine-cd-{slug}"
//      Or bare IDs for single-process pages (auto-detected):
//      id="card-engine"  id="engine-bar"  id="engine-cd"
//
//   3. Load this script after page JS: <script src="/js/engine-events.js"></script>
//
//   4. Call connectEngineEvents() from your DOMContentLoaded handler.
//
// Page hooks (all optional — define in your page's JS to opt in):
//   onPageRefresh()              — manual refresh button click handler
//   onPageResumed()              — tab regained visibility, refresh data
//   onSessionExpired()           — stop page-specific polling timers
//   onEngineProcessCompleted()   — orchestrator process finished, refresh
//   onEngineEventRaw()           — every event before filtering (Admin only)
//
// Shared utilities exposed to pages:
//   escapeHtml(str)              — DOM-safe HTML escaping
//   formatTimeOfDay(val)         — render any timestamp value as locale time
//   MONTH_NAMES                  — array, 1-indexed (use month_num directly)
//   DAY_NAMES                    — 3-letter day-of-week array, 0=Sunday
//   safeInt(val)                 — null-safe parseInt, returns 0 on bad input
//   safeFloat(val)               — null-safe parseFloat, returns 0 on bad input
//   formatTimeSince(seconds)     — "Xs/Xm/Xh Xm/Xd Xh" elapsed formatter
//   formatAge(minutes)           — "Xm/Xh Xm/Xd Xh" age formatter
//   showAlert(msg, opts)         — Promise-returning native-alert replacement
//   showConfirm(msg, opts)       — Promise-returning native-confirm replacement
//   engineFetch(url, options)    — visibility/session-aware fetch wrapper
//   pageRefresh()                — manual refresh handler (calls onPageRefresh)
// ============================================================================

// ============================================================================
// SHARED CONSTANTS
// ============================================================================

// Month names array, 1-indexed so month numbers from SQL/JS Date map directly:
//   MONTH_NAMES[1]  -> 'January'
//   MONTH_NAMES[12] -> 'December'
// The empty string at index 0 is intentional padding so callers don't need
// to subtract 1 from month numbers (which is error-prone and easy to forget).
var MONTH_NAMES = ['', 'January', 'February', 'March', 'April', 'May', 'June',
                   'July', 'August', 'September', 'October', 'November', 'December'];

// Day-of-week names, 3-letter form. 1-indexed to match SQL DATEPART(dw, ...)
// and the day_of_week column on schedule tables:
//   DAY_NAMES[1] -> 'Sun'
//   DAY_NAMES[7] -> 'Sat'
var DAY_NAMES = { 1: 'Sun', 2: 'Mon', 3: 'Tue', 4: 'Wed', 5: 'Thu', 6: 'Fri', 7: 'Sat' };

// Default day-of-week display order, Sun-Sat. Pages can override locally if needed.
var DAY_ORDER = [1, 2, 3, 4, 5, 6, 7];

// ============================================================================
// STATE
// ============================================================================

var engineWs = null;
var engineReconnectTimer = null;
var engineTickTimer = null;
var engineState = {};           // Per-slug state: { lastEvent, countdown, lastRefresh }
var ENGINE_GRACE_SEC = 30;
var ENGINE_RECONNECT_SEC = 3;
var ENGINE_TICK_MS = 1000;
var engineConnected = false;
var enginePopupVisible = false;

// Page Visibility — pause polling when tab is hidden
var enginePageHidden = false;

// Reconnection grace period — friendly UX during server restarts
var engineReconnectGraceSec = 60;      // Default; overridden by GlobalConfig on load
var engineReconnectStart = null;        // Timestamp when reconnecting state began
var engineConnectionState = 'connected'; // connected | reconnecting | disconnected | expired
var engineReconnectCheckTimer = null;

// Auth failure detection
var engineSessionExpired = false;

// Idle detection — pause polling after inactivity
var engineIdleTimeoutSec = 300;        // Default 5 minutes; overridden by GlobalConfig
var engineLastActivity = Date.now();    // Timestamp of last user interaction
var engineIdlePaused = false;           // Whether polling is paused due to inactivity
var engineIdleCheckTimer = null;

// ============================================================================
// INITIALIZATION
// ============================================================================

/**
 * Main entry point — call from page's DOMContentLoaded.
 * Connects WebSocket, loads initial state, starts countdown ticker.
 */
function connectEngineEvents() {
    if (typeof ENGINE_PROCESSES === 'undefined' || !ENGINE_PROCESSES) {
        console.warn('ENGINE_PROCESSES not defined — engine events disabled');
        return;
    }

    // Initialize state for each process
    Object.keys(ENGINE_PROCESSES).forEach(function(procName) {
        var slug = ENGINE_PROCESSES[procName].slug;
        engineState[slug] = {
            lastEvent: null,
            countdown: null,
            lastRefresh: null
        };
    });

    // Load reconnect grace period from GlobalConfig
    loadReconnectGraceConfig();

    // Load bootstrap state, then connect WebSocket
    loadEngineBootstrap().then(function() {
        openEngineWebSocket();
    });

    // Start 1-second countdown ticker
    engineTickTimer = setInterval(tickAllEngineIndicators, ENGINE_TICK_MS);

    // Page Visibility — pause/resume polling when tab is hidden/shown
    document.addEventListener('visibilitychange', function() {
        if (document.visibilityState === 'hidden') {
            enginePageHidden = true;
            // Stop WebSocket reconnect attempts while hidden
            if (engineReconnectTimer) {
                clearTimeout(engineReconnectTimer);
                engineReconnectTimer = null;
            }
        } else {
            enginePageHidden = false;
            if (engineSessionExpired) return; // Don't resume if session is dead

            // Reconnect WebSocket if needed
            if (!engineConnected && engineWs &&
                engineWs.readyState !== WebSocket.OPEN &&
                engineWs.readyState !== WebSocket.CONNECTING) {
                openEngineWebSocket();
            }

            // Notify page to do an immediate data refresh
            if (typeof onPageResumed === 'function') {
                try { onPageResumed(); } catch (e) {
                    console.error('[engine-events] onPageResumed error:', e);
                }
            }
        }
    });

    // Idle detection — pause polling after inactivity, resume on interaction
    loadIdleTimeoutConfig();
    engineLastActivity = Date.now();

    ['mousemove', 'mousedown', 'keydown', 'touchstart', 'scroll'].forEach(function(evt) {
        document.addEventListener(evt, onUserActivity, { passive: true });
    });

    engineIdleCheckTimer = setInterval(checkIdleTimeout, 10000); // Check every 10 seconds

    // Close popup on Escape key
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape' && enginePopupVisible) {
            closeEnginePopup();
        }
    });

    // Close popup on click outside
    document.addEventListener('click', function(e) {
        if (enginePopupVisible && !e.target.closest('.engine-popup') && !e.target.closest('.engine-card')) {
            closeEnginePopup();
        }
    });
}

// ============================================================================
// BOOTSTRAP (Initial State Load)
// ============================================================================

/**
 * Loads current engine state from REST endpoint on page load / reconnect.
 * Provides immediate card state without waiting for next push event.
 */
function loadEngineBootstrap() {
    return fetch('/api/engine/state')
        .then(function(response) {
            if (!response.ok) throw new Error('Bootstrap failed: ' + response.status);
            return response.json();
        })
        .then(function(state) {
            var now = Date.now();

            Object.keys(ENGINE_PROCESSES).forEach(function(procName) {
                var slug = ENGINE_PROCESSES[procName].slug;
                var event = state[procName];

                if (event) {
                    engineState[slug].lastEvent = event;
                    engineState[slug].lastRefresh = now;

                    // Calculate initial countdown from event scheduling metadata
                    if (event.eventType === 'PROCESS_COMPLETED' && event.timestamp) {
                        engineState[slug].countdown = calcCountdownFromEvent(event, now);
                    }
                }

                tickEngineIndicator(slug);
            });
        })
        .catch(function(e) {
            // Bootstrap failure is non-fatal — cards stay gray until first push event
            console.warn('Engine bootstrap:', e.message);
        });
}

// ============================================================================
// WEBSOCKET CONNECTION
// ============================================================================

function openEngineWebSocket() {
    if (engineWs && (engineWs.readyState === WebSocket.OPEN || engineWs.readyState === WebSocket.CONNECTING)) {
        return;
    }

    var protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    engineWs = new WebSocket(protocol + '//' + window.location.host + '/engine-events');

    engineWs.onopen = function() {
        var wasReconnecting = (engineConnectionState === 'reconnecting');
        engineConnected = true;
        engineConnectionState = 'connected';
        engineReconnectStart = null;

        if (engineReconnectCheckTimer) {
            clearInterval(engineReconnectCheckTimer);
            engineReconnectCheckTimer = null;
        }

        updateEngineConnectionIndicator(true);
        updateConnectionBanner();

        if (wasReconnecting) {
            // Server came back after a restart — show brief message then reload
            // to pick up any newly deployed files
            showReloadingBanner();
            setTimeout(function() { window.location.reload(); }, 1500);
            return;
        }

        console.log('[engine-events] WebSocket connected');
    };

    engineWs.onmessage = function(evt) {
        var event;
        try {
            event = JSON.parse(evt.data);
        } catch (e) {
            console.warn('[engine-events] Unparseable message:', evt.data);
            return;
        }

        handleEngineEvent(event);
    };

    engineWs.onclose = function() {
        engineConnected = false;
        updateEngineConnectionIndicator(false);

        // Don't reconnect if session is expired or page is hidden
        if (engineSessionExpired) return;
        if (enginePageHidden) return;

        // Enter reconnecting state if not already
        if (engineConnectionState === 'connected') {
            engineConnectionState = 'reconnecting';
            engineReconnectStart = Date.now();
            updateConnectionBanner();

            // Start checking grace period expiry
            if (!engineReconnectCheckTimer) {
                engineReconnectCheckTimer = setInterval(checkReconnectGrace, 1000);
            }
        }

        console.log('[engine-events] WebSocket closed, reconnecting in ' + ENGINE_RECONNECT_SEC + 's...');

        if (engineReconnectTimer) clearTimeout(engineReconnectTimer);
        engineReconnectTimer = setTimeout(function() {
            openEngineWebSocket();
        }, ENGINE_RECONNECT_SEC * 1000);
    };

    engineWs.onerror = function() {
        // onclose will fire after onerror — reconnect handled there
        engineConnected = false;
        updateEngineConnectionIndicator(false);
    };
}

// ============================================================================
// EVENT HANDLING
// ============================================================================

function handleEngineEvent(event) {
    // Raw event hook — delivers every event to the page before filtering.
    // Used by the Admin page to drive the process timeline from WebSocket
    // events instead of polling. Most pages don't define this function.
    if (typeof onEngineEventRaw === 'function') {
        try { onEngineEventRaw(event); } catch (e) {
            console.error('[engine-events] onEngineEventRaw error:', e);
        }
    }

    // Find which process this event belongs to
    var procConfig = ENGINE_PROCESSES[event.processName];
    if (!procConfig) return;  // Not a process this page cares about

    var slug = procConfig.slug;
    var now = Date.now();

    engineState[slug].lastEvent = event;
    engineState[slug].lastRefresh = now;

    if (event.eventType === 'PROCESS_STARTED') {
        // Clear countdown — process is actively running
        engineState[slug].countdown = null;
    }
    else if (event.eventType === 'PROCESS_COMPLETED') {
        // Calculate countdown from live scheduling metadata
        engineState[slug].countdown = calcCountdownFromEvent(event, Date.now());

        // Notify page of completion — allows event-driven data refresh
        if (typeof onEngineProcessCompleted === 'function') {
            try {
                onEngineProcessCompleted(event.processName, event);
            } catch (e) {
                console.error('[engine-events] onEngineProcessCompleted error:', e);
            }
        }
    }

    // Immediate visual update
    tickEngineIndicator(slug);
}

// ============================================================================
// COUNTDOWN CALCULATION
// ============================================================================

/**
 * Calculates the countdown value (in seconds) based on the process scheduling
 * metadata carried in the PROCESS_COMPLETED event.
 *
 * Pattern 1 (interval-only): scheduledTime empty → countdown = intervalSeconds
 * Pattern 2 (once-daily):    scheduledTime set, intervalSeconds=0 → countdown to scheduledTime tomorrow
 * Pattern 3 (time+interval): scheduledTime set, intervalSeconds>0 → intervalSeconds while polling,
 *                            countdown to scheduledTime tomorrow after today's success
 *
 * @param {Object} event - PROCESS_COMPLETED event with intervalSeconds, scheduledTime, runMode, status
 * @param {number} now - Current time in ms (Date.now())
 * @returns {number|null} Countdown in seconds, or null if no countdown applies
 */
function calcCountdownFromEvent(event, now) {
    var intervalSec = event.intervalSeconds || 0;
    var schedTime = event.scheduledTime || '';
    var runMode = event.runMode != null ? event.runMode : 1;

    // Queue-driven (run_mode=2) or disabled (run_mode=0): no countdown
    if (runMode !== 1) return null;

    // Calculate elapsed time since the event
    var elapsed = 0;
    if (event.timestamp) {
        elapsed = Math.floor((now - new Date(event.timestamp).getTime()) / 1000);
        if (elapsed < 0) elapsed = 0;
    }

    // Pattern 1: interval-only (no scheduled_time)
    if (!schedTime) {
        return intervalSec > 0 ? intervalSec - elapsed : null;
    }

    // Has scheduled_time — Pattern 2 or 3
    // Pattern 3 check: if intervalSeconds > 0 and process did NOT succeed,
    // it's still actively polling → use interval countdown
    if (intervalSec > 0 && event.status !== 'SUCCESS') {
        return intervalSec - elapsed;
    }

    // Pattern 2, or Pattern 3 after today's success:
    // Countdown to scheduledTime tomorrow (already relative to now)
    return calcSecondsUntilTomorrow(schedTime, now);
}

/**
 * Calculates seconds from now until the next occurrence of a given HH:mm:ss time.
 * If the time hasn't passed yet today, targets today. Otherwise targets tomorrow.
 * @param {string} timeStr - Time in "HH:mm:ss" format
 * @param {number} now - Current time in ms (Date.now())
 * @returns {number} Seconds until the next occurrence of that time
 */
function calcSecondsUntilTomorrow(timeStr, now) {
    var parts = timeStr.split(':');
    var h = parseInt(parts[0], 10) || 0;
    var m = parseInt(parts[1], 10) || 0;
    var s = parseInt(parts[2], 10) || 0;

    var today = new Date(now);
    var target = new Date(today);
    target.setHours(h, m, s, 0);

    // If the target time has already passed today, aim for tomorrow
    if (target.getTime() <= now) {
        target.setDate(target.getDate() + 1);
    }

    return Math.floor((target.getTime() - now) / 1000);
}

// ============================================================================
// COUNTDOWN TICKER
// ============================================================================

function tickAllEngineIndicators() {
    Object.keys(ENGINE_PROCESSES).forEach(function(procName) {
        var slug = ENGINE_PROCESSES[procName].slug;

        // Decrement countdown by 1 second each tick
        if (engineState[slug].countdown !== null) {
            engineState[slug].countdown -= 1;
        }

        tickEngineIndicator(slug);
    });
}

function tickEngineIndicator(slug) {
    var els = getEngineElements(slug);
    if (!els.bar) return;

    var state = engineState[slug];
    var event = state ? state.lastEvent : null;

    // ── No data yet: waiting state ──
    if (!event) {
        els.bar.className = 'engine-bar disabled';
        if (els.card) els.card.className = 'engine-card';
        if (els.cd) { els.cd.textContent = ''; els.cd.innerHTML = '&nbsp;'; }
        return;
    }

    // ── STARTED: process is running ──
    if (event.eventType === 'PROCESS_STARTED') {
        els.bar.className = 'engine-bar running';
        if (els.card) els.card.className = 'engine-card';
        if (els.cd) els.cd.textContent = 'RUNNING';
        return;
    }

    // ── COMPLETED: show countdown or escalation ──
    var lastFailed = (event.status === 'FAILED' || event.status === 'TIMEOUT');
    var countdown = state.countdown;

    // Determine effective interval for overdue threshold calculation.
    // For interval-based processes, use intervalSeconds directly.
    // For once-daily processes, use a fixed 10-minute grace window
    // (the orchestrator's 5-minute launch window plus margin).
    var effectiveInterval = event.intervalSeconds || 0;
    if (event.scheduledTime && (!effectiveInterval || effectiveInterval === 0)) {
        effectiveInterval = 600;
    }

    var cdText = '';
    var overdue = false;
    var critical = false;

    if (countdown !== null) {
        if (countdown > 0) {
            // Counting down to next execution
            cdText = fmtEngineCountdown(countdown);
        } else if (countdown >= -ENGINE_GRACE_SEC) {
            // Grace period -- count up, stay green (no overdue escalation)
            cdText = '+' + fmtEngineCountdown(Math.abs(countdown));
        } else {
            // Overdue -- past grace period
            cdText = '+' + fmtEngineCountdown(Math.abs(countdown));
            overdue = true;
            if (effectiveInterval > 0 && countdown < -(effectiveInterval * 2)) {
                critical = true;
            }
        }
    }

    // Determine bar and card classes
    var barCls, cardCls = 'engine-card';
    if (lastFailed || critical) {
        barCls = 'engine-bar critical';
        cardCls = 'engine-card card-critical';
    } else if (overdue) {
        barCls = 'engine-bar overdue';
        cardCls = 'engine-card card-warning';
    } else {
        barCls = 'engine-bar idle';
    }

    els.bar.className = barCls;
    if (els.card) els.card.className = cardCls;
    if (els.cd) {
        els.cd.textContent = cdText || '';
        if (!cdText) els.cd.innerHTML = '&nbsp;';
        els.cd.className = (overdue || critical) ? 'engine-countdown cd-overdue' : 'engine-countdown';
    }
}

// ============================================================================
// DOM ELEMENT RESOLUTION
// ============================================================================

/**
 * Finds engine card DOM elements by slug.
 * Multi-process pages: IDs have slug suffix (engine-bar-nb, card-engine-nb)
 * Single-process pages: bare IDs (engine-bar, card-engine) — auto-detected
 */
function getEngineElements(slug) {
    // Try suffixed first (multi-process pattern)
    var bar = document.getElementById('engine-bar-' + slug);
    var card = document.getElementById('card-engine-' + slug);
    var cd = document.getElementById('engine-cd-' + slug);

    // Fall back to bare IDs (single-process pattern)
    if (!bar) {
        bar = document.getElementById('engine-bar');
        card = document.getElementById('card-engine');
        cd = document.getElementById('engine-cd');
    }

    return { bar: bar, card: card, cd: cd };
}

// ============================================================================
// CONNECTION INDICATOR
// ============================================================================

/**
 * Subtle visual indicator on the engine-row when WebSocket is disconnected.
 * Adds/removes a 'ws-disconnected' class that pages can style.
 */
function updateEngineConnectionIndicator(connected) {
    var rows = document.querySelectorAll('.engine-row');
    rows.forEach(function(row) {
        if (connected) {
            row.classList.remove('ws-disconnected');
        } else {
            row.classList.add('ws-disconnected');
        }
    });
}

// ============================================================================
// LAST EXECUTION POPUP
// ============================================================================

/**
 * Shows a popup with last execution details when an engine card is clicked.
 * Call this from card click handlers or set up automatically.
 */
function initEngineCardClicks() {
    Object.keys(ENGINE_PROCESSES).forEach(function(procName) {
        var slug = ENGINE_PROCESSES[procName].slug;
        var els = getEngineElements(slug);
        if (els.card) {
            els.card.style.cursor = 'pointer';
            els.card.addEventListener('click', function(e) {
                e.stopPropagation();
                showEnginePopup(slug, procName, els.card);
            });
        }
    });
}

function showEnginePopup(slug, procName, anchorEl) {
    closeEnginePopup();

    var state = engineState[slug];
    var event = state ? state.lastEvent : null;

    if (!event) return;

    var popup = document.createElement('div');
    popup.className = 'engine-popup';
    popup.id = 'engine-popup';

    var statusColor = '#4ec9b0';
    var statusText = event.status || event.eventType;
    if (event.eventType === 'PROCESS_STARTED') {
        statusColor = '#569cd6';
        statusText = 'RUNNING';
    } else if (event.status === 'FAILED' || event.status === 'TIMEOUT') {
        statusColor = '#f48771';
    }

    var durationText = event.durationMs != null
        ? (event.durationMs / 1000).toFixed(1) + 's'
        : '-';

    var timeText = event.timestamp
        ? new Date(event.timestamp).toLocaleTimeString()
        : '-';

    var html = '' +
        '<div class="engine-popup-header">' +
            '<span class="engine-popup-title">' + procName + '</span>' +
            '<span class="engine-popup-close" onclick="closeEnginePopup()">&times;</span>' +
        '</div>' +
        '<div class="engine-popup-row">' +
            '<span class="engine-popup-label">Module</span>' +
            '<span class="engine-popup-value">' + (event.moduleName || '-') + '</span>' +
        '</div>' +
        '<div class="engine-popup-row">' +
            '<span class="engine-popup-label">Last Run</span>' +
            '<span class="engine-popup-value">' + timeText + '</span>' +
        '</div>' +
        '<div class="engine-popup-row">' +
            '<span class="engine-popup-label">Duration</span>' +
            '<span class="engine-popup-value">' + durationText + '</span>' +
        '</div>' +
        '<div class="engine-popup-row">' +
            '<span class="engine-popup-label">Status</span>' +
            '<span class="engine-popup-value" style="color:' + statusColor + ';font-weight:600">' + statusText + '</span>' +
        '</div>';

    if (event.exitCode != null) {
        html += '' +
        '<div class="engine-popup-row">' +
            '<span class="engine-popup-label">Exit Code</span>' +
            '<span class="engine-popup-value">' + event.exitCode + '</span>' +
        '</div>';
    }

    if (event.outputSummary) {
        html += '' +
        '<div class="engine-popup-output">' +
            '<div class="engine-popup-label">Output</div>' +
            '<pre class="engine-popup-pre">' + escapeHtml(event.outputSummary) + '</pre>' +
        '</div>';
    }

    if (event.taskId) {
        html += '' +
        '<div class="engine-popup-footer">Task #' + event.taskId + '</div>';
    }

    popup.innerHTML = html;

    // Position near the card
    var rect = anchorEl.getBoundingClientRect();
    popup.style.position = 'fixed';
    popup.style.top = (rect.bottom + 6) + 'px';
    popup.style.right = (window.innerWidth - rect.right) + 'px';
    popup.style.zIndex = '9999';

    document.body.appendChild(popup);
    enginePopupVisible = true;
}

function closeEnginePopup() {
    var existing = document.getElementById('engine-popup');
    if (existing) existing.remove();
    enginePopupVisible = false;
}

// ============================================================================
// SHARED UTILITIES (cross-page)
// ============================================================================

/**
 * DOM-safe HTML escaping. Returns the escaped form of any value, safe to
 * insert into innerHTML without enabling XSS.
 *
 * Public utility — pages should NOT define their own escapeHtml(); use this
 * one. Handles null/undefined by returning empty string.
 *
 * @param {*} val - any value (string preferred, others coerced via String())
 * @returns {string} HTML-safe string
 */
function escapeHtml(val) {
    if (val == null) return '';
    var div = document.createElement('div');
    div.textContent = String(val);
    return div.innerHTML;
}

/**
 * Renders a timestamp value as a locale time string. Accepts:
 *   - ISO 8601 strings: "2026-04-30T18:50:09Z"
 *   - .NET /Date(ms)/ format: "/Date(1714501809000)/"
 *   - Date objects
 *   - null/undefined (returns '-')
 *   - Unparseable values (returns '-')
 *
 * Output format: "1:23 PM" (locale-dependent)
 *
 * Public utility — pages should use this instead of defining their own
 * formatTime() variants. The function tolerates the assortment of timestamp
 * shapes that come back from different APIs across the platform.
 *
 * @param {*} val - timestamp in any supported form
 * @returns {string} formatted time of day, or '-' if unparseable
 */
function formatTimeOfDay(val) {
    if (!val) return '-';

    var d;
    if (val instanceof Date) {
        d = val;
    } else {
        var s = String(val);
        // .NET /Date(ms)/ format
        var match = s.match(/\/Date\((\d+)\)\//);
        if (match) {
            d = new Date(parseInt(match[1], 10));
        } else {
            d = new Date(s);
        }
    }

    if (!d || isNaN(d.getTime())) return '-';

    return d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true });
}

/**
 * Null-safe parseInt. Returns 0 for null/undefined/empty/NaN/'DBNull'.
 * Useful for displaying SQL Server numeric columns that may come back as
 * any of those values when the underlying data is missing.
 *
 * @param {*} val - any value
 * @returns {number} integer, or 0 on bad input
 */
function safeInt(val) {
    if (val == null || val === '' || val === 'DBNull') return 0;
    var n = parseInt(val, 10);
    return isNaN(n) ? 0 : n;
}

/**
 * Null-safe parseFloat. Returns 0 for null/undefined/empty/NaN/'DBNull'.
 * Companion to safeInt; same rationale.
 *
 * @param {*} val - any value
 * @returns {number} float, or 0 on bad input
 */
function safeFloat(val) {
    if (val == null || val === '' || val === 'DBNull') return 0;
    var n = parseFloat(val);
    return isNaN(n) ? 0 : n;
}

/**
 * Formats a duration in seconds as a human-readable elapsed string.
 *   <60s     -> "Xs"
 *   <60m     -> "Xm"
 *   <24h     -> "Xh Xm"
 *   >=1d     -> "Xd Xh"
 *
 * Public utility — used wherever "time since" is displayed, e.g.,
 * "last run X ago" indicators on collector status cards.
 *
 * @param {number} seconds - elapsed seconds
 * @returns {string} formatted string
 */
function formatTimeSince(seconds) {
    var s = safeInt(seconds);
    if (s < 60) return s + 's';
    var m = Math.floor(s / 60);
    if (m < 60) return m + 'm';
    var h = Math.floor(m / 60);
    m = m % 60;
    if (h < 24) return h + 'h ' + m + 'm';
    var d = Math.floor(h / 24);
    h = h % 24;
    return d + 'd ' + h + 'h';
}

/**
 * Formats a duration in minutes as a human-readable age string.
 *   <60m     -> "Xm"
 *   <24h     -> "Xh Xm"
 *   >=1d     -> "Xd Xh"
 *
 * Companion to formatTimeSince but takes minutes instead of seconds.
 * Used wherever batch/record age is displayed.
 *
 * @param {number} minutes - elapsed minutes
 * @returns {string} formatted string
 */
function formatAge(minutes) {
    var m = safeInt(minutes);
    if (m < 60) return m + 'm';
    var h = Math.floor(m / 60);
    m = m % 60;
    if (h < 24) return h + 'h ' + m + 'm';
    var d = Math.floor(h / 24);
    h = h % 24;
    return d + 'd ' + h + 'h';
}

// ============================================================================
// FORMATTING (engine-specific)
// ============================================================================

function fmtEngineCountdown(s) {
    var a = Math.abs(Math.floor(s));
    var m = Math.floor(a / 60);
    var sec = a % 60;
    if (m > 60) {
        var h = Math.floor(m / 60);
        return h + 'h ' + (m % 60) + 'm';
    }
    return m + ':' + (sec < 10 ? '0' : '') + sec;
}

// ============================================================================
// RECONNECTION GRACE PERIOD
// ============================================================================

/**
 * Checks whether the reconnection grace period has expired.
 * Called every 1 second while in 'reconnecting' state.
 */
function checkReconnectGrace() {
    if (engineConnectionState !== 'reconnecting') {
        if (engineReconnectCheckTimer) {
            clearInterval(engineReconnectCheckTimer);
            engineReconnectCheckTimer = null;
        }
        return;
    }

    var elapsed = (Date.now() - engineReconnectStart) / 1000;
    if (elapsed >= engineReconnectGraceSec) {
        engineConnectionState = 'disconnected';
        if (engineReconnectCheckTimer) {
            clearInterval(engineReconnectCheckTimer);
            engineReconnectCheckTimer = null;
        }
        updateConnectionBanner();
    }
}

/**
 * Loads the reconnect grace period from GlobalConfig.
 * Reuses the refresh-interval API which looks up ControlCenter | refresh_{page}_seconds.
 * Setting name: ControlCenter | reconnect_grace_seconds (loaded directly, not via the
 * refresh_* pattern — uses a dedicated fetch).
 * Non-blocking — uses default if unavailable.
 */
function loadReconnectGraceConfig() {
    fetch('/api/config/refresh-interval?page=reconnect_grace')
        .then(function(r) { return r.ok ? r.json() : null; })
        .then(function(data) {
            if (data && data.interval && !data.default) {
                engineReconnectGraceSec = data.interval;
            }
        })
        .catch(function() { /* use default */ });
}

// ============================================================================
// CONNECTION BANNER
// ============================================================================

/**
 * Manages the connection status banner that replaces the old red error banner
 * during server restarts and session expiry.
 *
 * States:
 *   connected    — banner hidden
 *   reconnecting — blue "Reconnecting..." banner (non-alarming)
 *   disconnected — red "Connection lost" banner (grace period expired)
 *   expired      — amber "Session expired" banner with sign-in link
 */
function updateConnectionBanner() {
    var el = document.getElementById('connection-banner');
    if (!el) return;

    if (engineSessionExpired) {
        el.className = 'connection-banner session-expired';
        el.innerHTML = 'Session expired \u2014 <a href="/login" class="banner-link">Sign In</a>';
        el.style.display = 'block';
        return;
    }

    switch (engineConnectionState) {
        case 'reconnecting':
            el.className = 'connection-banner reconnecting';
            el.textContent = 'Reconnecting to server\u2026';
            el.style.display = 'block';
            break;
        case 'disconnected':
            el.className = 'connection-banner disconnected';
            el.textContent = 'Connection lost \u2014 server may be unavailable';
            el.style.display = 'block';
            break;
        default:
            el.className = 'connection-banner';
            el.textContent = '';
            el.style.display = 'none';
    }
}

/**
 * Shows a brief "Reconnected" message before auto-reloading.
 */
function showReloadingBanner() {
    var el = document.getElementById('connection-banner');
    if (!el) return;
    el.className = 'connection-banner reloading';
    el.textContent = 'Server reconnected \u2014 reloading\u2026';
    el.style.display = 'block';
}

// ============================================================================
// SHARED FETCH WRAPPER — engineFetch()
// ============================================================================

/**
 * Shared fetch wrapper for all Control Center API calls.
 * Handles:
 *   - Page visibility: skips fetch when tab is hidden (returns null)
 *   - Session expiry: detects 302 redirect to login or HTML response,
 *     stops all polling, shows session-expired banner
 *   - JSON parsing: returns parsed data directly
 *   - Error propagation: throws on network/server errors for caller catch blocks
 *
 * Usage (replaces raw fetch):
 *   // Before:
 *   var response = await fetch('/api/endpoint');
 *   var data = await response.json();
 *
 *   // After:
 *   var data = await engineFetch('/api/endpoint');
 *   if (!data) return;  // hidden tab or session expired
 *
 * For POST requests:
 *   var data = await engineFetch('/api/endpoint', {
 *       method: 'POST',
 *       headers: { 'Content-Type': 'application/json' },
 *       body: JSON.stringify(payload)
 *   });
 */
async function engineFetch(url, options) {
    // Skip if tab is hidden (polling calls are wasted effort)
    if (enginePageHidden) return null;

    // Skip if session is already known to be expired
    if (engineSessionExpired) return null;

    // Skip if idle-paused
    if (engineIdlePaused) return null;

    var response;
    try {
        response = await fetch(url, options);
    } catch (err) {
        // Network error — server probably down
        throw err;
    }

    // Detect auth redirect: Pode returns 302 to /login, but fetch follows
    // redirects automatically, so we get a 200 with HTML content from /login.
    // Check if we got redirected to the login page.
    if (response.redirected && response.url && response.url.indexOf('/login') !== -1) {
        handleSessionExpired();
        return null;
    }

    // Also check content-type — if we asked for JSON but got HTML, session is gone
    var contentType = response.headers.get('content-type') || '';
    if (!contentType.includes('application/json') && response.ok) {
        // Got a 200 but with HTML — likely the login page served after redirect
        var bodySnippet = await response.text();
        if (bodySnippet.indexOf('Sign in with your network credentials') !== -1 ||
            bodySnippet.indexOf('<title>Login') !== -1) {
            handleSessionExpired();
            return null;
        }
        // Not login page — might be a legitimate non-JSON response
        throw new Error('Unexpected response type: ' + contentType);
    }

    if (!response.ok) {
        var errBody;
        try { errBody = await response.json(); } catch (e) { errBody = null; }
        var errMsg = (errBody && errBody.Error) ? errBody.Error : 'HTTP ' + response.status;
        throw new Error(errMsg);
    }

    return await response.json();
}

/**
 * Handles session expiry: stops all polling, shows sign-in banner.
 */
function handleSessionExpired() {
    if (engineSessionExpired) return; // Already handled
    engineSessionExpired = true;

    // Stop WebSocket reconnect
    if (engineReconnectTimer) {
        clearTimeout(engineReconnectTimer);
        engineReconnectTimer = null;
    }

    // Close WebSocket
    if (engineWs) {
        try { engineWs.close(); } catch (e) { /* ignore */ }
    }

    // Stop engine tick timer
    if (engineTickTimer) {
        clearInterval(engineTickTimer);
        engineTickTimer = null;
    }

    // Stop reconnect grace check
    if (engineReconnectCheckTimer) {
        clearInterval(engineReconnectCheckTimer);
        engineReconnectCheckTimer = null;
    }

    // Notify page to stop its own polling
    if (typeof onSessionExpired === 'function') {
        try { onSessionExpired(); } catch (e) {
            console.error('[engine-events] onSessionExpired error:', e);
        }
    }

    updateConnectionBanner();
    console.log('[engine-events] Session expired — polling stopped');
}

// ============================================================================
// IDLE DETECTION
// ============================================================================

/**
 * Called on any user interaction. Resets the idle timer and resumes
 * polling if it was paused due to inactivity.
 */
function onUserActivity() {
    engineLastActivity = Date.now();

    if (engineIdlePaused) {
        engineIdlePaused = false;
        hideIdleOverlay();

        // Resume if not hidden and not expired
        if (!enginePageHidden && !engineSessionExpired) {
            // Reconnect WebSocket if needed
            if (!engineConnected && engineWs &&
                engineWs.readyState !== WebSocket.OPEN &&
                engineWs.readyState !== WebSocket.CONNECTING) {
                openEngineWebSocket();
            }

            if (typeof onPageResumed === 'function') {
                try { onPageResumed(); } catch (e) {
                    console.error('[engine-events] onPageResumed error:', e);
                }
            }
        }
    }
}

/**
 * Checks whether the idle timeout has been exceeded.
 * Called every 10 seconds.
 */
function checkIdleTimeout() {
    if (engineIdlePaused || engineSessionExpired || enginePageHidden) return;

    var elapsed = (Date.now() - engineLastActivity) / 1000;
    if (elapsed >= engineIdleTimeoutSec) {
        engineIdlePaused = true;
        showIdleOverlay();
        console.log('[engine-events] Idle timeout — polling paused');
    }
}

/**
 * Loads idle timeout from GlobalConfig via the refresh-interval API.
 * Non-blocking — uses default if unavailable.
 */
function loadIdleTimeoutConfig() {
    fetch('/api/config/refresh-interval?page=idle_timeout')
        .then(function(r) { return r.ok ? r.json() : null; })
        .then(function(data) {
            if (data && data.interval && !data.default) {
                engineIdleTimeoutSec = data.interval;
            }
        })
        .catch(function() { /* use default */ });
}

/**
 * Shows a subtle overlay indicating polling is paused.
 */
function showIdleOverlay() {
    if (document.getElementById('engine-idle-overlay')) return;

    var overlay = document.createElement('div');
    overlay.id = 'engine-idle-overlay';
    overlay.className = 'idle-overlay';
    overlay.innerHTML = '<div class="idle-message">Paused \u2014 move mouse to resume</div>';
    document.body.appendChild(overlay);
}

/**
 * Removes the idle overlay.
 */
function hideIdleOverlay() {
    var overlay = document.getElementById('engine-idle-overlay');
    if (overlay) overlay.remove();
}

// ============================================================================
// SHARED PAGE REFRESH
// ============================================================================
// Handles refresh button spin animation and delegates to the page's data
// loading logic via the onPageRefresh() hook. Pages should define
// onPageRefresh() instead of their own pageRefresh() function.
//
// The typeof guard exists for backward compatibility with pages that still
// define their own local pageRefresh() — once all pages are migrated to
// onPageRefresh(), the guard should be removed and this becomes the
// unconditional implementation.

if (typeof pageRefresh !== 'function') {
    window.pageRefresh = function() {
        var btn = document.querySelector('.page-refresh-btn');
        if (btn) {
            btn.classList.add('spinning');
            btn.addEventListener('animationend', function() {
                btn.classList.remove('spinning');
            }, { once: true });
        }
        if (typeof onPageRefresh === 'function') {
            onPageRefresh();
        }
    };
}

// ============================================================================
// STYLED MODAL UTILITIES
// ============================================================================
// Replaces native alert() and confirm() across all Control Center pages.
// Returns Promises so callers can use .then() for async flow.
//
// Usage:
//   showAlert('File not found.', { title: 'Error', icon: '&#10005;', iconColor: '#f48771' });
//
//   showConfirm('Delete this item?', {
//       title: 'Confirm Delete',
//       confirmLabel: 'Delete',
//       confirmClass: 'xf-modal-btn-danger'
//   }).then(function(confirmed) { if (confirmed) { ... } });
//
//   // For HTML content in the body:
//   showConfirm('<p>Rich <strong>HTML</strong> content</p>', { html: true, ... });
// ============================================================================

function showAlert(message, options) {
    var opts = options || {};
    var title = opts.title || 'Notice';
    var icon = opts.icon || '&#9432;';
    var iconColor = opts.iconColor || '#569cd6';
    var buttonLabel = opts.buttonLabel || 'OK';

    return new Promise(function (resolve) {
        var id = 'xf-alert-' + Date.now();
        var overlay = document.createElement('div');
        overlay.id = id;
        overlay.className = 'xf-modal-overlay';
        overlay.innerHTML = '<div class="xf-modal">'
            + '<div class="xf-modal-header">'
            + '<span class="xf-modal-icon" style="color:' + iconColor + '">' + icon + '</span>'
            + '<span>' + escapeHtml(title) + '</span>'
            + '</div>'
            + '<div class="xf-modal-body"><p>' + escapeHtml(message) + '</p></div>'
            + '<div class="xf-modal-actions">'
            + '<button class="xf-modal-btn-primary" id="' + id + '-ok">' + escapeHtml(buttonLabel) + '</button>'
            + '</div></div>';
        document.body.appendChild(overlay);
        document.getElementById(id + '-ok').onclick = function () { overlay.remove(); resolve(); };
        document.getElementById(id + '-ok').focus();
    });
}

function showConfirm(message, options) {
    var opts = options || {};
    var title = opts.title || 'Confirm';
    var icon = opts.icon || '&#9888;';
    var iconColor = opts.iconColor || '#dcdcaa';
    var confirmLabel = opts.confirmLabel || 'Continue';
    var cancelLabel = opts.cancelLabel || 'Cancel';
    var confirmClass = opts.confirmClass || 'xf-modal-btn-primary';
    var messageHtml = opts.html || false;

    return new Promise(function (resolve) {
        var id = 'xf-confirm-' + Date.now();
        var overlay = document.createElement('div');
        overlay.id = id;
        overlay.className = 'xf-modal-overlay';
        var bodyContent = messageHtml ? message : '<p>' + escapeHtml(message) + '</p>';
        overlay.innerHTML = '<div class="xf-modal">'
            + '<div class="xf-modal-header">'
            + '<span class="xf-modal-icon" style="color:' + iconColor + '">' + icon + '</span>'
            + '<span>' + escapeHtml(title) + '</span>'
            + '</div>'
            + '<div class="xf-modal-body">' + bodyContent + '</div>'
            + '<div class="xf-modal-actions">'
            + '<button class="xf-modal-btn-cancel" id="' + id + '-cancel">' + escapeHtml(cancelLabel) + '</button>'
            + '<button class="' + confirmClass + '" id="' + id + '-ok">' + escapeHtml(confirmLabel) + '</button>'
            + '</div></div>';
        document.body.appendChild(overlay);
        document.getElementById(id + '-cancel').onclick = function () { overlay.remove(); resolve(false); };
        document.getElementById(id + '-ok').onclick = function () { overlay.remove(); resolve(true); };
    });
}
