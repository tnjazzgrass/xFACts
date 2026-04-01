/* ============================================================
   docs-controlcenter.js — Interactive behavior for CC guide pages

   Manages: tour vs. show-all mode toggle, callout marker states
   (idle/pulsing/visited/flash), additive slideout panel that
   builds up section content as markers are clicked, bidirectional
   highlighting between mockup and slideout, and flip key cards.

   Loaded on CC guide pages after nav.js.
   Version: Tracked in dbo.System_Metadata (component: Documentation.Site)
   ============================================================ */

(function () {
    'use strict';

    // ===== STATE =====
    var mode = 'tour';           // 'tour' or 'showall'
    var tourGuided = true;       // false once user clicks out of order
    var nextSuggested = 1;       // next marker to pulse in guided tour
    var visited = {};            // { 1: true, 3: true, ... }
    var totalMarkers = 0;
    var activeSection = null;    // currently highlighted section number
    var slideoutEl = null;
    var slideoutBody = null;

    // ===== INIT =====
    document.addEventListener('DOMContentLoaded', function () {
        slideoutEl = document.querySelector('.guide-slideout');
        slideoutBody = document.querySelector('.guide-slideout-body');

        var markers = document.querySelectorAll('.mock-container .callout-marker');
        totalMarkers = markers.length;

        buildSlideoutSlots();

        // Bind marker clicks (mockup → slideout)
        markers.forEach(function (el) {
            el.addEventListener('click', function (e) {
                e.preventDefault();
                var num = parseInt(el.textContent.trim(), 10);
                handleMarkerClick(num);
            });
        });

        // Bind mode buttons
        var tourBtn = document.getElementById('btn-tour');
        var showBtn = document.getElementById('btn-showall');
        if (tourBtn) tourBtn.addEventListener('click', function () { setMode('tour'); });
        if (showBtn) showBtn.addEventListener('click', function () { setMode('showall'); });

        // Bind slideout close
        var closeBtn = document.querySelector('.guide-slideout-close');
        if (closeBtn) closeBtn.addEventListener('click', closeSlideout);

        // Bind flip cards
        document.querySelectorAll('.key-flip-card').forEach(function (card) {
            card.addEventListener('click', function () {
                card.classList.toggle('flipped');
            });
        });

        // Bind sidebar section items (highlight mock section only, no slideout)
        document.querySelectorAll('.sidebar-item[data-marker]').forEach(function (item) {
            item.addEventListener('click', function () {
                var num = parseInt(item.getAttribute('data-marker'), 10);
                highlightMockSection(num);
            });
        });

        // Dismiss mock modal previews when clicking outside them
        var mockContainer = document.querySelector('.mock-container');
        if (mockContainer) {
            mockContainer.addEventListener('click', function (e) {
                var visibleModal = mockContainer.querySelector('.mock-modal-preview.mock-highlight');
                if (!visibleModal) return;
                // If click is inside the modal itself, ignore
                if (visibleModal.contains(e.target)) return;
                // If click is on a callout marker, let the marker handler deal with it
                if (e.target.closest('.callout-marker')) return;
                visibleModal.classList.remove('mock-highlight');
            });
        }

        // Set initial mode
        setMode('tour');
    });

    // ===== SLIDEOUT SLOT MANAGEMENT =====
    function buildSlideoutSlots() {
        if (!slideoutBody) return;
        slideoutBody.innerHTML = '';
        for (var i = 1; i <= totalMarkers; i++) {
            var slot = document.createElement('div');
            slot.className = 'slideout-slot';
            slot.setAttribute('data-section', i);
            slot.innerHTML = '<div class="slideout-slot-placeholder">' +
                '<span class="section-number">' + i + '</span>' +
                '<span class="slot-placeholder-text">Click marker ' + i + ' to reveal</span>' +
                '</div>';
            slideoutBody.appendChild(slot);
        }
    }

    function revealSlot(num) {
        var slot = slideoutBody.querySelector('.slideout-slot[data-section="' + num + '"]');
        if (!slot) return;

        if (slot.classList.contains('slot-revealed')) {
            highlightSlot(slot, num);
            return;
        }

        var sourceEl = document.querySelector('#section-' + num + ' .section');
        if (!sourceEl) return;

        slot.innerHTML = '';
        slot.classList.add('slot-revealed');

        var content = document.createElement('div');
        content.className = 'slideout-section-content';
        content.innerHTML = sourceEl.innerHTML;

        // Make the content clickable for bidirectional highlighting
        content.style.cursor = 'pointer';
        content.addEventListener('click', function () {
            highlightMockSection(num);
        });

        slot.appendChild(content);
        highlightSlot(slot, num);
    }

    function revealAllSlots() {
        for (var i = 1; i <= totalMarkers; i++) {
            var slot = slideoutBody.querySelector('.slideout-slot[data-section="' + i + '"]');
            if (!slot || slot.classList.contains('slot-revealed')) continue;

            var sourceEl = document.querySelector('#section-' + i + ' .section');
            if (!sourceEl) continue;

            slot.innerHTML = '';
            slot.classList.add('slot-revealed');

            var content = document.createElement('div');
            content.className = 'slideout-section-content';
            content.innerHTML = sourceEl.innerHTML;

            // Bidirectional click
            (function (num) {
                content.style.cursor = 'pointer';
                content.addEventListener('click', function () {
                    highlightMockSection(num);
                });
            })(i);

            slot.appendChild(content);
        }
    }

    function highlightSlot(slot, num) {
        slideoutBody.querySelectorAll('.slideout-slot').forEach(function (s) {
            s.classList.remove('slot-active');
        });
        slot.classList.add('slot-active');
        activeSection = num;

        // Also highlight the corresponding mock section
        highlightMockSection(num);

        setTimeout(function () {
            slot.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        }, 100);
    }

    // ===== MOCK SECTION HIGHLIGHTING =====
    function highlightMockSection(num) {
        // Clear all mock highlights
        document.querySelectorAll('[data-section]').forEach(function (el) {
            if (el.closest('.mock-container') || el.closest('.mock-header')) {
                el.classList.remove('mock-highlight', 'mock-flash');
            }
        });

        // Find all mock elements for this section (may be multiple, e.g. repeated time buttons)
        var mockEls = document.querySelectorAll('.mock-container [data-section="' + num + '"], .mock-header [data-section="' + num + '"]');
        if (mockEls.length === 0) return;

        // Flash then highlight all matching elements
        mockEls.forEach(function (mockEl) {
            mockEl.classList.add('mock-flash', 'mock-highlight');
            setTimeout(function () {
                mockEl.classList.remove('mock-flash');
            }, 600);
        });

        // Also flash the marker briefly
        flashMarker(num);

        // Highlight the corresponding slot in slideout if open
        var slot = slideoutBody.querySelector('.slideout-slot[data-section="' + num + '"]');
        if (slot && slot.classList.contains('slot-revealed')) {
            slideoutBody.querySelectorAll('.slideout-slot').forEach(function (s) {
                s.classList.remove('slot-active');
            });
            slot.classList.add('slot-active');
            setTimeout(function () {
                slot.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            }, 100);
        }

        activeSection = num;
    }

    function clearMockHighlights() {
        document.querySelectorAll('.mock-highlight').forEach(function (el) {
            el.classList.remove('mock-highlight', 'mock-flash');
        });
        activeSection = null;
    }

    function resetSlideout() {
        buildSlideoutSlots();
        closeSlideout();
        clearMockHighlights();
    }

    function openSlideout() {
        if (slideoutEl) slideoutEl.classList.add('open');
    }

    function closeSlideout() {
        if (slideoutEl) slideoutEl.classList.remove('open');
    }

    // ===== MODE TOGGLE =====
    function setMode(newMode) {
        mode = newMode;

        var tourBtn = document.getElementById('btn-tour');
        var showBtn = document.getElementById('btn-showall');
        if (tourBtn) tourBtn.classList.toggle('active', mode === 'tour');
        if (showBtn) showBtn.classList.toggle('active', mode === 'showall');

        if (mode === 'tour') {
            visited = {};
            tourGuided = true;
            nextSuggested = 1;
            resetSlideout();
            refreshMarkerStates();
        } else {
            visited = {};
            tourGuided = true;
            nextSuggested = 1;
            clearAllMarkerStates();
            clearMockHighlights();
            buildSlideoutSlots();
            revealAllSlots();
            for (var i = 1; i <= totalMarkers; i++) {
                visited[i] = true;
            }
            refreshMarkerStates();
            openSlideout();
        }
    }

    // ===== MARKER CLICK =====
    function handleMarkerClick(num) {
        if (mode === 'tour') {
            if (tourGuided && num !== nextSuggested) {
                tourGuided = false;
            }

            if (visited[num]) {
                flashMarker(num);
            }

            visited[num] = true;

            if (tourGuided) {
                nextSuggested = num + 1;
                if (nextSuggested > totalMarkers) {
                    nextSuggested = -1;
                }
            }

            revealSlot(num);
            openSlideout();
            refreshMarkerStates();

        } else {
            if (visited[num]) {
                flashMarker(num);
            }
            visited[num] = true;
            updateMarkerEl(num);

            var slot = slideoutBody.querySelector('.slideout-slot[data-section="' + num + '"]');
            if (slot) highlightSlot(slot, num);
        }
    }

    // ===== MARKER STATE MANAGEMENT =====
    function refreshMarkerStates() {
        for (var i = 1; i <= totalMarkers; i++) {
            var el = getMarkerEl(i);
            if (!el) continue;
            el.classList.remove('marker-pulsing', 'marker-visited', 'marker-flash');
            if (visited[i]) {
                el.classList.add('marker-visited');
            } else if (tourGuided && i === nextSuggested) {
                el.classList.add('marker-pulsing');
            }
        }
    }

    function clearAllMarkerStates() {
        for (var i = 1; i <= totalMarkers; i++) {
            var el = getMarkerEl(i);
            if (!el) continue;
            el.classList.remove('marker-pulsing', 'marker-flash', 'marker-visited');
        }
    }

    function updateMarkerEl(num) {
        var el = getMarkerEl(num);
        if (!el) return;
        el.classList.remove('marker-pulsing', 'marker-flash');
        if (visited[num]) {
            el.classList.add('marker-visited');
        }
    }

    function flashMarker(num) {
        var el = getMarkerEl(num);
        if (!el) return;
        el.classList.remove('marker-flash');
        void el.offsetWidth;
        el.classList.add('marker-flash');
        setTimeout(function () {
            el.classList.remove('marker-flash');
        }, 700);
    }

    function getMarkerEl(num) {
        var markers = document.querySelectorAll('.mock-container .callout-marker');
        for (var i = 0; i < markers.length; i++) {
            if (parseInt(markers[i].textContent.trim(), 10) === num) {
                return markers[i];
            }
        }
        return null;
    }

})();
