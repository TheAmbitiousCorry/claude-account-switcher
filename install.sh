#!/usr/bin/env bash
# Interactive installer for claude-account-switcher.
#
# Re-runnable. Every step is idempotent, and every file it touches outside
# ~/.claude-accounts is backed up first. uninstall.sh reverses all of it.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_ACCOUNTS_ROOT:-$HOME/.claude-accounts}"
BIN="$HOME/.local/bin"
SETTINGS="$HOME/.claude/settings.json"
STAMP="$(date +%s)"

bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; reset=$'\033[0m'

say()  { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$bold" "$*" "$reset"; }
ok()   { printf '  %s✓%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '  %s!%s %s\n' "$red" "$reset" "$*"; }
note() { printf '  %s%s%s\n' "$dim" "$*" "$reset"; }

# ---------------------------------------------------------------- prompt helpers

have() { command -v "$1" >/dev/null 2>&1; }

# Prompts read from the terminal so the script still works when piped into bash.
# Set CAS_INPUT to a file to answer non-interactively, which is also how the
# test suite drives this.
INPUT="${CAS_INPUT:-/dev/tty}"
[ -r "$INPUT" ] || INPUT=/dev/stdin
# Open once on its own descriptor. Redirecting per read would reopen the source
# each time, and every prompt would get the first line again.
exec 3<"$INPUT" || exec 3<&0

# choose "Header" "opt1" "opt2" ...   -> prints the chosen option
choose() {
  local header="$1"; shift
  if [ -z "${CAS_INPUT:-}" ] && have gum; then
    printf '%s\n' "$@" | gum choose --header "$header"
    return
  fi
  printf '%s\n' "$header" >&2
  local i=1 opt
  for opt in "$@"; do printf '  %d) %s\n' "$i" "$opt" >&2; i=$((i+1)); done
  local pick
  read -r -u 3 -p "> " pick
  case "$pick" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$pick" -ge 1 ] && [ "$pick" -le "$#" ] || return 1
       printf '%s\n' "${!pick}" ;;
  esac
}

# multichoose "Header" "opt1" "opt2" ... -> prints chosen options, one per line
multichoose() {
  local header="$1"; shift
  if [ -z "${CAS_INPUT:-}" ] && have gum; then
    printf '%s\n' "$@" | gum choose --no-limit --header "$header"
    return
  fi
  printf '%s (comma-separated numbers, blank for none)\n' "$header" >&2
  local i=1 opt
  for opt in "$@"; do printf '  %d) %s\n' "$i" "$opt" >&2; i=$((i+1)); done
  local picks
  read -r -u 3 -p "> " picks
  local n
  IFS=',' read -ra picks <<< "$picks"
  for n in "${picks[@]}"; do
    n="$(printf '%s' "$n" | tr -d '[:space:]')"
    case "$n" in
      ''|*[!0-9]*) continue ;;
      *) [ "$n" -ge 1 ] && [ "$n" -le "$#" ] && printf '%s\n' "${!n}" ;;
    esac
  done
}

confirm() {
  if [ -z "${CAS_INPUT:-}" ] && have gum; then gum confirm "$1"; return $?; fi
  local reply
  read -r -u 3 -p "$1 [y/N] " reply
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

ask() {
  local prompt="$1" default="${2:-}" reply
  if [ -z "${CAS_INPUT:-}" ] && have gum; then
    gum input --prompt "$prompt " --value "$default"
    return
  fi
  read -r -u 3 -p "$prompt [$default] " reply
  printf '%s\n' "${reply:-$default}"
}

backup() {
  [ -e "$1" ] || return 0
  cp -a "$1" "$1.bak.$STAMP"
  note "backed up $(basename "$1") -> $(basename "$1").bak.$STAMP"
}

# ---------------------------------------------------------------- prerequisites

head2 "Checking prerequisites"

missing=0
for c in bash python3; do
  if have "$c"; then ok "$c"; else warn "$c is required and was not found"; missing=1; fi
done
have jq || { warn "jq not found: the status line needs it"; }
if have gum; then ok "gum (prompts and picker)"
elif have fzf; then ok "fzf (prompts and picker)"
else note "neither gum nor fzf found: falling back to numbered menus"; fi

[ "$missing" -eq 0 ] || { say ""; say "Install the missing tools and re-run."; exit 1; }

if [ ! -d "$HOME/.claude" ]; then
  warn "$HOME/.claude does not exist. Run Claude Code once and sign in first."
  exit 1
fi

# ---------------------------------------------------------------- install files

head2 "Installing"

mkdir -p "$ROOT" "$BIN"
for f in switcher.sh sync.py statusline.sh; do
  ln -sfn "$REPO/lib/$f" "$ROOT/$f"
done
ln -sfn "$REPO/bin/claude-pick" "$BIN/claude-pick"
chmod +x "$REPO/bin/claude-pick" "$REPO/lib/statusline.sh" 2>/dev/null
ok "linked scripts into $ROOT and $BIN"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) warn "$BIN is not on your PATH; add it so claude-pick can be found" ;;
esac

# ---------------------------------------------------------------- sync choices

head2 "Profile sharing"
say "Extra accounts get their own config directory, so by default they share"
say "nothing: no CLAUDE.md, no skills, no plugins, no MCP servers."
say ""

sync_mode="$(choose "How should profiles relate?" \
  "Share and sync (recommended)" \
  "Keep fully isolated")" || sync_mode="Share and sync (recommended)"

shared_list=""
sync_keys=""
sync_dir="two-way"

if [ "$sync_mode" = "Keep fully isolated" ]; then
  sync_dir="isolated"
  shared_list=""
  ok "profiles will share nothing"
else
  say ""
  mapfile -t shared_pick < <(multichoose "Symlink from your main account into every profile:" \
    "CLAUDE.md (your global instructions)" \
    "skills" \
    "plugins (also carries plugin MCP servers)" \
    "agents" \
    "settings.json (theme, status line, plugin toggles)" \
    "themes" \
    "session history (projects, sessions, history.jsonl)")

  for item in "${shared_pick[@]}"; do
    case "$item" in
      CLAUDE.md*)        shared_list="$shared_list CLAUDE.md" ;;
      skills*)           shared_list="$shared_list skills" ;;
      plugins*)          shared_list="$shared_list plugins" ;;
      agents*)           shared_list="$shared_list agents" ;;
      settings.json*)    shared_list="$shared_list settings.json" ;;
      themes*)           shared_list="$shared_list themes" ;;
      session\ history*) shared_list="$shared_list projects sessions history.jsonl file-history shell-snapshots backups paste-cache session-env" ;;
    esac
  done

  say ""
  say "Some config lives inside .claude.json, which cannot be symlinked because"
  say "it also holds the account identity. Those keys get merged instead."
  say ""
  mapfile -t key_pick < <(multichoose "Merge which keys between profiles?" \
    "MCP servers" \
    "Project trust and per-directory history")

  for item in "${key_pick[@]}"; do
    case "$item" in
      "MCP servers") sync_keys="$sync_keys mcpServers" ;;
      Project*)      sync_keys="$sync_keys projects" ;;
    esac
  done

  if [ -n "$sync_keys" ]; then
    say ""
    d="$(choose "Which direction should merges flow?" \
      "Both ways (recommended)" \
      "Only from the main account outward")" || d="Both ways (recommended)"
    case "$d" in
      Only*) sync_dir="from-default" ;;
      *)     sync_dir="two-way" ;;
    esac
  else
    sync_dir="isolated"
  fi
  ok "sharing configured"
fi

shared_array="$(printf '%s' "$shared_list" | tr ' ' '\n' | sed '/^$/d' | sed 's/^/  /' )"
# Re-running the installer is the documented way to change answers, so the
# previous answers are worth keeping. This also preserves any hand edits.
backup "$ROOT/config.sh"
{
  echo "# Written by claude-account-switcher install.sh on $(date -Iseconds)."
  echo "# Edit freely, or delete this file to fall back to defaults."
  echo ""
  echo "CLAUDE_ACCOUNTS_SYNC_MODE=$sync_dir"
  echo "CLAUDE_ACCOUNTS_SYNC_KEYS=\"$(printf '%s' "$sync_keys" | sed 's/^ //')\""
  echo ""
  echo "# Copies kept per file before anything overwrites or deletes it."
  echo "# See them with 'clp backups'. Set to 0 to turn backups off."
  echo "CLAUDE_ACCOUNTS_BACKUP_KEEP=10"
  echo ""
  echo "CLAUDE_ACCOUNTS_SHARED=("
  [ -n "$shared_array" ] && printf '%s\n' "$shared_array"
  echo ")"
} > "$ROOT/config.sh"
ok "wrote $ROOT/config.sh"

# ---------------------------------------------------------------- shell wiring

head2 "Shell integration"

rcfile="$HOME/.bashrc"
[ -n "${ZSH_VERSION:-}" ] && rcfile="$HOME/.zshrc"
[ "$(basename "${SHELL:-bash}")" = "zsh" ] && rcfile="$HOME/.zshrc"
rcfile="$(ask "Which shell rc file should source the switcher?" "$rcfile")"

line="[ -r \"\$HOME/.claude-accounts/switcher.sh\" ] && source \"\$HOME/.claude-accounts/switcher.sh\""
if [ -f "$rcfile" ] && grep -qF "claude-accounts/switcher.sh" "$rcfile"; then
  ok "already sourced in $(basename "$rcfile")"
else
  backup "$rcfile"
  {
    echo ""
    echo "# claude-account-switcher (remove these two lines to disable)"
    echo "$line"
  } >> "$rcfile"
  ok "added to $(basename "$rcfile")"
fi

# ---------------------------------------------------------------- status line

head2 "Status line"
say "Shows a coloured badge with the account this session is signed in as."
say "${dim}Trade-off: enabling a custom status line makes Claude Code hide most"
say "footer key hints (esc to interrupt, ? for shortcuts).${reset}"
say ""

if confirm "Install the account status line?"; then
  if have python3; then
    backup "$SETTINGS"
    python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
except ValueError:
    print("  settings.json is not valid JSON; leaving it alone", file=sys.stderr)
    raise SystemExit(1)
cfg["statusLine"] = {"type": "command", "command": "~/.claude-accounts/statusline.sh"}
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
    [ $? -eq 0 ] && ok "status line configured"
  fi
else
  note "skipped"
fi

# ---------------------------------------------------------------- keybinding

head2 "Keyboard shortcut"
say "Launches Claude Code with the account picker in a new terminal window."
say ""

if confirm "Set up a keyboard shortcut?"; then
  combo="$(ask "Key combination" "SUPER + SHIFT + A")"

  extra_args=""
  if confirm "Skip permission prompts in shortcut-launched sessions?"; then
    extra_args="--permission-mode bypassPermissions"
  fi
  start_dir="$(ask "Start sessions in which directory when launched from \$HOME?" "$HOME")"

  {
    echo "CLAUDE_PICK_ARGS=\"$extra_args\""
    echo "CLAUDE_PICK_CD=\"$start_dir\""
  } >> "$ROOT/config.sh"

  hypr_user="$HOME/.config/hypr/bindings.lua"
  if [ -f "$hypr_user" ] && grep -q "o.bind" "$hypr_user"; then
    # Omarchy-style Lua bindings.
    launcher="claude-pick"
    have omarchy-launch-tui && launcher="omarchy-launch-tui --app-id=org.omarchy.agent claude-pick"
    backup "$hypr_user"
    {
      echo ""
      echo "-- claude-account-switcher"
      echo "hl.unbind(\"$combo\")"
      echo "o.bind(\"$combo\", \"Claude\", \"$launcher\")"
    } >> "$hypr_user"
    ok "added to $hypr_user"
    have hyprctl && hyprctl reload >/dev/null 2>&1 && ok "hyprland reloaded"
  elif [ -f "$HOME/.config/hypr/hyprland.conf" ]; then
    hypr_conf="$HOME/.config/hypr/hyprland.conf"
    mods="$(printf '%s' "$combo" | sed 's/ *+ *[^+]*$//' | tr -d ' ')"
    key="$(printf '%s' "$combo" | sed 's/.*+ *//' | tr -d ' ')"
    term="${TERMINAL:-$(for t in foot alacritty kitty ghostty wezterm; do have $t && echo $t && break; done)}"
    backup "$hypr_conf"
    {
      echo ""
      echo "# claude-account-switcher"
      echo "bind = $mods, $key, exec, ${term:-xterm} -e claude-pick"
    } >> "$hypr_conf"
    ok "added to $hypr_conf"
    have hyprctl && hyprctl reload >/dev/null 2>&1 && ok "hyprland reloaded"
  else
    note "no Hyprland config found. Bind this command in your desktop's"
    note "keyboard settings, in a terminal window:"
    say ""
    say "    claude-pick"
    say ""
    note "See docs/hyprland.md for worked examples."
  fi
else
  note "skipped"
fi

# ---------------------------------------------------------------- done

head2 "Done"
say "Start a new shell, then:"
say ""
say "  ${bold}clp add work${reset}      create a second account"
say "  ${bold}clp use work${reset}      launch it, then /login"
say "  ${bold}claude${reset}            pick an account"
say "  ${bold}clp list${reset}          see who each profile is signed in as"
say "  ${bold}clp backups${reset}       config and sign-in copies kept automatically"
say ""
say "Uninstall with ${bold}./uninstall.sh${reset}. Your ~/.claude is never modified."
