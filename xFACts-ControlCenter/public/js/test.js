/* ============================================================================
   xFACts Control Center - Bootloader Test Page (test.js)
   Location: E:\xFACts-ControlCenter\public\js\test.js

   Throwaway test page JS used to validate the cc-shared.js bootloader.
   Demonstrates the bootloader-driven page pattern: a <prefix>_init function
   called by the bootloader, event-scoped dispatch tables mapping page-local
   data-action-<event> values to handler functions, and per-event delegated
   listeners registered during init. Delete this file when bootloader
   validation is complete.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: PAGE CONFIGURATION
   FUNCTIONS: PAGE BOOT
   FUNCTIONS: ACTION HANDLERS
   ============================================================================ */


/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Page-local event-scoped action dispatch tables consumed by the delegated
   event listeners registered in test_init. One table per recognized event
   from CC_HTML_Spec.md Section 6.4; only the events with page-local actions
   need populated tables.
   Prefix: test
   ============================================================================ */

/* Page-local click action dispatch table. Maps page-local
   data-action-click values to handler functions. Shared cc-* actions are
   handled by cc-shared.js and never appear here. */
const test_clickActions = {
    'run-test-action': test_runTestAction
};


/* ============================================================================
   FUNCTIONS: PAGE BOOT
   ----------------------------------------------------------------------------
   The mandatory <prefix>_init function called by the cc-shared.js
   bootloader after this module loads. Writes a visible indicator confirming
   it ran and registers the delegated event listeners that route page-local
   data-action-<event> values to handlers in the corresponding dispatch
   tables.
   Prefix: test
   ============================================================================ */

/* Page boot function. Called by the cc-shared.js bootloader after this
   module is loaded. Updates the test-init-indicator div with a timestamp
   to confirm the bootloader successfully invoked us, then registers the
   delegated click listener that routes page-local data-action-click
   values to handlers in test_clickActions. */
function test_init() {
    const indicator = document.getElementById('test-init-indicator');
    if (indicator) {
        const now = new Date();
        const hh = String(now.getHours()).padStart(2, '0');
        const mm = String(now.getMinutes()).padStart(2, '0');
        const ss = String(now.getSeconds()).padStart(2, '0');
        indicator.textContent = 'test_init() ran at ' + hh + ':' + mm + ':' + ss;
    }

    document.body.addEventListener('click', test_handleClickAction);
}


/* ============================================================================
   FUNCTIONS: ACTION HANDLERS
   ----------------------------------------------------------------------------
   Delegated dispatcher for page-local data-action-click values plus the
   handler functions referenced from test_clickActions.
   Prefix: test
   ============================================================================ */

/* Delegated dispatcher for page-local click actions. Routes
   data-action-click values that do not begin with cc- to handlers in
   test_clickActions. Shared cc-* actions are ignored here and handled
   by cc-shared.js's listener. */
function test_handleClickAction(event) {
    const target = event.target.closest('[data-action-click]');
    if (!target) {
        return;
    }

    const action = target.getAttribute('data-action-click');
    if (!action || action.indexOf('cc-') === 0) {
        return;
    }

    const handler = test_clickActions[action];
    if (!handler) {
        console.warn('[test] Unknown page click action: ' + action);
        return;
    }

    handler(target, event);
}

/* Handler for the run-test-action button. Reads the data-action-message
   argument from the action element and writes it to the test-result div
   along with a timestamp. */
function test_runTestAction(target, event) {
    const message = target.dataset.actionMessage || '(no message attribute)';
    const result = document.getElementById('test-result');
    if (result) {
        const now = new Date();
        const hh = String(now.getHours()).padStart(2, '0');
        const mm = String(now.getMinutes()).padStart(2, '0');
        const ss = String(now.getSeconds()).padStart(2, '0');
        result.textContent = '[' + hh + ':' + mm + ':' + ss + '] ' + message;
    }
}
