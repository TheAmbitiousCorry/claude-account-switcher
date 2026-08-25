#!/usr/bin/env bash
# Reverses install.sh.
#
# Removes the shell hook, the status line setting, the keybinding, and the
# installed symlinks. Profile directories are kept unless you ask for them to
# go, since deleting one throws away that account's sign-in.
#
# ~/.claude and ~/.claude.json are never touched.

set -uo pipefail

ROOT="${CLAUDE_ACCOUNTS_ROOT:-$HOME/.claude-accounts}"
BIN="$HOME/.local/bin"
SETTINGS="$HOME/.claude/settings.json"
STAMP="$(date +%s)"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; reset=$'\033[0m'
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$bold" "$*" "$reset"; }
ok()    { printf '  %s✓%s %s\n' "$green" "$reset" "$*"; }
note()  { printf '  %s%s%s\n' "$dim" "$*" "$reset"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Same input handling as install.sh: read the terminal by default, or a file
# given in CAS_INPUT, opened once on its own descriptor.
INPUT="${CAS_INPUT:-/dev/tty}"
[ -r "$INPUT" ] || INPUT=/dev/stdin
exec 3<"$INPUT" || exec 3<&0

confirm() {
  if [ -z "${CAS_INPUT:-}" ] && have gum; then gum confirm "$1"; return $?; fi
  local reply
  read -r -u 3 -p "$1 [y/N] " reply
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}
backup() { [ -e "$1" ] && cp -a "$1" "$1.bak.$STAMP" && note "backed up $(basename "$1")"; }

# ---------------------------------------------------------------- shell hook

head2 "Shell integration"
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  [ -f "$rc" ] || continue
  grep -qF "claude-accounts/switcher.sh" "$rc" || continue
  backup "$rc"
  # Drop the source line and the comment directly above it.
  python3 - "$rc" <<'PY'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
out, i = [], 0
while i < len(lines):
    if "claude-accounts/switcher.sh" in lines[i]:
        # Also drop an immediately preceding comment and a blank line before it.
        while out and out[-1].lstrip().startswith("# claude-account-switcher"):
            out.pop()
        while out and out[-1].strip() == "":
            out.pop()
        i += 1
        continue
    out.append(lines[i])
    i += 1
with open(path, "w") as f:
    f.writelines(out)
PY
  ok "removed from $(basename "$rc")"
done

# ---------------------------------------------------------------- status line

head2 "Status line"
if [ -f "$SETTINGS" ] && grep -q "claude-accounts/statusline.sh" "$SETTINGS"; then
  backup "$SETTINGS"
  python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
except (FileNotFoundError, ValueError):
    raise SystemExit(0)
sl = cfg.get("statusLine")
# Only remove our own. A status line someone else configured stays.
if isinstance(sl, dict) and "claude-accounts/statusline.sh" in str(sl.get("command", "")):
    del cfg["statusLine"]
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
PY
  ok "removed statusLine from settings.json"
else
  note "not configured, or configured to something else"
fi

# ---------------------------------------------------------------- keybinding

head2 "Keyboard shortcut"
removed_binding=0
for f in "$HOME/.config/hypr/bindings.lua" "$HOME/.config/hypr/hyprland.conf"; do
  [ -f "$f" ] || continue
  grep -q "claude-account-switcher" "$f" || continue
  backup "$f"
  python3 - "$f" <<'PY'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
out, i = [], 0
while i < len(lines):
    if "claude-account-switcher" in lines[i]:
        # Drop the marker comment and the binding lines that follow it, up to
        # the next blank line or end of file.
        while out and out[-1].strip() == "":
            out.pop()
        i += 1
        while i < len(lines) and lines[i].strip() and "claude-account-switcher" not in lines[i]:
            i += 1
        continue
    out.append(lines[i])
    i += 1
with open(path, "w") as f:
    f.writelines(out)
PY
  ok "removed binding from $(basename "$f")"
  removed_binding=1
done
[ "$removed_binding" -eq 1 ] && have hyprctl && hyprctl reload >/dev/null 2>&1 && ok "hyprland reloaded"
[ "$removed_binding" -eq 0 ] && note "no binding found"

# ---------------------------------------------------------------- files

head2 "Installed files"
# -e, not -L: an install without --link copies these, and testing for a symlink
# would leave every copy behind.
for f in switcher.sh sync.py statusline.sh; do
  [ -e "$ROOT/$f" ] && rm -f "$ROOT/$f" && ok "removed $ROOT/$f"
done
rm -f "$ROOT/.install-info"
[ -e "$BIN/claude-pick" ] && rm -f "$BIN/claude-pick" && ok "removed $BIN/claude-pick"

# ---------------------------------------------------------------- profiles

head2 "Profiles"
profiles=()
if [ -d "$ROOT" ]; then
  for d in "$ROOT"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in _*|.*|backups) continue ;; esac
    profiles+=("$name")
  done
fi

if [ "${#profiles[@]}" -eq 0 ]; then
  note "none found"
  rm -f "$ROOT/config.sh" 2>/dev/null
  # Fails while backups are still there, which is correct: the next section
  # asks about those, and an empty root is removed at the end of it.
  rmdir "$ROOT" 2>/dev/null && ok "removed empty $ROOT"
else
  say "  These hold each account's sign-in:"
  for p in "${profiles[@]}"; do say "    $p"; done
  say ""
  if confirm "Delete them? You will have to sign in again on those accounts."; then
    # Keep the backups directory out of it. It is handled next, on its own
    # question, because it holds copies of sign-ins that were already deleted.
    for p in "${profiles[@]}"; do rm -rf "${ROOT:?}/$p"; done
    rm -f "$ROOT/config.sh" 2>/dev/null
    ok "removed ${#profiles[@]} profile(s)"
  else
    note "kept at $ROOT"
    note "re-running install.sh will pick them up again"
  fi
fi

# ---------------------------------------------------------------- backups

if [ -d "$ROOT/backups" ]; then
  head2 "Backups"
  say "  $(find "$ROOT/backups" -type f | wc -l) saved copies in $ROOT/backups"
  say "  These include .credentials.json copies, which are sign-in tokens."
  say ""
  if confirm "Delete them too?"; then
    rm -rf "${ROOT:?}/backups"
    ok "removed $ROOT/backups"
  else
    note "kept at $ROOT/backups"
  fi
fi

rmdir "$ROOT" 2>/dev/null && ok "removed empty $ROOT"

head2 "Done"
say "~/.claude and ~/.claude.json were not modified."
say "Backups of every edited file are alongside the originals, suffixed .bak.$STAMP"
say "Start a new shell to drop the ${bold}claude${reset} wrapper function."
