/* ============================================================
   ddl-erd.js — Dynamic ERD renderer for xFACts documentation
   
   Reads schema JSON files and renders entity-relationship diagrams
   using HTML table boxes and SVG relationship lines.

   Features:
     - Category filtering via data-category attribute
     - Connected subgraph detection and independent layout
     - Standalone tables rendered as compact grid
     - Smart connector routing (vertical vs horizontal)
     - Scale-to-fit prevents horizontal overflow
     - Only PK, FK, UQ columns shown (keys-only view)

   Usage:
     <div class="erd-root" data-schema="FileOps"></div>
     <div class="erd-root" data-schema="dbo" data-category="RBAC"></div>
     <script src="../../js/ddl-erd.js"></script>

   Version: 1.3.0
   ============================================================ */

(function () {
    'use strict';

    var CONFIG = {
        jsonBasePath: '../../data/ddl/',
        tableWidth: 210,
        rowHeight: 22,
        headerHeight: 32,
        footerHeight: 24,
        levelGap: 60,
        tableGap: 28,
        subgraphGap: 40,
        padding: 20,
        connectorColor: '#569cd6'
    };

    // ===== INITIALIZATION =====
    var roots = document.querySelectorAll('.erd-root');
    for (var i = 0; i < roots.length; i++) {
        initERD(roots[i]);
    }

    function initERD(container) {
        var schema = container.getAttribute('data-schema');
        if (!schema) return;

        var jsonUrl = CONFIG.jsonBasePath + schema + '.json';
        fetch(jsonUrl)
            .then(function (r) { return r.json(); })
            .then(function (data) {
                var category = container.getAttribute('data-category');
                var tables = data.tables || [];
                if (category) {
                    tables = tables.filter(function (t) {
                        return (t.category || '') === category;
                    });
                }
                if (tables.length === 0) {
                    container.innerHTML = '<p style="color: var(--text-muted);">No tables found.</p>';
                    return;
                }
                renderERD(container, tables, schema);
            })
            .catch(function (err) {
                container.innerHTML = '<p style="color: var(--accent-red);">Failed to load ' + schema + '.json: ' + err.message + '</p>';
            });
    }

    // ===== KEY COLUMN EXTRACTION =====

    function getKeyColumns(table) {
        var cols = table.columns || [];
        var pkNames = [], fkNames = [], uqNames = [];

        (table.indexes || []).forEach(function (idx) {
            if (idx.isPrimaryKey) {
                pkNames = idx.keyColumns.split(',').map(function (s) { return s.trim(); });
            }
            if (idx.isUniqueConstraint) {
                idx.keyColumns.split(',').forEach(function (c) {
                    var n = c.trim();
                    if (uqNames.indexOf(n) === -1) uqNames.push(n);
                });
            }
        });
        (table.foreignKeys || []).forEach(function (fk) {
            if (fkNames.indexOf(fk.column) === -1) fkNames.push(fk.column);
        });

        var seen = {}, ordered = [];
        function add(n) { if (!seen[n]) { seen[n] = true; ordered.push(n); } }
        pkNames.forEach(add); fkNames.forEach(add); uqNames.forEach(add);

        var keyCols = [];
        ordered.forEach(function (name) {
            var col = null;
            for (var i = 0; i < cols.length; i++) { if (cols[i].name === name) { col = cols[i]; break; } }
            if (!col) return;
            keyCols.push({
                name: col.name,
                dataType: col.dataType,
                length: col.length || null,
                isPK: pkNames.indexOf(name) !== -1,
                isFK: fkNames.indexOf(name) !== -1,
                isUQ: uqNames.indexOf(name) !== -1
            });
        });
        return { keyCols: keyCols, totalColCount: cols.length };
    }

    function getTableHeight(kc) {
        return CONFIG.headerHeight + kc.keyCols.length * CONFIG.rowHeight + CONFIG.footerHeight;
    }

    // ===== GRAPH ANALYSIS =====

    function buildInternalEdges(tables) {
        var nameSet = {};
        tables.forEach(function (t) { nameSet[t.name] = true; });
        var edges = [], involved = {};

        tables.forEach(function (t) {
            (t.foreignKeys || []).forEach(function (fk) {
                var ref = fk.referencedTable.replace(/^[^.]+\./, '');
                if (!nameSet[ref]) return;
                involved[t.name] = true;
                involved[ref] = true;
                var is11 = (t.indexes || []).some(function (idx) {
                    return idx.isUniqueConstraint && idx.keyColumns === fk.column;
                });
                edges.push({ from: ref, to: t.name, card: is11 ? '1:1' : '1:N' });
            });
        });
        return { edges: edges, involved: involved };
    }

    function findSubgraphs(tables, edges) {
        var parent = {};
        tables.forEach(function (t) { parent[t.name] = t.name; });
        function find(x) { while (parent[x] !== x) { parent[x] = parent[parent[x]]; x = parent[x]; } return x; }
        edges.forEach(function (e) { parent[find(e.from)] = find(e.to); });

        var groups = {};
        tables.forEach(function (t) {
            var r = find(t.name);
            if (!groups[r]) groups[r] = [];
            groups[r].push(t);
        });
        return Object.keys(groups).map(function (k) { return groups[k]; });
    }

    // ===== SUBGRAPH LAYOUT =====

    function layoutSubgraph(group, allEdges, keyColData) {
        var names = {};
        group.forEach(function (t) { names[t.name] = true; });
        var edges = allEdges.filter(function (e) { return names[e.from] && names[e.to]; });

        var ch = {}, pa = {};
        edges.forEach(function (e) {
            if (!ch[e.from]) ch[e.from] = [];
            if (ch[e.from].indexOf(e.to) === -1) ch[e.from].push(e.to);
            if (!pa[e.to]) pa[e.to] = [];
            if (pa[e.to].indexOf(e.from) === -1) pa[e.to].push(e.from);
        });

        var roots = group.filter(function (t) { return !pa[t.name]; }).map(function (t) { return t.name; });
        var lvl = {};
        var q = roots.slice();
        roots.forEach(function (n) { lvl[n] = 0; });
        while (q.length) {
            var c = q.shift();
            (ch[c] || []).forEach(function (x) {
                var nl = lvl[c] + 1;
                if (lvl[x] === undefined || lvl[x] < nl) { lvl[x] = nl; q.push(x); }
            });
        }
        group.forEach(function (t) { if (lvl[t.name] === undefined) lvl[t.name] = 0; });

        var byLvl = {}, maxL = 0;
        group.forEach(function (t) {
            var l = lvl[t.name];
            if (!byLvl[l]) byLvl[l] = [];
            byLvl[l].push(t);
            if (l > maxL) maxL = l;
        });
        for (var l = 0; l <= maxL; l++) { (byLvl[l] || []).sort(function (a, b) { return a.name.localeCompare(b.name); }); }

        // Detect direction
        var maxW = 0;
        for (var l = 0; l <= maxL; l++) { var len = (byLvl[l] || []).length; if (len > maxW) maxW = len; }
        var dir = maxW >= maxL + 1 ? 'td' : 'lr';
        var TW = CONFIG.tableWidth, GAP = CONFIG.tableGap;

        var pos = {};
        if (dir === 'td') {
            var cy = 0;
            for (var l = 0; l <= maxL; l++) {
                var tbl = byLvl[l] || [];
                var mH = 0;
                tbl.forEach(function (t) { var h = getTableHeight(keyColData[t.name]); if (h > mH) mH = h; });
                var tw = tbl.length * TW + (tbl.length - 1) * GAP;
                var sx = 0;
                if (l > 0) {
                    var pc = [];
                    tbl.forEach(function (t) { (pa[t.name] || []).forEach(function (p) { if (pos[p]) pc.push(pos[p].x + TW / 2); }); });
                    if (pc.length) { sx = Math.max(0, pc.reduce(function (a, b) { return a + b; }, 0) / pc.length - tw / 2); }
                }
                tbl.forEach(function (t, i) {
                    pos[t.name] = { x: sx + i * (TW + GAP), y: cy, w: TW, h: getTableHeight(keyColData[t.name]) };
                });
                cy += mH + CONFIG.levelGap;
            }
        } else {
            var cx = 0;
            for (var l = 0; l <= maxL; l++) {
                var tbl = byLvl[l] || [];
                var tH = 0;
                tbl.forEach(function (t) { tH += getTableHeight(keyColData[t.name]); });
                tH += (tbl.length - 1) * GAP;
                var sy = 0;
                if (l > 0) {
                    var pc = [];
                    tbl.forEach(function (t) { (pa[t.name] || []).forEach(function (p) { if (pos[p]) pc.push(pos[p].y + pos[p].h / 2); }); });
                    if (pc.length) { sy = Math.max(0, pc.reduce(function (a, b) { return a + b; }, 0) / pc.length - tH / 2); }
                }
                var ry = sy;
                tbl.forEach(function (t) {
                    var h = getTableHeight(keyColData[t.name]);
                    pos[t.name] = { x: cx, y: ry, w: TW, h: h };
                    ry += h + GAP;
                });
                cx += TW + CONFIG.levelGap + GAP;
            }
        }

        var mxX = 0, mxY = 0;
        Object.keys(pos).forEach(function (n) { var p = pos[n]; if (p.x + p.w > mxX) mxX = p.x + p.w; if (p.y + p.h > mxY) mxY = p.y + p.h; });
        return { pos: pos, edges: edges, w: mxX, h: mxY, dir: dir };
    }

    // ===== GLOBAL LAYOUT =====

    function computeLayout(tables, keyColData, containerW) {
        var fkInfo = buildInternalEdges(tables);
        var connected = tables.filter(function (t) { return fkInfo.involved[t.name]; });
        var standalone = tables.filter(function (t) { return !fkInfo.involved[t.name]; });

        var subgroups = findSubgraphs(connected, fkInfo.edges);
        var sgLayouts = subgroups.map(function (g) { return layoutSubgraph(g, fkInfo.edges, keyColData); });
        sgLayouts.sort(function (a, b) { return (b.w * b.h) - (a.w * a.h); });

        var maxW = Math.max(containerW - CONFIG.padding * 2, 500);
        var globalPos = {}, allEdges = [];
        var cx = CONFIG.padding, cy = CONFIG.padding, rowH = 0;

        sgLayouts.forEach(function (sg) {
            if (cx > CONFIG.padding && cx + sg.w > maxW) {
                cx = CONFIG.padding;
                cy += rowH + CONFIG.subgraphGap;
                rowH = 0;
            }
            Object.keys(sg.pos).forEach(function (n) {
                var p = sg.pos[n];
                globalPos[n] = { x: p.x + cx, y: p.y + cy, w: p.w, h: p.h };
            });
            sg.edges.forEach(function (e) { allEdges.push(e); });
            cx += sg.w + CONFIG.subgraphGap;
            if (sg.h > rowH) rowH = sg.h;
        });

        var connBot = 0;
        Object.keys(globalPos).forEach(function (n) { var p = globalPos[n]; if (p.y + p.h > connBot) connBot = p.y + p.h; });

        var stTop = null;
        if (standalone.length > 0) {
            standalone.sort(function (a, b) { return a.name.localeCompare(b.name); });
            stTop = connBot + CONFIG.subgraphGap + (subgroups.length > 0 ? 16 : 0);
            var stTableTop = stTop + 24; // clear the label text
            var cols = Math.min(Math.floor(maxW / (CONFIG.tableWidth + CONFIG.tableGap * 0.6)) || 1, standalone.length);
            standalone.forEach(function (t, i) {
                var col = i % cols, row = Math.floor(i / cols);
                var h = getTableHeight(keyColData[t.name]);
                globalPos[t.name] = {
                    x: CONFIG.padding + col * (CONFIG.tableWidth + CONFIG.tableGap * 0.6),
                    y: stTableTop + row * (h + CONFIG.tableGap * 0.6),
                    w: CONFIG.tableWidth, h: h, isStandalone: true
                };
            });
        }

        var totalW = 0, totalH = 0;
        Object.keys(globalPos).forEach(function (n) {
            var p = globalPos[n];
            if (p.x + p.w > totalW) totalW = p.x + p.w;
            if (p.y + p.h > totalH) totalH = p.y + p.h;
        });

        return { pos: globalPos, edges: allEdges, totalW: totalW + CONFIG.padding, totalH: totalH + CONFIG.padding, stTop: stTop };
    }

    // ===== SMART CONNECTOR ROUTING =====

    function buildPath(fp, tp) {
        var dx = tp.x - fp.x;
        var absDy = Math.abs(tp.y - fp.y);

        // Side-by-side: horizontal routing
        if (absDy < fp.h && Math.abs(dx) > 0) {
            var left = dx > 0 ? fp : tp;
            var right = dx > 0 ? tp : fp;
            var x1 = left.x + left.w, y1 = left.y + left.h / 2;
            var x2 = right.x, y2 = right.y + right.h / 2;
            var midX = x1 + (x2 - x1) / 2;
            return 'M' + x1 + ',' + y1 + ' C' + midX + ',' + y1 + ' ' + midX + ',' + y2 + ' ' + x2 + ',' + y2;
        }

        // Vertical: top-down routing
        if (tp.y > fp.y) {
            var x1 = fp.x + fp.w / 2, y1 = fp.y + fp.h;
            var x2 = tp.x + tp.w / 2, y2 = tp.y;
            var midY = y1 + (y2 - y1) / 2;
            return 'M' + x1 + ',' + y1 + ' C' + x1 + ',' + midY + ' ' + x2 + ',' + midY + ' ' + x2 + ',' + y2;
        }

        // Reverse vertical
        var x1 = fp.x + fp.w / 2, y1 = fp.y;
        var x2 = tp.x + tp.w / 2, y2 = tp.y + tp.h;
        var midY = y2 + (y1 - y2) / 2;
        return 'M' + x1 + ',' + y1 + ' C' + x1 + ',' + midY + ' ' + x2 + ',' + midY + ' ' + x2 + ',' + y2;
    }

    // ===== RENDERING =====

    function renderERD(container, tables, schema) {
        var keyColData = {};
        tables.forEach(function (t) { keyColData[t.name] = getKeyColumns(t); });

        var containerW = container.clientWidth || 900;
        var layout = computeLayout(tables, keyColData, containerW);

        // Title
        var category = container.getAttribute('data-category');
        var titleText = (category || schema) + ' Schema';
        var title = document.createElement('div');
        title.className = 'erd-title';
        title.textContent = titleText;
        container.appendChild(title);

        // Outer wrapper
        var outer = document.createElement('div');
        outer.className = 'erd-outer';

        // Canvas
        var canvas = document.createElement('div');
        canvas.className = 'erd-canvas';
        canvas.style.position = 'relative';
        canvas.style.width = layout.totalW + 'px';
        canvas.style.height = layout.totalH + 'px';
        canvas.style.transformOrigin = 'top left';

        // SVG layer
        var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('width', layout.totalW);
        svg.setAttribute('height', layout.totalH);
        svg.style.position = 'absolute';
        svg.style.top = '0';
        svg.style.left = '0';
        svg.style.pointerEvents = 'none';

        // Draw connectors
        layout.edges.forEach(function (e) {
            var fp = layout.pos[e.from], tp = layout.pos[e.to];
            if (!fp || !tp) return;

            var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
            path.setAttribute('d', buildPath(fp, tp));
            path.setAttribute('fill', 'none');
            path.setAttribute('stroke', CONFIG.connectorColor);
            path.setAttribute('stroke-width', '1.5');
            path.setAttribute('stroke-opacity', '0.7');
            svg.appendChild(path);

            var mx = (fp.x + fp.w / 2 + tp.x + tp.w / 2) / 2;
            var my = (fp.y + fp.h / 2 + tp.y + tp.h / 2) / 2;
            var lbl = document.createElementNS('http://www.w3.org/2000/svg', 'text');
            lbl.setAttribute('x', mx + 8);
            lbl.setAttribute('y', my - 4);
            lbl.setAttribute('fill', CONFIG.connectorColor);
            lbl.setAttribute('font-size', '11');
            lbl.setAttribute('font-family', 'var(--font-mono)');
            lbl.setAttribute('opacity', '0.8');
            lbl.textContent = e.card;
            svg.appendChild(lbl);
        });

        // Standalone divider
        if (layout.stTop !== null) {
            var line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
            line.setAttribute('x1', CONFIG.padding);
            line.setAttribute('y1', layout.stTop - 8);
            line.setAttribute('x2', layout.totalW - CONFIG.padding);
            line.setAttribute('y2', layout.stTop - 8);
            line.setAttribute('stroke', '#404040');
            line.setAttribute('stroke-width', '1');
            line.setAttribute('stroke-dasharray', '4,4');
            svg.appendChild(line);

            var stLabel = document.createElementNS('http://www.w3.org/2000/svg', 'text');
            stLabel.setAttribute('x', CONFIG.padding);
            stLabel.setAttribute('y', layout.stTop + 4);
            stLabel.setAttribute('fill', '#888888');
            stLabel.setAttribute('font-size', '11');
            stLabel.setAttribute('font-family', 'var(--font-main)');
            stLabel.textContent = 'Standalone Tables (no internal relationships)';
            svg.appendChild(stLabel);
        }

        canvas.appendChild(svg);

        // Table boxes
        tables.forEach(function (t) {
            var pos = layout.pos[t.name];
            if (!pos) return;
            var kc = keyColData[t.name];

            var box = document.createElement('div');
            box.className = 'erd-table' + (pos.isStandalone ? ' erd-standalone' : '');
            box.style.position = 'absolute';
            box.style.left = pos.x + 'px';
            box.style.top = pos.y + 'px';
            box.style.width = pos.w + 'px';

            var hdr = document.createElement('div');
            hdr.className = 'erd-table-header';
            hdr.textContent = t.name;
            box.appendChild(hdr);

            kc.keyCols.forEach(function (col) {
                var row = document.createElement('div');
                row.className = 'erd-table-col';
                var badges = '';
                if (col.isPK && col.isFK) { badges = '<span class="erd-badge pk-fk">PK FK</span>'; row.classList.add('is-pk', 'is-fk'); }
                else if (col.isPK) { badges = '<span class="erd-badge pk">PK</span>'; row.classList.add('is-pk'); }
                else if (col.isFK) { badges = '<span class="erd-badge fk">FK</span>'; row.classList.add('is-fk'); }
                else if (col.isUQ) { badges = '<span class="erd-badge uq">UQ</span>'; row.classList.add('is-uq'); }
                var ts = col.dataType;
                if (col.length) ts += '(' + col.length + ')';
                row.innerHTML = badges + '<span class="erd-col-name">' + esc(col.name) + '</span><span class="erd-col-type">' + esc(ts) + '</span>';
                box.appendChild(row);
            });

            var ftr = document.createElement('div');
            ftr.className = 'erd-table-footer';
            ftr.textContent = kc.totalColCount + ' columns';
            box.appendChild(ftr);

            canvas.appendChild(box);
        });

        outer.appendChild(canvas);
        container.appendChild(outer);

        // Scale-to-fit and fill container width
        requestAnimationFrame(function () {
            var availW = container.clientWidth;
            var scale = Math.min(1.0, availW / layout.totalW);
            if (scale < 1.0) {
                canvas.style.transform = 'scale(' + scale + ')';
                outer.style.height = (layout.totalH * scale) + 'px';
            } else {
                // Layout narrower than container — stretch canvas to fill
                canvas.style.width = availW + 'px';
                outer.style.height = layout.totalH + 'px';
                // Center content by offsetting the SVG and table boxes
                var offsetX = Math.floor((availW - layout.totalW) / 2);
                if (offsetX > 0) {
                    svg.style.left = offsetX + 'px';
                    var boxes = canvas.querySelectorAll('.erd-table');
                    for (var b = 0; b < boxes.length; b++) {
                        boxes[b].style.left = (parseFloat(boxes[b].style.left) + offsetX) + 'px';
                    }
                }
            }
            outer.style.overflow = 'hidden';
        });
    }

    // ===== HELPERS =====

    function esc(s) {
        return s ? s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;') : '';
    }
})();
