/* ============================================================================
   xFACts Control Center - Bootloader Test Page (test.js)
   Location: E:\xFACts-ControlCenter\public\js\test.js

   Throwaway test page JS used to validate the cc-shared.js bootloader.
   Demonstrates the new bootloader-driven page pattern: a <prefix>_init
   function called by the bootloader, a dispatch table mapping page-local
   data-action values to handler functions, and a delegated click listener
   registered during init. Delete this file when bootloader validation is
   complete.

   FILE ORGANIZATION
   -----------------
   CONSTANTS: PAGE CONFIGURATION
   FUNCTIONS: PAGE BOOT
   FUNCTIONS: ACTION HANDLERS
   ============================================================================ */


/* ============================================================================
   CONSTANTS: PAGE CONFIGURATION
   ----------------------------------------------------------------------------
   Page-local action dispatch table consumed by the delegated click listener
   registered in test_init.
   Prefix: test
   ============================================================================ */

/* Page-local action dispatch table. Maps page-local data-action values to
   handler functions. Shared cc-* actions are handled by cc-shared.js's
   sharedActions table and never appear here. */
const test_actions = {
    'run-test-action': test_runTestAction
};


/* ============================================================================
   FUNCTIONS: PAGE BOOT
   ----------------------------------------------------------------------------
   The mandatory <prefix>_init function called by the cc-shared.js
   bootloader after this module loads. Writes a visible indicator confirming
   it ran and registers the delegated click listener for page-local actions.
   Prefix: test
   ============================================================================ */

/* Page boot function. Called by the cc-shared.js bootloader after this
   module is loaded. Updates the test-init-indicator div with a timestamp
   to confirm the bootloader successfully invoked us, then registers the
   delegated click listener that routes page-local data-action values to
   handlers in test_actions. */
function test_init() {
    const indicator = document.getElementById('test-init-indicator');
    if (indicator) {
        const now = new Date();
        const hh = String(now.getHours()).padStart(2, '0');
        const mm = String(now.getMinutes()).padStart(2, '0');
        const ss = String(now.getSeconds()).padStart(2, '0');
		throw new Error('test boom');
        indicator.textContent = 'test_init() ran at ' + hh + ':' + mm + ':' + ss;
    }

    document.body.addEventListener('click', test_handlePageAction);
}


/* ============================================================================
   FUNCTIONS: ACTION HANDLERS
   ----------------------------------------------------------------------------
   Delegated dispatcher for page-local data-action values plus the handler
   functions referenced from test_actions.
   Prefix: test
   ============================================================================ */

/* Delegated dispatcher for page-local actions. Routes data-action values
   that do not begin with cc- to handlers in test_actions. Shared cc-*
   actions are ignored here and handled by cc-shared.js's listener. */
function test_handlePageAction(event) {
    const target = event.target.closest('[data-action]');
    if (!target) {
        return;
    }

    const action = target.dataset.action;
    if (!action || action.indexOf('cc-') === 0) {
        return;
    }

    const handler = test_actions[action];
    if (!handler) {
        console.warn('[test] Unknown page action: ' + action);
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
