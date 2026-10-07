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
  app's author already wrote them for users.

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
  `BACKSPACE` `HOME` `END` `PRIOR` (PgUp) `NEXT` (PgDn).
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

**Keep it honest with a generator** (recommended when there is source): a small script, `keymaps/gen-<id>.mjs`, that
reads the app's source and writes the JSON. Model it on `gen-vibezai.mjs`:

- take descriptions from the app's own key list or docs, plus an `EXTRA` list for keys the docs leave out;
- prove each key exists in a handler, and store each `file:line` in `src`;
- **drop and report** any documented key or command the code doesn't handle;
- report handled keys that no entry describes;
- take the source path as an argument, and write repo-relative `src` paths, never absolute home paths.

## 3. Test without opening the overlay

Never open the overlay or press real keys to test: it grabs the keyboard of whoever is using the machine. Use dry runs.

`P=angusforbes.universal-keybinding-explorer; d(){ omarchy-shell shell summon $P "$1" >/dev/null; sleep 1.3; qs -p /usr/share/omarchy/shell log | grep keybinding-explorer-dry | tail -1 | sed 's/.*-dry: //' | jq -c "${2:-.}"; }`

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
