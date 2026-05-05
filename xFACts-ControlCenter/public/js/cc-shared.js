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
   page-refresh hook, and the styled alert/confirm modals.

   This file is the canonical FOUNDATION and CHROME source for the platform.
   Per Section 4.4 of CC_JS_Spec.md, no other file may declare FOUNDATION or
   CHROME banners; cc-shared.js holds single-source ownership.

   FILE ORGANIZATION
   -----------------
   FOUNDATION: SHARED CONSTANTS
   STATE: ENGINE STATE
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
   ============================================================================ */

/* ============================================================================
   FOUNDATION: SHARED CONSTANTS
   ----------------------------------------------------------------------------
   Platform-wide constant lookups and threshold defaults. The MONTH_NAMES and
   DAY_NAMES values are 1-indexed to map directly from SQL DATEPART results
   and JavaScript Date methods without subtraction. The ENGINE_* threshold
   values are sensible defaults; pages do not override them, but the
   reconnection grace period and idle timeout are tunable via GlobalConfig
   and overwrite their corresponding STATE variables on load.
   Prefix: (none)
   ============================================================================ */

/* Month names lookup, 1-indexed so SQL month_num and JS Date month numbers
   map directly. The empty string at index 0 is intentional padding; without
   it every caller would have to remember to subtract 1, which is error-prone
   and easy to forget. Read as MONTH_NAMES[1] === 'January'. */
const MONTH_NAMES = ['', 'January', 'February', 'March', 'April', 'May', 'June',
                     'July', 'August', 'September', 'October', 'November', 'December'];

/* Day-of-week names lookup, 3-letter form, keyed by SQL DATEPART(dw, ...)
   values: 1=Sunday through 7=Saturday. Stored as an object literal rather
   than an array because day-of-week lookups in this codebase are always
   keyed access (DAY_NAMES[dayNum]), never iteration. Read as
   DAY_NAMES[1] === 'Sun'. */
const DAY_NAMES = { 1: 'Sun', 2: 'Mon', 3: 'Tue', 4: 'Wed', 5: 'Thu', 6: 'Fri', 7: 'Sat' };

/* Default day-of-week display order, Sun through Sat. Pages that need a
   different ordering (e.g. Mon-first regional preference) define their own
   local order array; this is the platform default. */
const DAY_ORDER = [1, 2, 3, 4, 5, 6, 7];

/* Engine card grace window in seconds. While the countdown is in [0, -GRACE]
   range the indicator stays green and counts up rather than escalating. */
const ENGINE_GRACE_SEC = 30;

/* Delay between WebSocket reconnect attempts, in seconds. */
const ENGINE_RECONNECT_SEC = 3;

/* Countdown ticker interval in milliseconds. */
const ENGINE_TICK_MS = 1000;

/* ============================================================================
   STATE: ENGINE STATE
   ----------------------------------------------------------------------------
   Module-scope mutable state for the engine indicator, WebSocket lifecycle,
   reconnection grace period, session-expiry detection, and idle pause
   subsystems. These are var bindings rather than const because every value
   here is mutated during the page's lifetime. Pages do not read or write
   these directly; the chrome functions below are the only legitimate
   accessors.
   Prefix: (none)
   ============================================================================ */

/* The active WebSocket instance for engine events, or null when not yet
   connected or after a clean shutdown. */
var engineWs = null;

/* setTimeout handle for the next reconnect attempt, or null when no
   reconnect is scheduled. */
var engineReconnectTimer = null;

/* setInterval handle for the 1-second countdown ticker, or null when the
   ticker is not running (e.g. after handleSessionExpired). */
var engineTickTimer = null;

/* Per-slug engine indicator state. Each entry holds { lastEvent, countdown,
   lastRefresh } for one process. Populated in connectEngineEvents from the
   page's ENGINE_PROCESSES map and updated on every WebSocket event. */
var engineState = {};

/* Whether the WebSocket is currently in the OPEN state. Tracked separately
   from engineWs.readyState so consumers can read it synchronously without
   a feature-detect dance. */
var engineConnected = false;

/* Whether the engine card popup is currently visible. Used to avoid
   stacking popups and to drive the click-outside dismiss handler. */
var enginePopupVisible = false;

/* Whether the page is currently hidden via the Page Visibility API. Used to
   suppress reconnect attempts and skip polling fetches on hidden tabs. */
var enginePageHidden = false;

/* Reconnection grace period in seconds. Starts at the safe default and is
   overwritten by loadReconnectGraceConfig with the GlobalConfig value if
   one is configured. */
var engineReconnectGraceSec = 60;

/* Timestamp (ms) at which the WebSocket entered the reconnecting state.
   null when not reconnecting; checked by checkReconnectGrace to decide
   when to escalate to the disconnected state. */
var engineReconnectStart = null;

/* Current connection-banner state: one of 'connected', 'reconnecting',
   'disconnected', 'expired'. Drives the styling and content of the
   connection banner. */
var engineConnectionState = 'connected';

/* setInterval handle for the reconnection grace check, or null when no
   reconnection is in progress. */
var engineReconnectCheckTimer = null;

/* Whether the session has been detected as expired (auth cookie lost,
   server returned login page). Once true, all polling and reconnects stop
   permanently for this page load. */
var engineSessionExpired = false;

/* Idle timeout in seconds. Starts at the safe default and is overwritten
   by loadIdleTimeoutConfig with the GlobalConfig value if one is
   configured. */
var engineIdleTimeoutSec = 300;

/* Timestamp (ms) of the last user interaction. Compared against
   engineIdleTimeoutSec by checkIdleTimeout to decide whether to pause
   polling. */
var engineLastActivity = Date.now();

/* Whether polling is currently paused due to user inactivity. Reset by
   onUserActivity on the next interaction. */
var engineIdlePaused = false;

/* setInterval handle for the periodic idle-timeout check. */
var engineIdleCheckTimer = null;

/* ============================================================================
   CHROME: INITIALIZATION
   ----------------------------------------------------------------------------
   The single platform-wide entry point that pages call from their
   DOMContentLoaded handler. Wires up the WebSocket, loads bootstrap state,
   starts the countdown ticker, registers the visibility/idle/escape-key
   listeners, and primes the connection banner.
   Prefix: (none)
   ============================================================================ */

/* Main entry point - call from page's DOMContentLoaded. Connects the
   WebSocket, loads initial state, and starts the countdown ticker. Pages
   define their own ENGINE_PROCESSES map before this script loads so the
   bootstrap fetch knows which slugs to populate. */
function connectEngineEvents() {
    if (typeof ENGINE_PROCESSES === 'undefined' || !ENGINE_PROCESSES) {
        console.warn('ENGINE_PROCESSES not defined - engine events disabled');
        return;
    }

    /* Initialize per-slug state for each configured process. */
    Object.keys(ENGINE_PROCESSES).forEach(function(procName) {
        var slug = ENGINE_PROCESSES[procName].slug;
        engineState[slug] = {
            lastEvent: null,
            countdown: null,
            lastRefresh: null
        };
    });

    /* Load the reconnect grace period from GlobalConfig in the background. */
    loadReconnectGraceConfig();

    /* Load bootstrap state from the REST endpoint, then connect the WebSocket. */
    loadEngineBootstrap().then(function() {
        openEngineWebSocket();
    });

    /* Start the 1-second countdown ticker. */
    engineTickTimer = setInterval(tickAllEngineIndicators, ENGINE_TICK_MS);

    /* Register visibility-change handling: pause WebSocket reconnects while
       the tab is hidden, resume on visibility return. */
    document.addEventListener('visibilitychange', handleVisibilityChange);

    /* Idle detection - pause polling after inactivity, resume on interaction. */
    loadIdleTimeoutConfig();
    engineLastActivity = Date.now();

    ['mousemove', 'mousedown', 'keydown', 'touchstart', 'scroll'].forEach(function(evt) {
        document.addEventListener(evt, onUserActivity, { passive: true });
    });

    engineIdleCheckTimer = setInterval(checkIdleTimeout, 10000);

    /* Close the engine popup on Escape and on outside-click. */
    document.addEventListener('keydown', handleGlobalKeydown);
    document.addEventListener('click', handleGlobalClick);
}

/* Visibility-change handler. Pauses WebSocket reconnects on hidden, resumes
   the WebSocket and notifies the page on return. Bound by
   connectEngineEvents. */
function handleVisibilityChange() {
    if (document.visibilityState === 'hidden') {
        enginePageHidden = true;
        if (engineReconnectTimer) {
            clearTimeout(engineReconnectTimer);
            engineReconnectTimer = null;
        }
        return;
    }

    enginePageHidden = false;
    if (engineSessionExpired) return;

    /* Reconnect WebSocket if it's not already connected or connecting. */
    if (!engineConnected && engineWs &&
        engineWs.readyState !== WebSocket.OPEN &&
        engineWs.readyState !== WebSocket.CONNECTING) {
        openEngineWebSocket();
    }

    /* Notify the page so it can do an immediate data refresh. */
    if (typeof onPageResumed === 'function') {
        try {
            onPageResumed();
        } catch (e) {
            console.error('[engine-events] onPageResumed error:', e);
        }
    }
}

/* Document-level keydown handler. Closes the engine popup on Escape; other
   keys are ignored here (page-specific keydown handlers are unaffected
   because the listener is passive in spirit - it only acts on Escape and
   only when the popup is visible). */
function handleGlobalKeydown(e) {
    if (e.key === 'Escape' && enginePopupVisible) {
        closeEnginePopup();
    }
}

/* Document-level click handler. Closes the engine popup on outside-click;
   clicks inside the popup or on an engine card are ignored so the click
   that opened the popup doesn't immediately close it. */
function handleGlobalClick(e) {
    if (enginePopupVisible &&
        !e.target.closest('.engine-popup') &&
        !e.target.closest('.engine-card')) {
        closeEnginePopup();
    }
}

/* ============================================================================
   CHROME: WEBSOCKET CONNECTION
   ----------------------------------------------------------------------------
   Opens and manages the engine-events WebSocket connection. Handlers for
   open, message, close, and error are bound via addEventListener to named
   functions defined in this section. The reconnect cycle, banner state
   transitions, and post-restart auto-reload behavior live here.
   Prefix: (none)
   ============================================================================ */

/* Opens the engine-events WebSocket. No-op if a connection is already open
   or in the process of opening. Binds the four lifecycle handlers via
   addEventListener. */
function openEngineWebSocket() {
    if (engineWs &&
        (engineWs.readyState === WebSocket.OPEN ||
         engineWs.readyState === WebSocket.CONNECTING)) {
        return;
    }

    var protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    engineWs = new WebSocket(protocol + '//' + window.location.host + '/engine-events');

    engineWs.addEventListener('open', handleEngineWsOpen);
    engineWs.addEventListener('message', handleEngineWsMessage);
    engineWs.addEventListener('close', handleEngineWsClose);
    engineWs.addEventListener('error', handleEngineWsError);
}

/* WebSocket 'open' handler. Marks the connection as live, clears the
   reconnect-grace timer if one is running, updates the connection
   indicator, and triggers a brief auto-reload if the open follows a
   reconnect (so newly deployed assets get picked up). */
function handleEngineWsOpen() {
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
        /* Server came back after a restart - show brief message then
           reload to pick up any newly deployed files. */
        showReloadingBanner();
        setTimeout(reloadPage, 1500);
        return;
    }

    console.log('[engine-events] WebSocket connected');
}

/* WebSocket 'message' handler. Parses the JSON payload and dispatches to
   handleEngineEvent; unparseable payloads are logged and dropped. */
function handleEngineWsMessage(evt) {
    var event;
    try {
        event = JSON.parse(evt.data);
    } catch (e) {
        console.warn('[engine-events] Unparseable message:', evt.data);
        return;
    }

    handleEngineEvent(event);
}

/* WebSocket 'close' handler. Clears the connected flag, transitions the
   banner state into 'reconnecting' if not already there, starts the
   grace-period check, and schedules a reconnect attempt. Skips reconnects
   when the session is expired or the page is hidden. */
function handleEngineWsClose() {
    engineConnected = false;
    updateEngineConnectionIndicator(false);

    if (engineSessionExpired) return;
    if (enginePageHidden) return;

    /* Enter reconnecting state if this is the first close after connected. */
    if (engineConnectionState === 'connected') {
        engineConnectionState = 'reconnecting';
        engineReconnectStart = Date.now();
        updateConnectionBanner();

        if (!engineReconnectCheckTimer) {
            engineReconnectCheckTimer = setInterval(checkReconnectGrace, 1000);
        }
    }

    console.log('[engine-events] WebSocket closed, reconnecting in ' + ENGINE_RECONNECT_SEC + 's...');

    if (engineReconnectTimer) clearTimeout(engineReconnectTimer);
    engineReconnectTimer = setTimeout(openEngineWebSocket, ENGINE_RECONNECT_SEC * 1000);
}

/* WebSocket 'error' handler. The 'close' event always fires after 'error',
   so the actual reconnect logic runs there; this handler just maintains
   the connection indicator. */
function handleEngineWsError() {
    engineConnected = false;
    updateEngineConnectionIndicator(false);
}

/* Reloads the current page. Trivial wrapper around window.location.reload
   so the setTimeout call site can pass a named function reference rather
   than constructing an anonymous wrapper. */
function reloadPage() {
    window.location.reload();
}

/* ============================================================================
   CHROME: EVENT HANDLING
   ----------------------------------------------------------------------------
   Dispatches a parsed WebSocket event payload to the right slug's state and
   triggers the page-side hooks. Pages that need to react to specific event
   types define onEngineProcessCompleted and/or onEngineEventRaw to opt in.
   Prefix: (none)
   ============================================================================ */

/* Dispatches an engine event to its target slug, updates state, calculates
   the new countdown, fires page hooks, and refreshes the indicator. Events
   for processes the page does not list in ENGINE_PROCESSES are silently
   ignored. */
function handleEngineEvent(event) {
    /* Raw-event hook delivers every event to the page before filtering.
       Used by the Admin page to drive the process timeline from WebSocket
       events instead of polling. Most pages do not define this. */
    if (typeof onEngineEventRaw === 'function') {
        try {
            onEngineEventRaw(event);
        } catch (e) {
            console.error('[engine-events] onEngineEventRaw error:', e);
        }
    }

    /* Find which configured process this event belongs to. */
    var procConfig = ENGINE_PROCESSES[event.processName];
    if (!procConfig) return;

    var slug = procConfig.slug;
    var now = Date.now();

    engineState[slug].lastEvent = event;
    engineState[slug].lastRefresh = now;

    if (event.eventType === 'PROCESS_STARTED') {
        /* Clear the countdown - the process is actively running. */
        engineState[slug].countdown = null;
    } else if (event.eventType === 'PROCESS_COMPLETED') {
        /* Calculate the new countdown from live scheduling metadata. */
        engineState[slug].countdown = calcCountdownFromEvent(event, Date.now());

        /* Notify the page so it can refresh its data. */
        if (typeof onEngineProcessCompleted === 'function') {
            try {
                onEngineProcessCompleted(event.processName, event);
            } catch (e) {
                console.error('[engine-events] onEngineProcessCompleted error:', e);
            }
        }
    }

    /* Immediate visual update so the user sees the change without waiting
       for the next 1-second tick. */
    tickEngineIndicator(slug);
}

/* ============================================================================
   CHROME: BOOTSTRAP
   ----------------------------------------------------------------------------
   Fetches the current engine state from the REST endpoint on page load and
   on reconnect, populating each card's initial state without waiting for
   the next push event from the WebSocket.
   Prefix: (none)
   ============================================================================ */

/* Loads current engine state from the REST endpoint on page load and on
   reconnect, providing immediate card state without waiting for the next
   push event. Returns the underlying fetch promise so the caller can
   chain WebSocket connect after bootstrap completes. Bootstrap failure
   is non-fatal: cards stay in the gray waiting state until the first
   push event arrives. */
function loadEngineBootstrap() {
    return fetch('/api/engine/state')
        .then(handleBootstrapResponse)
        .then(applyBootstrapState)
        .catch(handleBootstrapError);
}

/* Bootstrap response handler. Throws on non-OK status; otherwise returns
   the parsed JSON state object. */
function handleBootstrapResponse(response) {
    if (!response.ok) throw new Error('Bootstrap failed: ' + response.status);
    return response.json();
}

/* Applies a parsed bootstrap state object to engineState, computing the
   initial countdown for each PROCESS_COMPLETED event and rendering the
   indicator. */
function applyBootstrapState(state) {
    var now = Date.now();

    Object.keys(ENGINE_PROCESSES).forEach(function(procName) {
        var slug = ENGINE_PROCESSES[procName].slug;
        var event = state[procName];

        if (event) {
            engineState[slug].lastEvent = event;
            engineState[slug].lastRefresh = now;

            /* Calculate initial countdown from event scheduling metadata. */
            if (event.eventType === 'PROCESS_COMPLETED' && event.timestamp) {
                engineState[slug].countdown = calcCountdownFromEvent(event, now);
            }
        }

        tickEngineIndicator(slug);
    });
}

/* Bootstrap error handler. Bootstrap failure is non-fatal - the cards
   simply stay in the gray waiting state until the first WebSocket push
   event arrives. The warning is logged for diagnostics. */
function handleBootstrapError(e) {
    console.warn('Engine bootstrap:', e.message);
}

/* ============================================================================
   CHROME: COUNTDOWN CALCULATION
   ----------------------------------------------------------------------------
   Pure functions that convert a process scheduling metadata payload into a
   countdown value in seconds. Three scheduling patterns are supported:
   interval-only, once-daily, and time+interval. The math for each pattern
   lives here so handleEngineEvent and the bootstrap renderer share one
   implementation.
   Prefix: (none)
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
function calcCountdownFromEvent(event, now) {
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
    return calcSecondsUntilTomorrow(schedTime, now);
}

/* Calculates seconds from now until the next occurrence of a given
   HH:mm:ss time. If the time has not yet passed today, targets today.
   Otherwise targets tomorrow.

   @param {string} timeStr - Time in "HH:mm:ss" format
   @param {number} now - Current time in ms (Date.now())
   @returns {number} Seconds until the next occurrence of that time */
function calcSecondsUntilTomorrow(timeStr, now) {
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
   setInterval started by connectEngineEvents.
   Prefix: (none)
   ============================================================================ */

/* Decrements every active countdown by 1 second and re-renders every
   engine indicator. Called once per second by the engineTickTimer
   interval. */
function tickAllEngineIndicators() {
    Object.keys(ENGINE_PROCESSES).forEach(function(procName) {
        var slug = ENGINE_PROCESSES[procName].slug;

        /* Decrement countdown by 1 second each tick. */
        if (engineState[slug].countdown !== null) {
            engineState[slug].countdown -= 1;
        }

        tickEngineIndicator(slug);
    });
}

/* Renders the engine indicator for a single slug based on the current
   state. Computes bar/card classes from event status, countdown, and
   grace/critical thresholds; updates the countdown display text. */
function tickEngineIndicator(slug) {
    var els = getEngineElements(slug);
    if (!els.bar) return;

    var state = engineState[slug];
    var event = state ? state.lastEvent : null;

    /* No data yet: waiting state. */
    if (!event) {
        els.bar.className = 'engine-bar disabled';
        if (els.card) els.card.className = 'engine-card';
        if (els.cd) {
            els.cd.textContent = '';
            els.cd.innerHTML = '&nbsp;';
        }
        return;
    }

    /* STARTED: process is running. */
    if (event.eventType === 'PROCESS_STARTED') {
        els.bar.className = 'engine-bar running';
        if (els.card) els.card.className = 'engine-card';
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
            cdText = fmtEngineCountdown(countdown);
        } else if (countdown >= -ENGINE_GRACE_SEC) {
            /* Grace period - count up, stay green (no overdue escalation). */
            cdText = '+' + fmtEngineCountdown(Math.abs(countdown));
        } else {
            /* Overdue - past grace period. */
            cdText = '+' + fmtEngineCountdown(Math.abs(countdown));
            overdue = true;
            if (effectiveInterval > 0 && countdown < -(effectiveInterval * 2)) {
                critical = true;
            }
        }
    }

    /* Determine bar and card classes based on combined state. */
    var barCls;
    var cardCls = 'engine-card';
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

/* ============================================================================
   CHROME: DOM ELEMENT RESOLUTION
   ----------------------------------------------------------------------------
   Resolves the bar/card/countdown DOM elements for an engine slug. Pages
   may use suffixed IDs (engine-bar-{slug}) for multi-process layouts or
   bare IDs for single-process layouts; this function auto-detects the
   pattern.
   Prefix: (none)
   ============================================================================ */

/* Finds engine card DOM elements by slug.
   Multi-process pages: IDs have slug suffix (engine-bar-nb, card-engine-nb)
   Single-process pages: bare IDs (engine-bar, card-engine) - auto-detected */
function getEngineElements(slug) {
    /* Try suffixed first (multi-process pattern). */
    var bar = document.getElementById('engine-bar-' + slug);
    var card = document.getElementById('card-engine-' + slug);
    var cd = document.getElementById('engine-cd-' + slug);

    /* Fall back to bare IDs (single-process pattern). */
    if (!bar) {
        bar = document.getElementById('engine-bar');
        card = document.getElementById('card-engine');
        cd = document.getElementById('engine-cd');
    }

    return { bar: bar, card: card, cd: cd };
}

/* ============================================================================
   CHROME: CONNECTION INDICATOR
   ----------------------------------------------------------------------------
   Subtle visual indicator on the engine-row when the WebSocket is
   disconnected. Adds or removes a single class that pages style at their
   discretion.
   Prefix: (none)
   ============================================================================ */

/* Subtle visual indicator on the engine-row when WebSocket is disconnected.
   Adds or removes a 'ws-disconnected' class that pages can style. */
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

/* ============================================================================
   CHROME: ENGINE POPUP
   ----------------------------------------------------------------------------
   Click-to-show last-execution detail popup anchored to an engine card.
   initEngineCardClicks wires up the click handlers; showEnginePopup builds
   and positions the popup; closeEnginePopup tears it down.
   Prefix: (none)
   ============================================================================ */

/* Wires click handlers on every engine card to show the last-execution
   detail popup. Pages call this once after DOMContentLoaded to opt in. */
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

/* Builds and positions a popup with last execution details for a process.
   Anchors to the supplied card element. No-op if the slug has no
   lastEvent. */
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
            '<span class="engine-popup-close" data-engine-popup-close="1">&times;</span>' +
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

    /* Wire the close button via addEventListener; the previous inline
       onclick="closeEnginePopup()" was a forbidden pattern. The close
       span carries data-engine-popup-close="1" so the listener can find
       it without a fragile child-index lookup. */
    var closeBtn = popup.querySelector('[data-engine-popup-close="1"]');
    if (closeBtn) {
        closeBtn.addEventListener('click', closeEnginePopup);
    }

    /* Position near the card. */
    var rect = anchorEl.getBoundingClientRect();
    popup.style.position = 'fixed';
    popup.style.top = (rect.bottom + 6) + 'px';
    popup.style.right = (window.innerWidth - rect.right) + 'px';
    popup.style.zIndex = '9999';

    document.body.appendChild(popup);
    enginePopupVisible = true;
}

/* Removes the engine popup if present and clears the visibility flag.
   Idempotent: safe to call when no popup exists. */
function closeEnginePopup() {
    var existing = document.getElementById('engine-popup');
    if (existing) existing.remove();
    enginePopupVisible = false;
}

/* ============================================================================
   CHROME: RECONNECTION GRACE PERIOD
   ----------------------------------------------------------------------------
   Reconnection-state escalation: while the WebSocket is reconnecting, a
   grace-period timer checks every second whether the configured grace has
   elapsed and escalates the banner from 'reconnecting' (blue, friendly)
   to 'disconnected' (red, alarm) if reconnect has not succeeded in time.
   Prefix: (none)
   ============================================================================ */

/* Checks whether the reconnection grace period has expired. Called every
   1 second while in the 'reconnecting' state by the
   engineReconnectCheckTimer interval. */
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

/* Loads the reconnect grace period from GlobalConfig. Reuses the
   refresh-interval API which looks up ControlCenter | refresh_{page}_seconds.
   Setting name: ControlCenter | reconnect_grace_seconds (loaded directly,
   not via the refresh_* pattern - uses a dedicated fetch).
   Non-blocking - uses default if unavailable. */
function loadReconnectGraceConfig() {
    fetch('/api/config/refresh-interval?page=reconnect_grace')
        .then(parseConfigResponse)
        .then(applyReconnectGraceConfig)
        .catch(ignoreConfigError);
}

/* Parses a refresh-interval API response, returning the JSON body on OK
   or null on non-OK. Shared between the reconnect-grace and idle-timeout
   config loaders. */
function parseConfigResponse(r) {
    return r.ok ? r.json() : null;
}

/* Applies a parsed reconnect-grace config response to engineReconnectGraceSec.
   Only overwrites the default if the response carries a non-default
   interval. */
function applyReconnectGraceConfig(data) {
    if (data && data.interval && !data.default) {
        engineReconnectGraceSec = data.interval;
    }
}

/* Swallows errors from the refresh-interval API. Config load failure is
   non-fatal: the default value remains in effect. */
function ignoreConfigError() {
    /* Use default. */
}

/* ============================================================================
   CHROME: CONNECTION BANNER
   ----------------------------------------------------------------------------
   Manages the connection status banner that replaces the old red error
   banner during server restarts and session expiry. Four states: hidden,
   reconnecting (blue), disconnected (red), expired (amber with sign-in
   link).
   Prefix: (none)
   ============================================================================ */

/* Manages the connection status banner that replaces the old red error
   banner during server restarts and session expiry.

   States:
   connected    - banner hidden
   reconnecting - blue "Reconnecting..." banner (non-alarming)
   disconnected - red "Connection lost" banner (grace period expired)
   expired      - amber "Session expired" banner with sign-in link */
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

/* Shows a brief "Reconnected" message before auto-reloading. Called by
   handleEngineWsOpen when the open follows a reconnect. */
function showReloadingBanner() {
    var el = document.getElementById('connection-banner');
    if (!el) return;
    el.className = 'connection-banner reloading';
    el.textContent = 'Server reconnected \u2014 reloading\u2026';
    el.style.display = 'block';
}

/* ============================================================================
   CHROME: SHARED FETCH WRAPPER
   ----------------------------------------------------------------------------
   The engineFetch() wrapper that every Control Center API call should use
   instead of raw fetch(). It centralizes visibility-aware skipping, idle
   pausing, session-expiry detection, and error normalization so callers
   never have to reimplement those concerns.
   Prefix: (none)
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
     var data = await engineFetch('/api/endpoint');
     if (!data) return;  // hidden tab or session expired

   For POST requests:
     var data = await engineFetch('/api/endpoint', {
         method: 'POST',
         headers: { 'Content-Type': 'application/json' },
         body: JSON.stringify(payload)
     }); */
async function engineFetch(url, options) {
    /* Skip if tab is hidden (polling calls are wasted effort). */
    if (enginePageHidden) return null;

    /* Skip if session is already known to be expired. */
    if (engineSessionExpired) return null;

    /* Skip if idle-paused. */
    if (engineIdlePaused) return null;

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
        handleSessionExpired();
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
            handleSessionExpired();
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
   engineSessionExpired flag is set on the first call. */
function handleSessionExpired() {
    if (engineSessionExpired) return;
    engineSessionExpired = true;

    /* Stop WebSocket reconnect. */
    if (engineReconnectTimer) {
        clearTimeout(engineReconnectTimer);
        engineReconnectTimer = null;
    }

    /* Close WebSocket. */
    if (engineWs) {
        try {
            engineWs.close();
        } catch (e) {
            /* Ignore - close on an already-closed socket throws on some
               browsers. */
        }
    }

    /* Stop engine tick timer. */
    if (engineTickTimer) {
        clearInterval(engineTickTimer);
        engineTickTimer = null;
    }

    /* Stop reconnect grace check. */
    if (engineReconnectCheckTimer) {
        clearInterval(engineReconnectCheckTimer);
        engineReconnectCheckTimer = null;
    }

    /* Notify the page to stop its own polling. */
    if (typeof onSessionExpired === 'function') {
        try {
            onSessionExpired();
        } catch (e) {
            console.error('[engine-events] onSessionExpired error:', e);
        }
    }

    updateConnectionBanner();
    console.log('[engine-events] Session expired - polling stopped');
}

/* ============================================================================
   CHROME: IDLE DETECTION
   ----------------------------------------------------------------------------
   Pauses polling after a configurable period of user inactivity, resumes
   on the next interaction. The overlay element gives the user a visible
   signal that polling is suspended and dismisses on movement.
   Prefix: (none)
   ============================================================================ */

/* Called on any user interaction. Resets the idle timer and resumes
   polling if it was paused due to inactivity. */
function onUserActivity() {
    engineLastActivity = Date.now();

    if (engineIdlePaused) {
        engineIdlePaused = false;
        hideIdleOverlay();

        /* Resume if not hidden and not expired. */
        if (!enginePageHidden && !engineSessionExpired) {
            /* Reconnect WebSocket if needed. */
            if (!engineConnected && engineWs &&
                engineWs.readyState !== WebSocket.OPEN &&
                engineWs.readyState !== WebSocket.CONNECTING) {
                openEngineWebSocket();
            }

            if (typeof onPageResumed === 'function') {
                try {
                    onPageResumed();
                } catch (e) {
                    console.error('[engine-events] onPageResumed error:', e);
                }
            }
        }
    }
}

/* Checks whether the idle timeout has been exceeded. Called every 10
   seconds by the engineIdleCheckTimer interval. */
function checkIdleTimeout() {
    if (engineIdlePaused || engineSessionExpired || enginePageHidden) return;

    var elapsed = (Date.now() - engineLastActivity) / 1000;
    if (elapsed >= engineIdleTimeoutSec) {
        engineIdlePaused = true;
        showIdleOverlay();
        console.log('[engine-events] Idle timeout - polling paused');
    }
}

/* Loads idle timeout from GlobalConfig via the refresh-interval API.
   Non-blocking - uses default if unavailable. */
function loadIdleTimeoutConfig() {
    fetch('/api/config/refresh-interval?page=idle_timeout')
        .then(parseConfigResponse)
        .then(applyIdleTimeoutConfig)
        .catch(ignoreConfigError);
}

/* Applies a parsed idle-timeout config response to engineIdleTimeoutSec.
   Only overwrites the default if the response carries a non-default
   interval. */
function applyIdleTimeoutConfig(data) {
    if (data && data.interval && !data.default) {
        engineIdleTimeoutSec = data.interval;
    }
}

/* Shows a subtle overlay indicating polling is paused. Idempotent: a
   second call while the overlay is already up is a no-op. */
function showIdleOverlay() {
    if (document.getElementById('engine-idle-overlay')) return;

    var overlay = document.createElement('div');
    overlay.id = 'engine-idle-overlay';
    overlay.className = 'idle-overlay';
    overlay.innerHTML = '<div class="idle-message">Paused \u2014 move mouse to resume</div>';
    document.body.appendChild(overlay);
}

/* Removes the idle overlay if present. Idempotent: safe to call when
   no overlay exists. */
function hideIdleOverlay() {
    var overlay = document.getElementById('engine-idle-overlay');
    if (overlay) overlay.remove();
}

/* ============================================================================
   CHROME: SHARED FORMATTING
   ----------------------------------------------------------------------------
   Cross-page formatting and value-coercion utilities. Pages should use
   these instead of defining their own variants - the spec relies on
   single-source ownership of platform formatters so a downstream change
   (e.g. locale handling) propagates everywhere at once.
   Prefix: (none)
   ============================================================================ */

/* DOM-safe HTML escaping. Returns the escaped form of any value, safe to
   insert into innerHTML without enabling XSS.

   Public utility - pages should NOT define their own escapeHtml(); use
   this one. Handles null/undefined by returning empty string.

   @param {*} val - any value (string preferred, others coerced via String())
   @returns {string} HTML-safe string */
function escapeHtml(val) {
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
function formatTimeOfDay(val) {
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
function safeInt(val) {
    if (val == null || val === '' || val === 'DBNull') return 0;
    var n = parseInt(val, 10);
    return isNaN(n) ? 0 : n;
}

/* Null-safe parseFloat. Returns 0 for null/undefined/empty/NaN/'DBNull'.
   Companion to safeInt; same rationale.

   @param {*} val - any value
   @returns {number} float, or 0 on bad input */
function safeFloat(val) {
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

/* Formats a duration in minutes as a human-readable age string.
   <60m     -> "Xm"
   <24h     -> "Xh Xm"
   >=1d     -> "Xd Xh"

   Companion to formatTimeSince but takes minutes instead of seconds.
   Used wherever batch/record age is displayed.

   @param {number} minutes - elapsed minutes
   @returns {string} formatted string */
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

/* Formats a countdown value (positive or negative seconds) as an
   m:ss string, escalating to h Xm when the value crosses one hour. The
   sign is the caller's concern - this function takes the absolute value
   and floors. Used by tickEngineIndicator to render the engine-cd
   element. */
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

/* ============================================================================
   CHROME: SHARED PAGE REFRESH
   ----------------------------------------------------------------------------
   The platform-wide page-refresh handler invoked by every page's refresh
   button. Drives the spin animation on the button and delegates the
   actual data reload to the page's onPageRefresh hook.
   Prefix: (none)
   ============================================================================ */

/* Platform-wide page refresh handler. Drives the refresh button spin
   animation and delegates the actual data reload to the page's
   onPageRefresh hook. Pages define onPageRefresh and never define their
   own pageRefresh. */
function pageRefresh() {
    var btn = document.querySelector('.page-refresh-btn');
    if (btn) {
        btn.classList.add('spinning');
        btn.addEventListener('animationend', clearRefreshSpin, { once: true });
    }
    if (typeof onPageRefresh === 'function') {
        onPageRefresh();
    }
}

/* animationend handler for the refresh button spin animation. Clears the
   spinning class so the next refresh starts the animation cleanly. */
function clearRefreshSpin(e) {
    e.currentTarget.classList.remove('spinning');
}

/* ============================================================================
   CHROME: SHARED MODALS
   ----------------------------------------------------------------------------
   Promise-returning replacements for native window.alert and
   window.confirm. Used across every Control Center page so the styled
   modal experience is consistent and so callers can chain .then() for
   async flow. Both functions append an overlay to document.body and
   resolve when the user acts.

   Usage:
     showAlert('File not found.', { title: 'Error', icon: '&#10005;', iconColor: '#f48771' });

     showConfirm('Delete this item?', {
         title: 'Confirm Delete',
         confirmLabel: 'Delete',
         confirmClass: 'xf-modal-btn-danger'
     }).then(function(confirmed) { if (confirmed) { ... } });

     // For HTML content in the body:
     showConfirm('<p>Rich <strong>HTML</strong> content</p>', { html: true, ... });
   Prefix: (none)
   ============================================================================ */

/* Promise-returning replacement for native alert(). Appends an overlay
   modal to document.body, focuses the OK button, and resolves the
   returned promise when the user clicks OK. Options: title, icon,
   iconColor, buttonLabel. */
function showAlert(message, options) {
    var opts = options || {};
    var title = opts.title || 'Notice';
    var icon = opts.icon || '&#9432;';
    var iconColor = opts.iconColor || '#569cd6';
    var buttonLabel = opts.buttonLabel || 'OK';

    return new Promise(function(resolve) {
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

        /* Wire the OK button via addEventListener; the previous inline
           onclick assignment was a forbidden pattern. */
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
   confirm, false on cancel. Options: title, icon, iconColor,
   confirmLabel, cancelLabel, confirmClass, html. The html option, when
   true, lets the message string render as raw HTML (used for richer
   confirmation prompts). */
function showConfirm(message, options) {
    var opts = options || {};
    var title = opts.title || 'Confirm';
    var icon = opts.icon || '&#9888;';
    var iconColor = opts.iconColor || '#dcdcaa';
    var confirmLabel = opts.confirmLabel || 'Continue';
    var cancelLabel = opts.cancelLabel || 'Cancel';
    var confirmClass = opts.confirmClass || 'xf-modal-btn-primary';
    var messageHtml = opts.html || false;

    return new Promise(function(resolve) {
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

        /* Wire the cancel and OK buttons via addEventListener; the
           previous inline onclick assignments were forbidden patterns. */
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
