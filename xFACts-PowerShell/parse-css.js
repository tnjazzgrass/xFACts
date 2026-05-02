// parse-css.js
// xFACts Asset Registry — CSS parser helper
//
// Reads CSS source from stdin, parses with PostCSS, emits the complete parse
// tree as nested-tree JSON to stdout. Each rule's selector is also decomposed
// via postcss-selector-parser and attached as a structured tree.
//
// Captures every node type (rules, at-rules, declarations, comments), source
// position info, raw text, decomposed selector trees with selector type
// information (class, id, tag, pseudo, attribute, etc.). No filtering.
//
// Module resolution: this script does NOT specify where its dependencies
// live. The caller (the PowerShell extractor) must set the NODE_PATH
// environment variable to include the directory containing postcss before
// invoking node.exe. On FA-SQLDBB that path is:
//   C:\Program Files\nodejs-libs\node_modules
//
// Invocation pattern:
//   $env:NODE_PATH = 'C:\Program Files\nodejs-libs\node_modules'
//   Get-Content file.css -Raw | & node.exe parse-css.js

const postcss = require('postcss');
const selectorParser = require('postcss-selector-parser');

// Read all of stdin
let source = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { source += chunk; });
process.stdin.on('end', () => {
    try {
        const root = postcss.parse(source);

        // Convert PostCSS AST into a plain JSON tree. PostCSS nodes have
        // back-references and parser internals that don't serialize cleanly,
        // so we rebuild as a simple object tree.
        const tree = nodeToJson(root);

        const result = {
            ast: tree,
            sourceLength: source.length
        };

        process.stdout.write(JSON.stringify(result, null, 2));
    } catch (err) {
        const errOut = {
            error: true,
            message: err.message,
            line: err.line || null,
            column: err.column || null,
            stack: err.stack
        };
        process.stdout.write(JSON.stringify(errOut, null, 2));
        process.exit(1);
    }
});

// Recursively convert a PostCSS node to a JSON-safe object.
function nodeToJson(node) {
    const out = {
        type: node.type,
        source: node.source ? {
            start: node.source.start || null,
            end: node.source.end || null
        } : null
    };

    // Node-type-specific fields
    switch (node.type) {
        case 'root':
            // Top-level container; just walk children
            break;

        case 'rule':
            out.selector = node.selector;
            out.selectors = node.selectors;             // array form
            out.selectorTree = decomposeSelector(node.selector);
            break;

        case 'atrule':
            out.name = node.name;                       // e.g. 'media', 'keyframes'
            out.params = node.params;                   // e.g. '(max-width: 768px)'
            break;

        case 'decl':
            out.prop = node.prop;
            out.value = node.value;
            out.important = node.important || false;
            break;

        case 'comment':
            out.text = node.text;
            break;

        default:
            // Unknown / future node type — capture raw fields
            out.raw = JSON.stringify(node, getCircularReplacer());
            break;
    }

    // Recurse into children if this is a container node
    if (node.nodes && Array.isArray(node.nodes)) {
        out.nodes = node.nodes.map(nodeToJson);
    }

    return out;
}

// Use postcss-selector-parser to break a selector string into a structured
// tree. Captures multi-selector lists, compound selectors, pseudo-elements,
// pseudo-classes, attribute selectors, combinators — everything the parser
// gives us.
function decomposeSelector(selectorString) {
    if (!selectorString) return null;
    let parsed = null;
    try {
        selectorParser(root => {
            parsed = selectorNodeToJson(root);
        }).processSync(selectorString);
    } catch (err) {
        return { error: err.message };
    }
    return parsed;
}

function selectorNodeToJson(node) {
    const out = {
        type: node.type,                                // root, selector, class, id, tag, pseudo, attribute, combinator, etc.
        value: node.value !== undefined ? node.value : null
    };
    if (node.attribute !== undefined) out.attribute = node.attribute;
    if (node.operator !== undefined) out.operator = node.operator;
    if (node.namespace !== undefined) out.namespace = node.namespace;
    if (node.source) {
        out.source = {
            start: node.source.start || null,
            end: node.source.end || null
        };
    }
    if (node.nodes && Array.isArray(node.nodes)) {
        out.nodes = node.nodes.map(selectorNodeToJson);
    }
    return out;
}

// Safe circular reference handler for the unknown-node fallback path
function getCircularReplacer() {
    const seen = new WeakSet();
    return (key, value) => {
        if (typeof value === 'object' && value !== null) {
            if (seen.has(value)) return '[Circular]';
            seen.add(value);
        }
        // Skip parent back-references that PostCSS adds
        if (key === 'parent') return undefined;
        return value;
    };
}
