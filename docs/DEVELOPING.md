# Developing the Universal Keybinding Explorer

## Files

- `Explorer.qml`: the whole overlay (logic and UI). `manifest.json` declares it an overlay plugin with `keepLoaded: true`.
- `bin/keybinding-explorer [on|off|esc|toggle]`: summons or hides the overlay and switches Hyprland's submap.
  - `on` passes the focused window's class and title (`hyprctl activewindow`), so the overlay can start in that app.
  - `esc` is the submap's Escape. In app mode it goes back to the Hyprland keys; otherwise it leaves.
  - While the overlay is in app mode it keeps the flag file `$XDG_RUNTIME_DIR/keybinding-explorer-app`. `esc` removes
    the file before asking the overlay to leave the app, so a second Esc always leaves, even if the overlay died.
- `hypr/bindings.lua`: the SUPER + ALT + K / SUPER + ALT + CTRL + K bindings and the `keybinding-explorer` submap, to copy into your config.
- `keymaps/*.json`: one keymap per app. `keymaps/gen-<app>.mjs` regenerates one from the app's source.
- `skills/add-app-keymap/SKILL.md`: how an agent adds an app.

## Data

- **Hyprland bindings:** `$OMARCHY_PATH/bin/omarchy-menu-keybindings --print` (the SUPER + K list), parsed as
  `MODS + KEY → description` on every open.
  - Modifiers are normalised to SUPER CTRL SHIFT ALT. Aliases map to those four: MOD / MOD4 / WIN / LOGO / META / CMD →
    SUPER, CONTROL / CTL → CTRL, MOD1 → ALT. An unknown modifier is kept after them.
- **Keymaps:** `jq -cs . keymaps/*.json` on every open, before the Hyprland list loads. A file without `app` or
  `bindings` is skipped. A broken JSON file logs "keybinding-explorer: bad keymap JSON", and then no app loads, so check
  new files with `jq . keymaps/<id>.json`.

## Dry runs

`omarchy-shell shell summon angusforbes.universal-keybinding-explorer '<payload>'` with `"dry": true` builds the
state without a window and logs one JSON line, prefixed `keybinding-explorer-dry:`. Read it with:

`qs -p /usr/share/omarchy/shell log | grep keybinding-explorer-dry | tail -1`

**Payload keys**

| Key | Effect |
|---|---|
| `mods` | Modifiers pressed, in order |
| `key` | The key pressed with them |
| `release` | Let go of the modifiers |
| `scroll` | `["up", "down", "pageup", "pagedown"]` |
| `word` | Typed as a quick word |
| `wordMods` | Modifiers pressed during the word |
| `focus` | `{class, title}`: as if that window were focused at open |
| `app` | Start in that keymap's `id` |
| `enter` | Press Enter (opens a listed app) |
| `then` | Later presses, in order: `{mods, key}`, `{word}`, `{type: ":ef"}` (plain key presses), `{toggle: true}` (F1), `{esc: true}`, `{backspace: true}` |

**Output fields:** app, appAuto, view (`app` / `all`), cmdMode, cmdFilter, title, exit (the hint line), meaning (the
big text), listTitle, chips, activeMods, matches, variants, rows, firstRows, cursorAt, hitRow, apps (loaded keymaps).

A dry run never touches the app-mode flag file, and always ends back in Hyprland mode.

## Deploying QML edits

A loaded overlay does not hot-reload. The shell logs "Local plugin changed, reloading", but the old QML keeps
answering. After a QML edit, run `omarchy-restart-shell`, then check:

- `omarchy-shell shell ping` says ok;
- `hyprctl layers -j` still shows `omarchy-bar`.

Keymap JSON edits need no restart, because keymaps are re-read on every open.

## Design notes

- **A submap, not a keyboard grab.** Hyprland's binds fire before any client sees the key, so the submap turns them off.
  Escape is a Hyprland bind, so it still gets you out if the overlay dies.
- **Hyprland's binds in app mode.** They are left out by default because they distract; F1 shows them. An app key that
  Hyprland binds too is always marked, since the app can never receive it.
- **Explain only.** Enter on a command, or any key, never reaches the app.
