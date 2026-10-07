#!/usr/bin/env node
// Regenerates the hyprpi panels' keymaps for the Universal Keybinding Explorer from hyprpi's own source
// (https://github.com/angusforbes/hyprpi): the agents panel, the Stream, the projects panel and the Thoughts window.
//
//   node keymaps/gen-hyprpi.mjs <path to a hyprpi checkout>      (or set HYPRPI_SRC; default ../hyprpi next to this repo)
//
// Writes keymaps/hyprpi-shared.json (the shared message box, included by all four, "shared": true) and
// keymaps/hyprpi-{agents,stream,projects,thoughts}.json.
//
// Keys: the panels read raw terminal input, so each key below is given as the escape sequence its handler compares
// against (e.g. "\x1b[1;5A"). The generator decodes the sequence into the explorer's chord (CTRL + UP) and finds the
// handler line in the named file (a line comparing against that literal: ===, case, a {seq: …} map, .has()), searching
// from the handler function's start. A key whose literal isn't found is DROPPED and reported, so a renamed or removed
// key never survives here. `code` instead of `seq` finds a line by a code fragment (mouse buttons, Sets).
// Descriptions are written here, from the code and its comments and the panels' own /help text.
//
// Commands: the common ones come from lib/tui/command-line.mjs (commonCommands, imported, so the list is exactly what
// the panels run), each panel's own from its createCommands({ commands: [...] }) entries (the projects panel: the
// BOARD_COMMANDS table in lib/tui/board-view.mjs). Hidden commands (hidden: true, e.g. /ignore) are left out. A panel
// command overrides a common one of the same name, as createCommands does.
import { readFileSync, writeFileSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { execFileSync } from "node:child_process"

const HERE = dirname(fileURLToPath(import.meta.url))
const SRC = process.argv[2] || process.env.HYPRPI_SRC || join(HERE, "../../hyprpi")
const read = (f) => readFileSync(join(SRC, f), "utf8").split("\n")
const MODORDER = ["SUPER", "CTRL", "SHIFT", "ALT"]

// ---- escape sequence → chord ------------------------------------------------------------------
const CSI_LETTER = { A: "UP", B: "DOWN", C: "RIGHT", D: "LEFT", H: "HOME", F: "END", Z: "TAB" }
const CSI_TILDE = { 1: "HOME", 2: "INSERT", 3: "DELETE", 4: "END", 5: "PRIOR", 6: "NEXT" }
const CODEPOINT = { 9: "TAB", 13: "RETURN", 27: "ESCAPE", 32: "SPACE", 127: "BACKSPACE" }
const modsOf = (n) => { const m = Number(n || 1) - 1, s = []; if (m & 4) s.push("CTRL"); if (m & 1) s.push("SHIFT"); if (m & 2) s.push("ALT"); return s }
const keyOfChar = (c) => /[a-z]/.test(c) ? [[], c.toUpperCase()] : /[A-Z]/.test(c) ? [["SHIFT"], c] : /[0-9]/.test(c) ? [[], c]
  : c === "\x7f" ? [[], "BACKSPACE"] : null
function decode(seq) {
  let m, mods = [], key = null
  if (seq === "\x1b") key = "ESCAPE"
  else if (seq === "\r") key = "RETURN"
  else if (seq === "\t") key = "TAB"
  else if (seq === "\x7f") key = "BACKSPACE"
  else if (seq === "\x00") { mods = ["CTRL"]; key = "SPACE" }
  else if (seq === "\x1f") { mods = ["CTRL"]; key = "SLASH" }          // also Ctrl+- / Ctrl+_ in terminals
  else if (seq.length === 1 && seq < " ") { mods = ["CTRL"]; key = String.fromCharCode(seq.charCodeAt(0) + 64) }
  else if (seq === "\x1b[Z") { mods = ["SHIFT"]; key = "TAB" }
  else if ((m = /^\x1b\[(?:1;(\d+))?([ABCDHFZ])$/.exec(seq))) { mods = modsOf(m[1]); key = CSI_LETTER[m[2]]; if (m[2] === "Z") mods.push("SHIFT") }
  else if ((m = /^\x1b\[(\d+)(?:;(\d+))?~$/.exec(seq)) && CSI_TILDE[m[1]]) { mods = modsOf(m[2]); key = CSI_TILDE[m[1]] }
  else if ((m = /^\x1b\[27;(\d+);(\d+)~$/.exec(seq))) { mods = modsOf(m[1]); key = CODEPOINT[m[2]] || String.fromCharCode(+m[2]).toUpperCase() }
  else if ((m = /^\x1b\[(\d+);(\d+)u$/.exec(seq))) { mods = modsOf(m[2]); key = CODEPOINT[m[1]] || String.fromCharCode(+m[1]).toUpperCase() }
  else if ((m = /^\x1b([\s\S])$/.exec(seq)) && keyOfChar(m[1])) { const [x, k] = keyOfChar(m[1]); mods = ["ALT", ...x]; key = k }
  if (!key) throw new Error(`can't decode ${JSON.stringify(seq)}`)
  return { mods: MODORDER.filter((x) => mods.includes(x)).join(" "), key }
}

// ---- find a handler line --------------------------------------------------------------------
// "\x1b[A" as written in source: control characters and DEL as \xHH, \r \t \b as themselves
const lit = (seq) => [...seq].map((c) => c === "\r" ? "\\r" : c === "\t" ? "\\t" : c === "\b" ? "\\b"
  : c < " " || c === "\x7f" ? "\\x" + c.charCodeAt(0).toString(16).padStart(2, "0") : c === '"' ? '\\"' : c).join("")
function findLine(file, from, { seq, code, re }) {
  const lines = read(file)
  let i0 = lines.findIndex((l) => from.test(l)); if (i0 < 0) i0 = 0
  for (let i = i0; i < lines.length; i++) {
    const l = lines[i]
    if (/^\s*\/\//.test(l)) continue
    if (re && !re.test(l)) continue // a key handled in several places: the line that does what the entry says
    // not a list check (["…"].includes(d)) nor a paste conversion (d === "\r" ? "\n" : d)
    if (code ? l.includes(code) : (l.includes(`"${lit(seq)}"`) && !/\.includes\(/.test(l) && !l.includes(`"${lit(seq)}" ?`))) return `${file}:${i + 1}`
  }
  return null
}

// ---- the keys -------------------------------------------------------------------------------
// [seq or {code}, desc, chord override (for mouse / extra chords)]
const S = (seq, desc, extra = {}) => ({ seq, desc, ...extra })
const C = (code, mods, key, desc) => ({ code, desc, chord: { mods, key } })

const SHARED = {
  file: "lib/tui/input-box.mjs", from: /^\s*function key\(d\)/, section: "Message box",
  keys: [
    S("\x1b[A", "Up a line in the box; at its start, your earlier messages (history)"),
    S("\x1b[B", "Down a line in the box; at its end, forward through history to your draft"),
    S("\x1b[D", "Cursor left (with a selection: to its start)"),
    S("\x1b[C", "Cursor right (with a selection: to its end)"),
    S("\x1b[1;5D", "Word left"), S("\x1b[1;5C", "Word right"),
    S("\x1b[1;3D", "Word left"), S("\x1b[1;3C", "Word right"),
    S("\x1bb", "Word left"), S("\x1bf", "Word right"),
    S("\x1b[H", "Start of the line"), S("\x1b[F", "End of the line"), S("\x05", "End of the line"),
    S("\x1b[1;2D", "Select left"), S("\x1b[1;2C", "Select right"),
    S("\x1b[1;6D", "Select a word left"), S("\x1b[1;6C", "Select a word right"),
    S("\x1b[1;2H", "Select to the start of the line"), S("\x1b[1;2F", "Select to the end of the line"),
    S("\x1b[1;2A", "Select up a line"), S("\x1b[1;2B", "Select down a line"),
    S("\x7f", "Delete the character before the cursor (or the selection)"),
    S("\x1b[3~", "Delete the character after the cursor (or the selection)"),
    S("\x1b\x7f", "Delete the word before the cursor"), S("\x17", "Delete the word before the cursor"),
    S("\x15", "Clear the box (Alt+Z brings it back)"),
    S("\x03", "Copy the selection, else the whole text (never deletes)"),
    S("\x1b[2;5~", "Copy (what Omarchy's SUPER+C sends)"),
    S("\x18", "Cut the selection"),
    S("\x16", "Paste text, or a screenshot: its path goes in at the cursor"),
    S("\x1b[2;2~", "Paste (what Omarchy's SUPER+V sends)"),
    S("\x1b[13;2u", "New line in the message"),
    S("\x1a", "Undo"), S("\x1f", "Undo (Ctrl+- too)", { also: [{ mods: "CTRL", key: "MINUS" }] }),
    S("\x19", "Redo"), S("\x1b[122;6u", "Redo"),
    S("\x1bz", "The previous cleared draft (again: older ones)"),
  ],
}

const PANELS = [
  {
    id: "hyprpi-agents", app: "hyprpi agents", about: "hyprpi's agents panel: this world's agents and projects",
    match: ["hyprpi", "agents", "panel", "router"], title: "^hyprpi-router [A-Z]$",
    file: "mockups/agents-tui.mjs", from: /^function onKey\(d\)/, section: "Agents", cmdPanel: "mockups/agents-tui.mjs",
    keys: [
      S("\r", "Run the /command in the box; empty box: the agent under the cursor (live: jump to its window · parked: revive it here · closed: resume it)"),
      S("\t", "Complete a /command"),
      S("\x1b", "Close help; with text in the box: drop its selection, else clear it"),
      S("\x03", "Copy the box (its selection, else all); empty box: quit"),
      S("\x11", "Quit the panel"),
      S("\x0f", "Views: live · + parked / closed (and archived projects)"),
      S("\x17", "Close the agent under the cursor (empty box; twice to confirm). With text: delete a word"),
      S("\x0b", "Kill the agent under the cursor (twice to confirm; a closed agent: forget it)"),
      S("\x0e", "A new agent here"),
      S("\x1b[9;5u", "Next world"), S("\x1b[9;6u", "Previous world"),
      S("\x1b[1;5A", "Cursor up the list"), S("\x1b[1;5B", "Cursor down the list"),
      S("\x1b[1;5H", "Cursor to the first agent"), S("\x1b[1;5F", "Cursor to the last row"),
      S("\x1b[5~", "Cursor up 5"), S("\x1b[6~", "Cursor down 5"),
      C("b === 16", "CTRL", "LEFT MOUSE BUTTON", "That agent, as Enter would (jump · revive · resume); on a project: its card"),
      C("b === 0 && press", "", "LEFT MOUSE BUTTON", "Put the cursor on a row; on a project's @member: jump to that agent"),
    ],
  },
  {
    id: "hyprpi-stream", app: "hyprpi Stream", about: "hyprpi's Stream panel: this world's room, messages and activity",
    match: ["hyprpi", "stream", "room", "panel"], title: "^hyprpi-room [A-Z]$",
    file: "mockups/room-tui.mjs", from: /^function onKey\(d\)/, section: "Stream", cmdPanel: "mockups/room-tui.mjs",
    keys: [
      S("\r", "Send the message (or run the /command)", { re: /return send\(\)/ }),
      S("\x1b[13;5u", "Send, the same as Enter"),
      S("\t", "Complete a /command; else an @project at the cursor (again: the next one)"),
      S("\x1b[Z", "Complete an @agent at the cursor (again: the next one)"),
      S("\x06", "Stream view: full → compact → topics → all activity"),
      { code: "CTRL_TAB.has(d)", desc: "Next world", chord: { mods: "CTRL", key: "TAB" } },
      { code: "CTRL_SHIFT_TAB.has(d)", desc: "Previous world", chord: { mods: "CTRL SHIFT", key: "TAB" } },
      S("\x1b[1;3A", "Pick the previous Stream row"), S("\x1b[1;3B", "Pick the next Stream row"),
      S("\x1b[1;3H", "Pick the oldest Stream row"), S("\x1b[1;3F", "No row picked (back to the newest)"),
      S("\x1b[1;5A", "Scroll the Stream up a line"), S("\x1b[1;5B", "Scroll the Stream down a line"),
      S("\x1b[5~", "Scroll the Stream up a page"), S("\x1b[6~", "Scroll the Stream down a page"),
      S("\x1b[1;5H", "Scroll to the oldest"), S("\x1b[1;5F", "Back to the newest"),
      S("\x1b", "Drop the box's selection, else the picked row, else the /stream filter, else the note; in help: back", { re: /Esc: text selection/ }),
      S("\x03", "Copy the box's selection, else the whole message; never quits"),
      S("\x1b[2;5~", "Copy the highlighted Stream text, else the box's selection (what SUPER+C sends)"),
      S("\x11", "Quit the panel"),
      S("\x0e", "A new agent here"),
      C("b === 16 && m[4] === \"M\"", "CTRL", "LEFT MOUSE BUTTON", "An agent's name: jump to its window; a link or file: open it"),
      C("b === 4 && inConvo", "SHIFT", "LEFT MOUSE BUTTON", "Copy the whole message (Shift+drag: several)"),
    ],
  },
  {
    id: "hyprpi-projects", app: "hyprpi projects", about: "hyprpi's projects panel: this world's project board",
    match: ["hyprpi", "projects", "board", "panel"], title: "^hyprpi-board [A-Z]$",
    file: "mockups/board-tui.mjs", from: /^function onKey\(d\)/, section: "Projects", cmdPanel: "board",
    keys: [
      S("\r", "Send the box (a board command or a message); empty box: open the highlighted card, back to all projects, or put an item's handle in the box"),
      S("\x1b[13;5u", "The board's Enter, whatever is typed (Decisions: send)"),
      S("\x1b", "Drop the box's selection, then the highlight, then the open card or help; Decisions: back to the cards. Never quits"),
      S("\x06", "Cards ⇄ Decisions view"),
      S("\t", "Complete a /command, an item handle after @project, or an @project"),
      S("\x1b[Z", "Complete an @agent"),
      { code: "CTRL_TAB.has(d)", desc: "Next world", chord: { mods: "CTRL", key: "TAB" } },
      { code: "CTRL_SHIFT_TAB.has(d)", desc: "Previous world", chord: { mods: "CTRL SHIFT", key: "TAB" } },
      S("\x1b[5~", "Page up"), S("\x1b[6~", "Page down"),
      S("\x1b[1;5H", "Top of the board"), S("\x1b[1;5F", "Bottom of the board"),
      S("\x11", "Quit the panel"),
      { file: "lib/tui/board-view.mjs", from: /^\s*function key\(d, /, seq: "\x1b[1;5A", desc: "Highlight the previous card or item (Decisions: previous decision)" },
      { file: "lib/tui/board-view.mjs", from: /^\s*function key\(d, /, seq: "\x1b[1;5B", desc: "Highlight the next card or item (Decisions: next decision)" },
      { file: "lib/tui/board-view.mjs", from: /^\s*function key\(d, /, seq: "\x00", desc: "Fold / open the highlighted card" },
      { file: "lib/tui/board-view.mjs", from: /^\s*function key\(d, /, seq: "\x0f", desc: "Fold / open the highlighted card" },
      { file: "lib/tui/board-view.mjs", from: /^\s*function key\(d, /, seq: "\x04", desc: "Drop the highlighted item; on a project's header: archive the project" },
      { file: "lib/tui/board-view.mjs", from: /^\s*function key\(d, /, seq: "\x01", desc: "Archive (or unarchive) the highlighted item" },
      { file: "lib/tui/board-view.mjs", from: /^\s*function key\(d, /, seq: "\x14", desc: "Mark the highlighted item done" },
      ...[1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => ({ code: "/^\\x1b([1-9])$/.exec(d)", file: "lib/tui/board-view.mjs", from: /^\s*function key\(d, /,
        desc: `Answer the highlighted decision with option ${n} (${"abcdefghi"[n - 1]})`, chord: { mods: "ALT", key: String(n) } })),
      S("\x1bl", "Decisions: put the current one off (to the end of the list)", { from: /^function decisionKey/ }),
      C("b === 4 && press", "SHIFT", "LEFT MOUSE BUTTON", "Copy the whole item"),
      C("b === 16", "CTRL", "LEFT MOUSE BUTTON", "An @agent: jump to its window; a link: open it"),
    ],
  },
  {
    id: "hyprpi-thoughts", app: "hyprpi Thoughts", about: "hyprpi's Thoughts window: talk to this world's Thoughts agent, search its history",
    match: ["hyprpi", "thoughts", "search", "panel"], title: "^hyprpi-search [A-Z]$",
    file: "mockups/search-tui.mjs", from: /^function onKey\(d\)/, section: "Thoughts", cmdPanel: "mockups/search-tui.mjs",
    keys: [
      S("\r", "Talk to Thoughts (it remembers; it can ask agents and hand them work), or run the /command"),
      S("\x1b[13;5u", "The same as Enter"),
      S("\x1b", "Interrupt what's running; else close help. Never touches the box"),
      S("\x14", "Keyword ⇄ AI mode"),
      S("\x1b[1;5A", "Move the highlight up (scroll back through the thread)"), S("\x1b[1;5B", "Move the highlight down"),
      S("\x1b[5~", "Scroll back a page"), S("\x1b[6~", "Scroll forward a page"),
      S("\x1b[1;5H", "The oldest"), S("\x1b[1;5F", "Back to the newest, and follow"),
      S("\x1b[F", "End of the box; with an empty box, follow the newest again"),
      S("\t", "Complete a /command or an @name (again: the next one)"), S("\x1b[Z", "Complete an @name, backwards"),
      { code: "CTRL_TAB.has(d)", desc: "Next world", chord: { mods: "CTRL", key: "TAB" } },
      { code: "CTRL_SHIFT_TAB.has(d)", desc: "Previous world", chord: { mods: "CTRL SHIFT", key: "TAB" } },
      S("\x01", "Cursor to the start of the box"),
      S("\x03", "Copy the box's selection, else the whole box; never quits"),
      S("\x1b[2;5~", "Copy the highlighted thread text, else the box's selection (what SUPER+C sends)"),
      S("\x11", "Quit the window"),
      C("b === 16 && m[4] === \"M\"", "CTRL", "LEFT MOUSE BUTTON", "An agent's name or an evidence line: jump to that agent's window"),
    ],
  },
]

// ---- build ----------------------------------------------------------------------------------
const report = { dropped: [], cmdHidden: [] }
function buildKeys(def, section) {
  const out = []
  for (const k of def.keys) {
    const file = k.file || def.file, from = k.from || def.from
    const src = findLine(file, from, k)
    const label = k.seq != null ? JSON.stringify(k.seq) : k.code
    if (!src) { report.dropped.push(`${def.id || "shared"}: ${label}`); continue }
    const chords = [k.chord || decode(k.seq), ...(k.also || [])]
    for (const c of chords) out.push({ mods: c.mods, key: c.key, desc: k.desc, section, src: [src], ...(k.seq != null ? { seq: k.seq } : {}) })
  }
  // one entry per chord: the first wins (an earlier, more specific handler line)
  const seen = new Set()
  return out.filter((b) => { const id = b.mods + "|" + b.key; if (seen.has(id)) return false; seen.add(id); return true })
}

const strRe = '"((?:[^"\\\\]|\\\\.)*)"'
const unq = (s) => JSON.parse(`"${s}"`)
function panelCommands(file) {
  const out = []
  read(file).forEach((l, i) => {
    const m = new RegExp(`\\{ name: ${strRe}(?:, usage: ${strRe})?, help: ${strRe}`).exec(l)
    if (!m) return
    if (/hidden:\s*true/.test(l)) { report.cmdHidden.push(unq(m[1])); return }
    const name = unq(m[1]), usage = m[2] != null ? unq(m[2]) : name
    out.push({ cmd: name.slice(1), args: usage.slice(name.length).trim(), desc: unq(m[3]), src: [`${file}:${i + 1}`] })
  })
  return out
}
function boardCommands() {
  const file = "lib/tui/board-view.mjs", out = []
  let inTable = false
  read(file).forEach((l, i) => {
    if (/^export const BOARD_COMMANDS = \[/.test(l)) { inTable = true; return }
    if (inTable && /^\];/.test(l)) { inTable = false; return }
    const m = inTable && new RegExp(`^\\s*\\[${strRe}, ${strRe}\\]`).exec(l)
    if (!m) return
    const name = unq(m[1]), text = unq(m[2])
    // "/todo @p text: add a Next item" → args "@p text", desc "add a Next item"; "the same as /fold" stays whole
    const u = text.startsWith(name) && text.indexOf(": ") > 0 ? text.indexOf(": ") : -1
    out.push({ cmd: name.slice(1), args: u > 0 ? text.slice(name.length, u).trim() : "", desc: u > 0 ? text.slice(u + 2) : text, src: [`${file}:${i + 1}`] })
  })
  return out
}
async function commonCommandsWithSrc() {
  const file = "lib/tui/command-line.mjs", lines = read(file)
  const mod = await import(pathToFileURL(join(SRC, file)).href)
  const list = mod.commonCommands({})
  const fnStart = lines.findIndex((l) => /^export function commonCommands/.test(l))
  const genLine = lines.findIndex((l, i) => i > fnStart && /Object\.keys\(PANELS\)/.test(l))
  const out = []
  for (const c of list) {
    if (c.hidden) { report.cmdHidden.push(c.name); continue }
    let i = lines.findIndex((l, j) => j > fnStart && l.includes(`name: "${c.name}"`))
    if (i < 0) i = genLine // /agents /room /board come from Object.keys(PANELS)
    if (i < 0) { report.dropped.push(`common command ${c.name}`); continue }
    const usage = c.usage || c.name
    out.push({ cmd: c.name.slice(1), args: usage.slice(c.name.length).trim(), desc: c.help || "", src: [`${file}:${i + 1}`] })
  }
  return out
}

const commit = (() => { try { return execFileSync("git", ["-C", SRC, "rev-parse", "HEAD"], { encoding: "utf8" }).trim() } catch { return "" } })()
const common = await commonCommandsWithSrc()
const header = { format: "keybinding-explorer-keymap/1", generatedBy: "keymaps/gen-hyprpi.mjs", source: "https://github.com/angusforbes/hyprpi", sourceCommit: commit }
const write = (id, obj) => { writeFileSync(join(HERE, id + ".json"), JSON.stringify(obj, null, 1) + "\n"); console.log(`wrote keymaps/${id}.json: ${(obj.bindings || []).length} keys, ${(obj.commands || []).length} commands`) }

write("hyprpi-shared", { ...header, id: "hyprpi-shared", shared: true, about: "The message box every hyprpi panel shares (lib/tui/input-box.mjs)",
  bindings: buildKeys(SHARED, SHARED.section) })
for (const p of PANELS) {
  const own = p.cmdPanel === "board" ? boardCommands() : panelCommands(p.cmdPanel)
  const commands = [...own, ...common.filter((c) => !own.some((o) => o.cmd === c.cmd))]
    .map((c) => ({ ...c, where: own.some((o) => o === c) ? `the ${p.app} box` : "the box, in every hyprpi panel" }))
  write(p.id, { ...header, id: p.id, app: p.app, about: p.about, match: p.match, focus: { title: [p.title] }, include: ["hyprpi-shared"],
    prefix: "/", bindings: buildKeys(p, p.section), commands })
}
if (report.dropped.length) console.log(`not found in the source (dropped): ${report.dropped.join(" · ")}`)
console.log(`hidden commands left out: ${[...new Set(report.cmdHidden)].join(" ") || "none"}`)
