import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Universal Keybinding Explorer ("learn mode") for Omarchy. https://github.com/angusforbes/omarchy-universal-keybinding-explorer
//
// bin/keybinding-explorer puts Hyprland into the `keybinding-explorer` submap (which binds
// only Escape and SUPER+ALT+K, both of which leave) and summons this overlay.
// With the normal bindings out of the way, every key and chord reaches this
// keyboard-exclusive layer instead of firing its action:
//   * held modifiers pop up as keycaps, in the order they were pressed;
//   * the bindings that use exactly those modifiers are listed below;
//   * completing a chord shows what it does, using the same descriptions as
//     the SUPER+K list (`omarchy-menu-keybindings --print` is the source).
//
// Dry check (no window is shown; result goes to the shell log, prefix
// "keybinding-explorer-dry:"):
//   omarchy-shell shell summon angusforbes.universal-keybinding-explorer '{"dry":true,"mods":["SUPER","SHIFT"],"key":"1"}'
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  readonly property string pluginId: (manifest && manifest.id) || "angusforbes.universal-keybinding-explorer"

  property bool opened: false

  // Parsed bindings: { mods: "SUPER SHIFT", key: "1", keyU: "1", desc: "…" }
  // `bindings` is the ACTIVE set: Hyprland's (hyprBindings) normally, an app's keymap in app mode.
  property var bindings: []
  property var hyprBindings: []
  property var pendingDry: null

  // App contexts: keymaps/<id>.json, one per app (format: README.md "App keymaps"). In app mode the
  // chords are looked up in that app's keys; Hyprland's own binds stay in the set as "Hyprland: …" (they fire
  // first, so they win). Esc (via `keybinding-explorer esc`) or Backspace goes back to Hyprland mode.
  readonly property string keymapDir: String(Qt.resolvedUrl("keymaps")).replace(/^file:\/\//, "")
  property var apps: []            // loaded keymap files
  property var app: null           // the app whose keys are explained, or null (Hyprland mode)
  property bool appAuto: false     // app mode came from the focused window at open
  property var pendingFocus: null  // { class, title } of the window focused when SUPER+ALT+CTRL+K was pressed (`keybinding-explorer app`)
  property bool dryRunning: false
  // App mode views: "app" = only the app's own keys (default; an app key Hyprland grabs first is marked
  // "⚠ taken by Hyprland"), "all" = the app's keys plus every Hyprland bind as "Hyprland: …". F1 toggles (free in
  // vibezAI and in Hyprland; shown in the header).
  property string appView: "app"
  readonly property string viewKey: "F1"
  // Commands: ":" in app mode lists the app's ":" commands; the letters after it filter them.
  property bool cmdMode: false
  property string cmdFilter: ""

  // Live chord state.
  property var held: []            // modifiers currently held, in press order
  property var shownMods: []       // modifier set on screen; stays after release until the next chord/modifier
  property var comboMods: []       // modifiers held when the last key was pressed
  property string comboKey: ""     // last non-modifier key ("" = none yet)

  // Search. Plain typing (letters, digits, space, Backspace, with or without
  // SHIFT) edits this; nothing is bound to those keys, so there is no conflict.
  // Anything with SUPER / CTRL / ALT, and bare special keys, stay lookups.
  property string filterText: ""
  property var searchRows: []
  property int caretPos: 0         // caret index in filterText
  property int caretTick: 0        // bumped on every edit/move so the caret stops blinking

  // Derived view state (recomputed by refresh()).
  property string activeModKey: ""
  property var matches: []
  property var variants: []
  property var rows: []
  property int hitRow: -1
  // Search panel parked for now. Flip to true
  // to bring back the bottom search box and plain-typing search.
  readonly property bool searchEnabled: false
  // Key mode: a bare (unmodified) key was pressed; the list shows every
  // binding on that key and stays while Up/Down previews them.
  property string browseKey: ""
  // Word mode: letters typed quickly (each within typeGapMs of the last) build
  // a word that is searched across every binding; a slower key starts over as
  // a single-key lookup.
  readonly property int typeGapMs: 400
  property string typedWord: ""
  property double lastTypeMs: 0
  property string browseWord: ""
  property bool browseAll: false   // arrows started on the idle list: keep the full list while previewing
  property int cursorRow: -1       // Up/Down (bare) moves this through the list

  // Display order for modifiers: SUPER, CTRL, SHIFT, ALT, then the key, whatever order they
  // are written or pressed in. modKey(), the rows, the keycaps and the sort all follow it.
  readonly property var modOrder: ["SUPER", "CTRL", "SHIFT", "ALT"]

  // Theme tokens: share the [menu] surface so it looks like SUPER+K / emojis.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color scrim: Color.menu.scrim
  property color accent: Color.menu.selectedText
  property color selectedBackground: Color.menu.selectedBackground
  property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Math.min(Style.space(760), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(720), panel.height - Style.gapsOut * 2)
  property int capHeight: Math.max(Style.space(52), Style.font.display + Style.space(24))

  // ---------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) { payload = {} }

    // `keybinding-explorer esc` while in app mode: back to Hyprland mode, the overlay stays.
    // With the command list open, Esc only closes the list (the script already removed the flag: set it again).
    if (payload.leaveApp) {
      if (root.opened && root.cmdMode) { root.exitCmd(); root.setAppFlag(true) }
      else if (root.opened) root.leaveApp()
      return
    }

    root.resetChord()
    if (payload.dry) {
      root.pendingDry = payload
    } else {
      root.pendingFocus = payload.focus || null
      root.opened = true
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
    // Reload every time so freshly edited bindings.lua and keymaps show up: keymaps first, then the bindings.
    keymapLoader.running = false
    keymapLoader.running = true
  }

  function close() {
    root.opened = false
    root.leaveApp()
    root.resetChord()
  }

  // ------------------------------------------------------------- app contexts

  function loadKeymaps(text) {
    var list = []
    try { list = JSON.parse(text || "[]") || [] } catch (e) { console.warn("keybinding-explorer: bad keymap JSON", e); list = [] }
    list = list.filter(function(a) { return a && (Array.isArray(a.bindings) || Array.isArray(a.commands)) })
    // Shared files ("shared": true, no app of their own) hold keys or commands several apps have; an app pulls them in
    // with "include": [ids]. The app's own entries win: an included key is dropped when the app has the same chord,
    // an included command when the app has one of the same name.
    var byId = {}
    list.forEach(function(a) { if (a.id) byId[a.id] = a })
    var mapB = function(b) {
      var mods = String(b.mods || "").split(/[\s+]+/).filter(function(m) { return m.length > 0 })
      var desc = (b.section ? b.section + ": " : "") + b.desc
      return { mods: root.modKey(mods), key: String(b.key), keyU: String(b.key).toUpperCase(), desc: desc, section: b.section || "" }
    }
    var mapC = function(c) { return { cmd: String(c.cmd), args: c.args || "", desc: c.desc || "", where: c.where || "", aliases: c.aliases || [] } }
    root.apps = list.filter(function(a) { return a.app && !a.shared }).map(function(a) {
      var bs = (a.bindings || []).map(mapB), cs = (a.commands || []).map(mapC)
      var have = {}, haveC = {}
      bs.forEach(function(b) { have[b.mods + "|" + b.keyU] = true })
      cs.forEach(function(c) { haveC[c.cmd] = true })
      ;[].concat(a.include || []).forEach(function(id) {
        var sh = byId[id]
        if (!sh) { console.warn("keybinding-explorer: " + a.app + " includes a missing keymap", id); return }
        ;(sh.bindings || []).map(mapB).forEach(function(b) { var k = b.mods + "|" + b.keyU; if (!have[k]) { have[k] = true; bs.push(b) } })
        ;(sh.commands || []).map(mapC).forEach(function(c) { if (!haveC[c.cmd]) { haveC[c.cmd] = true; cs.push(c) } })
      })
      return { id: a.id || a.app, app: a.app, about: a.about || "", match: a.match || [], focus: a.focus || {}, bindings: bs, commands: cs,
               prefix: String(a.prefix || ":") }
    })
  }

  // Search words that find an app entry: every typed word must be in its name or one of its match words.
  function appsMatching(q) {
    var toks = String(q || "").toLowerCase().split(/\s+/).filter(function(t) { return t.length > 0 })
    if (toks.length === 0) return []
    return root.apps.filter(function(a) {
      var hay = ([a.app, a.id].concat(a.match)).join(" ").toLowerCase()
      return toks.every(function(t) { return hay.indexOf(t) >= 0 })
    })
  }

  // The app whose keymap "focus" rule matches the focused window: class and/or title regexes (case-insensitive).
  function appForWindow(w) {
    if (!w) return null
    var test = function(pats, s) {
      return [].concat(pats || []).some(function(p) { try { return new RegExp(p, "i").test(String(s || "")) } catch (e) { return false } })
    }
    for (var i = 0; i < root.apps.length; i++) {
      var f = root.apps[i].focus
      if (test(f.class, w["class"]) || test(f.title, w.title)) return root.apps[i]
    }
    return null
  }

  function findApp(id) {
    var u = String(id || "").toLowerCase()
    for (var i = 0; i < root.apps.length; i++) if (root.apps[i].id.toLowerCase() === u || root.apps[i].app.toLowerCase() === u) return root.apps[i]
    return null
  }

  function setAppFlag(on) {
    if (root.dryRunning) return
    Quickshell.execDetached(["bash", "-c", on ? 'touch "${XDG_RUNTIME_DIR:-/tmp}/keybinding-explorer-app"' : 'rm -f "${XDG_RUNTIME_DIR:-/tmp}/keybinding-explorer-app"'])
  }

  function enterApp(a, auto) {
    if (!a) return
    root.app = a
    root.appAuto = !!auto
    root.appView = "app"   // app-only view by default
    root.bindings = root.appBindingSet()
    root.setAppFlag(true)
    root.resetChord()
  }

  // The active set for the current view. Hyprland grabs its chords before any app sees them: in "all" they are listed
  // after the app's keys as "Hyprland: …"; in "app" they are left out, but an app key Hyprland takes is marked.
  function appBindingSet() {
    var a = root.app
    if (!a) return root.hyprBindings
    var hyp = {}
    root.hyprBindings.forEach(function(b) { var k = b.mods + "|" + b.keyU; if (!hyp[k]) hyp[k] = b.desc })
    var own = a.bindings.map(function(b) {
      var t = hyp[b.mods + "|" + b.keyU]
      if (!t) return b
      return { mods: b.mods, key: b.key, keyU: b.keyU, section: b.section, taken: t,
               desc: b.desc + "  \u26a0 taken by Hyprland (" + t + ")" }
    })
    if (root.appView !== "all") return own
    return own.concat(root.hyprBindings.map(function(b) {
      return { mods: b.mods, key: b.key, keyU: b.keyU, desc: "Hyprland: " + b.desc, global: true }
    }))
  }

  function toggleView() {
    if (!root.app) return
    root.appView = root.appView === "all" ? "app" : "all"
    root.bindings = root.appBindingSet()
    root.resetChord()
  }

  // ":" commands, filtered: names (or aliases) starting with the typed letters; if none do, any whose name,
  // arguments, aliases or description contain them.
  function commandRows(f) {
    var q = String(f || "").toLowerCase().trim()
    var cs = root.app ? root.app.commands : []
    var pre = [], rest = []
    cs.forEach(function(c) {
      var names = [c.cmd].concat(c.aliases)
      if (q === "" || names.some(function(n) { return n.toLowerCase().indexOf(q) === 0 })) pre.push(c)
      else if ((names.join(" ") + " " + c.args + " " + c.desc).toLowerCase().indexOf(q) >= 0) rest.push(c)
    })
    // Like the app's own Tab completion: name prefixes; only when none fits, any command mentioning the letters.
    return (pre.length ? pre : rest).map(function(c) {
      return { cmdRow: c, left: root.app.prefix + c.cmd + (c.args ? " " + c.args : ""), right: c.desc, hit: false }
    })
  }

  function enterCmd() {
    root.resetChord()
    root.cmdMode = true
    root.cmdFilter = ""
    root.refresh()
  }

  function exitCmd() {
    if (!root.cmdMode) return
    root.cmdMode = false
    root.cmdFilter = ""
    root.refresh()
  }

  // App mode: ":" opens the command list; while it's open printable keys filter it and Backspace edits (on an empty
  // filter it closes the list). Returns true when it took the key. Up/Down are handled before this (they browse).
  function cmdKey(event) {
    if (!root.app) return false
    var hard = event.modifiers & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier)
    if (!root.cmdMode) {
      if (!hard && event.text === root.app.prefix && root.browseWord === "") { root.enterCmd(); return true }
      return false
    }
    if (hard) { root.exitCmd(); return false }
    if (event.key === Qt.Key_Backspace) {
      if (root.cmdFilter === "") root.exitCmd()
      else { root.cmdFilter = root.cmdFilter.slice(0, -1); root.refresh() }
      return true
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) return true   // explain only: nothing runs
    if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
      root.cmdFilter += event.text
      root.refresh()
      return true
    }
    root.exitCmd()
    return false
  }

  // Dry runs: type a string as plain key presses through the same paths as the keyboard.
  function dryType(t) {
    for (var i = 0; i < t.length; i++) {
      var ch = t[i], ev = { key: 0, text: ch, modifiers: 0, isAutoRepeat: false, nativeScanCode: 0 }
      if (root.cmdKey(ev)) continue
      root.applyWord(root.typedWord + ch)
    }
  }

  function leaveApp() {
    var was = root.app !== null
    root.app = null
    root.appAuto = false
    root.bindings = root.hyprBindings
    if (was) root.setAppFlag(false)
    root.resetChord()
  }

  // Enter on an app row (the cursor's, else the first one listed) opens that app's keys.
  function pickApp() {
    if (root.app) return false
    var r = root.cursorRow >= 0 && root.rows[root.cursorRow] && root.rows[root.cursorRow].app ? root.rows[root.cursorRow] : null
    for (var i = 0; !r && i < root.rows.length; i++) if (root.rows[i].app) r = root.rows[i]
    if (!r) return false
    root.enterApp(r.app, false)
    return true
  }

  // Leaving from inside the overlay (not normally used: Escape and
  // SUPER+ALT+K are submap binds that run `keybinding-explorer off`).
  function leave() {
    Quickshell.execDetached(["bash", "-c", "exec \"$HOME/.local/bin/keybinding-explorer\" off"])
  }

  // ------------------------------------------------------------------ parsing

  // Aliases → the four names: MOD / MOD4 / WIN / LOGO / META / CMD = SUPER, CONTROL / CTL = CTRL, MOD1 = ALT.
  readonly property var modAliases: ({ "SUPER": "SUPER", "MOD": "SUPER", "MOD4": "SUPER", "WIN": "SUPER", "WINDOWS": "SUPER", "LOGO": "SUPER",
    "META": "SUPER", "CMD": "SUPER", "CTRL": "CTRL", "CONTROL": "CTRL", "CTL": "CTRL", "SHIFT": "SHIFT", "ALT": "ALT", "MOD1": "ALT" })
  function canonMod(m) { var u = String(m).toUpperCase().replace(/^\$/, ""); return root.modAliases[u] || u }
  function isModWord(m) { return root.modAliases.hasOwnProperty(String(m).toUpperCase().replace(/^\$/, "")) }
  // Modifiers in modOrder; anything unknown is kept after them (never dropped).
  function modKey(list) {
    var out = [], canon = list.map(root.canonMod)
    for (var i = 0; i < modOrder.length; i++)
      if (canon.indexOf(modOrder[i]) >= 0) out.push(modOrder[i])
    for (var j = 0; j < canon.length; j++)
      if (out.indexOf(canon[j]) < 0) out.push(canon[j])
    return out.join(" ")
  }

  // Search (typed keyword and the parked search panel), order-insensitive: modifier words, in any order
  // or alias ("shift super s", "super+shift+s", "win s"), must all be on the binding; other words must be in
  // its combo, key or description. Exact hits first: the typed key itself, then exactly the typed modifiers.
  function findBindings(q) {
    var toks = String(q || "").toLowerCase().split(/[\s+]+/).filter(function(t) { return t.length > 0 })
    if (toks.length === 0) return []
    var needMods = [], terms = []
    for (var i = 0; i < toks.length; i++) {
      if (root.isModWord(toks[i])) { var cm = root.canonMod(toks[i]); if (needMods.indexOf(cm) < 0) needMods.push(cm) }
      else terms.push(toks[i])
    }
    var found = []
    for (var w = 0; w < root.bindings.length; w++) {
      var b = root.bindings[w], have = b.mods ? b.mods.split(" ") : [], ok = true
      for (var m = 0; m < needMods.length && ok; m++) if (have.indexOf(needMods[m]) < 0) ok = false
      if (!ok) continue
      var hay = (root.prettyCombo(b) + " " + b.key + " " + b.desc).toLowerCase()
      for (var t = 0; t < terms.length && ok; t++) if (hay.indexOf(terms[t]) < 0) ok = false
      if (!ok) continue
      var keyHit = terms.some(function(x) { return x === b.keyU.toLowerCase() || x === String(root.prettyKey(b.key)).toLowerCase() })
      var modsHit = needMods.length > 0 && needMods.length === have.length
      found.push({ b: b, score: (keyHit ? 2 : 0) + (modsHit ? 1 : 0), i: w })
    }
    found.sort(function(x, y) { return (y.score - x.score) || (x.i - y.i) })
    return found.map(function(f) { return f.b })
  }

  function parse(text) {
    var out = []
    var seen = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var arrow = line.indexOf("→")
      if (arrow < 0) continue
      var left = line.slice(0, arrow).trim()
      var desc = line.slice(arrow + 1).trim()
      if (!left) continue
      var plus = left.lastIndexOf(" + ")
      var modsStr = plus < 0 ? "" : left.slice(0, plus)
      var key = plus < 0 ? left : left.slice(plus + 3).trim()
      var mods = modsStr.split(/\s+/).filter(function(m) { return m.length > 0 }).map(function(m) {
        return root.canonMod(m)
      })
      var b = { mods: modKey(mods), key: key, keyU: key.toUpperCase(), desc: desc }
      var id = b.mods + "|" + b.keyU + "|" + desc
      if (seen[id]) continue
      seen[id] = true
      out.push(b)
    }
    root.hyprBindings = out
    root.app = null
    root.appAuto = false
    root.bindings = out
    root.refresh()
    root.refreshSearch()

    // Opened while an app with a keymap was focused: start in its context.
    if (root.pendingFocus) {
      var fa = root.appForWindow(root.pendingFocus)
      root.pendingFocus = null
      if (fa) root.enterApp(fa, true)
      else root.setAppFlag(false)
    }

    if (root.pendingDry) {
      var p = root.pendingDry
      root.pendingDry = null
      root.dryRunning = true
      if (p.focus) { var dfa = root.appForWindow(p.focus); if (dfa) root.enterApp(dfa, true) }
      if (p.app) root.enterApp(root.findApp(p.app), false)
      var pm = (p.mods || []).map(function(m) { return String(m).toUpperCase() })
      for (var j = 0; j < pm.length; j++) root.modPressed(pm[j])
      if (p.filter) root.setFilter(String(p.filter))
      if (p.filter) root.caretPos = root.filterText.length
      var ek = { left: Qt.Key_Left, right: Qt.Key_Right, home: Qt.Key_Home, end: Qt.Key_End, bs: Qt.Key_Backspace, del: Qt.Key_Delete }
      ;(p.edits || []).forEach(function(e) {
        root.typed(ek[e] ? { key: ek[e], text: "", modifiers: 0 } : { key: 0, text: String(e), modifiers: 0 })
      })
      if (p.key) root.chord(String(p.key))
      else root.refresh()
      if (p.release) root.held = []
      if (p.word !== undefined) root.applyWord(String(p.word))
      ;(p.wordMods || []).forEach(function(m) { root.modPressed(String(m).toUpperCase()) })
      var sk = { up: Qt.Key_Up, down: Qt.Key_Down, pageup: Qt.Key_PageUp, pagedown: Qt.Key_PageDown }
      ;(p.scroll || []).forEach(function(d) { if (sk[d]) root.scrollList(sk[d]) })
      if (p.enter) { if (!root.pickApp()) root.chord("RETURN") }
      if (p.then) {   // keys after entering an app: [{mods, key}], each pressed and let go
        ;[].concat(p.then).forEach(function(c) {
          if (c.esc) { if (root.cmdMode) root.exitCmd(); else root.leaveApp(); return }
          if (c.toggle) { root.toggleView(); return }
          if (c.type !== undefined) { root.dryType(String(c.type)); return }
          if (c.backspace) { if (!root.cmdKey({ key: Qt.Key_Backspace, text: "", modifiers: 0 })) root.backspaceKey(); return }
          root.held = []
          ;(c.mods || []).forEach(function(m) { root.modPressed(String(m).toUpperCase()) })
          if (c.key) root.chord(String(c.key))
          if (c.word !== undefined) root.applyWord(String(c.word))
        })
      }
      console.log("keybinding-explorer-dry: " + JSON.stringify({
        app: root.app ? root.app.app : "",
        appAuto: root.appAuto,
        view: root.app ? root.appView : "",
        cmdMode: root.cmdMode,
        cmdFilter: root.cmdFilter,
        listTitle: listTitle.text,
        title: titleText.text,
        exit: exitText.text,
        meaning: mainText.text,
        apps: root.apps.map(function(a) { return a.app + " (" + a.bindings.length + ")" }),
        bindings: root.bindings.length,
        chips: root.chipLabels(),
        activeMods: root.activeModKey,
        matches: root.matches.map(function(b) { return b.desc }),
        variants: root.variants.map(function(b) { return root.prettyCombo(b) + " → " + b.desc }),
        rows: root.rows.length,
        firstRows: root.rows.slice(0, 5).map(function(r) { return r.left + " → " + r.right }),
        search: root.searchRows.slice(0, 5).map(function(r) { return r.left + " → " + r.right }),
        searchCount: root.searchRows.length,
        hitRow: root.hitRow,
        cursorRow: root.cursorRow,
        filterText: root.filterText,
        caretPos: root.caretPos,
        cursorAt: root.cursorRow >= 0 ? root.rows[root.cursorRow].left + " → " + root.rows[root.cursorRow].right : ""
      }))
      root.leaveApp()
      root.dryRunning = false
      root.resetChord()
      if (!root.opened && root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    }
  }

  // ------------------------------------------------------------- chord state

  // The search panel is independent of the chord view above it.
  function setFilter(text) {
    root.filterText = text
    root.refreshSearch()
  }

  // Punctuation typed in the search box -> the key name used in bindings.
  readonly property var charKeyNames: ({ "-": "MINUS", "=": "EQUAL", ",": "COMMA", ".": "PERIOD", "/": "SLASH",
    "[": "BRACKETLEFT", "]": "BRACKETRIGHT", ";": "SEMICOLON", "'": "APOSTROPHE", "`": "GRAVE", "\\": "BACKSLASH" })

  function escHtml(t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }

  function refreshSearch() {
    var out = []
    var q = root.filterText.trim()
    if (q.length === 1) {
      // One character = that KEY, with any modifiers (A -> SUPER+A,
      // SUPER+SHIFT+A, ...), not every binding containing the letter.
      var want = root.charKeyNames[q] || q.toUpperCase()
      var hits = root.bindings.filter(function(b) { return b.keyU === want })
      hits.sort(function(x, y) {
        var dx = x.mods ? x.mods.split(" ").length : 0, dy = y.mods ? y.mods.split(" ").length : 0
        return dx - dy
      })
      for (var h = 0; h < hits.length; h++) {
        var hb = hits[h]
        out.push({
          leftHtml: (hb.mods ? root.escHtml(hb.mods) + " + " : "")
                    + "<font color='" + root.accent + "'><b>" + root.escHtml(root.prettyKey(hb.key)) + "</b></font>",
          rightHtml: root.escHtml(hb.desc),
          left: root.prettyCombo(hb), right: hb.desc
        })
      }
    } else {
      var hits2 = root.findBindings(q)
      for (var i = 0; i < hits2.length; i++) {
        var combo = root.prettyCombo(hits2[i])
        out.push({ leftHtml: root.highlight(combo), rightHtml: root.highlight(hits2[i].desc), left: combo, right: hits2[i].desc })
      }
    }
    root.searchRows = out
    Qt.callLater(function() { searchList.positionViewAtBeginning() })
  }


  // Bare Up/Down/PageUp/PageDown (nothing bound to them) move a cursor through
  // the bindings list. With any modifier held they are ordinary lookups.
  function isScrollKey(event) {
    var k = event.key
    if (k !== Qt.Key_Up && k !== Qt.Key_Down && k !== Qt.Key_PageUp && k !== Qt.Key_PageDown) return false
    if (event.modifiers & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier)) return false
    return root.held.length === 0
  }

  function scrollList(k) {
    var n = root.rows.length
    if (n === 0) return
    var page = Math.max(1, Math.floor(list.height / Style.spacing.popupRowHeight) - 1)
    var step = k === Qt.Key_Up ? -1 : k === Qt.Key_Down ? 1 : k === Qt.Key_PageUp ? -page : page
    var cur = root.cursorRow
    if (cur < 0) cur = step > 0 ? -1 : n
    var next = Math.max(0, Math.min(n - 1, cur + step))
    // Skip group headers, in the direction of travel (then the other way).
    var dir = step > 0 ? 1 : -1
    while (next >= 0 && next < n && root.rows[next].header) next += dir
    if (next < 0 || next >= n) {
      next = Math.max(0, Math.min(n - 1, next))
      while (next >= 0 && next < n && root.rows[next].header) next -= dir
    }
    if (next < 0 || next >= n || root.rows[next].header) return
    var row = root.rows[next]
    if (row.app || row.cmdRow) {   // an app entry ("Enter to explore") or a ":" command: shown up top
      root.comboMods = []
      root.comboKey = ""
      root.refresh(next)
      return
    }
    // Show the highlighted binding up top as if its chord had been pressed.
    if (root.comboKey === "" && root.shownMods.length === 0 && root.browseWord === "" && root.browseKey === "") root.browseAll = true
    root.comboMods = row.mods ? row.mods.split(" ") : []
    root.comboKey = row.key
    root.refresh(next)
    // Keep the group's header in view when landing on its first binding.
    if (next > 0 && root.rows[next - 1].header)
      Qt.callLater(function() { list.positionViewAtIndex(next - 1, ListView.Contain) })
  }

  // Search editing keys: printable characters (SHIFT allowed), Backspace,
  // Delete, and bare Left/Right/Home/End for the caret. None of these are
  // bound without SUPER/CTRL/ALT, so they never hide a real lookup.
  // Printable main-block keys (SHIFT allowed, nothing else held), plus
  // Backspace while a typed word is on screen.
  function isWordKey(event) {
    if (event.modifiers & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier)) return false
    for (var i = 0; i < root.held.length; i++) if (root.held[i] !== "SHIFT") return false
    if (event.key === Qt.Key_Backspace) return root.typedWord.length > 0
    var sc = root.scanNames[event.nativeScanCode]
    if (!sc || sc === "RETURN" || sc === "TAB" || sc === "BACKSPACE") return false
    return !!event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
  }

  function typingFast() {
    return root.typedWord !== "" && (Date.now() - root.lastTypeMs) <= root.typeGapMs
  }

  // Once two letters have come in quickly we are in word mode, and every
  // later letter (at any speed) extends the word until Backspace empties it.
  function wordKey(event) {
    var inWord = root.browseWord !== ""
    var fast = root.typingFast()
    root.lastTypeMs = Date.now()
    if (event.key === Qt.Key_Backspace) {
      if (inWord) root.applyWord(root.typedWord.slice(0, -1))
      else root.resetChord()
      return
    }
    if (inWord || fast) { root.applyWord(root.typedWord + event.text); return }
    if (event.isAutoRepeat) return
    // A fresh (slow) key: look up just that key, and start a new word with it.
    root.typedWord = event.text
    root.bareKey(root.keyName(event))
  }

  // Show one key on its own (every binding on it), ignoring a held SHIFT.
  function bareKey(name) {
    root.browseAll = false
    root.browseWord = ""
    root.browseKey = String(name).toUpperCase()
    root.comboMods = []
    root.shownMods = []
    root.comboKey = name
    root.refresh()
  }

  function applyWord(w) {
    root.typedWord = w
    if (w.trim().length === 0) { root.resetChord(); return }
    if (w.length === 1) {
      // One letter is never a keyword: it's that key's lookup (e.g. after
      // Backspacing "om" down to "o"). A quick next letter makes a word again.
      root.bareKey(root.charKeyNames[w] || w.toUpperCase())
      root.typedWord = w
      return
    }
    root.browseAll = false
    root.browseKey = ""
    root.browseWord = w
    root.comboKey = ""
    root.comboMods = []
    root.shownMods = []
    root.refresh()
  }

  function isTyping(event) {
    var hard = Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier
    if (event.modifiers & hard) return false
    for (var i = 0; i < root.held.length; i++) if (root.held[i] !== "SHIFT") return false
    var k = event.key
    if (k === Qt.Key_Backspace) return true
    if (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Home || k === Qt.Key_End || k === Qt.Key_Delete)
      return !(event.modifiers & Qt.ShiftModifier) && root.held.length === 0
    var sc = root.scanNames[event.nativeScanCode]
    if (!sc || sc === "RETURN" || sc === "TAB") return false  // only the main typing block
    return !!event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
  }

  function typed(event) {
    var t = root.filterText, c = Math.max(0, Math.min(root.caretPos, t.length))
    switch (event.key) {
    case Qt.Key_Backspace:
      if (event.modifiers & Qt.ShiftModifier) { root.caretPos = 0; root.setFilter(""); }
      else if (c > 0) { root.caretPos = c - 1; root.setFilter(t.slice(0, c - 1) + t.slice(c)) }
      break
    case Qt.Key_Delete:
      if (c < t.length) root.setFilter(t.slice(0, c) + t.slice(c + 1))
      break
    case Qt.Key_Left: root.caretPos = Math.max(0, c - 1); break
    case Qt.Key_Right: root.caretPos = Math.min(t.length, c + 1); break
    case Qt.Key_Home: root.caretPos = 0; break
    case Qt.Key_End: root.caretPos = t.length; break
    default:
      root.caretPos = c + event.text.length
      root.setFilter(t.slice(0, c) + event.text + t.slice(c))
    }
    root.caretTick++
  }

  // Search terms highlighted in the accent colour (StyledText).
  function highlight(text) {
    var esc = function(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    var terms = root.filterText.toLowerCase().split(/\s+/).filter(function(t) { return t.length > 0 })
    if (terms.length === 0) return esc(text)
    var lower = text.toLowerCase(), marks = []
    for (var i = 0; i < text.length; i++) marks.push(false)
    for (var t = 0; t < terms.length; t++) {
      var from = 0, at
      while ((at = lower.indexOf(terms[t], from)) >= 0) {
        for (var j = at; j < at + terms[t].length; j++) marks[j] = true
        from = at + terms[t].length
      }
    }
    var out = "", on = false
    for (var k = 0; k < text.length; k++) {
      if (marks[k] && !on) { out += "<font color='" + root.accent + "'><b>"; on = true }
      if (!marks[k] && on) { out += "</b></font>"; on = false }
      out += esc(text[k])
    }
    return on ? out + "</b></font>" : out
  }

  // Backspace with no typed word: in app mode it goes back to Hyprland mode; otherwise it's a lookup.
  function backspaceKey() {
    if (root.app && root.typedWord === "") { root.leaveApp(); return true }
    return false
  }

  function resetChord() {
    root.cmdMode = false
    root.cmdFilter = ""
    root.typedWord = ""
    root.browseWord = ""
    root.browseAll = false
    root.browseKey = ""
    root.filterText = ""
    root.caretPos = 0
    root.searchRows = []
    root.held = []
    root.shownMods = []
    root.comboMods = []
    root.comboKey = ""
    root.refresh()
  }

  function modPressed(m) {
    if (root.cmdMode) {   // command list: SHIFT is for ":" and capitals; another modifier closes the list
      if (m === "SHIFT") { if (root.held.indexOf(m) < 0) root.held = root.held.concat([m]); return }
      root.cmdMode = false
      root.cmdFilter = ""
    }
    if (m === "SHIFT" && (root.browseWord !== "" || root.typingFast())) {   // capital letter mid-word
      if (root.held.indexOf(m) < 0) root.held = root.held.concat([m])
      return
    }
    // CTRL / ALT / SUPER (or SHIFT outside a word) drops any typed word and goes
    // back to plain chord mode, as if the word had never been typed.
    var hadWord = root.browseWord !== "" || root.typedWord !== ""
    root.typedWord = ""
    if (hadWord) {
      root.comboKey = ""
      root.comboMods = []
      root.shownMods = root.held.filter(function(x) { return x !== m })  // e.g. a SHIFT still down
    }
    root.browseWord = ""
    root.browseAll = false
    root.browseKey = ""
    if (root.comboKey !== "") {   // a new chord starts
      root.comboKey = ""
      root.comboMods = []
    }
    // First modifier after everything was let go starts a fresh set.
    if (root.held.length === 0) root.shownMods = []
    if (root.held.indexOf(m) < 0) root.held = root.held.concat([m])
    if (root.shownMods.indexOf(m) < 0) root.shownMods = root.shownMods.concat([m])
    root.refresh()
  }

  function modReleased(m) {
    // The modifier set (and any finished chord) stays on screen after release,
    // so Up/Down can then browse that set. Only a new key/modifier replaces it.
    root.held = root.held.filter(function(x) { return x !== m })
  }

  function syncHeld(qtMods) {
    var want = []
    if (qtMods & Qt.MetaModifier) want.push("SUPER")
    if (qtMods & Qt.ShiftModifier) want.push("SHIFT")
    if (qtMods & Qt.ControlModifier) want.push("CTRL")
    if (qtMods & Qt.AltModifier) want.push("ALT")
    var kept = root.held.filter(function(m) { return want.indexOf(m) >= 0 })
    for (var i = 0; i < want.length; i++) if (kept.indexOf(want[i]) < 0) kept.push(want[i])
    root.held = kept
  }

  function chord(name) {
    root.typedWord = ""
    root.browseWord = ""
    root.browseAll = false
    root.browseKey = root.held.length === 0 ? String(name).toUpperCase() : ""
    root.comboMods = root.held.slice()
    root.shownMods = root.held.slice()
    root.comboKey = name
    root.refresh()
  }

  function chipLabels() {
    var mods = root.comboKey !== "" ? root.comboMods : root.shownMods
    var out = root.modKey(mods).split(" ").filter(function(x) { return x.length > 0 })   // SUPER CTRL SHIFT ALT, not press order
    if (root.cmdMode) return [root.app.prefix + root.cmdFilter.replace(/ /g, "\u2423")]
    if (root.comboKey !== "") out.push(root.displayKey(root.comboKey))
    else if (root.browseWord !== "") out.push(root.browseWord.replace(/ /g, "\u2423"))
    return out
  }

  // Friendly labels for the special (XF86 media/function-row) keys and the
  // mouse wheel. Icons are the ones Omarchy's own OSD uses. Only the display
  // changes; search still matches the real names too.
  function g(cp) { return String.fromCodePoint(cp) }
  readonly property var prettyNames: ({
    "XF86AUDIORAISEVOLUME": root.g(0xf028) + "  Volume up key",
    "XF86AUDIOLOWERVOLUME": root.g(0xf027) + "  Volume down key",
    "XF86AUDIOMUTE": root.g(0xeee8) + "  Mute key",
    "XF86AUDIOMICMUTE": root.g(0xf036d) + "  Mic mute key",
    "XF86AUDIOPLAY": root.g(0xf040a) + "  Play/pause key",
    "XF86AUDIOPAUSE": root.g(0xf03e4) + "  Pause key",
    "XF86AUDIONEXT": root.g(0xf04ad) + "  Next track key",
    "XF86AUDIOPREV": root.g(0xf04ae) + "  Previous track key",
    "XF86MONBRIGHTNESSUP": root.g(0xf185) + "  Brightness up key",
    "XF86MONBRIGHTNESSDOWN": root.g(0xf185) + "  Brightness down key",
    "XF86KBDBRIGHTNESSUP": root.g(0xf030c) + "  Keyboard backlight up",
    "XF86KBDBRIGHTNESSDOWN": root.g(0xf030c) + "  Keyboard backlight down",
    "XF86KBDLIGHTONOFF": root.g(0xf030c) + "  Keyboard backlight on/off",
    "XF86CALCULATOR": "Calculator key",
    "XF86EJECT": root.g(0xf052) + "  Eject key",
    "XF86POWEROFF": root.g(0xf0425) + "  Power button",
    "XF86TOUCHPADTOGGLE": root.g(0xf07f8) + "  Touchpad toggle key",
    "XF86TOUCHPADON": root.g(0xf07f8) + "  Touchpad on key",
    "XF86TOUCHPADOFF": root.g(0xf07f8) + "  Touchpad off key",
    "XF86TOOLS": "F13 (Tools)",
    "MOUSE_UP": "Scroll up",
    "MOUSE_DOWN": "Scroll down"
  })

  function prettyKey(key) {
    return root.prettyNames[String(key).toUpperCase()] || key
  }

  function prettyCombo(b) {
    return (b.mods ? b.mods + " + " : "") + root.prettyKey(b.key)
  }

  // Prefer the spelling used in the bindings list (e.g. "Home"), then prettify.
  function displayKey(name) {
    return root.prettyKey(root.rawDisplayKey(name))
  }

  function rawDisplayKey(name) {
    var u = String(name).toUpperCase()
    for (var i = 0; i < root.bindings.length; i++)
      if (root.bindings[i].keyU === u) return root.bindings[i].key
    return name
  }

  // Fewest modifiers first, then SUPER < CTRL < SHIFT < ALT combinations (modOrder).
  function modSort(x, y) {
    var dx = x.mods ? x.mods.split(" ").length : 0, dy = y.mods ? y.mods.split(" ").length : 0
    if (dx !== dy) return dx - dy
    var w = function(m) { var t = 0; m.split(" ").forEach(function(p) { t = t * 5 + (root.modOrder.indexOf(p) + 1) }); return t }
    return w(x.mods || "") - w(y.mods || "")
  }

  function keyRank(k) {
    if (/^[A-Z]$/.test(k)) return 0
    if (/^[0-9]$/.test(k)) return 1
    if (/^F[0-9]+$/.test(k)) return 2
    return 3
  }

  function refresh(keepCursor) {
    var mods = root.comboKey !== "" ? root.comboMods : root.shownMods
    var mk = modKey(mods)
    var keyU = root.comboKey.toUpperCase()
    root.activeModKey = mk

    var matches = [], variants = [], rows = []
    if (root.comboKey !== "") {
      for (var i = 0; i < root.bindings.length; i++) {
        var b = root.bindings[i]
        if (b.keyU !== keyU) continue
        if (b.mods === mk) matches.push(b)
        else variants.push(b)
      }
    }

    if (root.app && root.cmdMode) {
      rows = root.commandRows(root.cmdFilter)
    } else if (root.browseWord !== "") {
      // Apps with a keymap whose name or match words fit come first: Enter opens their keys.
      if (!root.app) {
        var am = root.appsMatching(root.browseWord)
        for (var ai = 0; ai < am.length; ai++)
          rows.push({ app: am[ai], left: "App: " + am[ai].app, right: (am[ai].about ? am[ai].about + ". " : "")
                      + "Enter explains its " + am[ai].bindings.length + " keys", hit: false })
      }
      // Word typed quickly: every binding whose keys or description contain
      // all its words (case-insensitive), in the order of the SUPER+K list.
      // Modifier words match in any order; see findBindings. Only spaces so far: nothing matches yet.
      var found = root.findBindings(root.browseWord)
      for (var f = 0; f < found.length; f++)
        rows.push({ mods: found[f].mods, key: found[f].key, left: root.prettyCombo(found[f]), right: found[f].desc,
                    hit: root.comboKey !== "" && found[f].mods === mk && found[f].keyU === keyU })
      if (root.comboKey === "") variants = found.slice()   // shown as "Examples"
      if (root.app) rows = rows.concat(root.commandRows(root.browseWord).filter(function(r) {   // and its ":" commands
        var hay = (r.left + " " + r.right).toLowerCase()
        return root.browseWord.toLowerCase().split(/\s+/).filter(function(t) { return t }).every(function(t) { return hay.indexOf(t) >= 0 })
      }))
    } else if (root.browseKey !== "") {
      // Every binding on this key, fewest modifiers first.
      var onKey = root.bindings.filter(function(b) { return b.keyU === root.browseKey })
      onKey.sort(root.modSort)
      for (var q = 0; q < onKey.length; q++)
        rows.push({ mods: onKey[q].mods, key: onKey[q].key, left: root.prettyCombo(onKey[q]), right: onKey[q].desc,
                    hit: root.comboKey !== "" && onKey[q].mods === mk && onKey[q].keyU === keyU })
    } else if (root.app && (root.browseAll || (mods.length === 0 && root.comboKey === ""))) {
      // App mode, idle / browsing: the app's own keys (not Hyprland's), grouped by the app's sections, in keymap order.
      var secs = {}, secNames = []
      root.bindings.forEach(function(b) {
        if (b.global) return
        if (!secs[b.section]) { secs[b.section] = []; secNames.push(b.section) }
        secs[b.section].push(b)
      })
      secNames.forEach(function(s) {
        rows.push({ header: true, left: s || root.app.app, right: secs[s].length + (secs[s].length === 1 ? " key" : " keys"), hit: false })
        secs[s].forEach(function(b) {
          var d = b.section && b.desc.indexOf(b.section + ": ") === 0 ? b.desc.slice(b.section.length + 2) : b.desc
          rows.push({ mods: b.mods, key: b.key, left: root.prettyCombo(b), right: d,
                      hit: root.comboKey !== "" && b.mods === mk && b.keyU === keyU })
        })
      })
      var cmdRows = root.commandRows("")
      if (cmdRows.length) {   // the app's ":" commands
        rows.push({ header: true, left: "Commands (type " + root.app.prefix + ")", right: cmdRows.length + (cmdRows.length === 1 ? " command" : " commands"), hit: false })
        rows = rows.concat(cmdRows)
      }
    } else if (root.browseAll || (mods.length === 0 && root.comboKey === "")) {
      // Idle / browsing: every binding, grouped under a header per modifier
      // set (biggest set first), so Up/Down can walk through all of them.
      var groups = {}, names = []
      for (var j = 0; j < root.bindings.length; j++) {
        var gb = root.bindings[j]
        if (!groups[gb.mods]) { groups[gb.mods] = []; names.push(gb.mods) }
        groups[gb.mods].push(gb)
      }
      names.sort(function(a, b) { return groups[b].length - groups[a].length })
      for (var gi = 0; gi < names.length; gi++) {
        var gl = groups[names[gi]]
        gl.sort(function(a, b) {
          var r = root.keyRank(a.keyU) - root.keyRank(b.keyU)
          return r !== 0 ? r : a.keyU.localeCompare(b.keyU)
        })
        rows.push({ header: true, left: names[gi] || "No modifier", right: gl.length + (gl.length === 1 ? " binding" : " bindings"), hit: false })
        for (var gk = 0; gk < gl.length; gk++)
          rows.push({ mods: gl[gk].mods, key: gl[gk].key, left: root.prettyKey(gl[gk].key), right: gl[gk].desc,
                      hit: root.comboKey !== "" && gl[gk].mods === mk && gl[gk].keyU === keyU })
      }
    } else {
      var group = root.bindings.filter(function(b) { return b.mods === mk })
      group.sort(function(a, b) {
        var r = root.keyRank(a.keyU) - root.keyRank(b.keyU)
        return r !== 0 ? r : a.keyU.localeCompare(b.keyU)
      })
      for (var k = 0; k < group.length; k++)
        rows.push({ mods: mk, key: group[k].key, left: root.prettyKey(group[k].key), right: group[k].desc, hit: root.comboKey !== "" && group[k].keyU === keyU })
    }

    if (!(root.browseWord !== "" && root.comboKey === "")) variants.sort(root.modSort)
    // App mode: a chord Hyprland grabs is listed first, since it never reaches the app.
    if (root.app) matches.sort(function(x, y) { return (y.global ? 1 : 0) - (x.global ? 1 : 0) })

    var hit = -1
    for (var r = 0; r < rows.length; r++) if (rows[r].hit) { hit = r; break }

    root.matches = matches
    root.variants = variants
    root.rows = rows
    root.hitRow = hit
    root.cursorRow = (keepCursor !== undefined && keepCursor >= 0 && keepCursor < rows.length) ? keepCursor : hit
    root.syncChips(root.chipLabels())
    if (root.cursorRow >= 0) Qt.callLater(function() { list.positionViewAtIndex(root.cursorRow, ListView.Contain) })
    else Qt.callLater(function() { list.positionViewAtBeginning() })
  }

  // Keep delegates for unchanged chips so only new keycaps "pop".
  function syncChips(labels) {
    var last = root.comboKey !== "" || root.browseWord !== "" || root.cmdMode
    var keep = 0
    while (keep < chipModel.count && keep < labels.length
           && chipModel.get(keep).label === labels[keep]
           && chipModel.get(keep).isKey === (last && keep === labels.length - 1)) keep++
    while (chipModel.count > keep) chipModel.remove(chipModel.count - 1)
    for (var i = keep; i < labels.length; i++)
      chipModel.append({ label: labels[i], isKey: last && i === labels.length - 1 })
  }

  // ------------------------------------------------------------ key decoding

  function modifierName(key) {
    switch (key) {
    case Qt.Key_Shift: return "SHIFT"
    case Qt.Key_Control: return "CTRL"
    case Qt.Key_Alt: case Qt.Key_AltGr: return "ALT"
    case Qt.Key_Meta: case Qt.Key_Super_L: case Qt.Key_Super_R:
    case Qt.Key_Hyper_L: case Qt.Key_Hyper_R: return "SUPER"
    }
    return ""
  }

  // xkb keycodes (evdev + 8) for the main block, so SHIFT+1 reads "1", not "!".
  readonly property var scanNames: ({
    10: "1", 11: "2", 12: "3", 13: "4", 14: "5", 15: "6", 16: "7", 17: "8", 18: "9", 19: "0",
    20: "MINUS", 21: "EQUAL", 22: "BACKSPACE", 23: "TAB",
    24: "Q", 25: "W", 26: "E", 27: "R", 28: "T", 29: "Y", 30: "U", 31: "I", 32: "O", 33: "P",
    34: "BRACKETLEFT", 35: "BRACKETRIGHT", 36: "RETURN",
    38: "A", 39: "S", 40: "D", 41: "F", 42: "G", 43: "H", 44: "J", 45: "K", 46: "L",
    47: "SEMICOLON", 48: "APOSTROPHE", 49: "GRAVE", 51: "BACKSLASH",
    52: "Z", 53: "X", 54: "C", 55: "V", 56: "B", 57: "N", 58: "M",
    59: "COMMA", 60: "PERIOD", 61: "SLASH", 65: "SPACE"
  })

  function qtKeyName(k) {
    switch (k) {
    case Qt.Key_Return: case Qt.Key_Enter: return "RETURN"
    case Qt.Key_Tab: case Qt.Key_Backtab: return "TAB"
    case Qt.Key_Space: return "SPACE"
    case Qt.Key_Backspace: return "BACKSPACE"
    case Qt.Key_Delete: return "DELETE"
    case Qt.Key_Insert: return "INSERT"
    case Qt.Key_Home: return "HOME"
    case Qt.Key_End: return "END"
    case Qt.Key_PageUp: return "PRIOR"
    case Qt.Key_PageDown: return "NEXT"
    case Qt.Key_Left: return "LEFT"
    case Qt.Key_Right: return "RIGHT"
    case Qt.Key_Up: return "UP"
    case Qt.Key_Down: return "DOWN"
    case Qt.Key_Print: return "PRINT"
    case Qt.Key_Escape: return "ESCAPE"
    case Qt.Key_VolumeUp: return "XF86AudioRaiseVolume"
    case Qt.Key_VolumeDown: return "XF86AudioLowerVolume"
    case Qt.Key_VolumeMute: return "XF86AudioMute"
    case Qt.Key_MicMute: return "XF86AudioMicMute"
    case Qt.Key_MediaPlay: case Qt.Key_MediaTogglePlayPause: return "XF86AudioPlay"
    case Qt.Key_MediaPause: return "XF86AudioPause"
    case Qt.Key_MediaNext: return "XF86AudioNext"
    case Qt.Key_MediaPrevious: return "XF86AudioPrev"
    case Qt.Key_MonBrightnessUp: return "XF86MonBrightnessUp"
    case Qt.Key_MonBrightnessDown: return "XF86MonBrightnessDown"
    case Qt.Key_KeyboardBrightnessUp: return "XF86KbdBrightnessUp"
    case Qt.Key_KeyboardBrightnessDown: return "XF86KbdBrightnessDown"
    case Qt.Key_KeyboardLightOnOff: return "XF86KbdLightOnOff"
    case Qt.Key_Calculator: return "XF86Calculator"
    case Qt.Key_Eject: return "XF86Eject"
    case Qt.Key_PowerOff: return "XF86PowerOff"
    case Qt.Key_Tools: return "XF86Tools"
    case Qt.Key_TouchpadToggle: return "XF86TouchpadToggle"
    case Qt.Key_TouchpadOn: return "XF86TouchpadOn"
    case Qt.Key_TouchpadOff: return "XF86TouchpadOff"
    }
    if (k >= Qt.Key_F1 && k <= Qt.Key_F35) return "F" + (k - Qt.Key_F1 + 1)
    return ""
  }

  function keyName(event) {
    var byScan = root.scanNames[event.nativeScanCode]
    if (byScan) return byScan
    var byQt = root.qtKeyName(event.key)
    if (byQt) return byQt
    if (event.text && event.text.length === 1 && event.text.charCodeAt(0) > 32) return event.text.toUpperCase()
    return "key 0x" + event.key.toString(16)
  }

  function mouseName(button) {
    if (button === Qt.LeftButton) return "LEFT MOUSE BUTTON"
    if (button === Qt.RightButton) return "RIGHT MOUSE BUTTON"
    if (button === Qt.MiddleButton) return "MIDDLE MOUSE BUTTON"
    return ""
  }

  ListModel { id: chipModel }

  Process {
    id: keymapLoader
    command: ["bash", "-c", "shopt -s nullglob; f=(\"$1\"/*.json); (( ${#f[@]} )) && jq -cs . \"${f[@]}\" || echo '[]'", "_", root.keymapDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loadKeymaps(text)
        loader.running = false
        loader.running = true
      }
    }
  }

  Process {
    id: loader
    command: [root.omarchyPath + "/bin/omarchy-menu-keybindings", "--print"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
  }

  // --------------------------------------------------------------------- UI

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "universal-keybinding-explorer"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }

    // Mouse chords (SUPER + click / scroll) are learnable too; clicks never
    // dismiss. Escape is the way out.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      onPressed: function(mouse) {
        var n = root.mouseName(mouse.button)
        if (!n) return
        root.syncHeld(mouse.modifiers)
        root.chord(n)
        keyCatcher.forceActiveFocus()
      }
      // Bare wheel scrolls the bindings list like Up/Down (nothing is bound to
      // it); with SUPER/ALT/... held it is a lookup (e.g. SUPER + Scroll down).
      property real wheelAcc: 0
      onWheel: function(wheel) {
        if (wheel.angleDelta.y === 0) return
        var hard = Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier
        if (!(wheel.modifiers & hard) && root.held.length === 0) {
          var r = Util.wheelSteps(wheelAcc, wheel.angleDelta.y)
          wheelAcc = r.remainder
          var n = Math.abs(r.steps)
          for (var i = 0; i < n; i++) root.scrollList(r.steps > 0 ? Qt.Key_Up : Qt.Key_Down)
          return
        }
        wheelAcc = 0
        root.syncHeld(wheel.modifiers)
        root.chord(wheel.angleDelta.y > 0 ? "mouse_up" : "mouse_down")
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        event.accepted = true
        var mod = root.modifierName(event.key)
        if (mod) { if (!event.isAutoRepeat) root.modPressed(mod); return }
        // Held arrows / Backspace / letters repeat; chords do not.
        if (root.isScrollKey(event)) { root.scrollList(event.key); return }
        // App mode: F1 switches app-only / app + Hyprland; ":" opens the command list and filters it.
        if (root.app && event.key === Qt.Key_F1 && !event.isAutoRepeat && !(event.modifiers & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier))) { root.toggleView(); return }
        if (root.cmdKey(event)) return
        // App contexts: Enter on a listed app opens its keys; Backspace (no word) goes back to Hyprland.
        var bare = !(event.modifiers & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier)) && root.held.length === 0
        if (bare && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !event.isAutoRepeat && root.pickApp()) return
        if (bare && event.key === Qt.Key_Backspace && !event.isAutoRepeat && root.backspaceKey()) return
        if (root.searchEnabled && root.isTyping(event)) { root.typed(event); return }
        if (root.isWordKey(event)) { root.wordKey(event); return }
        if (event.isAutoRepeat) return
        root.syncHeld(event.modifiers)
        root.chord(root.keyName(event))
      }
      Keys.onReleased: function(event) {
        event.accepted = true
        if (event.isAutoRepeat) return
        var mod = root.modifierName(event.key)
        if (mod) root.modReleased(mod)
      }
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      Item {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // Header
        Item {
          id: header
          anchors { top: parent.top; left: parent.left; right: parent.right }
          // Title on the left, elided; the hints share its row only in Hyprland mode (short), and in app mode sit on
          // their own dim line underneath, so the two never overlap, however long the app name or narrow the card.
          height: titleText.implicitHeight + (root.app ? Style.spacing.sm + exitText.implicitHeight : 0)

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.top: parent.top
            width: Math.max(0, parent.width - (root.app ? 0 : exitText.implicitWidth + Style.spacing.lg))
            elide: Text.ElideRight
            text: "󰌌  Universal Keybinding Explorer" + (root.app ? "  \u00b7  " + root.app.app + (root.appAuto ? " (focused)" : "") : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
          Text {
            id: exitText
            x: root.app ? 0 : parent.width - width
            y: root.app ? titleText.implicitHeight + Style.spacing.sm : (titleText.implicitHeight - implicitHeight) / 2
            width: root.app ? parent.width : implicitWidth
            elide: Text.ElideRight
            // The view's name leads the hint line, so it stays readable when a long app name elides the title.
            text: root.app ? (root.appView === "all" ? "App + Hyprland keys" : "App keys only") + "  \u00b7  "
                             + root.viewKey + ": " + (root.appView === "all" ? "app keys only" : "show Hyprland keys too")
                             + "  \u00b7  Esc: back to Hyprland  \u00b7  SUPER ALT + K: leave" : "Esc or SUPER ALT + K to leave"
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Keycaps
        Item {
          id: capsArea
          anchors { top: header.bottom; topMargin: Style.spacing.huge; left: parent.left; right: parent.right }
          height: root.capHeight

          Text {
            anchors.centerIn: parent
            visible: chipModel.count === 0
            text: "Press any key or chord"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Row {
            id: capsRow
            anchors.centerIn: parent
            spacing: Style.spacing.lg

            Repeater {
              model: chipModel
              delegate: Row {
                id: chipRow
                required property int index
                required property string label
                required property bool isKey
                spacing: Style.spacing.lg

                Text {
                  visible: chipRow.index > 0
                  anchors.verticalCenter: parent.verticalCenter
                  text: "+"
                  color: root.foreground
                  opacity: 0.45
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }

                // Keycap: outer rect is the rim, a thicker bottom edge gives depth.
                Rectangle {
                  id: cap
                  height: root.capHeight
                  width: Math.max(height, capLabel.implicitWidth + Style.space(28))
                  radius: root.cornerRadius
                  color: chipRow.isKey ? root.accent : Util.alpha(root.foreground, 0.45)
                  transformOrigin: Item.Center
                  scale: 0.6
                  opacity: 0

                  Rectangle {
                    anchors { fill: parent; leftMargin: 1; rightMargin: 1; topMargin: 1; bottomMargin: Style.space(4) }
                    radius: root.cornerRadius
                    color: root.background

                    Rectangle {
                      anchors.fill: parent
                      radius: root.cornerRadius
                      color: chipRow.isKey ? Util.alpha(root.accent, 0.14) : Style.normalFill
                    }

                    Text {
                      id: capLabel
                      anchors.centerIn: parent
                      text: chipRow.label
                      color: chipRow.isKey ? root.accent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.heading
                      font.bold: true
                    }
                  }

                  ParallelAnimation {
                    id: pop
                    SequentialAnimation {
                      NumberAnimation { target: cap; property: "scale"; to: 1.08; duration: 90; easing.type: Easing.OutQuad }
                      NumberAnimation { target: cap; property: "scale"; to: 1.0; duration: 110; easing.type: Easing.InOutQuad }
                    }
                    NumberAnimation { target: cap; property: "opacity"; to: 1; duration: 120 }
                  }
                  Component.onCompleted: pop.start()
                }
              }
            }
          }
        }

        // Result. Fixed height (two lines for the meaning, then up to four
        // "same key" rows) so the list below never jumps as chords change.
        FontMetrics { id: fmDisplay; font.family: root.fontFamily; font.pixelSize: Style.font.display }
        FontMetrics { id: fmBody; font.family: root.fontFamily; font.pixelSize: Style.font.body }
        FontMetrics { id: fmCaption; font.family: root.fontFamily; font.pixelSize: Style.font.caption }

        Item {
          id: result
          readonly property int mainH: Math.ceil(fmDisplay.height * 2)
          readonly property int rowH: Math.ceil(fmBody.height * 1.25)
          anchors { top: capsArea.bottom; topMargin: Style.spacing.huge; left: parent.left; right: parent.right }
          height: mainH + Style.spacing.lg + Math.ceil(fmCaption.height) + Style.spacing.sm + rowH * 4

          // Meaning (or status), vertically centred in a two-line slot.
          Item {
            id: mainSlot
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: result.mainH

            Text {
              anchors.centerIn: parent
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              maximumLineCount: 2
              elide: Text.ElideRight
              id: mainText
              readonly property bool hasMeaning: root.comboKey !== "" && root.matches.length > 0
              readonly property var cursorApp: root.cursorRow >= 0 && root.rows[root.cursorRow] ? root.rows[root.cursorRow].app || null : null
              text: {
                if (cursorApp) return cursorApp.app + ": press Enter to explore its keys"
                var cc = root.cursorRow >= 0 && root.rows[root.cursorRow] ? root.rows[root.cursorRow].cmdRow : null
                if (cc) return root.app.prefix + cc.cmd + (cc.args ? " " + cc.args : "") + "  \u2014  " + cc.desc + (cc.where ? "  (" + cc.where + ")" : "")
                if (root.cmdMode) {
                  var nc = root.rows.length
                  return nc === 0 ? "No " + root.app.app + " command matches \u201c" + root.app.prefix + root.cmdFilter + "\u201d"
                       : nc === 1 ? root.app.prefix + root.rows[0].cmdRow.cmd + (root.rows[0].cmdRow.args ? " " + root.rows[0].cmdRow.args : "") + "  \u2014  " + root.rows[0].cmdRow.desc
                       : nc + " " + root.app.app + " commands" + (root.cmdFilter ? " match" : "") + "  \u00b7  type to filter"
                }
                if (root.comboKey !== "" && root.app && root.matches.length === 0 && !(root.comboMods.length === 0 && root.variants.length > 0))
                  return "Not a " + root.app.app + " key" + (root.appView === "app" ? "  (" + root.viewKey + " shows Hyprland's too)" : "")
                if (root.comboKey !== "" && root.app && root.matches.length > 1 && root.matches[0].global && !root.matches[root.matches.length - 1].global)
                  return root.matches.map(function(b) { return b.desc }).join("  \u00b7  ") + "  (Hyprland takes it first)"
                if (root.comboKey !== "")
                  return root.matches.length ? root.matches.map(function(b) { return b.desc }).join("  \u00b7  ")
                       : (root.comboMods.length === 0 && root.variants.length > 0)
                         ? "Used in " + root.variants.length + (root.variants.length === 1 ? " binding" : " bindings")
                         : "Not bound"
                if (root.browseWord !== "" && root.shownMods.length > 0)
                  return "No " + root.activeModKey + " binding matches \u201c" + root.browseWord + "\u201d"
                if (root.browseWord !== "") {
                  var na = root.rows.filter(function(r) { return r.app }).length, c = root.rows.length - na
                  var appsTxt = na === 0 ? "" : (c > 0 ? "  \u00b7  " : "") + na + (na === 1 ? " app (Enter explains its keys)" : " apps")
                  return c + na === 0 ? "Nothing matches \u201c" + root.browseWord + "\u201d"
                                 : (c > 0 ? c + (c === 1 ? " binding matches" : " bindings match") : "") + appsTxt
                }
                if (root.shownMods.length === 0 && root.app) return "Press any " + root.app.app + " key, or \u2191\u2193 to browse them all"
                if (root.shownMods.length === 0) return "Hold a modifier to see what it unlocks, or \u2191\u2193 to browse them all"
                var n = root.rows.length
                return n === 0 ? "Nothing is bound to " + root.activeModKey + " + \u2026"
                               : n + (n === 1 ? " binding uses " : " bindings use ") + root.activeModKey
              }
              color: hasMeaning ? root.accent : root.foreground
              opacity: hasMeaning ? 1 : 0.6
              font.family: root.fontFamily
              font.pixelSize: root.comboKey !== "" ? Style.font.display : Style.font.title
            }
          }

          // Same key with other modifiers (at most four; search finds the rest).
          Text {
            id: variantsTitle
            anchors { top: mainSlot.bottom; topMargin: Style.spacing.lg; left: parent.left; right: parent.right }
            horizontalAlignment: Text.AlignHCenter
            visible: (root.comboKey !== "" || root.browseWord !== "") && root.variants.length > 0
            text: (root.comboMods.length === 0 && root.matches.length === 0 ? "Examples" : "Same key with other modifiers")
                  + (root.variants.length > 4 ? "  (4 of " + root.variants.length + ")" : "")
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Column {
            anchors { top: variantsTitle.bottom; topMargin: Style.spacing.sm; left: parent.left; right: parent.right }
            Repeater {
              model: (root.comboKey !== "" || root.browseWord !== "") ? root.variants.slice(0, 4) : []
              delegate: Text {
                required property var modelData
                width: result.width
                height: result.rowH
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: root.prettyCombo(modelData) + "  \u2192  " + modelData.desc
                color: root.foreground
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
        }

        // Search panel (bottom). Separate from the chord view: plain typing
        // lands here and filters every binding by keys and description.
        Item {
          id: searchPanel
          visible: root.searchEnabled
          readonly property bool active: root.filterText.trim() !== ""
          readonly property int rowH: Style.spacing.popupRowHeight
          readonly property int shownRows: Math.max(1, Math.min(root.searchRows.length, 7))
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          height: searchField.height + (active ? searchTitle.implicitHeight + Style.spacing.sm * 2 + shownRows * rowH + Style.spacing.lg : 0)
          Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
          clip: true

          Rectangle {
            id: searchRule
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 1
            visible: searchPanel.active
            color: Util.alpha(root.foreground, 0.15)
          }

          Text {
            id: searchTitle
            visible: searchPanel.active
            anchors { top: searchRule.bottom; topMargin: Style.spacing.sm; left: parent.left }
            text: root.searchRows.length === 0 ? "No keybindings match \u201c" + root.filterText.trim() + "\u201d"
                  : root.searchRows.length + (root.searchRows.length === 1 ? " match" : " matches")
                    + (root.searchRows.length > searchPanel.shownRows ? "  (showing " + searchPanel.shownRows + "; type more to narrow)" : "")
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          ListView {
            id: searchList
            visible: searchPanel.active
            anchors { top: searchTitle.bottom; topMargin: Style.spacing.sm; left: parent.left; right: parent.right; bottom: searchField.top; bottomMargin: Style.spacing.lg }
            clip: true
            model: root.searchRows
            interactive: false

            delegate: Item {
              required property var modelData
              width: searchList.width
              height: searchPanel.rowH

              Text {
                id: searchKey
                anchors { left: parent.left; leftMargin: Style.spacing.rowPaddingX; verticalCenter: parent.verticalCenter }
                width: Style.space(250)
                elide: Text.ElideRight
                textFormat: Text.StyledText
                text: modelData.leftHtml
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                anchors { left: searchKey.right; right: parent.right; rightMargin: Style.spacing.rowPaddingX; verticalCenter: parent.verticalCenter }
                elide: Text.ElideRight
                textFormat: Text.StyledText
                text: modelData.rightHtml
                color: root.foreground
                opacity: 0.85
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          // Search field (plain typing lands here).
          Rectangle {
            id: searchField
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: Math.max(Style.space(34), Style.font.heading + Style.spacing.controlPaddingY * 2)
            radius: root.cornerRadius
            color: root.filterText ? root.selectedBackground : Util.alpha(root.foreground, 0.04)
            border.width: 1
            border.color: Util.alpha(root.foreground, root.filterText ? 0.35 : 0.15)

            Text {
              id: searchIcon
              anchors { left: parent.left; leftMargin: Style.spacing.controlPaddingX; verticalCenter: parent.verticalCenter }
              text: "\uf002"
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }
            Item {
              id: searchText
              anchors { left: searchIcon.right; leftMargin: Style.spacing.lg; right: parent.right; rightMargin: Style.space(170); verticalCenter: parent.verticalCenter }
              height: parent.height
              clip: true

              Row {
                anchors.verticalCenter: parent.verticalCenter
                // Keep the caret visible when the text is wider than the field.
                x: Math.min(0, searchText.width - beforeCaret.implicitWidth - Style.space(4))

                Text {
                  id: beforeCaret
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.filterText.slice(0, root.caretPos)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                }
                Rectangle {
                  id: caret
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(1, Style.space(2))
                  height: Style.font.heading + Style.space(2)
                  color: root.accent
                  property int tick: root.caretTick
                  onTickChanged: { caret.opacity = 1; blink.restart() }
                  SequentialAnimation on opacity {
                    id: blink
                    loops: Animation.Infinite
                    running: root.opened
                    PauseAnimation { duration: 450 }
                    NumberAnimation { to: 0; duration: 180 }
                    PauseAnimation { duration: 350 }
                    NumberAnimation { to: 1; duration: 180 }
                  }
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.filterText !== "" ? root.filterText.slice(root.caretPos) : "Search keybindings\u2026"
                  color: root.foreground
                  opacity: root.filterText !== "" ? 1 : 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                }
              }
            }
            Text {
              anchors { right: parent.right; rightMargin: Style.spacing.controlPaddingX; verticalCenter: parent.verticalCenter }
              visible: root.filterText !== ""
              text: "\u2190 \u2192 move  \u00b7  Shift+Backspace clears"
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

        }

        // List of bindings for the current modifier set (or an overview).
        Rectangle {
          id: rule
          anchors { top: result.bottom; topMargin: Style.spacing.huge; left: parent.left; right: parent.right }
          height: 1
          color: Util.alpha(root.foreground, 0.15)
        }

        Text {
          id: listTitle
          anchors { top: rule.bottom; topMargin: Style.spacing.lg; left: parent.left }
          text: root.browseWord !== "" ? "Bindings matching \u201c" + root.browseWord + "\u201d"
                : root.browseKey !== "" ? "Every binding on " + root.prettyKey(root.rawDisplayKey(root.browseKey))
                : root.cmdMode ? (root.cmdFilter ? root.app.app + " commands matching \u201c" + root.app.prefix + root.cmdFilter + "\u201d" : root.app.app + " commands")
                : root.app && (root.browseAll || (root.activeModKey === "" && root.comboKey === "")) ? "All " + root.app.app + " keys"
                : root.browseAll ? "All keybindings"
                : root.activeModKey !== "" ? root.activeModKey + " + …"
                : (root.comboKey !== "" ? "No modifier" : "All keybindings")
          color: root.foreground
          opacity: 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ListView {
          id: list
          anchors { top: listTitle.bottom; topMargin: Style.spacing.sm; left: parent.left; right: parent.right; bottom: root.searchEnabled ? searchPanel.top : parent.bottom; bottomMargin: root.searchEnabled ? Style.spacing.lg : 0 }
          clip: true
          model: root.rows
          boundsBehavior: Flickable.StopAtBounds
          interactive: false

          delegate: Rectangle {
            required property var modelData
            required property int index
            width: list.width
            height: Style.spacing.popupRowHeight
            radius: root.cornerRadius
            color: index === root.cursorRow ? root.selectedBackground : "transparent"

            Text {
              id: rowKey
              anchors { left: parent.left; leftMargin: Style.spacing.rowPaddingX; verticalCenter: parent.verticalCenter }
              width: modelData.header ? parent.width * 0.6 : Style.space(230)
              elide: Text.ElideRight
              text: modelData.left
              color: index === root.cursorRow ? root.accent : root.foreground
              opacity: modelData.header ? 0.55 : 1
              font.family: root.fontFamily
              font.pixelSize: modelData.header ? Style.font.caption : Style.font.body
              font.bold: !modelData.header
            }
            Text {
              anchors { left: rowKey.right; right: parent.right; rightMargin: Style.spacing.rowPaddingX; verticalCenter: parent.verticalCenter }
              elide: Text.ElideRight
              horizontalAlignment: modelData.header ? Text.AlignRight : Text.AlignLeft
              text: modelData.right
              color: index === root.cursorRow ? root.accent : root.foreground
              opacity: modelData.header ? 0.45 : (index === root.cursorRow ? 1 : 0.8)
              font.family: root.fontFamily
              font.pixelSize: modelData.header ? Style.font.caption : Style.font.body
            }
          }
        }
      }
    }
  }
}
