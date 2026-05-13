# ============================================================================
# xFACts Control Center - Bootloader Validation Test Page
# Location: E:\xFACts-ControlCenter\scripts\routes\BootloaderTest.ps1
#
# Throwaway test page used to validate the cc-shared.js bootloader (page
# module discovery, <prefix>_init invocation, shared action dispatch, and
# page-error-banner failure handling). Not tracked in System_Metadata. Delete
# this file and /js/test.js when bootloader validation is complete.
# ============================================================================

Add-PodeRoute -Method Get -Path '/bootloader-test' -Authentication 'ADLogin' -ScriptBlock {

    $html = @"

<!DOCTYPE html>
<html>
<head>
    <title>Bootloader Test</title>
    <link rel="stylesheet" href="/css/cc-shared.css">
</head>
<body data-page="test">

    <div id="page-error-banner" class="page-error-banner"></div>

    <div style="padding: 20px; max-width: 800px; margin: 0 auto;">
        <h1>Bootloader Validation Test</h1>

        <p>If the bootloader is working, the indicator below shows the time
        <code>test_init()</code> ran. Use the buttons to verify dispatch routing
        for shared and page-local actions.</p>

        <div id="test-init-indicator" style="padding: 12px; margin: 16px 0;
            background: rgba(78, 201, 176, 0.1); border: 1px solid rgba(78, 201, 176, 0.3);
            border-radius: 4px; color: #4ec9b0;">
            test_init() has not run yet.
        </div>

        <h2>Dispatch Tests</h2>

        <p>Click each button and watch the result area below.</p>

        <p>
            <button type="button" data-action="cc-page-refresh"
                style="padding: 8px 12px; margin-right: 8px;">
                Shared action: cc-page-refresh
            </button>

            <button type="button" data-action="run-test-action"
                data-action-message="page-local action fired correctly"
                style="padding: 8px 12px; margin-right: 8px;">
                Page-local action: run-test-action
            </button>

            <button type="button" data-action="cc-bogus-action"
                style="padding: 8px 12px;">
                Unknown shared action: cc-bogus-action
            </button>
        </p>

        <div id="test-result" style="padding: 12px; margin: 16px 0;
            background: rgba(86, 156, 214, 0.1); border: 1px solid rgba(86, 156, 214, 0.3);
            border-radius: 4px; color: #569cd6; min-height: 40px;">
            No action fired yet.
        </div>

        <h2>Failure-Mode Notes</h2>

        <p>To test the failure-mode UI (page-error-banner), rename
        <code>/js/test.js</code> on disk to force a 404, then reload. The
        page-error-banner should appear with a Refresh button.</p>

        <p>To test the missing-init case, restore <code>/js/test.js</code>
        but comment out the <code>test_init</code> function, then reload.</p>

        <p>To test the init-throws case, edit <code>test_init</code> to throw,
        then reload.</p>
    </div>

    <script src="/js/cc-shared.js"></script>
</body>
</html>

"@
    Write-PodeHtmlResponse -Value $html
}