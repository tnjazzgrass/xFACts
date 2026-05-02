// parse-js.js
// xFACts Asset Registry — JavaScript parser helper
//
// Reads JavaScript source from stdin, parses with acorn (with location info
// and comments), emits the complete AST as nested-tree JSON to stdout.
//
// Captures every node type, line/column positions, comments, async/generator
// flags, parameters — the full AST. No filtering.
//
// Module resolution: this script does NOT specify where its dependencies
// live. The caller (the PowerShell extractor) must set the NODE_PATH
// environment variable to include the directory containing acorn before
// invoking node.exe. On FA-SQLDBB that path is:
//   C:\Program Files\nodejs-libs\node_modules
//
// Invocation pattern:
//   $env:NODE_PATH = 'C:\Program Files\nodejs-libs\node_modules'
//   Get-Content file.js -Raw | & node.exe parse-js.js

const acorn = require('acorn');

// Read all of stdin
let source = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { source += chunk; });
process.stdin.on('end', () => {
    try {
        const comments = [];

        const ast = acorn.parse(source, {
            ecmaVersion: 'latest',
            sourceType: 'script',          // CC files are not ES modules
            locations: true,                // line/column on every node
            ranges: true,                   // start/end character offsets
            allowHashBang: true,
            allowReturnOutsideFunction: true,
            allowAwaitOutsideFunction: true,
            allowImportExportEverywhere: true,
            onComment: (block, text, start, end, startLoc, endLoc) => {
                comments.push({
                    type: block ? 'Block' : 'Line',
                    value: text,
                    start: start,
                    end: end,
                    loc: { start: startLoc, end: endLoc }
                });
            }
        });

        // Top-level result includes the AST plus the full comment list
        // (comments aren't AST nodes; they live in their own collection).
        const result = {
            ast: ast,
            comments: comments,
            sourceLength: source.length
        };

        process.stdout.write(JSON.stringify(result, null, 2));
    } catch (err) {
        // Emit a structured error so the PowerShell side can detect it
        const errOut = {
            error: true,
            message: err.message,
            line: err.loc ? err.loc.line : null,
            column: err.loc ? err.loc.column : null,
            pos: err.pos !== undefined ? err.pos : null,
            stack: err.stack
        };
        process.stdout.write(JSON.stringify(errOut, null, 2));
        process.exit(1);
    }
});
