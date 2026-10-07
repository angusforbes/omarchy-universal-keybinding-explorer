#!/usr/bin/env node
// Regenerates keymaps/vibezai.json for the Universal Keybinding Explorer from vibezAI's own source
// (https://github.com/angusforbes/vibezAI, a terminal Apple Music player).
//
//   node keymaps/gen-vibezai.mjs <path to a vibezAI checkout>     (or set VIBEZAI_SRC; default ../vibezAI next to this repo)
//
// Where things come from:
//   * the keys and their descriptions: the "## Key bindings" tables in vibezAI's README.md (the app author's own words,
//     kept next to the code), plus EXTRA below for keys the code handles that the README doesn't list;
//   * proof that each key is really handled: every key must be found in the Go key handlers
//     (internal/tui/*.go and views/*.go: `case "…"`, `k == "…"`, `NavKey() … "…"`, `msg.String() == "…"`);
//     each binding records those places as "src": ["internal/tui/model.go:1246", …].
// It prints a coverage report: README keys the code doesn't handle (dropped, so the explorer never claims a
// key that does nothing), and handled keys that no entry describes (add them to EXTRA if they matter).
// Nothing in vibezAI is changed.
import { readFileSync, writeFileSync, readdirSync } from "node:fs"
import { join, dirname, relative } from "node:path"
import { fileURLToPath } from "node:url"
import { execFileSync } from "node:child_process"

const SRC = process.argv[2] || process.env.VIBEZAI_SRC || join(dirname(fileURLToPath(import.meta.url)), "../../vibezAI")
const OUT = join(dirname(fileURLToPath(import.meta.url)), "vibezai.json")

// Keys the code handles that the README tables don't list. tea = the key as bubbletea spells it (source lookup).
const EXTRA = [
  { section: "Search", tea: "ctrl+;", desc: "Start or stop typing into the prompt (same as ctrl+'; the two keys sit side by side)" },
  { section: "Tracks", tea: "x", desc: "Remove the highlighted track (same as d)" },
  { section: "Tracks", tea: "delete", desc: "Remove the highlighted track (same as d); while typing in Search: delete the character after the cursor" },
  { section: "Tracks", tea: "+", desc: "Volume up" },
  { section: "Tracks", tea: "=", desc: "Volume up" },
  { section: "Tracks", tea: "-", desc: "Volume down" },
  { section: "Tracks", tea: "j", desc: "Move the highlight down (like ↓); in Lyrics: scroll down" },
  { section: "Tracks", tea: "k", desc: "Move the highlight up (like ↑); in Lyrics: scroll up" },
  { section: "Tracks", tea: "g", desc: "Highlight the first track; in Lyrics: jump to the top" },
  { section: "Tracks", tea: "G", desc: "Highlight the last track; in Lyrics: jump to the bottom" },
  { section: "Search prompt (typing)", tea: "left", desc: "Move the cursor left in the prompt" },
  { section: "Search prompt (typing)", tea: "home", desc: "Cursor to the start of the prompt" },
  { section: "Search prompt (typing)", tea: "ctrl+a", desc: "Cursor to the start of the prompt" },
  { section: "Search prompt (typing)", tea: "end", desc: "Cursor to the end of the prompt" },
  { section: "Search prompt (typing)", tea: "ctrl+e", desc: "Cursor to the end of the prompt" },
  { section: "Search prompt (typing)", tea: "backspace", desc: "Delete the character before the cursor" },
  { section: "Search prompt (typing)", tea: "ctrl+w", desc: "Delete the word before the cursor" },
  { section: "Search prompt (typing)", tea: "ctrl+u", desc: "Delete everything before the cursor" },
  { section: "Equalizer", tea: "h", desc: "Equalizer: previous band (like ←)" },
  { section: "Equalizer", tea: "l", desc: "Equalizer: next band (like →)" },
  { section: "Equalizer", tea: "0", desc: "Equalizer: reset the band" },
  { section: "About", tea: "ctrl+shift+g", desc: "About panel: open this fork on GitHub" },
  { section: "Tracks", tea: "ctrl+c", desc: "Quit" },
  { section: "Search", tea: "shift+tab", desc: "Move the keys back to Tracks (same as Tab)" },
  { section: "Search", tea: "pgup", desc: "Page up in the Search list" },
  { section: "Search", tea: "pgdown", desc: "Page down in the Search list" },
  { section: "Search", tea: "a", desc: "Add the highlighted Search track to Tracks" },
]

// Clearer one-key wording where a README row covers a pair ("Seek ±10 s" for ← and →). Keyed "section|tea";
// the README row stays in "more".
const OVERRIDE = {
  "Tracks|left": "Seek back 10 s", "Tracks|right": "Seek forward 10 s",
  "Tracks|ctrl+shift+d": "Cut everything above the highlight",
  "Tracks|K": "Move the highlighted track up", "Tracks|J": "Move the highlighted track down",
  "Tracks|shift+left": "Move the highlighted track up", "Tracks|shift+right": "Move the highlighted track down",
  "Tracks|shift+up": "Jump the highlight to the top", "Tracks|shift+down": "Jump the highlight to the bottom",
  "Tracks|up": "Move the highlight up (playback doesn't change)", "Tracks|down": "Move the highlight down (playback doesn't change)",
  "Search|ctrl+up": "Move the Search highlight up", "Search|ctrl+down": "Move the Search highlight down",
  "Search|up": "Move the highlight in Tracks up, without leaving Search", "Search|down": "Move the highlight in Tracks down, without leaving Search",
  "Search|ctrl+shift+up": "Sweep-select upwards: mark the highlighted item and everything passed over",
  "Search|ctrl+shift+down": "Sweep-select downwards: mark the highlighted item and everything passed over",
  "Search|enter": "While typing: run the search or AI lookup and stop typing; otherwise play the highlighted track",
  "Search|right": "Open or fold the highlighted header, album or playlist (on a ± row: five more or fewer)",
  "Search|ctrl+enter": "Open or fold the highlighted header, album or playlist (on a ± row: five more or fewer)",
  "Search|tab": "Move the keys back to Tracks", "Search|esc": "Move the keys back to Tracks; while typing, only stop typing",
}

const KEYLIKE = /^(ctrl\+|shift\+|alt\+)*([a-zA-Z0-9_]|[^\w\s]|up|down|left|right|enter|esc|tab|space|delete|backspace|home|end|pgup|pgdown)$/
const ARROWS = { "↑": "up", "↓": "down", "←": "left", "→": "right" }
const NAMED = { up: "UP", down: "DOWN", left: "LEFT", right: "RIGHT", enter: "RETURN", esc: "ESCAPE", tab: "TAB", space: "SPACE",
  delete: "DELETE", backspace: "BACKSPACE", home: "HOME", end: "END", pgup: "PRIOR", pgdown: "NEXT" }
const PUNCT = { "/": "SLASH", "'": "APOSTROPHE", ";": "SEMICOLON", ",": "COMMA", ".": "PERIOD", "-": "MINUS", "=": "EQUAL", "`": "GRAVE", "[": "BRACKETLEFT", "]": "BRACKETRIGHT", "\\": "BACKSLASH" }
const SHIFTED = { "?": "SLASH", ":": "SEMICOLON", "+": "EQUAL", "_": "MINUS", "\"": "APOSTROPHE", "<": "COMMA", ">": "PERIOD", "!": "1", "@": "2", "#": "3" }
const MODORDER = ["SUPER", "CTRL", "SHIFT", "ALT"]

// README token → bubbletea spelling ("shift+↑" → "shift+up", "Tab" → "tab"; single letters keep their case).
function teaOf(tok) {
  let t = tok.trim()
  for (const [a, w] of Object.entries(ARROWS)) t = t.split(a).join(w)
  return t.length === 1 ? t : t.toLowerCase()
}

// bubbletea spelling → explorer chord { mods: "CTRL SHIFT", key: "D" }, the names the explorer's key listener produces.
function chordOf(tea) {
  const parts = tea === "+" ? ["+"] : tea.endsWith("++") ? [...tea.slice(0, -2).split("+"), "+"] : tea.split("+")
  let key = parts.pop()
  const mods = new Set(parts.map((m) => ({ ctrl: "CTRL", shift: "SHIFT", alt: "ALT", super: "SUPER" })[m.toLowerCase()] || m.toUpperCase()))
  if (NAMED[key.toLowerCase()] && key.length > 1) key = NAMED[key.toLowerCase()]
  else if (SHIFTED[key]) { mods.add("SHIFT"); key = SHIFTED[key] }
  else if (PUNCT[key]) key = PUNCT[key]
  else if (/^[A-Z]$/.test(key)) { if (!parts.length) mods.add("SHIFT") }
  else key = key.toUpperCase()
  return { mods: MODORDER.filter((m) => mods.has(m)).join(" "), key }
}

const clean = (s) => s.replace(/\[([^\]]+)\]\([^)]*\)/g, "$1").replace(/`/g, "").replace(/\\\|/g, "|").trim()

// --- Go key handlers: where each bubbletea key string is handled
const goFiles = []
for (const d of ["internal/tui", "internal/tui/views"])
  for (const f of readdirSync(join(SRC, d))) if (f.endsWith(".go") && !f.endsWith("_test.go")) goFiles.push(join(SRC, d, f))
const handled = new Map() // tea → ["file:line"]
for (const f of goFiles) {
  readFileSync(f, "utf8").split("\n").forEach((line, i) => {
    if (!/^\s*case\s|k\s*==\s*"|NavKey\(\)\s*string|msg\.String\(\)\s*==/.test(line)) return
    if (/^\s*case\s/.test(line) && !/^\s*case\s+(k\s*==\s*)?"/.test(line)) return // case on a non-key value
    const vals = [...line.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((m) => m[1].replace(/\\(.)/g, "$1"))
    if (vals.some((k) => !KEYLIKE.test(k))) return // e.g. case "1", "true", "on": a config value, not a key
    const isCase = /^\s*case\s/.test(line)
    for (const k of vals) {
      if (!handled.has(k)) handled.set(k, [])
      const ref = `${relative(SRC, f)}:${i + 1}`
      handled.get(k).push({ ref, isCase })
    }
  })
}
// switch cases first (the handler itself), then comparisons / NavKey, each in file order
const refsOf = (k) => { const r = handled.get(k); return r ? [...r.filter((x) => x.isCase), ...r.filter((x) => !x.isCase)].map((x) => x.ref) : null }
const srcOf = (tea) => refsOf(tea) || (/^ctrl\+shift\+[a-z]$/.test(tea) && refsOf(tea.slice(0, -1) + tea.slice(-1).toUpperCase())) || null

// --- README tables
const readme = readFileSync(join(SRC, "README.md"), "utf8")
const kb = readme.slice(readme.indexOf("## Key bindings"), readme.indexOf("\n## ", readme.indexOf("## Key bindings") + 5))
let section = ""
const entries = []
for (const line of kb.split("\n")) {
  const h = line.match(/^###\s+(.*)/)
  if (h) { section = clean(h[1]).replace(/\s*\(.*\)$/, "").replace(/^Command mode.*/, "Command mode"); continue }
  if (!line.startsWith("|") || /^\|\s*-/.test(line) || /^\|\s*(Key|Command)\s*\|/.test(line)) continue
  const cells = line.split(/(?<!\\)\|/).slice(1, -1).map((c) => c.trim())
  if (cells.length < 2 || section === "Command mode") continue // commands are typed words, not keys
  const toks = [...cells[0].matchAll(/`([^`]+)`/g)].map((m) => m[1])
  const desc = clean(cells[1])
  // "Next / previous" with `n` / `p`: give each key its own half when the halves line up with the keys.
  const head = desc.split(/[;:]/)[0]
  const halves = head.split(/\s+\/\s+/)
  toks.forEach((tok, i) => {
    let d = desc
    const tea = teaOf(tok)
    if (OVERRIDE[`${section}|${tea}`]) d = OVERRIDE[`${section}|${tea}`]
    else if (toks.length > 1 && halves.length === toks.length && halves.every((x) => x.length < 40)) d = halves[i].charAt(0).toUpperCase() + halves[i].slice(1)
    // Long README rows: the explorer shows the first clause (two lines on screen); the whole row stays in "more".
    if (d.length > 90) d = d.split("; ")[0]
    if (d.length > 100) d = d.split(": ")[0]
    entries.push({ section, tea: teaOf(tok), desc: d, more: d === desc ? undefined : desc, from: "README.md" })
  })
}
for (const e of EXTRA) entries.push({ ...e, from: "source" })

// --- Build, keeping only keys the code really handles
const bindings = [], dropped = []
const seen = new Set()
for (const e of entries) {
  const src = srcOf(e.tea)
  if (!src) { dropped.push(`${e.section}: ${e.tea}`); continue }
  const c = chordOf(e.tea)
  const id = `${e.section}|${c.mods}|${c.key}`
  if (seen.has(id)) continue
  seen.add(id)
  bindings.push({ mods: c.mods, key: c.key, desc: e.desc, ...(e.more ? { more: e.more } : {}), section: e.section, tea: e.tea, src: src.slice(0, 4), from: e.from })
}
const described = new Set(entries.map((e) => e.tea))
const undescribed = [...handled.keys()].filter((k) => !described.has(k) && !described.has(k.toLowerCase()))

// --- ":" commands: the master list allCommands in model.go (the CMD footer and Tab completion both read it),
// each with its dispatch case in executeCommand. A listed command with no dispatch case is dropped and reported.
const modelGo = join(SRC, "internal/tui/model.go")
const mlines = readFileSync(modelGo, "utf8").split("\n")
const mref = (i) => `${relative(SRC, modelGo)}:${i + 1}`
const findLine = (re, from = 0) => { for (let i = from; i < mlines.length; i++) if (re.test(mlines[i])) return i; return -1 }
const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
// Where ":" opens command mode: from anywhere in the normal view (Tracks, Lyrics, Equalizer, the debug log), from Search
// while not typing, but not from About (its handler drops every other key first).
const colonAny = findLine(/^\s*if k == ":" \{/), colonSearch = findLine(/^\s*case k == ":":/), aboutDrop = findLine(/m\.panels\[m\.activePanel\] == m\.aboutP \{/)
const whereSrc = [colonAny, colonSearch, aboutDrop].filter((i) => i >= 0).map(mref)
const WHERE = "Anywhere but About: Tracks, Search (when not typing), Lyrics, Equalizer and the debug log"
const listStart = findLine(/^var allCommands = \[\]cmdEntry\{/), execStart = findLine(/^func \(m \*Model\) executeCommand\(/)
const commands = [], cmdDropped = []
for (let i = listStart + 1; listStart >= 0 && i < mlines.length && !/^\}/.test(mlines[i]); i++) {
  const m = mlines[i].match(/^\s*\{"([^"]+)",\s*"([^"]*)",\s*"((?:[^"\\]|\\.)*)"\}/)
  if (!m) continue
  const [, trigger, usage, description] = m
  const disp = findLine(new RegExp(`cmd == "${esc(trigger)}"|HasPrefix\\(cmd, "${esc(trigger)}`), execStart)
  if (disp < 0) { cmdDropped.push(trigger); continue }
  const alias = (mlines[disp].match(/cmd == "([^"]+)"/g) || []).map((x) => x.slice(8, -1)).filter((x) => x !== trigger)
  commands.push({ cmd: trigger, args: usage.slice(trigger.length).trim(), desc: description.replace(/\\(.)/g, "$1"),
    ...(alias.length ? { aliases: alias } : {}), where: WHERE, src: [mref(i), mref(disp)], whereSrc })
}

const out = {
  format: "keybinding-explorer-keymap/1",
  id: "vibezai",
  app: "vibezAI",
  about: "Apple Music in the terminal (a fork of vibez)",
  match: ["vibez", "vibezai", "apple music", "music"],
  // Focused-window rule: SUPER+ALT+K starts in this app when the focused window's class OR title matches
  // one of these regexes (case-insensitive). vibez-toggle opens it as app-id org.omarchy.vibez (~/.local/bin/vibez-toggle).
  focus: { class: ["^org\\.omarchy\\.vibez$"], title: ["^vibez(AI)?$"] },
  generatedBy: "keymaps/gen-vibezai.mjs",
  source: "https://github.com/angusforbes/vibezAI",
  sourceCommit: (() => { try { return execFileSync("git", ["-C", SRC, "rev-parse", "HEAD"], { encoding: "utf8" }).trim() } catch { return "" } })(),
  bindings,
  commands,
}
writeFileSync(OUT, JSON.stringify(out, null, 1) + "\n")
console.log(`wrote ${OUT}: ${bindings.length} bindings from ${entries.length} entries`)
console.log(`${commands.length} ":" commands${cmdDropped.length ? `; listed but not dispatched (dropped): ${cmdDropped.join(", ")}` : ""}`)
if (dropped.length) console.log(`README/EXTRA keys not found in the Go handlers (dropped): ${dropped.join(", ")}`)
if (undescribed.length) console.log(`handled in Go but not described (add to EXTRA if they matter): ${undescribed.join(" ")}`)
