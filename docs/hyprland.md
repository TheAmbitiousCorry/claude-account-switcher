# Keyboard shortcuts

`claude-pick` is the entry point for a shortcut or a desktop launcher. It shows
the account picker inside the terminal window Claude Code is about to occupy, so
the choice and the session share one window, then hands off with `exec`.

The installer offers to set this up and can write the Hyprland binding for you.
This page covers doing it by hand, and the environment variables that shape it.

## Environment

Set these in `~/.claude-accounts/config.sh`:

```bash
CLAUDE_PICK_ARGS=""        # extra arguments passed through to claude
CLAUDE_PICK_CD="$HOME/Work"   # start here when launched from $HOME
```

`CLAUDE_PICK_CD` exists because Claude Code will not remember a trust decision
for `$HOME`. A launcher that starts there asks on every session. Pointing it at a
project directory avoids that.

`CLAUDE_PICK_ARGS` is empty by default, deliberately. If you want
shortcut-launched sessions to skip permission prompts, set it explicitly:

```bash
CLAUDE_PICK_ARGS="--permission-mode bypassPermissions"
```

Understand what that does before turning it on. It runs an agent with no approval
step, which is reasonable in a sandbox or a scratch repo and unreasonable
somewhere it can do damage.

## Hyprland

### Omarchy, or any Lua-based config

Omarchy configures Hyprland in Lua and loads user files after its own defaults,
so overrides go in `~/.config/hypr/bindings.lua`. Unbind before rebinding a key
that already has a default:

```lua
hl.unbind("SUPER + SHIFT + A")
o.bind("SUPER + SHIFT + A", "Claude", "claude-pick")
```

On Omarchy, `omarchy-launch-tui` opens the default terminal with a fixed app-id,
which keeps existing window rules and theming matching:

```lua
hl.unbind("SUPER + SHIFT + A")
o.bind("SUPER + SHIFT + A", "Claude",
  "omarchy-launch-tui --app-id=org.omarchy.agent claude-pick")
```

Apply and check:

```bash
hyprctl reload
hyprctl configerrors        # should print nothing
omarchy menu keybindings --print | grep -i claude
```

Note that `omarchy-agent`, the stock Claude binding, cannot show a picker. It
`exec`s the binary with arguments from a non-interactive script, so the shell
function is neither loaded nor consulted. That is why this ships a separate
launcher rather than reusing it.

### Plain hyprland.conf

```
bind = SUPER SHIFT, A, exec, foot -e claude-pick
```

Swap `foot` for your terminal. Reload with `hyprctl reload`.

## Other desktops

Any launcher works as long as it opens a terminal and runs `claude-pick` in it.

GNOME, in Settings, Keyboard, Custom Shortcuts:

```
Command: kgx -- claude-pick
```

KDE, in System Settings, Shortcuts, Custom Shortcuts, as a command action:

```
konsole -e claude-pick
```

A `.desktop` entry:

```ini
[Desktop Entry]
Type=Application
Name=Claude Code
Exec=foot -e claude-pick
Terminal=false
```

## If the shortcut opens nothing

- `claude-pick` must be on `PATH` for the session your compositor launches, not
  just your interactive shell. `~/.local/bin` is the usual gap. Test with an
  absolute path first: `foot -e ~/.local/bin/claude-pick`.
- With one profile configured the picker is skipped by design and Claude Code
  starts immediately. Create a second profile to see it.
- Run `claude-pick` directly in a terminal to see any error before the window
  closes.
