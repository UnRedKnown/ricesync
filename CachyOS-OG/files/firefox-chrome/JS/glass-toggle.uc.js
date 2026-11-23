// ==UserScript==
// @name           Glass toggle
// @description    Toolbar button that turns the glass styles on and off
//                 (flips the about:config pref user.glass.enabled)
// @onlyonce
// ==/UserScript==

(function () {
  // Firefox moved this module (resource:// -> moz-src://); browser windows
  // also have it as a global. Use whichever exists.
  let CUI = globalThis.CustomizableUI;
  for (const url of ["moz-src:///browser/components/customizableui/CustomizableUI.sys.mjs",
                     "resource:///modules/CustomizableUI.sys.mjs"]) {
    if (CUI) break;
    try { CUI = ChromeUtils.importESModule(url).CustomizableUI; } catch (e) {}
  }
  if (!CUI) { console.error("glass-toggle: CustomizableUI not found"); return; }
  const CustomizableUI = CUI;
  const PREF = "user.glass.enabled";
  const ID = "glass-toggle-button";

  function update(node) {
    const on = Services.prefs.getBoolPref(PREF, true);
    // Firefox draws a button as "pressed" whenever the checked attribute is
    // present (even checked="false"), so add it only while glass is off
    if (on) node.removeAttribute("checked");
    else node.setAttribute("checked", "true");
    node.setAttribute("tooltiptext", on ? "Glass styles: on (click to turn off)" : "Glass styles: off (click to turn on)");
  }

  // getWidget() returns something for any id, even unknown ones, so check
  // that it's a button made by a script (an "API" widget)
  if (CustomizableUI.getWidget(ID)?.provider === CustomizableUI.PROVIDER_API) return;

  CustomizableUI.createWidget({
    id: ID,
    type: "button",
    label: "Glass",
    tooltiptext: "Toggle glass styles",
    defaultArea: CustomizableUI.AREA_NAVBAR,
    onCreated: node => update(node),
    onCommand: () => Services.prefs.setBoolPref(PREF, !Services.prefs.getBoolPref(PREF, true)),
  });

  Services.prefs.addObserver(PREF, () => {
    for (const win of Services.wm.getEnumerator("navigator:browser")) {
      const node = win.document.getElementById(ID);
      if (node) update(node);
    }
  });
})();
