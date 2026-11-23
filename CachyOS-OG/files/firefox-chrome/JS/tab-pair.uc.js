// ==UserScript==
// @name           Tab pairs
// @description    Two tabs as one: clicking the active one switches to the other
// @include        main
// ==/UserScript==
//
// Right-click a tab -> "Pair with next tab": the next tab is hidden and this
// one gets a small ⇄ next to its close button. Clicking the pair while it's already the active tab
// switches to the other page, in the same place on the tab bar. Clicking it
// from another tab just goes to it. Right-click -> "Unpair tabs" brings both
// back as normal tabs, and so does closing one of them (the other stays).
// Pairs survive restarts (kept in Firefox's session store).
// The hidden page stays loaded, so its notifications keep coming.

(function () {
    if (window.__tabPairs) return;
    window.__tabPairs = true;

    const SS = (() => {
        try { return SessionStore; } catch (e) {}
        return ChromeUtils.importESModule("resource:///modules/sessionstore/SessionStore.sys.mjs").SessionStore;
    })();
    const KEY_ID = "tabPairId", KEY_HIDDEN = "tabPairHidden";

    const style = document.createElement("style");
    style.textContent = `
        .tab-pair-icon {
            flex: none; margin-inline: 4px 2px; opacity: .6;
            font-size: 1.1em; line-height: 1; pointer-events: none;
        }`;
    document.documentElement.appendChild(style);

    const tabs = () => [...gBrowser.tabs];
    // a tab's pair id: on the tab, or (right after a restart) in the session
    const pairIdOf = tab => tab.getAttribute("tab-pair") || SS.getCustomTabValue(tab, KEY_ID) || null;
    const partnerOf = tab => {
        const id = pairIdOf(tab);
        return id ? tabs().find(t => t !== tab && pairIdOf(t) === id && !t.closing) : null;
    };

    // the ⇄, as its own little element in the tab's row, just before the
    // close button: the tab lays it out like its other parts, any width
    function mark(tab, on) {
        const old = tab.querySelector(".tab-pair-icon");
        if (!on) return old && old.remove();
        if (old) return;
        const content = tab.querySelector(".tab-content");
        if (!content) return;
        const icon = document.createElement("span");
        icon.className = "tab-pair-icon";
        icon.textContent = "⇄";
        content.insertBefore(icon, content.querySelector(".tab-close-button"));
    }

    function setPair(tab, id, hidden) {
        mark(tab, !!id);
        if (id) {
            tab.setAttribute("tab-pair", id);
            SS.setCustomTabValue(tab, KEY_ID, id);
            SS.setCustomTabValue(tab, KEY_HIDDEN, hidden ? "1" : "0");
        } else {
            tab.removeAttribute("tab-pair");
            try { SS.deleteCustomTabValue(tab, KEY_ID); SS.deleteCustomTabValue(tab, KEY_HIDDEN); } catch (e) {}
        }
    }

    // keep the hidden partner right next to the visible one
    function placeAfter(tab, target) {
        if (tab._tPos === target._tPos + 1) return;
        try {
            if (gBrowser.moveTabsAfter) return gBrowser.moveTabsAfter([tab], target);
        } catch (e) {}
        const index = target._tPos + (tab._tPos > target._tPos ? 1 : 0);
        try { gBrowser.moveTabTo(tab, { tabIndex: index }); } catch (e) { gBrowser.moveTabTo(tab, index); }
    }

    function pair(tab) {
        const visible = tabs().filter(t => !t.hidden && !t.pinned);
        const next = visible[visible.indexOf(tab) + 1];
        if (!next || tab.pinned || tab.hasAttribute("tab-pair") || next.hasAttribute("tab-pair")) return;
        const id = String(Date.now());
        setPair(tab, id, false);
        setPair(next, id, true);
        if (next.selected) gBrowser.selectedTab = tab;
        gBrowser.hideTab(next);
        load(next);
    }

    function unpair(tab) {
        const other = partnerOf(tab);
        setPair(tab, null);
        if (other) {
            setPair(other, null);
            gBrowser.showTab(other);
        }
    }

    function swap(tab) {
        const other = partnerOf(tab);
        if (!other) return unpair(tab);
        gBrowser.showTab(other);
        placeAfter(other, tab);
        gBrowser.selectedTab = other;
        gBrowser.hideTab(tab);
        SS.setCustomTabValue(other, KEY_HIDDEN, "0");
        SS.setCustomTabValue(tab, KEY_HIDDEN, "1");
    }

    // a click on the tab that was already active switches (mousedown selects,
    // so remember the state from before it)
    let wasSelected = null;
    gBrowser.tabContainer.addEventListener("mousedown", e => {
        const tab = e.target.closest(".tabbrowser-tab");
        wasSelected = (e.button === 0 && tab && tab.selected && tab.hasAttribute("tab-pair")) ? tab : null;
    }, true);
    gBrowser.tabContainer.addEventListener("click", e => {
        const tab = e.target.closest(".tabbrowser-tab");
        if (e.button !== 0 || !tab || tab !== wasSelected) return;
        if (e.target.closest(".tab-close-button, .tab-icon-overlay, .tab-audio-button")) return;
        wasSelected = null;
        swap(tab);
    });

    // closing one: the other becomes a normal tab again
    gBrowser.tabContainer.addEventListener("TabClose", e => {
        const tab = e.target;
        if (!tab.hasAttribute("tab-pair")) return;
        const other = partnerOf(tab);
        if (other) { setPair(other, null); gBrowser.showTab(other); }
    });

    // the menu
    const menu = document.getElementById("tabContextMenu");
    const sep = document.createXULElement("menuseparator");
    const itemPair = document.createXULElement("menuitem");
    itemPair.setAttribute("label", "Pair with next tab");
    const itemUnpair = document.createXULElement("menuitem");
    itemUnpair.setAttribute("label", "Unpair tabs");
    menu.append(sep, itemPair, itemUnpair);
    const target = () => (typeof TabContextMenu !== "undefined" && TabContextMenu.contextTab) || gBrowser.selectedTab;
    itemPair.addEventListener("command", () => pair(target()));
    itemUnpair.addEventListener("command", () => unpair(target()));
    menu.addEventListener("popupshowing", e => {
        if (e.target !== menu) return;
        const paired = target().hasAttribute("tab-pair");
        itemPair.hidden = paired;
        itemUnpair.hidden = !paired;
    });

    // Firefox loads hidden tabs only once they're shown, and other tabs only
    // once they're clicked, so after a restart the hidden half of a pair sat
    // there unloaded (no notifications). Ask Firefox's session restore to load
    // it now (the same request its split view uses for its tabs).
    function load(tab) {
        if (!tab.hasAttribute("pending")) return;
        tab.dispatchEvent(new CustomEvent("TabSplitViewActivate",
            { bubbles: true, detail: { tabs: [tab] } }));
    }

    // after a restart: put the pairs back together
    function restore(tab) {
        const id = SS.getCustomTabValue(tab, KEY_ID);
        if (!id) return;
        tab.setAttribute("tab-pair", id);
        mark(tab, true);
        if (SS.getCustomTabValue(tab, KEY_HIDDEN) === "1" && !tab.selected) gBrowser.hideTab(tab);
        setTimeout(() => load(tab), 1500);
    }
    // (Firefox restores a tab's page only when it's first shown, so this runs
    // for all tabs once the window is back, not when each page loads)
    const restoreAll = () => tabs().forEach(restore);
    window.addEventListener("SSWindowRestored", restoreAll);
    try { SS.promiseAllWindowsRestored.then(restoreAll); } catch (e) {}
    gBrowser.tabContainer.addEventListener("SSTabRestoring", e => restore(e.target));
    restoreAll();
})();
