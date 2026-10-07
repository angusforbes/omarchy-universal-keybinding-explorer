-- Universal Keybinding Explorer: add this to ~/.config/hypr/bindings.lua (Omarchy's Lua config).
--
-- SUPER + ALT + K switches to the `keybinding-explorer` submap, where only Escape and SUPER + ALT + K are bound,
-- so every other key reaches the overlay, which explains it instead of running it.
-- Escape: in an app's context, back to the Hyprland keys; otherwise leave. SUPER + ALT + K: leave.
-- Omarchy binds SUPER + ALT + K to "Tmux keybindings" by default; it is unbound here (pick another chord if you
-- want to keep it: change both places below).
hl.unbind("SUPER + ALT + K")
o.bind("SUPER + ALT + K", "Universal keybinding explorer", "$HOME/.local/bin/keybinding-explorer on")
hl.define_submap("keybinding-explorer", function()
  hl.bind("ESCAPE", hl.dsp.exec_cmd("$HOME/.local/bin/keybinding-explorer esc"))
  hl.bind("SUPER + ALT + K", hl.dsp.exec_cmd("$HOME/.local/bin/keybinding-explorer off"))
  -- Optional: let PRINT still take a screenshot inside the explorer.
  hl.bind("PRINT", hl.dsp.exec_cmd("omarchy-capture-screenshot"))
end)
