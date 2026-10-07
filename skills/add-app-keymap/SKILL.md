---
name: add-app-keymap
description: Add an app to the Universal Keybinding Explorer (Omarchy plugin angusforbes.universal-keybinding-explorer, SUPER+ALT+K) - find where the app really handles its keys and its ":" or "/" commands, write keymaps/<app>.json with source references and a focused-window rule (ideally from a small generator script), and test it with dry runs that never open the overlay. Use when asked to "add <app> to the keybinding explorer", "make the explorer know <app>'s keys", or to update an app's keymap after its keys changed.
---

# Add an app to the Universal Keybinding Explorer

The explorer explains keys; it never sends any. An app is one JSON file in the plugin's `keymaps/` folder. The overlay
re-reads every file on each open, so no code change or shell restart is needed.

- **Plugin folder:** `~/.config/omarchy/plugins/angusforbes.universal-keybinding-explorer`. It may be a symlink to a
  checkout; `readlink -f` shows where.
- **Format:** the README's "App keymaps" section. The example to copy is `keymaps/vibezai.json` with its generator
  `keymaps/gen-vibezai.mjs`.

## 1. Find the truth in the app

The keymap must describe what the app **really** does. Docs drift, so the code wins.

- Find the source: a git checkout, the package's source, or upstream on GitHub. If there's no source (a closed app),
  use its official keyboard-shortcut docs, and say so in `about` or a `notes` field.
- Find where key presses are handled: grep for the toolkit's key handler.
  - Go bubbletea: `case "ctrl+…"`, `msg.String()`.
  - Python textual: `BINDINGS`, `Binding(`.
  - Node / blessed / ink: `key.name`, `useInput`, `screen.key(`.
  - Qt: `Keys.onPressed`, `Shortcut {`.
  - Browser and Electron apps: `keydown`, `hotkeys(`.
  - Neovim plugins: `vim.keymap.set`.
  - Readline-style TUIs: their keymap table.
- Note where each key works (which view, panel or mode), and record each handler's `file:line`.
- Look for typed commands too: a `:` command line (vim-like), `/` slash commands, or a command palette. Find the command
  list or table and the dispatch (`switch`, `if cmd ==`). Record each command's name, arguments, description, aliases,
  and the parts of the app where the prefix key opens it.
- If the app has its own key list (a help screen, footer hints, a README table), use its wording for descriptions. The
  app's author already wrote them for users. **But check every description against the function the key calls.** Help
  text, hints and comments drift: in hyprpi a hint still said "^Z undo drop" for a key nothing reaches any more, and
  Ctrl+T's handler only shows a note now.
- **Trace the handler in order.** A key handler is often a chain of `if (d === …) return …` lines, and an earlier line
  shadows a later one. In hyprpi the shared box's undo takes Ctrl+Z and Ctrl+/ first, so the panels' later Ctrl+/ and
  ^Z lines are dead code. Describe what the first line that takes the key does, and point `src` at that line.
- **Keys a shared widget handles** (a text box used by several screens) belong in one shared keymap that each app
  includes (step 2). Where the app overrides the widget, the app's entry wins: in hyprpi the agents panel's box is one
  line, so its Shift+Enter does nothing, and that panel says so.
- **Modes and views.** When a key means different things in different modes (Cards vs Decisions), either give one entry
  per `section`, or say both in the description ("Cards view: …; Decisions: …").
- **Hint-only and no-op branches count.** A key that only shows a hint ("Ctrl+Tab switches world") is still handled;
  say what it does, so the explorer doesn't answer "Not a … key".

### Raw-terminal TUIs (escape sequences)

TUIs that read raw terminal input (Node `process.stdin`, curses without a key table) compare against escape sequences,
not key names. Decode them into the explorer's chords; `keymaps/gen-hyprpi.mjs` has a `decode()` you can copy.

| Sequence | Chord |
|---|---|
| `\r` `\t` `\x1b` `\x7f` | RETURN, TAB, ESCAPE, BACKSPACE |
| `\x01`…`\x1a` | CTRL + A…Z (`\x03` CTRL+C, `\x17` CTRL+W) |
| `\x00` / `\x1f` | CTRL+SPACE / CTRL+SLASH (a terminal sends the same byte for Ctrl+- and Ctrl+_) |
| `\x1b` + char | ALT + that key (`\x1bb` ALT+B; `\x1bL` ALT+SHIFT+L) |
| `\x1b[A` `B` `C` `D` `H` `F` | UP DOWN RIGHT LEFT HOME END |
| `\x1b[1;Nx` | the same key with modifiers N: 2 SHIFT, 3 ALT, 5 CTRL, 6 CTRL+SHIFT, 7 CTRL+ALT (N−1 = bits: 1 shift, 2 alt, 4 ctrl) |
| `\x1b[N~` / `\x1b[N;M~` | 2 INSERT, 3 DELETE, 5 PRIOR, 6 NEXT (1 HOME, 4 END), M as above |
| `\x1b[K;Mu` / `\x1b[27;M;K~` | key with codepoint K (13 RETURN, 9 TAB, 32 SPACE, 122 z) and modifiers M |
| `\x1b[Z` | SHIFT+TAB |
| `\x1b[<b;x;yM` (SGR mouse) | b 0 LEFT MOUSE BUTTON, +4 SHIFT, +16 CTRL; 64 / 65 MOUSE_UP / MOUSE_DOWN (wheel) |

On Omarchy, SUPER+C and SUPER+V reach a terminal app as Ctrl+Insert (`\x1b[2;5~`) and Shift+Insert (`\x1b[2;2~`). List
those chords, not SUPER+C / SUPER+V: Hyprland binds those, so the explorer would mark them "taken by Hyprland".

## 2. Write `keymaps/<id>.json`

```json
{
  "format": "keybinding-explorer-keymap/1",
  "id": "myapp", "app": "MyApp", "about": "one line: what the app is",
  "match": ["myapp", "words people would type to find it"],
  "focus": { "class": ["^com\\.example\\.MyApp$"], "title": ["^MyApp( —.*)?$"] },
  "bindings": [ { "mods": "CTRL", "key": "S", "section": "Editor", "desc": "Save", "src": ["src/keys.ts:42"] } ],
  "commands": [ { "cmd": "w", "args": "[file]", "desc": "Write the file", "where": "Normal mode", "src": ["src/cmd.ts:10"] } ]
}
```

**Key names**

- Use the explorer's names: `A`…`Z`, `0`…`9`, `F1`…, `SLASH` `APOSTROPHE` `SEMICOLON` `COMMA` `PERIOD` `MINUS` `EQUAL`
  `GRAVE` `BRACKETLEFT` `BRACKETRIGHT` `BACKSLASH`, `UP` `DOWN` `LEFT` `RIGHT` `RETURN` `TAB` `SPACE` `ESCAPE` `DELETE`
  `BACKSPACE` `HOME` `END` `INSERT` `PRIOR` (PgUp) `NEXT` (PgDn).
- Mouse: `LEFT MOUSE BUTTON`, `RIGHT MOUSE BUTTON`, `MIDDLE MOUSE BUTTON` (with modifiers, e.g. CTRL for Ctrl+click), and
  `MOUSE_UP` / `MOUSE_DOWN` for the wheel. Clicks and Ctrl+clicks can be looked up by clicking in the explorer. The bare
  wheel scrolls the explorer's own list, so wheel entries are only listed. Put double and triple clicks and drags in the
  click entry's description.
- Modifiers are `SUPER CTRL SHIFT ALT`, in any order, or `""` for a bare key.
- **A shifted character is SHIFT + its unshifted key** (US layout): `?` is `SHIFT` + `SLASH`, `:` is `SHIFT` +
  `SEMICOLON`, `+` is `SHIFT` + `EQUAL`, and capital `G` is `SHIFT` + `G`. Most toolkits spell these differently ("?",
  "G", "shift+g"), so convert them.
- If one key does different things in different parts of the app, give it one entry per `section`. The explorer lists
  both.

**Descriptions**

- Keep each one to two short lines. Put the full text in `more` if you like.
- Give paired keys their own wording ("Seek back 10 s" and "Seek forward 10 s", not "Seek ±10 s" twice).

**`focus`: which windows start the explorer in this app**

- Run `hyprctl activewindow -j | jq '{class, title}'` with the app focused.
- Anchor the regexes (`^…$`) so they don't catch unrelated windows: a terminal whose title merely mentions the app
  must not count. Terminal apps often share their terminal's class (`kitty`), so match on `title`, or launch the app
  with its own class or app-id and match that.
- Leave `focus` out if no rule is reliable. People can still find the app by typing its name.

**Commands and shared parts**

- `prefix`: the key that starts the app's commands (`":"` by default; `"/"` for slash commands). In the explorer, that
  key opens the command list.
- Leave hidden or secret commands out (`hidden: true`, easter eggs, debug commands): the explorer is for users.
- If a command table embeds the usage in its help text ("/todo @p text: add a Next item"), split it into `args` and `desc`.
- A keymap with `"shared": true` and no `app` holds keys or commands that several apps share. Apps pull it in with
  `"include": ["<its id>"]`. The app's own chord or command name wins. The four hyprpi panels share `hyprpi-shared.json`.

**Keep it honest with a generator** (recommended when there is source): a small script, `keymaps/gen-<id>.mjs`, that
reads the app's source and writes the JSON. Model it on `gen-vibezai.mjs`:

- take descriptions from the app's own key list or docs, plus an `EXTRA` list for keys the docs leave out;
- prove each key exists in a handler, and store each `file:line` in `src`;
- **drop and report** any documented key or command the code doesn't handle;
- report handled keys that no entry describes;
- take the source path as an argument, and write repo-relative `src` paths, never absolute home paths.

## 3. Test without opening the overlay

Never open the overlay or press real keys to test: it grabs the keyboard of whoever is using the machine. Use dry runs.

`P=angusforbes.universal-keybinding-explorer; d(){ omarchy-shell shell summon $P "$1" >/dev/null; sleep 2; qs -p /usr/share/omarchy/shell log | grep keybinding-explorer-dry | tail -1 | sed 's/.*-dry: //' | jq -c "${2:-.}"; }`

There is one explorer, and its log is shared. If two agents run dry runs at once, `tail -1` can return the other
agent's result, so check the `app` field in every answer, and run the test again when it's wrong. Test one app at a time.
You can't open the app just to test `focus`. Check the rule against the title the source sets (e.g.
`\x1b]2;hyprpi-room ${room}\x07`), against `hyprctl clients -j` for windows already open, and with a dry run's `focus`.

- `jq . keymaps/<id>.json` prints the file. A broken file stops every app from loading.
- `d '{"dry":true}' .apps` lists your app with its key count.
- `d '{"dry":true,"word":"<a match word>"}' .firstRows` shows the App row first.
- `d '{"dry":true,"app":"<id>","then":[{"mods":["CTRL"],"key":"S"}]}' '{meaning,chips}'` shows your description.
- `d '{"dry":true,"focus":{"class":"<class>","title":"<title>"}}' '{app,appAuto,title}'` gives `appAuto: true`. Try an
  unrelated window too, which should give `app: ""`.
- `d '{"dry":true,"app":"<id>","then":[{"type":":"}]}' '{rows,firstRows}'` lists the commands, if there are any.
- Watch the meaning text for "⚠ taken by Hyprland". It means Hyprland grabs that chord first, so the app never gets it.
  It's worth telling the user about.
- Hyprland mode must be unchanged: `d '{"dry":true}' .rows` gives the same count as before you started.

## 4. Finish

- Spot-check five random entries: does each `src` line really handle that key?
- Commit the JSON (and the generator) to the plugin's repo.
- Tell the user how to regenerate the file, and what the generator reported as dropped or undescribed.
