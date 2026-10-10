-- Universal Keybinding Explorer: add this to ~/.config/hypr/bindings.lua (Omarchy's Lua config).
--
-- SUPER + ALT + K opens it at the top level (all system keys; type an app name to search its keys);
-- SUPER + ALT + CTRL + K opens the focused app's keys if a keymap matches it, else the top level (J418).
-- Both switch to the `keybinding-explorer` submap, where only Escape and the two opening chords are bound,
-- so every other key reaches the overlay, which explains it instead of running it.
-- Escape: in an app's context, back to the Hyprland keys; otherwise leave. SUPER + ALT + K: leave.
-- Omarchy binds SUPER + ALT + K to "Tmux keybindings" by default; it is unbound here (pick another chord if you
-- want to keep it: change both places below).
hl.unbind("SUPER + ALT + K")
o.bind("SUPER + ALT + K", "Universal keybinding explorer", "$HOME/.local/bin/keybinding-explorer on")
o.bind("SUPER + ALT + CTRL + K", "Keybinding explorer for the focused app", "$HOME/.local/bin/keybinding-explorer app")
hl.define_submap("keybinding-explorer", function()
  hl.bind("ESCAPE", hl.dsp.exec_cmd("$HOME/.local/bin/keybinding-explorer esc"))
  hl.bind("SUPER + ALT + K", hl.dsp.exec_cmd("$HOME/.local/bin/keybinding-explorer off"))
  hl.bind("SUPER + ALT + CTRL + K", hl.dsp.exec_cmd("$HOME/.local/bin/keybinding-explorer off"))
  -- Optional: let PRINT still take a screenshot inside the explorer.
  hl.bind("PRINT", hl.dsp.exec_cmd("omarchy-capture-screenshot"))
end)
