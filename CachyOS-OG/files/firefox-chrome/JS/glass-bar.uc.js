// ==UserScript==
// @name           Glass bar per wallpaper
// @description    Picks the tab/address bar colour and the active tab's
//                 darkening for the current wallpaper, from extra columns in
//                 Noctalia's wallpaper-schemes.conf. Follows wallpaper
//                 changes live (checks every 2 seconds).
// @onlyonce
// ==/UserScript==
//
// ~/.config/noctalia/wallpaper-schemes.conf, first matching line wins (the
// same line wallpaper-scheme and matcolor use; they ignore the extra columns):
//   # wallpaper (name/glob)   Noctalia scheme   bar                    tab
//   wall1.png                 m3-tonal-spot     solid                  35%
//   wall2.png                 m3-fruit-salad    a
//   wall3.png                 m3-content        rgba(0, 0, 0, 0.5)     0.2
//   wall4.png                 m3-content        -                      30%
//   *                         m3-tonal-spot
//
// bar:  a      Material surface colour as glass
//       b      dark glass with a hint of the Material primary colour (default)
//       solid  like b, but not see-through
//       -      the default (b), to give only a tab value
//       or any CSS colour (spaces are fine)
// tab:  how much darker the active tab is: 35% or 0.35 (default: 0, normal).
//       A number at the end of the line is always read as the tab value.
//
// The script sets two variables on each window for userChrome.css:
//   --glass-bar-bg     the bar colour
//   --glass-tab-dark   the active tab's extra darkness (0 to 1)
// The wallpaper is read from ~/.cache/current-wallpaper (a link to it, made
// by the Noctalia "On Wallpaper Changed" hook).

(function () {
  const { setInterval } = ChromeUtils.importESModule("resource://gre/modules/Timer.sys.mjs");
  const HOME = Services.dirsvc.get("Home", Ci.nsIFile).path;
  const CONF = HOME + "/.config/noctalia/wallpaper-schemes.conf";
  const LINK = HOME + "/.cache/current-wallpaper";

  const BARS = {
    a: "color-mix(in srgb, var(--toolbar-background-color) 70%, transparent)",
    b: "color-mix(in srgb, var(--toolbarbutton-icon-fill) 18%, rgba(16, 16, 20, 0.7))",
    solid: "color-mix(in srgb, var(--toolbarbutton-icon-fill) 18%, rgb(16, 16, 20))",
  };
  const DEFAULT = { bg: BARS.b, tab: "0" };

  const globToRegex = g =>
    new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");

  // "35%", "0.35" or "35" -> "0.35"; anything else -> null
  function tabValue(word) {
    const m = word.match(/^(\d+(?:\.\d+)?)(%?)$/);
    if (!m) return null;
    let v = parseFloat(m[1]);
    if (m[2] === "%" || v > 1) v /= 100;
    return String(Math.min(1, Math.max(0, v)));
  }

  function wallpaperPath() {
    try {
      const f = Cc["@mozilla.org/file/local;1"].createInstance(Ci.nsIFile);
      f.initWithPath(LINK);
      return f.exists() ? (f.isSymlink() ? f.target : f.path) : "";
    } catch (e) { return ""; }
  }

  function parse(conf, wall) {
    const name = wall.split("/").pop();
    for (const raw of conf.split("\n")) {
      // full-line comments, and "# ..." after the fields (a #hex colour stays)
      const line = raw.replace(/^\s*#.*$/, "").replace(/\s+#\s.*$/, "").trim();
      if (!line) continue;
      const f = line.split(/\s+/);
      if (f.length < 2) continue;
      const re = globToRegex(f[0]);
      if (!(re.test(name) || re.test(wall))) continue;

      // first match decides, like wallpaper-scheme
      const rest = f.slice(2);
      let tab = DEFAULT.tab;
      if (rest.length && tabValue(rest[rest.length - 1]) !== null) tab = tabValue(rest.pop());
      const bar = rest.join(" ");
      const bg = !bar || bar === "-" ? DEFAULT.bg : (BARS[bar.toLowerCase()] || bar);
      return { bg, tab };
    }
    return DEFAULT;
  }

  let lastKey = null;
  let current = DEFAULT;

  function applyAll() {
    for (const win of Services.wm.getEnumerator("navigator:browser")) {
      const s = win.document.documentElement.style;
      if (s.getPropertyValue("--glass-bar-bg") !== current.bg) s.setProperty("--glass-bar-bg", current.bg);
      if (s.getPropertyValue("--glass-tab-dark") !== current.tab) s.setProperty("--glass-tab-dark", current.tab);
    }
  }

  async function check() {
    const wall = wallpaperPath();
    let conf = "", confTime = 0;
    try { confTime = (await IOUtils.stat(CONF)).lastModified; } catch (e) {}
    const key = wall + "|" + confTime;
    if (key !== lastKey) {
      lastKey = key;
      if (confTime) {
        try { conf = await IOUtils.readUTF8(CONF); } catch (e) {}
      }
      current = parse(conf, wall);
    }
    applyAll();   // every time, so new windows get it too
  }

  check();
  setInterval(() => check().catch(e => console.error("glass-bar:", e)), 2000);
})();
