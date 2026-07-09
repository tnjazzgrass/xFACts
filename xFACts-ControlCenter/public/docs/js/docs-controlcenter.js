/* ============================================================================
   xFACts Control Center - Documentation Control Center Guide Behavior (docs-controlcenter.js)
   Location: E:\xFACts-ControlCenter\public\docs\js\docs-controlcenter.js
   Version: Tracked in dbo.System_Metadata (component: Documentation.Site)

   Drives the interactive Control Center guide pages: the guided-tour versus
   show-all mode toggle, the callout marker states over the mockup
   (idle, pulsing, visited, flash), the additive slideout panel that reveals
   section detail as markers are clicked, the bidirectional highlighting between
   the mockup and the slideout, and the flip key cards. All interaction runs
   through a single delegated body-click dispatcher registered at page boot.

   FILE ORGANIZATION
   -----------------
   STATE: GUIDE STATE
   FUNCTIONS: INITIALIZATION
   FUNCTIONS: EVENT DELEGATION
   FUNCTIONS: MODE
   FUNCTIONS: MARKERS
   FUNCTIONS: MOCK HIGHLIGHTING
   FUNCTIONS: SLIDEOUT
   ============================================================================ */

/* ============================================================================
   STATE: GUIDE STATE
   ----------------------------------------------------------------------------
   The mutable runtime state of the guide: the current mode, whether the guided
   tour is still in order, the next suggested marker, the visited-marker set,
   the total marker count, the active section, and the cached slideout panel and
   body elements.
   Prefix: doc
   ============================================================================ */

/* The current guide mode, either tour or showall. */
var doc_mode = 'tour';

/* Whether the guided tour is still being followed in order. */
var doc_tourGuided = true;

/* The marker number suggested next during a guided tour. */
var doc_nextSuggested = 1;

/* The set of visited marker numbers, keyed by marker number. */
var doc_visited = {};

/* The total number of callout markers on the page. */
var doc_totalMarkers = 0;

/* The currently highlighted section number, or null when none. */
var doc_activeSection = null;

/* The cached slideout panel element. */
var doc_slideoutEl = null;

/* The cached slideout body element. */
var doc_slideoutBody = null;

/* ============================================================================
   FUNCTIONS: INITIALIZATION
   ----------------------------------------------------------------------------
   The page boot function. Caches the slideout elements, counts the markers,
   builds the initial slideout slots, registers the single delegated body-click
   dispatcher, and sets the initial tour mode.
   Prefix: doc
   ============================================================================ */

/* Boots the guide page: caches elements, builds slots, binds delegation. */
function doc_init() {
    doc_slideoutEl = document.querySelector('.doc-guide-slideout');
    doc_slideoutBody = document.querySelector('.doc-guide-slideout-body');

    var markers = document.querySelectorAll('.doc-mock-container .doc-callout-marker');
    doc_totalMarkers = markers.length;

    doc_buildSlideoutSlots();
    document.body.addEventListener('click', doc_onBodyClick);
    doc_setMode('tour');
}

/* ============================================================================
   FUNCTIONS: EVENT DELEGATION
   ----------------------------------------------------------------------------
   The single delegated body-click dispatcher. Routes each click to the right
   handler by matching the closest interactive ancestor: callout markers, mode
   buttons, the slideout close control, flip cards, sidebar items, and revealed
   slideout content. A click that lands outside an open mock modal preview and
   not on a marker dismisses the preview.
   Prefix: doc
   ============================================================================ */

/* Routes a body click to the matching guide handler by closest ancestor. */
function doc_onBodyClick(event) {
    var marker = event.target.closest('.doc-callout-marker');
    if (marker) {
        event.preventDefault();
        doc_handleMarkerClick(parseInt(marker.textContent.trim(), 10));
        return;
    }

    var modeBtn = event.target.closest('.doc-mode-btn');
    if (modeBtn) {
        doc_setMode(modeBtn.getAttribute('data-doc-mode'));
        return;
    }

    var closeBtn = event.target.closest('.doc-guide-slideout-close');
    if (closeBtn) {
        doc_closeSlideout();
        return;
    }

    var flipCard = event.target.closest('.doc-key-flip-card');
    if (flipCard) {
        var flipInner = flipCard.querySelector('.doc-key-flip-inner');
        if (flipInner) {
            flipInner.classList.toggle('doc-key-flipped');
        }
        return;
    }

    var sidebarItem = event.target.closest('.doc-sidebar-item');
    if (sidebarItem) {
        doc_highlightMockSection(parseInt(sidebarItem.getAttribute('data-marker'), 10));
        return;
    }

    var slotContent = event.target.closest('.doc-slideout-section-content');
    if (slotContent) {
        doc_highlightMockSection(parseInt(slotContent.getAttribute('data-section'), 10));
        return;
    }

    doc_dismissModalPreview(event);
}

/* Dismisses an open mock modal preview on a click outside it and off markers. */
function doc_dismissModalPreview(event) {
    var container = document.querySelector('.doc-mock-container');
    if (!container) {
        return;
    }
    var preview = container.querySelector('.doc-mock-modal-preview.doc-mock-highlight');
    if (!preview) {
        return;
    }
    if (preview.contains(event.target)) {
        return;
    }
    if (event.target.closest('.doc-callout-marker')) {
        return;
    }
    preview.classList.remove('doc-mock-highlight');
}

/* ============================================================================
   FUNCTIONS: MODE
   ----------------------------------------------------------------------------
   The mode toggle between the guided tour and the show-all view. Tour mode
   resets the visited set and pulses the first marker; show-all mode reveals
   every slot, marks every marker visited, and opens the slideout.
   Prefix: doc
   ============================================================================ */

/* Switches the guide between tour and show-all modes. */
function doc_setMode(newMode) {
    doc_mode = newMode;

    var tourBtn = document.querySelector('.doc-mode-btn[data-doc-mode="tour"]');
    var showBtn = document.querySelector('.doc-mode-btn[data-doc-mode="showall"]');
    if (tourBtn) {
        tourBtn.classList.toggle('doc-mode-active', doc_mode === 'tour');
    }
    if (showBtn) {
        showBtn.classList.toggle('doc-mode-active', doc_mode === 'showall');
    }

    doc_visited = {};
    doc_tourGuided = true;
    doc_nextSuggested = 1;

    if (doc_mode === 'tour') {
        doc_resetSlideout();
        doc_refreshMarkerStates();
    } else {
        doc_clearAllMarkerStates();
        doc_clearMockHighlights();
        doc_buildSlideoutSlots();
        doc_revealAllSlots();
        for (var i = 1; i <= doc_totalMarkers; i++) {
            doc_visited[i] = true;
        }
        doc_refreshMarkerStates();
        doc_openSlideout();
    }
}

/* ============================================================================
   FUNCTIONS: MARKERS
   ----------------------------------------------------------------------------
   The callout marker behavior: handling a marker click in either mode,
   refreshing every marker's state class from the visited set and tour
   position, clearing all marker states, updating a single marker, flashing a
   marker on revisit, and locating a marker element by its number.
   Prefix: doc
   ============================================================================ */

/* Handles a marker click, revealing its slot and advancing the tour. */
function doc_handleMarkerClick(num) {
    if (doc_mode === 'tour') {
        if (doc_tourGuided && num !== doc_nextSuggested) {
            doc_tourGuided = false;
        }
        if (doc_visited[num]) {
            doc_flashMarker(num);
        }
        doc_visited[num] = true;
        if (doc_tourGuided) {
            doc_nextSuggested = num + 1;
            if (doc_nextSuggested > doc_totalMarkers) {
                doc_nextSuggested = -1;
            }
        }
        doc_revealSlot(num);
        doc_openSlideout();
        doc_refreshMarkerStates();
    } else {
        if (doc_visited[num]) {
            doc_flashMarker(num);
        }
        doc_visited[num] = true;
        doc_updateMarkerEl(num);
        var slot = doc_slideoutBody.querySelector('.doc-slideout-slot[data-section="' + num + '"]');
        if (slot) {
            doc_highlightSlot(slot, num);
        }
    }
}

/* Refreshes every marker's state class from visited and tour position. */
function doc_refreshMarkerStates() {
    for (var i = 1; i <= doc_totalMarkers; i++) {
        var el = doc_getMarkerEl(i);
        if (!el) {
            continue;
        }
        el.classList.remove('doc-marker-pulsing', 'doc-marker-visited', 'doc-marker-flash');
        if (doc_visited[i]) {
            el.classList.add('doc-marker-visited');
        } else if (doc_tourGuided && i === doc_nextSuggested) {
            el.classList.add('doc-marker-pulsing');
        }
    }
}

/* Clears every marker's state class. */
function doc_clearAllMarkerStates() {
    for (var i = 1; i <= doc_totalMarkers; i++) {
        var el = doc_getMarkerEl(i);
        if (!el) {
            continue;
        }
        el.classList.remove('doc-marker-pulsing', 'doc-marker-flash', 'doc-marker-visited');
    }
}

/* Updates a single marker's state to visited. */
function doc_updateMarkerEl(num) {
    var el = doc_getMarkerEl(num);
    if (!el) {
        return;
    }
    el.classList.remove('doc-marker-pulsing', 'doc-marker-flash');
    if (doc_visited[num]) {
        el.classList.add('doc-marker-visited');
    }
}

/* Flashes a marker briefly to signal a revisit. */
function doc_flashMarker(num) {
    var el = doc_getMarkerEl(num);
    if (!el) {
        return;
    }
    el.classList.remove('doc-marker-flash');
    void el.offsetWidth;
    el.classList.add('doc-marker-flash');
    setTimeout(function () {
        el.classList.remove('doc-marker-flash');
    }, 700);
}

/* Returns the marker element whose number matches, or null. */
function doc_getMarkerEl(num) {
    var markers = document.querySelectorAll('.doc-mock-container .doc-callout-marker');
    for (var i = 0; i < markers.length; i++) {
        if (parseInt(markers[i].textContent.trim(), 10) === num) {
            return markers[i];
        }
    }
    return null;
}

/* ============================================================================
   FUNCTIONS: MOCK HIGHLIGHTING
   ----------------------------------------------------------------------------
   The mockup highlighting: flashing and highlighting every mock element for a
   section number, mirroring the highlight into the slideout slot, flashing the
   marker, and clearing all mock highlights.
   Prefix: doc
   ============================================================================ */

/* Flashes and highlights every mock element bound to a section number. */
function doc_highlightMockSection(num) {
    var clearTargets = document.querySelectorAll('.doc-mock-container [data-section], .doc-mock-header [data-section]');
    for (var c = 0; c < clearTargets.length; c++) {
        clearTargets[c].classList.remove('doc-mock-highlight', 'doc-mock-flash');
    }

    var mockEls = document.querySelectorAll('.doc-mock-container [data-section="' + num + '"], .doc-mock-header [data-section="' + num + '"]');
    if (mockEls.length === 0) {
        return;
    }

    for (var m = 0; m < mockEls.length; m++) {
        var mockEl = mockEls[m];
        mockEl.classList.add('doc-mock-flash', 'doc-mock-highlight');
        doc_clearFlashLater(mockEl);
    }

    doc_flashMarker(num);

    var slot = doc_slideoutBody.querySelector('.doc-slideout-slot[data-section="' + num + '"]');
    if (slot && slot.classList.contains('doc-slot-revealed')) {
        doc_markSlotActive(slot);
        doc_scrollSlotIntoView(slot);
    }

    doc_activeSection = num;
}

/* Removes the transient flash class from a mock element after its animation. */
function doc_clearFlashLater(mockEl) {
    setTimeout(function () {
        mockEl.classList.remove('doc-mock-flash');
    }, 600);
}

/* Clears every mock highlight and flash and resets the active section. */
function doc_clearMockHighlights() {
    var els = document.querySelectorAll('.doc-mock-highlight');
    for (var i = 0; i < els.length; i++) {
        els[i].classList.remove('doc-mock-highlight', 'doc-mock-flash');
    }
    doc_activeSection = null;
}

/* ============================================================================
   FUNCTIONS: SLIDEOUT
   ----------------------------------------------------------------------------
   The additive slideout panel: building the numbered placeholder slots,
   revealing a single slot or all slots from the hidden section content,
   marking and scrolling the active slot, opening and closing the panel, and
   resetting it back to placeholders.
   Prefix: doc
   ============================================================================ */

/* Builds the numbered placeholder slots into the slideout body. */
function doc_buildSlideoutSlots() {
    if (!doc_slideoutBody) {
        return;
    }
    doc_slideoutBody.innerHTML = '';
    for (var i = 1; i <= doc_totalMarkers; i++) {
        var slot = document.createElement('div');
        slot.className = 'doc-slideout-slot';
        slot.setAttribute('data-section', i);
        slot.innerHTML = '<div class="doc-slideout-slot-placeholder">' +
            '<span class="doc-section-number">' + i + '</span>' +
            '<span class="doc-slot-placeholder-text">Click marker ' + i + ' to reveal</span>' +
            '</div>';
        doc_slideoutBody.appendChild(slot);
    }
}

/* Reveals a single slot's section content, or re-highlights it if revealed. */
function doc_revealSlot(num) {
    var slot = doc_slideoutBody.querySelector('.doc-slideout-slot[data-section="' + num + '"]');
    if (!slot) {
        return;
    }
    if (slot.classList.contains('doc-slot-revealed')) {
        doc_highlightSlot(slot, num);
        return;
    }
    var sourceEl = document.querySelector('#doc-section-' + num + ' .doc-guide-section-inner');
    if (!sourceEl) {
        return;
    }
    doc_fillSlot(slot, sourceEl, num);
    doc_highlightSlot(slot, num);
}

/* Reveals every unrevealed slot from its hidden section content. */
function doc_revealAllSlots() {
    for (var i = 1; i <= doc_totalMarkers; i++) {
        var slot = doc_slideoutBody.querySelector('.doc-slideout-slot[data-section="' + i + '"]');
        if (!slot || slot.classList.contains('doc-slot-revealed')) {
            continue;
        }
        var sourceEl = document.querySelector('#doc-section-' + i + ' .doc-guide-section-inner');
        if (!sourceEl) {
            continue;
        }
        doc_fillSlot(slot, sourceEl, i);
    }
}

/* Fills a slot with a clickable clone of its hidden section content. */
function doc_fillSlot(slot, sourceEl, num) {
    slot.innerHTML = '';
    slot.classList.add('doc-slot-revealed');
    var content = document.createElement('div');
    content.className = 'doc-slideout-section-content';
    content.setAttribute('data-section', num);
    content.innerHTML = sourceEl.innerHTML;
    slot.appendChild(content);
}

/* Marks a slot active, mirrors the mock highlight, and scrolls it into view. */
function doc_highlightSlot(slot, num) {
    doc_markSlotActive(slot);
    doc_activeSection = num;
    doc_highlightMockSection(num);
    doc_scrollSlotIntoView(slot);
}

/* Marks a single slot as the active slot, clearing the others. */
function doc_markSlotActive(slot) {
    var slots = doc_slideoutBody.querySelectorAll('.doc-slideout-slot');
    for (var i = 0; i < slots.length; i++) {
        slots[i].classList.remove('doc-slot-active');
    }
    slot.classList.add('doc-slot-active');
}

/* Scrolls a slot into view within the slideout body after a brief delay. */
function doc_scrollSlotIntoView(slot) {
    setTimeout(function () {
        slot.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }, 100);
}

/* Opens the slideout panel. */
function doc_openSlideout() {
    if (doc_slideoutEl) {
        doc_slideoutEl.classList.add('doc-slideout-open');
    }
}

/* Closes the slideout panel. */
function doc_closeSlideout() {
    if (doc_slideoutEl) {
        doc_slideoutEl.classList.remove('doc-slideout-open');
    }
}

/* Resets the slideout to placeholders, closes it, and clears highlights. */
function doc_resetSlideout() {
    doc_buildSlideoutSlots();
    doc_closeSlideout();
    doc_clearMockHighlights();
}

document.addEventListener('DOMContentLoaded', doc_init);
