/* ============================================================================
   xFACts Control Center - Shared Foundation and Chrome (cc-shared.js)
   Location: E:\xFACts-ControlCenter\public\js\cc-shared.js
   Version: Tracked in dbo.System_Metadata (component: ControlCenter)

   Platform-wide shared module loaded by every page in the Control Center. It
   owns the foundation primitives (canonical month/day name lookups, engine
   threshold defaults), the cross-page mutable state that backs the engine
   indicator and connection lifecycle subsystems, and the chrome utilities
   that pages consume directly: HTML escaping, timestamp formatting, the
   visibility/idle/session-aware fetch wrapper, the engine card system, the
   connection status banner, the reconnection grace mechanism, the shared
   page-refresh hook, and the styled alert/confirm modals. The bootloader
   in this file discovers each page's JS module via the body's
   data-cc-prefix attribute and invokes its lifecycle entry point.

   FILE ORGANIZATION
   -----------------
   FOUNDATION: SHARED CONSTANTS
   STATE: ENGINE STATE
   BOOTLOADER: PAGE BOOT AND ACTION DISPATCH
   CHROME: INITIALIZATION
   CHROME: WEBSOCKET CONNECTION
   CHROME: EVENT HANDLING
   CHROME: BOOTSTRAP
   CHROME: COUNTDOWN CALCULATION
   CHROME: COUNTDOWN TICKER
   CHROME: DOM ELEMENT RESOLUTION
   CHROME: CONNECTION INDICATOR
   CHROME: ENGINE POPUP
   CHROME: RECONNECTION GRACE PERIOD
   CHROME: CONNECTION BANNER
   CHROME: SHARED FETCH WRAPPER
   CHROME: IDLE DETECTION
   CHROME: SHARED FORMATTING
   CHROME: SHARED PAGE REFRESH
   CHROME: SHARED MODALS
   CHROME: REDACTION
   ============================================================================ */

/* ============================================================================
   FOUNDATION: SHARED CONSTANTS
   ----------------------------------------------------------------------------
   Platform-wide constant lookups and threshold defaults. The cc_MONTH_NAMES
   and cc_DAY_NAMES values are 1-indexed to map directly from SQL DATEPART
   results and JavaScript Date methods without subtraction. The cc_ENGINE_*
   threshold values are sensible defaults; pages do not override them, but
   the reconnection grace period and idle timeout are tunable via
   GlobalConfig and overwrite their corresponding STATE variables on load.
   Prefix: cc
   ============================================================================ */

/* Month names lookup, 1-indexed so SQL month_num and JS Date month numbers
   map directly. The empty string at index 0 is intentional padding; without
   it every caller would have to remember to subtract 1, which is error-prone
   and easy to forget. Read as cc_MONTH_NAMES[1] === 'January'. */
const cc_MONTH_NAMES = ['', 'January', 'February', 'March', 'April', 'May', 'June',
                        'July', 'August', 'September', 'October', 'November', 'December'];

/* Day-of-week names lookup, 3-letter form, keyed by SQL DATEPART(dw, ...)
   values: 1=Sunday through 7=Saturday. Stored as an object literal rather
   than an array because day-of-week lookups in this codebase are always
   keyed access (cc_DAY_NAMES[dayNum]), never iteration. Read as
   cc_DAY_NAMES[1] === 'Sun'. */
const cc_DAY_NAMES = { 1: 'Sun', 2: 'Mon', 3: 'Tue', 4: 'Wed', 5: 'Thu', 6: 'Fri', 7: 'Sat' };

/* Default day-of-week display order, Sun through Sat. Pages that need a
   different ordering (e.g. Mon-first regional preference) define their own
   local order array; this is the platform default. */
const cc_DAY_ORDER = [1, 2, 3, 4, 5, 6, 7];

/* Engine card grace window in seconds. While the countdown is in [0, -GRACE]
   range the indicator stays green and counts up rather than escalating. */
const cc_ENGINE_GRACE_SEC = 30;

/* Delay between WebSocket reconnect attempts, in seconds. */
const cc_ENGINE_RECONNECT_SEC = 3;

/* Countdown ticker interval in milliseconds. */
const cc_ENGINE_TICK_MS = 1000;

/* Default replacement body for a redacted cnsmr_accnt_ar_log event message in
   the shared profanity redaction modal. The original received-timestamp tail,
   when present, is preserved and appended server-side. */
const cc_REDACTION_DEFAULT_BODY = 'Consumer Replied: Non-standard vulgar text reply - do not text.';

/* ============================================================================
   STATE: ENGINE STATE
   ----------------------------------------------------------------------------
   Module-scope mutable state for the engine indicator, WebSocket lifecycle,
   reconnection grace period, session-expiry detection, and idle pause
   subsystems. These are var bindings rather than const because every value
   here is mutated during the page's lifetime. Pages do not read or write
   these directly; the chrome functions below are the only legitimate
   accessors. cc_pagePrefix is captured at boot from the body's
   data-cc-prefix attribute and read by every function that needs to
   resolve a page-local hook or ENGINE_PROCESSES map via window[...] lookup.
   Prefix: cc
   ============================================================================ */

/* The body's data-cc-prefix value, captured at DOMContentLoaded. Used by
   every chrome function that needs to resolve a page-local identifier
   (hooks, ENGINE_PROCESSES) by computed name on the window object. Null
   until the bootloader sets it. */
var cc_pagePrefix = null;

/* The active WebSocket instance for engine events, or null when not yet
   connected or after a clean shutdown. */
var cc_engineWs = null;

/* setTimeout handle for the next reconnect attempt, or null when no
   reconnect is scheduled. */
var cc_engineReconnectTimer = null;

/* setInterval handle for the 1-second countdown ticker, or null when the
   ticker is not running (e.g. after cc_handleSessionExpired). */
var cc_engineTickTimer = null;

/* Per-slug engine indicator state. Each entry holds { lastEvent, countdown,
   lastRefresh } for one process. Populated in cc_connectEngineEvents from
   the page's <prefix>_ENGINE_PROCESSES map and updated on every WebSocket
   event. */
var cc_engineState = {};

/* Whether the WebSocket is currently in the OPEN state. Tracked separately
   from cc_engineWs.readyState so consumers can read it synchronously
   without a feature-detect dance. */
var cc_engineConnected = false;

/* Whether the engine card popup is currently visible. Used to avoid
   stacking popups and to drive the click-outside dismiss handler. */
var cc_enginePopupVisible = false;

/* Whether the page is currently hidden via the Page Visibility API. Used to
   suppress reconnect attempts and skip polling fetches on hidden tabs. */
var cc_enginePageHidden = false;

/* Reconnection grace period in seconds. Starts at the safe default and is
   overwritten by cc_loadReconnectGraceConfig with the GlobalConfig value
   if one is configured. */
var cc_engineReconnectGraceSec = 60;

/* Timestamp (ms) at which the WebSocket entered the reconnecting state.
   null when not reconnecting; checked by cc_checkReconnectGrace to decide
   when to escalate to the disconnected state. */
var cc_engineReconnectStart = null;

/* Current connection-banner state: one of 'connected', 'reconnecting',
   'disconnected', 'expired'. Drives the styling and content of the
   connection banner. */
var cc_engineConnectionState = 'connected';

/* setInterval handle for the reconnection grace check, or null when no
   reconnection is in progress. */
var cc_engineReconnectCheckTimer = null;

/* Whether the session has been detected as expired (auth cookie lost,
   server returned login page). Once true, all polling and reconnects stop
   permanently for this page load. */
var cc_engineSessionExpired = false;

/* Idle timeout in seconds. Starts at the safe default and is overwritten
   by cc_loadIdleTimeoutConfig with the GlobalConfig value if one is
   configured. */
var cc_engineIdleTimeoutSec = 300;

/* Timestamp (ms) of the last user interaction. Compared against
   cc_engineIdleTimeoutSec by cc_checkIdleTimeout to decide whether to
   pause polling. */
var cc_engineLastActivity = Date.now();

/* Whether polling is currently paused due to user inactivity. Reset by
   cc_onUserActivity on the next interaction. */
var cc_engineIdlePaused = false;

/* setInterval handle for the periodic idle-timeout check. */
var cc_engineIdleCheckTimer = null;

/* ============================================================================
   BOOTLOADER: PAGE BOOT AND ACTION DISPATCH
   ----------------------------------------------------------------------------
   Orchestrates page module discovery, loading, and lifecycle invocation. The
   DOMContentLoaded handler reads data-cc-page and data-cc-prefix from
   <body>, captures the prefix into cc_pagePrefix for post-boot hook
   resolution, injects the page's JS module, invokes the page's
   <prefix>_init function, and registers a delegated event listener for
   each recognized event type from CC_HTML_Spec.md Section 6.4. Each
   listener routes data-action-<event> values to the matching dispatch
   table: cc-* values go to the shared chrome tables in this file,
   page-local values go to the page's own dispatch tables exposed on
   window. Failures populate the cc-page-error-banner placeholder when
   present and log to the console.
   Prefix: cc
   ============================================================================ */

/* The closed set of recognized event names from CC_HTML_Spec.md Section
   6.4. The bootloader registers one delegated listener per entry on
   document.body at page boot. Extending the recognized set requires a
   spec amendment plus a corresponding entry here. */
const cc_RECOGNIZED_EVENTS = ['click', 'change', 'input', 'submit',
                              'keydown', 'keyup', 'focus', 'blur'];

/* Shared chrome click-action dispatch table. Maps cc-* data-action-click
   values to handler functions exposed by other sections of this file.
   Entries are added one at a time as pages surface concrete needs. */
const cc_clickActions = {
    'cc-page-refresh':   cc_pageRefresh,
    'cc-reload-page':    cc_reloadPage,
    'cc-open-redaction': cc_openRedaction
};

/* Shared chrome change-action dispatch table. Parallel to cc_clickActions
   but routes data-action-change values. Currently empty; entries are added
   one at a time as concrete needs surface. */
const cc_changeActions  = {};

/* Shared chrome input-action dispatch table. Parallel to cc_clickActions
   but routes data-action-input values. Currently empty. */
const cc_inputActions   = {};

/* Shared chrome submit-action dispatch table. Parallel to cc_clickActions
   but routes data-action-submit values. Currently empty. */
const cc_submitActions  = {};

/* Shared chrome keydown-action dispatch table. Parallel to cc_clickActions
   but routes data-action-keydown values. Currently empty. */
const cc_keydownActions = {};

/* Shared chrome keyup-action dispatch table. Parallel to cc_clickActions
   but routes data-action-keyup values. Currently empty. */
const cc_keyupActions   = {};

/* Shared chrome focus-action dispatch table. Parallel to cc_clickActions
   but routes data-action-focus values. Currently empty. */
const cc_focusActions   = {};

/* Shared chrome blur-action dispatch table. Parallel to cc_clickActions
   but routes data-action-blur values. Currently empty. */
const cc_blurActions    = {};

/* Lookup of event name to its shared dispatch table. Used by
   cc_handleSharedAction to find the right table for the event that fired
   without a switch/case ladder. */
const cc_actionTables = {
    click:    cc_clickActions,
    change:   cc_changeActions,
    input:    cc_inputActions,
    submit:   cc_submitActions,
    keydown:  cc_keydownActions,
    keyup:    cc_keyupActions,
    focus:    cc_focusActions,
    blur:     cc_blurActions
};

/* Bootloader entry point. Fires once on DOMContentLoaded. Reads
   data-cc-page and data-cc-prefix from <body>, captures the prefix into
   cc_pagePrefix for later hook lookups, registers a delegated listener
   for each recognized event so cc-* actions dispatch even before the
   page module loads, then injects the page's JS module. */
document.addEventListener('DOMContentLoaded', function() {
    cc_registerActionListeners();

    const pageKey = document.body.dataset.ccPage;
    const prefix  = document.body.dataset.ccPrefix;

    if (!pageKey || !prefix) {
        return;
    }

    /* Capture the prefix in module scope so post-boot hook firings (e.g.
       cc_handleVisibilityChange, cc_handleEngineEvent) can resolve the
       page's <prefix>_<hook> functions on window. */
    cc_pagePrefix = prefix;

    cc_loadPageModule(pageKey, prefix);
});

/* Registers one delegated listener per recognized event on document.body.
   Each listener routes events targeting elements that declare
   data-action-<event> to the shared dispatch table for that event when
   the action value carries the cc- prefix. Page-local actions are
   handled by listeners registered in the page's <prefix>_init function. */
function cc_registerActionListeners() {
    cc_RECOGNIZED_EVENTS.forEach(function(eventName) {
        document.body.addEventListener(eventName, function(event) {
            cc_handleSharedAction(eventName, event);
        });
    });
}

/* Injects the page's JS module via a <script> tag and wires success and
   failure callbacks. On successful load, invokes <prefix>_init. On any
   failure, logs to the console and populates the cc-page-error-banner. */
function cc_loadPageModule(pageKey, prefix) {
    const script = document.createElement('script');
    script.src = '/js/' + pageKey + '.js';
    script.addEventListener('load', function() {
        cc_invokePageInit(pageKey, prefix);
    });
    script.addEventListener('error', function() {
        cc_renderPageError('Page module failed to load.');
        console.error('[cc-shared] Failed to load page module: /js/' + pageKey + '.js');
    });
    document.head.appendChild(script);
}

/* Looks up the page's <prefix>_init function on window and invokes it.
   Logs to the console and populates the cc-page-error-banner if the
   function is missing or throws during execution. */
function cc_invokePageInit(pageKey, prefix) {
    const initFnName = prefix + '_init';
    const initFn = window[initFnName];

    if (typeof initFn !== 'function') {
        cc_renderPageError('Page boot function not found.');
        console.error('[cc-shared] Page module loaded but ' + initFnName + '() not found');
        return;
    }

    try {
        initFn();
    } catch (err) {
        cc_renderPageError('Page boot failed.');
        console.error('[cc-shared] ' + initFnName + '() threw during execution:', err);
    }
}

/* Populates the cc-page-error-banner placeholder with a user-facing error
   message and a refresh control. Falls back to console-only output when
   the placeholder is absent from the page shell. */
function cc_renderPageError(message) {
    const banner = document.getElementById('cc-page-error-banner');
    if (!banner) {
        return;
    }

    banner.innerHTML =
        '<span class="cc-page-error-banner-message">' + cc_escapeHtml(message) + '</span>' +
        ' <button type="button" class="cc-page-error-banner-refresh" ' +
        'data-action-click="cc-reload-page">Refresh</button>' +
        ' <span class="cc-page-error-banner-contact">If the problem continues, ' +
        'contact the Applications &amp; Integration team.</span>';
    banner.classList.add('cc-page-error-banner-visible');
}

/* Delegated dispatcher for shared chrome actions. Routes
   data-action-<event> values that begin with cc- to handlers in the
   shared dispatch table for the firing event. Page-local actions (no
   cc- prefix) are ignored here and handled by the page's own delegated
   listeners registered in <prefix>_init. */
function cc_handleSharedAction(eventName, event) {
    const attrName = 'data-action-' + eventName;
    const target = event.target.closest('[' + attrName + ']');
    if (!target) {
        return;
    }

    const action = target.getAttribute(attrName);
    if (!action || action.indexOf('cc-') !== 0) {
        return;
    }

    const handler = cc_actionTables[eventName][action];
    if (!handler) {
        console.warn('[cc-shared] Unknown shared ' + eventName + ' action: ' + action);
        return;
    }

    handler(target, event);
}

/* ============================================================================
   CHROME: INITIALIZATION
   ----------------------------------------------------------------------------
   The single platform-wide entry point that pages call from their
   <prefix>_init function. Wires up the WebSocket, loads bootstrap state,
   starts the countdown ticker, registers the visibility/idle/escape-key
   listeners, and primes the connection banner.
   Prefix: cc
   ============================================================================ */

/* Main entry point - call from the page's <prefix>_init function. Connects
   the WebSocket, loads initial state, and starts the countdown ticker.
   Pages define their <prefix>_ENGINE_PROCESSES map at module scope before
   this script loads so the bootstrap fetch knows which slugs to populate. */
function cc_connectEngineEvents() {
    var processes = window[cc_pagePrefix + '_ENGINE_PROCESSES'];
    if (typeof processes === 'undefined' || !processes) {
        console.warn('[cc-shared] ' + cc_pagePrefix + '_ENGINE_PROCESSES not defined - engine events disabled');
        return;
    }

    /* Initialize per-slug state for each configured process. */
    Object.keys(processes).forEach(function(procName) {
        var slug = processes[procName].slug;
        cc_engineState[slug] = {
            lastEvent: null,
            countdown: null,
            lastRefresh: null
        };
    });

    /* Load the reconnect grace period from GlobalConfig in the background. */
    cc_loadReconnectGraceConfig();

    /* Load bootstrap state from the REST endpoint, then connect the WebSocket. */
    cc_loadEngineBootstrap().then(function() {
        cc_openEngineWebSocket();
    });

    /* Start the 1-second countdown ticker. */
    cc_engineTickTimer = setInterval(cc_tickAllEngineIndicators, cc_ENGINE_TICK_MS);

    /* Register visibility-change handling: pause WebSocket reconnects while
       the tab is hidden, resume on visibility return. */
    document.addEventListener('visibilitychange', cc_handleVisibilityChange);

    /* Idle detection - pause polling after inactivity, resume on interaction. */
    cc_loadIdleTimeoutConfig();
    cc_engineLastActivity = Date.now();

    /* User activity detection - bound directly rather than via forEach so
       the populator's per-element listener loop check stays clean. */
    document.addEventListener('mousemove',  cc_onUserActivity, { passive: true });
    document.addEventListener('mousedown',  cc_onUserActivity, { passive: true });
    document.addEventListener('keydown',    cc_onUserActivity, { passive: true });
    document.addEventListener('touchstart', cc_onUserActivity, { passive: true });
    document.addEventListener('scroll',     cc_onUserActivity, { passive: true });

    cc_engineIdleCheckTimer = setInterval(cc_checkIdleTimeout, 10000);

    /* Close the engine popup on Escape and on outside-click. */
    document.addEventListener('keydown', cc_handleGlobalKeydown);
    document.addEventListener('click', cc_handleGlobalClick);
}

/* Visibility-change handler. Pauses WebSocket reconnects on hidden, resumes
   the WebSocket and notifies the page on return. On return, drives the
   refresh-button spin animation before invoking <prefix>_onPageResumed so
   every page gets the same visual feedback that fresh data is being
   loaded. Bound by cc_connectEngineEvents. */
function cc_handleVisibilityChange() {
    if (document.visibilityState === 'hidden') {
        cc_enginePageHidden = true;
        if (cc_engineReconnectTimer) {
            clearTimeout(cc_engineReconnectTimer);
            cc_engineReconnectTimer = null;
        }
        return;
    }

    cc_enginePageHidden = false;
    if (cc_engineSessionExpired) return;

    /* Reconnect WebSocket if it's not already connected or connecting. */
    if (!cc_engineConnected && cc_engineWs &&
        cc_engineWs.readyState !== WebSocket.OPEN &&
        cc_engineWs.readyState !== WebSocket.CONNECTING) {
        cc_openEngineWebSocket();
    }

    /* Drive the refresh-button spin animation so the user sees a clear
       signal that the page is reloading data after returning from a
       hidden tab. The animation runs in parallel with the page's
       <prefix>_onPageResumed fetching new data. */
    var btn = document.querySelector('.cc-page-refresh-btn');
    if (btn) {
        btn.classList.add('cc-page-refresh-spinning');
        btn.addEventListener('animationend', cc_clearRefreshSpin, { once: true });
    }

    /* Notify the page so it can do an immediate data refresh. */
    var onPageResumed = window[cc_pagePrefix + '_onPageResumed'];
    if (typeof onPageResumed === 'function') {
        try {
            onPageResumed();
        } catch (e) {
            console.error('[cc-shared] ' + cc_pagePrefix + '_onPageResumed error:', e);
        }
    }
}

/* Document-level keydown handler. Closes the engine popup on Escape; other
   keys are ignored here (page-specific keydown handlers are unaffected
   because the listener is passive in spirit - it only acts on Escape and
   only when the popup is visible). */
function cc_handleGlobalKeydown(e) {
    if (e.key === 'Escape' && cc_enginePopupVisible) {
        cc_closeEnginePopup();
    }
}

/* Document-level click handler. Two responsibilities:
   1) Open the engine popup on engine-card click. Cards are identified by
      their existing id attribute (id="cc-card-engine" for single-process
      pages, id="cc-card-engine-{slug}" for multi-process pages).
   2) Close the engine popup on outside-click. Clicks inside the popup or
      on an engine card are ignored so the click that opened the popup
      doesn't immediately close it.
   Bound once at INITIALIZATION; covers all engine cards on the page
   regardless of layout pattern, with no per-card listener attachment. */
function cc_handleGlobalClick(e) {
    var processes = window[cc_pagePrefix + '_ENGINE_PROCESSES'];
    if (!processes) return;

    var card = e.target.closest('.cc-card-engine');
    if (card && card.id) {
        var slug = card.id === 'cc-card-engine'
            ? Object.keys(processes).map(function(k) { return processes[k].slug; })[0]
            : card.id.replace(/^cc-card-engine-/, '');
        var procName = null;
        for (var k in processes) {
            if (processes[k].slug === slug) { procName = k; break; }
        }
        if (procName) {
            e.stopPropagation();
            cc_showEnginePopup(slug, procName, card);
        }
        return;
    }
    if (cc_enginePopupVisible && !e.target.closest('.cc-engine-popup')) {
        cc_closeEnginePopup();
    }
}

/* ============================================================================
   CHROME: WEBSOCKET CONNECTION
   ----------------------------------------------------------------------------
   Opens and manages the engine-events WebSocket connection. Handlers for
   open, message, close, and error are bound via addEventListener to named
   functions defined in this section. The reconnect cycle, banner state
   transitions, and post-restart auto-reload behavior live here.
   Prefix: cc
   ============================================================================ */

/* Opens the engine-events WebSocket. No-op if a connection is already open
   or in the process of opening. Binds the four lifecycle handlers via
   addEventListener. */
function cc_openEngineWebSocket() {
    if (cc_engineWs &&
        (cc_engineWs.readyState === WebSocket.OPEN ||
         cc_engineWs.readyState === WebSocket.CONNECTING)) {
        return;
    }

    var protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    cc_engineWs = new WebSocket(protocol + '//' + window.location.host + '/engine-events');

    cc_engineWs.addEventListener('open', cc_handleEngineWsOpen);
    cc_engineWs.addEventListener('message', cc_handleEngineWsMessage);
    cc_engineWs.addEventListener('close', cc_handleEngineWsClose);
    cc_engineWs.addEventListener('error', cc_handleEngineWsError);
}

/* WebSocket 'open' handler. Marks the connection as live, clears the
   reconnect-grace timer if one is running, updates the connection
   indicator, and triggers a brief auto-reload if the open follows a
   reconnect (so newly deployed assets get picked up). */
function cc_handleEngineWsOpen() {
    var wasReconnecting = (cc_engineConnectionState === 'reconnecting');
    cc_engineConnected = true;
    cc_engineConnectionState = 'connected';
    cc_engineReconnectStart = null;

    if (cc_engineReconnectCheckTimer) {
        clearInterval(cc_engineReconnectCheckTimer);
        cc_engineReconnectCheckTimer = null;
    }

    cc_updateEngineConnectionIndicator(true);
    cc_updateConnectionBanner();

    if (wasReconnecting) {
        /* Server came back after a restart - show brief message then
           reload to pick up any newly deployed files. */
        cc_showReloadingBanner();
        setTimeout(cc_reloadPage, 1500);
        return;
    }

    console.log('[cc-shared] WebSocket connected');
}

/* WebSocket 'message' handler. Parses the JSON payload and dispatches to
   cc_handleEngineEvent; unparseable payloads are logged and dropped. */
function cc_handleEngineWsMessage(evt) {
    var event;
    try {
        event = JSON.parse(evt.data);
    } catch (e) {
        console.warn('[cc-shared] Unparseable message:', evt.data);
        return;
    }

    cc_handleEngineEvent(event);
}

/* WebSocket 'close' handler. Clears the connected flag, transitions the
   banner state into 'reconnecting' if not already there, starts the
   grace-period check, and schedules a reconnect attempt. Skips reconnects
   when the session is expired or the page is hidden. */
function cc_handleEngineWsClose() {
    cc_engineConnected = false;
    cc_updateEngineConnectionIndicator(false);

    if (cc_engineSessionExpired) return;
    if (cc_enginePageHidden) return;

    /* Enter reconnecting state if this is the first close after connected. */
    if (cc_engineConnectionState === 'connected') {
        cc_engineConnectionState = 'reconnecting';
        cc_engineReconnectStart = Date.now();
        cc_updateConnectionBanner();

        if (!cc_engineReconnectCheckTimer) {
            cc_engineReconnectCheckTimer = setInterval(cc_checkReconnectGrace, 1000);
        }
    }

    console.log('[cc-shared] WebSocket closed, reconnecting in ' + cc_ENGINE_RECONNECT_SEC + 's...');

    if (cc_engineReconnectTimer) clearTimeout(cc_engineReconnectTimer);
    cc_engineReconnectTimer = setTimeout(cc_openEngineWebSocket, cc_ENGINE_RECONNECT_SEC * 1000);
}

/* WebSocket 'error' handler. The 'close' event always fires after 'error',
   so the actual reconnect logic runs there; this handler just maintains
   the connection indicator. */
function cc_handleEngineWsError() {
    cc_engineConnected = false;
    cc_updateEngineConnectionIndicator(false);
}

/* Reloads the current page. Trivial wrapper around window.location.reload
   so the setTimeout call site can pass a named function reference rather
   than constructing an anonymous wrapper. */
function cc_reloadPage() {
    window.location.reload();
}

/* ============================================================================
   CHROME: EVENT HANDLING
   ----------------------------------------------------------------------------
   Dispatches a parsed WebSocket event payload to the right slug's state and
   triggers the page-side hooks. Pages that need to react to specific event
   types define <prefix>_onEngineProcessCompleted and/or
   <prefix>_onEngineEventRaw to opt in.
   Prefix: cc
   ============================================================================ */

/* Dispatches an engine event to its target slug, updates state, calculates
   the new countdown, fires page hooks, and refreshes the indicator. Events
   for processes the page does not list in <prefix>_ENGINE_PROCESSES are
   silently ignored. */
function cc_handleEngineEvent(event) {
    /* Raw-event hook delivers every event to the page before filtering.
       Used by the Admin page to drive the process timeline from WebSocket
       events instead of polling. Most pages do not define this. */
    var onEngineEventRaw = window[cc_pagePrefix + '_onEngineEventRaw'];
    if (typeof onEngineEventRaw === 'function') {
        try {
            onEngineEventRaw(event);
        } catch (e) {
            console.error('[cc-shared] ' + cc_pagePrefix + '_onEngineEventRaw error:', e);
        }
    }

    /* Find which configured process this event belongs to. */
    var processes = window[cc_pagePrefix + '_ENGINE_PROCESSES'];
    if (!processes) return;
    var procConfig = processes[event.processName];
    if (!procConfig) return;

    var slug = procConfig.slug;
    var now = Date.now();

    cc_engineState[slug].lastEvent = event;
    cc_engineState[slug].lastRefresh = now;

    if (event.eventType === 'PROCESS_STARTED') {
        /* Clear the countdown - the process is actively running. */
        cc_engineState[slug].countdown = null;
    } else if (event.eventType === 'PROCESS_COMPLETED') {
        /* Calculate the new countdown from live scheduling metadata. */
        cc_engineState[slug].countdown = cc_calcCountdownFromEvent(event, Date.now());

        /* Notify the page so it can refresh its data. */
        var onEngineProcessCompleted = window[cc_pagePrefix + '_onEngineProcessCompleted'];
        if (typeof onEngineProcessCompleted === 'function') {
            try {
                onEngineProcessCompleted(event.processName, event);
            } catch (e) {
                console.error('[cc-shared] ' + cc_pagePrefix + '_onEngineProcessCompleted error:', e);
            }
        }
    }

    /* Immediate visual update so the user sees the change without waiting
       for the next 1-second tick. */
    cc_tickEngineIndicator(slug);
}

/* ============================================================================
   CHROME: BOOTSTRAP
   ----------------------------------------------------------------------------
   Fetches the current engine state from the REST endpoint on page load and
   on reconnect, populating each card's initial state without waiting for
   the next push event from the WebSocket.
   Prefix: cc
   ============================================================================ */

/* Loads current engine state from the REST endpoint on page load and on
   reconnect, providing immediate card state without waiting for the next
   push event. Returns the underlying fetch promise so the caller can
   chain WebSocket connect after bootstrap completes. Bootstrap failure
   is non-fatal: cards stay in the gray waiting state until the first
   push event arrives. */
function cc_loadEngineBootstrap() {
    return fetch('/api/engine/state')
        .then(cc_handleBootstrapResponse)
        .then(cc_applyBootstrapState)
        .catch(cc_handleBootstrapError);
}

/* Bootstrap response handler. Throws on non-OK status; otherwise returns
   the parsed JSON state object. */
function cc_handleBootstrapResponse(response) {
    if (!response.ok) throw new Error('Bootstrap failed: ' + response.status);
    return response.json();
}

/* Applies a parsed bootstrap state object to cc_engineState, computing the
   initial countdown for each PROCESS_COMPLETED event and rendering the
   indicator. */
function cc_applyBootstrapState(state) {
    var now = Date.now();
    var processes = window[cc_pagePrefix + '_ENGINE_PROCESSES'];
    if (!processes) return;

    Object.keys(processes).forEach(function(procName) {
        var slug = processes[procName].slug;
        var event = state[procName];

        if (event) {
            cc_engineState[slug].lastEvent = event;
            cc_engineState[slug].lastRefresh = now;

            /* Calculate initial countdown from event scheduling metadata. */
            if (event.eventType === 'PROCESS_COMPLETED' && event.timestamp) {
                cc_engineState[slug].countdown = cc_calcCountdownFromEvent(event, now);
            }
        }

        cc_tickEngineIndicator(slug);
    });
}

/* Bootstrap error handler. Bootstrap failure is non-fatal - the cards
   simply stay in the gray waiting state until the first WebSocket push
   event arrives. The warning is logged for diagnostics. */
function cc_handleBootstrapError(e) {
    console.warn('[cc-shared] Engine bootstrap:', e.message);
}

/* ============================================================================
   CHROME: COUNTDOWN CALCULATION
   ----------------------------------------------------------------------------
   Pure functions that convert a process scheduling metadata payload into a
   countdown value in seconds. Three scheduling patterns are supported:
   interval-only, once-daily, and time+interval. The math for each pattern
   lives here so cc_handleEngineEvent and the bootstrap renderer share one
   implementation.
   Prefix: cc
   ============================================================================ */

/* Calculates the countdown value (in seconds) based on the process
   scheduling metadata carried in the PROCESS_COMPLETED event.

   Pattern 1 (interval-only): scheduledTime empty -> countdown = intervalSeconds
   Pattern 2 (once-daily):    scheduledTime set, intervalSeconds=0 -> countdown to scheduledTime tomorrow
   Pattern 3 (time+interval): scheduledTime set, intervalSeconds>0 -> intervalSeconds while polling,
                              countdown to scheduledTime tomorrow after today's success

   @param {Object} event - PROCESS_COMPLETED event with intervalSeconds, scheduledTime, runMode, status
   @param {number} now - Current time in ms (Date.now())
   @returns {number|null} Countdown in seconds, or null if no countdown applies */
function cc_calcCountdownFromEvent(event, now) {
    var intervalSec = event.intervalSeconds || 0;
    var schedTime = event.scheduledTime || '';
    var runMode = event.runMode != null ? event.runMode : 1;

    /* Queue-driven (run_mode=2) or disabled (run_mode=0): no countdown. */
    if (runMode !== 1) return null;

    /* Calculate elapsed time since the event. */
    var elapsed = 0;
    if (event.timestamp) {
        elapsed = Math.floor((now - new Date(event.timestamp).getTime()) / 1000);
        if (elapsed < 0) elapsed = 0;
    }

    /* Pattern 1: interval-only (no scheduled_time). */
    if (!schedTime) {
        return intervalSec > 0 ? intervalSec - elapsed : null;
    }

    /* Has scheduled_time - Pattern 2 or 3.
       Pattern 3 check: if intervalSeconds > 0 and the process did NOT
       succeed, it's still actively polling -> use interval countdown. */
    if (intervalSec > 0 && event.status !== 'SUCCESS') {
        return intervalSec - elapsed;
    }

    /* Pattern 2, or Pattern 3 after today's success: countdown to
       scheduledTime tomorrow (already relative to now). */
    return cc_calcSecondsUntilTomorrow(schedTime, now);
}

/* Calculates seconds from now until the next occurrence of a given
   HH:mm:ss time. If the time has not yet passed today, targets today.
   Otherwise targets tomorrow.

   @param {string} timeStr - Time in "HH:mm:ss" format
   @param {number} now - Current time in ms (Date.now())
   @returns {number} Seconds until the next occurrence of that time */
function cc_calcSecondsUntilTomorrow(timeStr, now) {
    var parts = timeStr.split(':');
    var h = parseInt(parts[0], 10) || 0;
    var m = parseInt(parts[1], 10) || 0;
    var s = parseInt(parts[2], 10) || 0;

    var today = new Date(now);
    var target = new Date(today);
    target.setHours(h, m, s, 0);

    /* If the target time has already passed today, aim for tomorrow. */
    if (target.getTime() <= now) {
        target.setDate(target.getDate() + 1);
    }

    return Math.floor((target.getTime() - now) / 1000);
}

/* ============================================================================
   CHROME: COUNTDOWN TICKER
   ----------------------------------------------------------------------------
   Drives the per-second decrement of every active countdown and refreshes
   the visual state of every engine indicator on the page. Runs on a
   setInterval started by cc_connectEngineEvents.
   Prefix: cc
   ============================================================================ */

/* Decrements every active countdown by 1 second and re-renders every
   engine indicator. Called once per second by the cc_engineTickTimer
   interval. */
function cc_tickAllEngineIndicators() {
    var processes = window[cc_pagePrefix + '_ENGINE_PROCESSES'];
    if (!processes) return;

    Object.keys(processes).forEach(function(procName) {
        var slug = processes[procName].slug;

        /* Decrement countdown by 1 second each tick. */
        if (cc_engineState[slug].countdown !== null) {
            cc_engineState[slug].countdown -= 1;
        }

        cc_tickEngineIndicator(slug);
    });
}

/* Renders the engine indicator for a single slug based on the current
   state. Computes bar/card classes from event status, countdown, and
   grace/critical thresholds; updates the countdown display text. */
function cc_tickEngineIndicator(slug) {
    var els = cc_getEngineElements(slug);
    if (!els.bar) return;

    var state = cc_engineState[slug];
    var event = state ? state.lastEvent : null;

    /* No data yet: waiting state. */
    if (!event) {
        els.bar.className = 'cc-engine-bar cc-disabled';
        if (els.card) els.card.className = 'cc-card-engine';
        if (els.cd) els.cd.textContent = '';
        return;
    }

    /* STARTED: process is running. */
    if (event.eventType === 'PROCESS_STARTED') {
        els.bar.className = 'cc-engine-bar cc-running';
        if (els.card) els.card.className = 'cc-card-engine';
        if (els.cd) els.cd.textContent = 'RUNNING';
        return;
    }

    /* COMPLETED: show countdown or escalation. */
    var lastFailed = (event.status === 'FAILED' || event.status === 'TIMEOUT');
    var countdown = state.countdown;

    /* Determine effective interval for overdue threshold calculation. For
       interval-based processes, use intervalSeconds directly. For
       once-daily processes, use a fixed 10-minute grace window (the
       orchestrator's 5-minute launch window plus margin). */
    var effectiveInterval = event.intervalSeconds || 0;
    if (event.scheduledTime && (!effectiveInterval || effectiveInterval === 0)) {
        effectiveInterval = 600;
    }

    var cdText = '';
    var overdue = false;
    var critical = false;

    if (countdown !== null) {
        if (countdown > 0) {
            /* Counting down to next execution. */
            cdText = cc_fmtEngineCountdown(countdown);
        } else if (countdown >= -cc_ENGINE_GRACE_SEC) {
            /* Grace period - count up, stay green (no overdue escalation). */
            cdText = '+' + cc_fmtEngineCountdown(Math.abs(countdown));
        } else {
            /* Overdue - past grace period. */
            cdText = '+' + cc_fmtEngineCountdown(Math.abs(countdown));
            overdue = true;
            if (effectiveInterval > 0 && countdown < -(effectiveInterval * 2)) {
                critical = true;
            }
        }
    }

    /* Determine bar and card classes based on combined state. */
    var barCls;
    var cardCls = 'cc-card-engine';
    if (lastFailed || critical) {
        barCls = 'cc-engine-bar cc-critical';
        cardCls = 'cc-card-engine cc-card-critical';
    } else if (overdue) {
        barCls = 'cc-engine-bar cc-overdue';
        cardCls = 'cc-card-engine cc-card-warning';
    } else {
        barCls = 'cc-engine-bar cc-idle';
    }

    els.bar.className = barCls;
    if (els.card) els.card.className = cardCls;
    if (els.cd) {
        els.cd.textContent = cdText || '';
        els.cd.className = (overdue || critical) ? 'cc-engine-cd cc-cd-overdue' : 'cc-engine-cd';
    }
}

/* ============================================================================
   CHROME: DOM ELEMENT RESOLUTION
   ----------------------------------------------------------------------------
   Resolves the bar/card/countdown DOM elements for an engine slug. Engine
   card IDs follow the slug-suffixed pattern cc-engine-bar-{slug},
   cc-card-engine-{slug}, cc-engine-cd-{slug} emitted by Get-EngineCardsHtml.
   Prefix: cc
   ============================================================================ */

/* Finds engine card DOM elements by slug. Each engine card on a page is
   identified by a slug-suffixed ID (cc-engine-bar-{slug}, cc-card-engine-{slug},
   cc-engine-cd-{slug}) emitted by Get-EngineCardsHtml when the page registers
   processes in Orchestrator.ProcessRegistry. */
function cc_getEngineElements(slug) {
    var bar = document.getElementById('cc-engine-bar-' + slug);
    var card = document.getElementById('cc-card-engine-' + slug);
    var cd = document.getElementById('cc-engine-cd-' + slug);
    return { bar: bar, card: card, cd: cd };
}

/* ============================================================================
   CHROME: CONNECTION INDICATOR
   ----------------------------------------------------------------------------
   Subtle visual indicator on the cc-engine-row when the WebSocket is
   disconnected. Adds or removes a single class that pages style at their
   discretion.
   Prefix: cc
   ============================================================================ */

/* Subtle visual indicator on the cc-engine-row when WebSocket is
   disconnected. Adds or removes a 'cc-ws-disconnected' class that pages can
   style. */
function cc_updateEngineConnectionIndicator(connected) {
    var rows = document.querySelectorAll('.cc-engine-row');
    rows.forEach(function(row) {
        if (connected) {
            row.classList.remove('cc-ws-disconnected');
        } else {
            row.classList.add('cc-ws-disconnected');
        }
    });
}

/* ============================================================================
   CHROME: ENGINE POPUP
   ----------------------------------------------------------------------------
   Click-to-show last-execution detail popup anchored to an engine card.
   The click is dispatched by cc_handleGlobalClick (delegated on document
   at page boot); cc_showEnginePopup builds and positions the popup;
   cc_closeEnginePopup tears it down. The clickable cursor styling lives
   in cc-shared.css on .cc-card-engine.
   Prefix: cc
   ============================================================================ */

/* Builds and positions a popup with last execution details for a process.
   Anchors to the supplied card element. No-op if the slug has no
   lastEvent. */
function cc_showEnginePopup(slug, procName, anchorEl) {
    cc_closeEnginePopup();

    var state = cc_engineState[slug];
    var event = state ? state.lastEvent : null;

    if (!event) return;

    var popup = document.createElement('div');
    popup.className = 'cc-engine-popup';

    var statusText = event.status || event.eventType;
    var statusClass = 'cc-status-success';
    if (event.eventType === 'PROCESS_STARTED') {
        statusText = 'RUNNING';
        statusClass = 'cc-status-running';
    } else if (event.status === 'FAILED' || event.status === 'TIMEOUT') {
        statusClass = 'cc-status-failed';
    }

    var durationText = event.durationMs != null
        ? (event.durationMs / 1000).toFixed(1) + 's'
        : '-';

    var timeText = event.timestamp
        ? new Date(event.timestamp).toLocaleTimeString()
        : '-';

    var html = '' +
        '<div class="cc-engine-popup-header">' +
            '<span class="cc-engine-popup-title">' + procName + '</span>' +
            '<span class="cc-engine-popup-close" data-cc-engine-popup-close="1">&times;</span>' +
        '</div>' +
        '<div class="cc-engine-popup-row">' +
            '<span class="cc-engine-popup-label">Module</span>' +
            '<span class="cc-engine-popup-value">' + (event.moduleName || '-') + '</span>' +
        '</div>' +
        '<div class="cc-engine-popup-row">' +
            '<span class="cc-engine-popup-label">Last Run</span>' +
            '<span class="cc-engine-popup-value">' + timeText + '</span>' +
        '</div>' +
        '<div class="cc-engine-popup-row">' +
            '<span class="cc-engine-popup-label">Duration</span>' +
            '<span class="cc-engine-popup-value">' + durationText + '</span>' +
        '</div>' +
        '<div class="cc-engine-popup-row">' +
            '<span class="cc-engine-popup-label">Status</span>' +
            '<span class="cc-engine-popup-status ' + statusClass + '">' + statusText + '</span>' +
        '</div>';

    if (event.exitCode != null) {
        html += '' +
        '<div class="cc-engine-popup-row">' +
            '<span class="cc-engine-popup-label">Exit Code</span>' +
            '<span class="cc-engine-popup-value">' + event.exitCode + '</span>' +
        '</div>';
    }

    if (event.outputSummary) {
        html += '' +
        '<div class="cc-engine-popup-output">' +
            '<div class="cc-engine-popup-label">Output</div>' +
            '<pre class="cc-engine-popup-pre">' + cc_escapeHtml(event.outputSummary) + '</pre>' +
        '</div>';
    }

    if (event.taskId) {
        html += '' +
        '<div class="cc-engine-popup-footer">Task #' + event.taskId + '</div>';
    }

    popup.innerHTML = html;

    /* Wire the close button via addEventListener; the previous inline
       onclick="cc_closeEnginePopup()" was a forbidden pattern. The close
       span carries data-cc-engine-popup-close="1" so the listener can
       find it without a fragile child-index lookup. */
    var closeBtn = popup.querySelector('[data-cc-engine-popup-close="1"]');
    if (closeBtn) {
        closeBtn.addEventListener('click', cc_closeEnginePopup);
    }

    /* Position near the card. The top and right coordinates depend on the
       clicked card's runtime bounding rect, so they are computed here and
       applied directly. Static layout (position, z-index) lives in
       cc-shared.css on .cc-engine-popup. */
    var rect = anchorEl.getBoundingClientRect();
    popup.style.top = (rect.bottom + 6) + 'px';
    popup.style.right = (window.innerWidth - rect.right) + 'px';

    document.body.appendChild(popup);
    cc_enginePopupVisible = true;
}

/* Removes the engine popup if present and clears the visibility flag.
   Idempotent: safe to call when no popup exists. */
function cc_closeEnginePopup() {
    var existing = document.querySelector('.cc-engine-popup');
    if (existing) existing.remove();
    cc_enginePopupVisible = false;
}

/* ============================================================================
   CHROME: RECONNECTION GRACE PERIOD
   ----------------------------------------------------------------------------
   Reconnection-state escalation: while the WebSocket is reconnecting, a
   grace-period timer checks every second whether the configured grace has
   elapsed and escalates the banner from 'reconnecting' (blue, friendly)
   to 'disconnected' (red, alarm) if reconnect has not succeeded in time.
   Prefix: cc
   ============================================================================ */

/* Checks whether the reconnection grace period has expired. Called every
   1 second while in the 'reconnecting' state by the
   cc_engineReconnectCheckTimer interval. */
function cc_checkReconnectGrace() {
    if (cc_engineConnectionState !== 'reconnecting') {
        if (cc_engineReconnectCheckTimer) {
            clearInterval(cc_engineReconnectCheckTimer);
            cc_engineReconnectCheckTimer = null;
        }
        return;
    }

    var elapsed = (Date.now() - cc_engineReconnectStart) / 1000;
    if (elapsed >= cc_engineReconnectGraceSec) {
        cc_engineConnectionState = 'disconnected';
        if (cc_engineReconnectCheckTimer) {
            clearInterval(cc_engineReconnectCheckTimer);
            cc_engineReconnectCheckTimer = null;
        }
        cc_updateConnectionBanner();
    }
}

/* Loads the reconnect grace period from GlobalConfig. Reuses the
   refresh-interval API which looks up ControlCenter | refresh_{page}_seconds.
   Setting name: ControlCenter | reconnect_grace_seconds (loaded directly,
   not via the refresh_* pattern - uses a dedicated fetch).
   Non-blocking - uses default if unavailable. */
function cc_loadReconnectGraceConfig() {
    fetch('/api/config/refresh-interval?page=reconnect_grace')
        .then(cc_parseConfigResponse)
        .then(cc_applyReconnectGraceConfig)
        .catch(cc_ignoreConfigError);
}

/* Parses a refresh-interval API response, returning the JSON body on OK
   or null on non-OK. Shared between the reconnect-grace and idle-timeout
   config loaders. */
function cc_parseConfigResponse(r) {
    return r.ok ? r.json() : null;
}

/* Applies a parsed reconnect-grace config response to
   cc_engineReconnectGraceSec. Only overwrites the default if the
   response carries a non-default interval. */
function cc_applyReconnectGraceConfig(data) {
    if (data && data.interval && !data.default) {
        cc_engineReconnectGraceSec = data.interval;
    }
}

/* Swallows errors from the refresh-interval API. Config load failure is
   non-fatal: the default value remains in effect. */
function cc_ignoreConfigError() {
    /* Use default. */
}

/* ============================================================================
   CHROME: CONNECTION BANNER
   ----------------------------------------------------------------------------
   Manages the connection status banner that replaces the old red error
   banner during server restarts and session expiry. Four states: hidden,
   reconnecting (blue), disconnected (red), expired (amber with sign-in
   link).
   Prefix: cc
   ============================================================================ */

/* Manages the connection status banner that replaces the old red error
   banner during server restarts and session expiry.

   States:
   connected    - banner hidden
   reconnecting - blue "Reconnecting..." banner (non-alarming)
   disconnected - red "Connection lost" banner (grace period expired)
   expired      - amber "Session expired" banner with sign-in link */
function cc_updateConnectionBanner() {
    var el = document.getElementById('cc-connection-banner');
    if (!el) return;

    if (cc_engineSessionExpired) {
        el.className = 'cc-connection-banner cc-session-expired';
        el.innerHTML = 'Session expired \u2014 <a href="/login" class="cc-banner-link">Sign In</a>';
        return;
    }

    switch (cc_engineConnectionState) {
        case 'reconnecting':
            el.className = 'cc-connection-banner cc-reconnecting';
            el.textContent = 'Reconnecting to server\u2026';
            break;
        case 'disconnected':
            el.className = 'cc-connection-banner cc-disconnected';
            el.textContent = 'Connection lost \u2014 server may be unavailable';
            break;
        default:
            el.className = 'cc-connection-banner';
            el.textContent = '';
    }
}

/* Shows a brief "Reconnected" message before auto-reloading. Called by
   cc_handleEngineWsOpen when the open follows a reconnect. */
function cc_showReloadingBanner() {
    var el = document.getElementById('cc-connection-banner');
    if (!el) return;
    el.className = 'cc-connection-banner cc-reloading';
    el.textContent = 'Server reconnected \u2014 reloading\u2026';
}

/* ============================================================================
   CHROME: SHARED FETCH WRAPPER
   ----------------------------------------------------------------------------
   The cc_engineFetch() wrapper that every Control Center API call should
   use instead of raw fetch(). It centralizes visibility-aware skipping,
   idle pausing, session-expiry detection, and error normalization so
   callers never have to reimplement those concerns.
   Prefix: cc
   ============================================================================ */

/* Shared fetch wrapper for all Control Center API calls.
   Handles:
   - Page visibility: skips fetch when tab is hidden (returns null)
   - Session expiry: detects 302 redirect to login or HTML response,
     stops all polling, shows session-expired banner
   - JSON parsing: returns parsed data directly
   - Error propagation: throws on network/server errors for caller catch blocks

   Usage (replaces raw fetch):
     // Before:
     var response = await fetch('/api/endpoint');
     var data = await response.json();

     // After:
     var data = await cc_engineFetch('/api/endpoint');
     if (!data) return;  // hidden tab or session expired

   For POST requests:
     var data = await cc_engineFetch('/api/endpoint', {
         method: 'POST',
         headers: { 'Content-Type': 'application/json' },
         body: JSON.stringify(payload)
     }); */
async function cc_engineFetch(url, options) {
    /* Skip if tab is hidden (polling calls are wasted effort). */
    if (cc_enginePageHidden) return null;

    /* Skip if session is already known to be expired. */
    if (cc_engineSessionExpired) return null;

    /* Skip if idle-paused. */
    if (cc_engineIdlePaused) return null;

    var response;
    try {
        response = await fetch(url, options);
    } catch (err) {
        /* Network error - server probably down. */
        throw err;
    }

    /* Detect auth redirect: Pode returns 302 to /login, but fetch follows
       redirects automatically, so we get a 200 with HTML content from
       /login. Check if we got redirected to the login page. */
    if (response.redirected && response.url && response.url.indexOf('/login') !== -1) {
        cc_handleSessionExpired();
        return null;
    }

    /* Also check content-type - if we asked for JSON but got HTML, the
       session is gone. */
    var contentType = response.headers.get('content-type') || '';
    if (!contentType.includes('application/json') && response.ok) {
        /* Got a 200 but with HTML - likely the login page served after
           redirect. */
        var bodySnippet = await response.text();
        if (bodySnippet.indexOf('Sign in with your network credentials') !== -1 ||
            bodySnippet.indexOf('<title>Login') !== -1) {
            cc_handleSessionExpired();
            return null;
        }
        /* Not login page - might be a legitimate non-JSON response. */
        throw new Error('Unexpected response type: ' + contentType);
    }

    if (!response.ok) {
        var errBody;
        try {
            errBody = await response.json();
        } catch (e) {
            errBody = null;
        }
        var errMsg = (errBody && errBody.Error) ? errBody.Error : 'HTTP ' + response.status;
        throw new Error(errMsg);
    }

    return await response.json();
}

/* Handles session expiry: stops all polling, shows the sign-in banner.
   Idempotent - second and later calls are no-ops because the
   cc_engineSessionExpired flag is set on the first call. */
function cc_handleSessionExpired() {
    if (cc_engineSessionExpired) return;
    cc_engineSessionExpired = true;

    /* Stop WebSocket reconnect. */
    if (cc_engineReconnectTimer) {
        clearTimeout(cc_engineReconnectTimer);
        cc_engineReconnectTimer = null;
    }

    /* Close WebSocket. */
    if (cc_engineWs) {
        try {
            cc_engineWs.close();
        } catch (e) {
            /* Ignore - close on an already-closed socket throws on some
               browsers. */
        }
    }

    /* Stop engine tick timer. */
    if (cc_engineTickTimer) {
        clearInterval(cc_engineTickTimer);
        cc_engineTickTimer = null;
    }

    /* Stop reconnect grace check. */
    if (cc_engineReconnectCheckTimer) {
        clearInterval(cc_engineReconnectCheckTimer);
        cc_engineReconnectCheckTimer = null;
    }

    /* Notify the page to stop its own polling. */
    var onSessionExpired = window[cc_pagePrefix + '_onSessionExpired'];
    if (typeof onSessionExpired === 'function') {
        try {
            onSessionExpired();
        } catch (e) {
            console.error('[cc-shared] ' + cc_pagePrefix + '_onSessionExpired error:', e);
        }
    }

    cc_updateConnectionBanner();
    console.log('[cc-shared] Session expired - polling stopped');
}

/* ============================================================================
   CHROME: IDLE DETECTION
   ----------------------------------------------------------------------------
   Pauses polling after a configurable period of user inactivity, resumes
   on the next interaction. The overlay element gives the user a visible
   signal that polling is suspended and dismisses on movement.
   Prefix: cc
   ============================================================================ */

/* Called on any user interaction. Resets the idle timer and resumes
   polling if it was paused due to inactivity. */
function cc_onUserActivity() {
    cc_engineLastActivity = Date.now();

    if (cc_engineIdlePaused) {
        cc_engineIdlePaused = false;
        cc_hideIdleOverlay();

        /* Resume if not hidden and not expired. */
        if (!cc_enginePageHidden && !cc_engineSessionExpired) {
            /* Reconnect WebSocket if needed. */
            if (!cc_engineConnected && cc_engineWs &&
                cc_engineWs.readyState !== WebSocket.OPEN &&
                cc_engineWs.readyState !== WebSocket.CONNECTING) {
                cc_openEngineWebSocket();
            }

            var onPageResumed = window[cc_pagePrefix + '_onPageResumed'];
            if (typeof onPageResumed === 'function') {
                try {
                    onPageResumed();
                } catch (e) {
                    console.error('[cc-shared] ' + cc_pagePrefix + '_onPageResumed error:', e);
                }
            }
        }
    }
}

/* Checks whether the idle timeout has been exceeded. Called every 10
   seconds by the cc_engineIdleCheckTimer interval. */
function cc_checkIdleTimeout() {
    if (cc_engineIdlePaused || cc_engineSessionExpired || cc_enginePageHidden) return;

    var elapsed = (Date.now() - cc_engineLastActivity) / 1000;
    if (elapsed >= cc_engineIdleTimeoutSec) {
        cc_engineIdlePaused = true;
        cc_showIdleOverlay();
        console.log('[cc-shared] Idle timeout - polling paused');
    }
}

/* Loads idle timeout from GlobalConfig via the refresh-interval API.
   Non-blocking - uses default if unavailable. */
function cc_loadIdleTimeoutConfig() {
    fetch('/api/config/refresh-interval?page=idle_timeout')
        .then(cc_parseConfigResponse)
        .then(cc_applyIdleTimeoutConfig)
        .catch(cc_ignoreConfigError);
}

/* Applies a parsed idle-timeout config response to cc_engineIdleTimeoutSec.
   Only overwrites the default if the response carries a non-default
   interval. */
function cc_applyIdleTimeoutConfig(data) {
    if (data && data.interval && !data.default) {
        cc_engineIdleTimeoutSec = data.interval;
    }
}

/* Shows a subtle overlay indicating polling is paused. Idempotent: a
   second call while the overlay is already up is a no-op. */
function cc_showIdleOverlay() {
    if (document.querySelector('.cc-idle-overlay')) return;

    var overlay = document.createElement('div');
    overlay.className = 'cc-idle-overlay';
    overlay.innerHTML = '<div class="cc-idle-message">Paused \u2014 move mouse to resume</div>';
    document.body.appendChild(overlay);
}

/* Removes the idle overlay if present. Idempotent: safe to call when
   no overlay exists. */
function cc_hideIdleOverlay() {
    var overlay = document.querySelector('.cc-idle-overlay');
    if (overlay) overlay.remove();
}

/* ============================================================================
   CHROME: SHARED FORMATTING
   ----------------------------------------------------------------------------
   Cross-page formatting and value-coercion utilities. Pages should use
   these instead of defining their own variants - the spec relies on
   single-source ownership of platform formatters so a downstream change
   (e.g. locale handling) propagates everywhere at once.
   Prefix: cc
   ============================================================================ */

/* DOM-safe HTML escaping. Returns the escaped form of any value, safe to
   insert into innerHTML without enabling XSS.

   Public utility - pages should NOT define their own escapeHtml(); use
   this one. Handles null/undefined by returning empty string.

   @param {*} val - any value (string preferred, others coerced via String())
   @returns {string} HTML-safe string */
function cc_escapeHtml(val) {
    if (val == null) return '';
    var div = document.createElement('div');
    div.textContent = String(val);
    return div.innerHTML;
}

/* Renders a timestamp value as a locale time string. Accepts:
   - ISO 8601 strings: "2026-04-30T18:50:09Z"
   - .NET /Date(ms)/ format: "/Date(1714501809000)/"
   - Date objects
   - null/undefined (returns '-')
   - Unparseable values (returns '-')

   Output format: "1:23 PM" (locale-dependent)

   Public utility - pages should use this instead of defining their own
   formatTime() variants. The function tolerates the assortment of
   timestamp shapes that come back from different APIs across the
   platform.

   @param {*} val - timestamp in any supported form
   @returns {string} formatted time of day, or '-' if unparseable */
function cc_formatTimeOfDay(val) {
    if (!val) return '-';

    var d;
    if (val instanceof Date) {
        d = val;
    } else {
        var s = String(val);
        /* .NET /Date(ms)/ format. */
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

/* Null-safe parseInt. Returns 0 for null/undefined/empty/NaN/'DBNull'.
   Useful for displaying SQL Server numeric columns that may come back as
   any of those values when the underlying data is missing.

   @param {*} val - any value
   @returns {number} integer, or 0 on bad input */
function cc_safeInt(val) {
    if (val == null || val === '' || val === 'DBNull') return 0;
    var n = parseInt(val, 10);
    return isNaN(n) ? 0 : n;
}

/* Null-safe parseFloat. Returns 0 for null/undefined/empty/NaN/'DBNull'.
   Companion to cc_safeInt; same rationale.

   @param {*} val - any value
   @returns {number} float, or 0 on bad input */
function cc_safeFloat(val) {
    if (val == null || val === '' || val === 'DBNull') return 0;
    var n = parseFloat(val);
    return isNaN(n) ? 0 : n;
}

/* Formats a duration in seconds as a human-readable elapsed string.
   <60s     -> "Xs"
   <60m     -> "Xm"
   <24h     -> "Xh Xm"
   >=1d     -> "Xd Xh"

   Public utility - used wherever "time since" is displayed, e.g.,
   "last run X ago" indicators on collector status cards.

   @param {number} seconds - elapsed seconds
   @returns {string} formatted string */
function cc_formatTimeSince(seconds) {
    var s = cc_safeInt(seconds);
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

/* Formats a duration in minutes as a human-readable age string.
   <60m     -> "Xm"
   <24h     -> "Xh Xm"
   >=1d     -> "Xd Xh"

   Companion to cc_formatTimeSince but takes minutes instead of seconds.
   Used wherever batch/record age is displayed.

   @param {number} minutes - elapsed minutes
   @returns {string} formatted string */
function cc_formatAge(minutes) {
    var m = cc_safeInt(minutes);
    if (m < 60) return m + 'm';
    var h = Math.floor(m / 60);
    m = m % 60;
    if (h < 24) return h + 'h ' + m + 'm';
    var d = Math.floor(h / 24);
    h = h % 24;
    return d + 'd ' + h + 'h';
}

/* Formats a countdown value (positive or negative seconds) as an
   m:ss string, escalating to h Xm when the value crosses one hour. The
   sign is the caller's concern - this function takes the absolute value
   and floors. Used by cc_tickEngineIndicator to render the engine-cd
   element. */
function cc_fmtEngineCountdown(s) {
    var a = Math.abs(Math.floor(s));
    var m = Math.floor(a / 60);
    var sec = a % 60;
    if (m > 60) {
        var h = Math.floor(m / 60);
        return h + 'h ' + (m % 60) + 'm';
    }
    return m + ':' + (sec < 10 ? '0' : '') + sec;
}

/* ============================================================================
   CHROME: SHARED PAGE REFRESH
   ----------------------------------------------------------------------------
   The platform-wide page-refresh handler invoked by every page's refresh
   button. Drives the spin animation on the button and delegates the
   actual data reload to the page's <prefix>_onPageRefresh hook.
   Prefix: cc
   ============================================================================ */

/* Platform-wide page refresh handler. Drives the refresh button spin
   animation and delegates the actual data reload to the page's
   <prefix>_onPageRefresh hook. Pages define <prefix>_onPageRefresh and
   never define their own pageRefresh. */
function cc_pageRefresh() {
    var btn = document.querySelector('.cc-page-refresh-btn');
    if (btn) {
        btn.classList.add('cc-page-refresh-spinning');
        btn.addEventListener('animationend', cc_clearRefreshSpin, { once: true });
    }
    var onPageRefresh = window[cc_pagePrefix + '_onPageRefresh'];
    if (typeof onPageRefresh === 'function') {
        onPageRefresh();
    }
}

/* animationend handler for the refresh button spin animation. Clears the
   spinning class so the next refresh starts the animation cleanly. Shared
   by manual refresh (cc_pageRefresh) and tab-resume
   (cc_handleVisibilityChange). */
function cc_clearRefreshSpin(e) {
    e.currentTarget.classList.remove('cc-page-refresh-spinning');
}

/* ============================================================================
   CHROME: SHARED MODALS
   ----------------------------------------------------------------------------
   Promise-returning replacements for native window.alert and
   window.confirm. Used across every Control Center page so the styled
   modal experience is consistent and so callers can chain .then() for
   async flow. Both functions append an overlay to document.body and
   resolve when the user acts.

   Generated markup is the modal overlay shape: an outer cc-modal-overlay
   (full-viewport dimmer that flex-centers its content) containing one
   nested .cc-dialog.cc-dialog-modal with cc-dialog-header, cc-dialog-body,
   and cc-dialog-actions children.

   Usage:
     cc_showAlert('File not found.', { title: 'Error' });

     cc_showConfirm('Delete this item?', {
         title: 'Confirm Delete',
         confirmLabel: 'Delete',
         confirmClass: 'cc-dialog-btn-danger'
     }).then(function(confirmed) { if (confirmed) { ... } });

     // For HTML content in the body:
     cc_showConfirm('<p>Rich <strong>HTML</strong> content</p>', { html: true, ... });
   Prefix: cc
   ============================================================================ */

/* Promise-returning replacement for native alert(). Appends an overlay
   modal to document.body, focuses the OK button, and resolves the
   returned promise when the user clicks OK. Options: title, buttonLabel. */
function cc_showAlert(message, options) {
    var opts = options || {};
    var title = opts.title || 'Notice';
    var buttonLabel = opts.buttonLabel || 'OK';

    return new Promise(function(resolve) {
        var id = 'cc-alert-' + Date.now();
        var overlay = document.createElement('div');
        overlay.id = id;
        overlay.className = 'cc-modal-overlay';
        overlay.innerHTML = '<div class="cc-dialog cc-dialog-modal">'
            + '<div class="cc-dialog-header">'
            + '<h3 class="cc-dialog-title">' + cc_escapeHtml(title) + '</h3>'
            + '</div>'
            + '<div class="cc-dialog-body">'
            + '<p class="cc-dialog-paragraph cc-last">' + cc_escapeHtml(message) + '</p>'
            + '</div>'
            + '<div class="cc-dialog-actions">'
            + '<button class="cc-dialog-btn-primary" id="' + id + '-ok">' + cc_escapeHtml(buttonLabel) + '</button>'
            + '</div>'
            + '</div>';
        document.body.appendChild(overlay);

        /* Wire the OK button via addEventListener; inline onclick is a
           forbidden pattern. */
        var okBtn = document.getElementById(id + '-ok');
        okBtn.addEventListener('click', function() {
            overlay.remove();
            resolve();
        });
        okBtn.focus();
    });
}

/* Promise-returning replacement for native confirm(). Appends an overlay
   modal to document.body and resolves the returned promise with true on
   confirm, false on cancel. Options: title, confirmLabel, cancelLabel,
   confirmClass, html. The html option, when true, lets the message string
   render as raw HTML (used for richer confirmation prompts). */
function cc_showConfirm(message, options) {
    var opts = options || {};
    var title = opts.title || 'Confirm';
    var confirmLabel = opts.confirmLabel || 'Continue';
    var cancelLabel = opts.cancelLabel || 'Cancel';
    var confirmClass = opts.confirmClass || 'cc-dialog-btn-primary';
    var messageHtml = opts.html || false;

    return new Promise(function(resolve) {
        var id = 'cc-confirm-' + Date.now();
        var overlay = document.createElement('div');
        overlay.id = id;
        overlay.className = 'cc-modal-overlay';
        var bodyContent = messageHtml
            ? message
            : '<p class="cc-dialog-paragraph cc-last">' + cc_escapeHtml(message) + '</p>';
        overlay.innerHTML = '<div class="cc-dialog cc-dialog-modal">'
            + '<div class="cc-dialog-header">'
            + '<h3 class="cc-dialog-title">' + cc_escapeHtml(title) + '</h3>'
            + '</div>'
            + '<div class="cc-dialog-body">' + bodyContent + '</div>'
            + '<div class="cc-dialog-actions">'
            + '<button class="cc-dialog-btn-cancel" id="' + id + '-cancel">' + cc_escapeHtml(cancelLabel) + '</button>'
            + '<button class="' + confirmClass + '" id="' + id + '-ok">' + cc_escapeHtml(confirmLabel) + '</button>'
            + '</div>'
            + '</div>';
        document.body.appendChild(overlay);

        /* Wire the cancel and OK buttons via addEventListener; inline
           onclick is a forbidden pattern. */
        document.getElementById(id + '-cancel').addEventListener('click', function() {
            overlay.remove();
            resolve(false);
        });
        document.getElementById(id + '-ok').addEventListener('click', function() {
            overlay.remove();
            resolve(true);
        });
    });
}

/* ============================================================================
   CHROME: REDACTION
   ----------------------------------------------------------------------------
   The shared profanity redaction modal, surfaced via the cc-open-redaction
   click action on the Business Services and Applications & Integration pages.
   cc_openRedaction builds and appends the modal; the search drives
   /api/.../redaction-search through the page's own slug, the operator selects
   a candidate event, reviews and optionally edits the redaction and review
   messages, confirms via cc_showConfirm, and cc_redactionApply posts to
   /api/.../redaction-apply. All markup is built here (the dynamic-modal
   pattern shared with cc_showAlert / cc_showConfirm); the cc-redaction-*
   content classes live in cc-shared.css. The API base path is derived from
   the page's data-cc-page slug so one shared implementation serves every page
   that surfaces the tool.
   Prefix: cc
   ============================================================================ */

/* Resolves the redaction API base path for the current page from the body's
   data-cc-page slug, so the shared modal posts to the page's own endpoints. */
function cc_redactionApiBase() {
    var slug = document.body.dataset.ccPage || '';
    return '/api/' + slug;
}

/* Builds and appends the redaction modal overlay to document.body, wires its
   controls, and focuses the search input. Dispatched from the cc-open-redaction
   click action. */
function cc_openRedaction() {
    if (document.getElementById('cc-modal-redaction')) {
        return;
    }

    var overlay = document.createElement('div');
    overlay.id = 'cc-modal-redaction';
    overlay.className = 'cc-modal-overlay';
    overlay.innerHTML = cc_redactionModalHtml();
    document.body.appendChild(overlay);

    overlay.addEventListener('click', function(event) {
        if (event.target === overlay) {
            cc_closeRedaction();
        }
    });

    document.getElementById('cc-redaction-close').addEventListener('click', cc_closeRedaction);
    document.getElementById('cc-redaction-tab-id').addEventListener('click', function() {
        cc_redactionSetMode('id');
    });
    document.getElementById('cc-redaction-tab-consumer').addEventListener('click', function() {
        cc_redactionSetMode('consumer');
    });
    document.getElementById('cc-redaction-search-btn').addEventListener('click', cc_redactionSearch);

    cc_redactionSetMode('id');
}

/* Returns the inner HTML for the redaction modal dialog. The body holds the
   search controls and an empty results/detail region the handlers populate. */
function cc_redactionModalHtml() {
    return '<div class="cc-dialog cc-dialog-modal cc-wide">'
        + '<div class="cc-dialog-header">'
        + '<h3 class="cc-dialog-title">Profanity Redaction</h3>'
        + '<button class="cc-dialog-close" id="cc-redaction-close">&times;</button>'
        + '</div>'
        + '<div class="cc-dialog-body">'
        + '<div class="cc-redaction-search">'
        + '<div class="cc-redaction-mode-tabs">'
        + '<button class="cc-redaction-mode-tab" id="cc-redaction-tab-id">By Event ID</button>'
        + '<button class="cc-redaction-mode-tab" id="cc-redaction-tab-consumer">By Consumer + Date</button>'
        + '</div>'
        + '<div class="cc-redaction-input-row" id="cc-redaction-inputs"></div>'
        + '</div>'
        + '<div id="cc-redaction-results-region"></div>'
        + '<div id="cc-redaction-detail-region"></div>'
        + '</div>'
        + '</div>';
}

/* Switches the search mode between 'id' and 'consumer', updates the active tab
   styling, and renders the matching input fields. Clears any prior results and
   detail so a mode switch starts clean. */
function cc_redactionSetMode(mode) {
    var idTab = document.getElementById('cc-redaction-tab-id');
    var consumerTab = document.getElementById('cc-redaction-tab-consumer');
    idTab.classList.toggle('cc-active', mode === 'id');
    consumerTab.classList.toggle('cc-active', mode === 'consumer');

    var inputs = document.getElementById('cc-redaction-inputs');
    if (mode === 'id') {
        inputs.innerHTML = '<div class="cc-redaction-field">'
            + '<span class="cc-redaction-label">Event ID</span>'
            + '<input type="text" class="cc-redaction-input" id="cc-redaction-log-id" placeholder="cnsmr_accnt_ar_log_id">'
            + '</div>'
            + '<button class="cc-dialog-btn-primary" id="cc-redaction-search-btn">Search</button>';
    } else {
        inputs.innerHTML = '<div class="cc-redaction-field">'
            + '<span class="cc-redaction-label">Consumer ID</span>'
            + '<input type="text" class="cc-redaction-input" id="cc-redaction-agency-id" placeholder="Agency consumer id">'
            + '</div>'
            + '<div class="cc-redaction-field">'
            + '<span class="cc-redaction-label">Event Date</span>'
            + '<input type="date" class="cc-redaction-input" id="cc-redaction-event-date">'
            + '</div>'
            + '<button class="cc-dialog-btn-primary" id="cc-redaction-search-btn">Search</button>';
    }

    document.getElementById('cc-redaction-search-btn').addEventListener('click', cc_redactionSearch);
    document.getElementById('cc-redaction-results-region').innerHTML = '';
    document.getElementById('cc-redaction-detail-region').innerHTML = '';
}

/* Reads the active search inputs, posts to the redaction-search endpoint, and
   renders the candidate results. Shows an inline status while in flight and on
   error. */
function cc_redactionSearch() {
    var idInput = document.getElementById('cc-redaction-log-id');
    var mode = idInput ? 'id' : 'consumer';
    var payload = { mode: mode };

    if (mode === 'id') {
        var logId = idInput.value.trim();
        if (!logId) {
            return;
        }
        payload.log_id = logId;
    } else {
        var agencyId = document.getElementById('cc-redaction-agency-id').value.trim();
        var eventDate = document.getElementById('cc-redaction-event-date').value;
        if (!agencyId || !eventDate) {
            return;
        }
        payload.agency_id = agencyId;
        payload.event_date = eventDate;
    }

    var resultsRegion = document.getElementById('cc-redaction-results-region');
    var detailRegion = document.getElementById('cc-redaction-detail-region');
    detailRegion.innerHTML = '';
    resultsRegion.innerHTML = '<div class="cc-redaction-status">Searching...</div>';

    cc_engineFetch(cc_redactionApiBase() + '/redaction-search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    })
        .then(function(data) {
            if (!data) {
                return;
            }
            if (data.error) {
                resultsRegion.innerHTML = '<div class="cc-redaction-status cc-error">' + cc_escapeHtml(data.error) + '</div>';
                return;
            }
            cc_redactionRenderResults(data.events || []);
        })
        .catch(function(err) {
            resultsRegion.innerHTML = '<div class="cc-redaction-status cc-error">Search failed: ' + cc_escapeHtml(err.message) + '</div>';
        });
}

/* Renders the candidate result rows into the results region. Each row shows the
   event id, its action/result codes, a likely-target flag for the non-standard
   reply codes, and a message preview. Clicking a row selects it for redaction. */
function cc_redactionRenderResults(events) {
    var resultsRegion = document.getElementById('cc-redaction-results-region');

    if (!events.length) {
        resultsRegion.innerHTML = '<div class="cc-redaction-status">No matching events found.</div>';
        return;
    }

    var html = '<div class="cc-redaction-results-caption">' + events.length + ' event(s) found. Select the event to redact:</div>';
    html += '<div class="cc-redaction-results">';
    events.forEach(function(ev) {
        var likely = ev.is_likely ? ' cc-likely' : '';
        var badge = ev.is_likely ? '<span class="cc-redaction-likely-badge">Likely</span>' : '';
        html += '<div class="cc-redaction-result-row' + likely + '">'
            + '<div class="cc-redaction-result-head">'
            + '<span class="cc-redaction-result-id">' + cc_escapeHtml(String(ev.log_id)) + '</span>'
            + '<span>actn ' + cc_escapeHtml(String(ev.actn_cd)) + ' / rslt ' + cc_escapeHtml(String(ev.rslt_cd)) + '</span>'
            + badge
            + '</div>'
            + '<div class="cc-redaction-result-preview">' + cc_escapeHtml(ev.message || '') + '</div>'
            + '</div>';
    });
    html += '</div>';
    resultsRegion.innerHTML = html;

    var rows = resultsRegion.querySelectorAll('.cc-redaction-result-row');
    Array.prototype.forEach.call(rows, function(row, index) {
        row.addEventListener('click', function() {
            cc_redactionSelect(events[index], rows, row);
        });
    });
}

/* Marks the clicked result row as selected and renders the redaction detail:
   the event's current message read-only, plus the editable redaction and review
   message fields pre-filled with their defaults. */
function cc_redactionSelect(ev, rows, selectedRow) {
    Array.prototype.forEach.call(rows, function(r) {
        r.classList.remove('cc-selected');
    });
    selectedRow.classList.add('cc-selected');

    var reviewDefault = 'Non-standard vulgar text reviewed: ID: ' + ev.log_id;

    var detailRegion = document.getElementById('cc-redaction-detail-region');
    detailRegion.innerHTML = '<div class="cc-redaction-detail">'
        + '<div class="cc-redaction-message-field">'
        + '<span class="cc-redaction-label">Current Message</span>'
        + '<div class="cc-redaction-current">' + cc_escapeHtml(ev.message || '') + '</div>'
        + '</div>'
        + '<div class="cc-redaction-message-field">'
        + '<span class="cc-redaction-label">Redaction Message (Redacted Event)</span>'
        + '<textarea class="cc-redaction-textarea" id="cc-redaction-body"></textarea>'
        + '</div>'
        + '<div class="cc-redaction-message-field">'
        + '<span class="cc-redaction-label">Review Message (New Event)</span>'
        + '<textarea class="cc-redaction-textarea" id="cc-redaction-review"></textarea>'
        + '</div>'
        + '<div class="cc-dialog-actions">'
        + '<button class="cc-dialog-btn-danger" id="cc-redaction-apply-btn">Redact Event</button>'
        + '</div>'
        + '</div>';

    document.getElementById('cc-redaction-body').value = cc_REDACTION_DEFAULT_BODY;
    document.getElementById('cc-redaction-review').value = reviewDefault;
    document.getElementById('cc-redaction-apply-btn').addEventListener('click', function() {
        cc_redactionApply(ev.log_id);
    });
}

/* Confirms the redaction via cc_showConfirm, then posts the log id and the
   edited redaction and review messages to the redaction-apply endpoint. On
   success notifies via cc_showAlert and closes the modal; on error surfaces the
   message via cc_showAlert. */
function cc_redactionApply(logId) {
    var redactionBody = document.getElementById('cc-redaction-body').value;
    var reviewMessage = document.getElementById('cc-redaction-review').value;

    cc_showConfirm('<p class="cc-dialog-paragraph cc-last">Redact this event? This updates the live Debt Manager record and cannot be undone.</p>', {
        html: true,
        title: 'Confirm Redaction',
        confirmLabel: 'Redact',
        confirmClass: 'cc-dialog-btn-danger'
    }).then(function(confirmed) {
        if (!confirmed) {
            return;
        }
        cc_engineFetch(cc_redactionApiBase() + '/redaction-apply', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                log_id: logId,
                redaction_body: redactionBody,
                review_message: reviewMessage
            })
        })
            .then(function(data) {
                if (!data) {
                    return;
                }
                if (data.error) {
                    cc_showAlert('Redaction failed: ' + data.error, { title: 'Error' });
                    return;
                }
                cc_closeRedaction();
                cc_showAlert('Event redacted and review event recorded.', { title: 'Redaction Complete' });
            })
            .catch(function(err) {
                cc_showAlert('Redaction failed: ' + err.message, { title: 'Error' });
            });
    });
}

/* Removes the redaction modal overlay from document.body. Wired from the close
   button and a backdrop click. */
function cc_closeRedaction() {
    var overlay = document.getElementById('cc-modal-redaction');
    if (overlay) {
        overlay.remove();
    }
}
