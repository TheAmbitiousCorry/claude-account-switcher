# Claude Code account switcher.
#
# Your existing account stays exactly where it is, in ~/.claude, and is the
# profile named "default". Extra accounts live in ~/.claude-accounts/<name>/
# and reach the shared config through symlinks, so CLAUDE.md, skills, plugins,
# settings, agents, themes and session history are the same on every account.
# Only the sign-in differs.
#
# Remove the "source" line from ~/.bashrc to disable all of this.

CLAUDE_ACCOUNTS_ROOT="${CLAUDE_ACCOUNTS_ROOT:-$HOME/.claude-accounts}"

# Written by install.sh. Safe to edit by hand or delete to fall back to the
# defaults below.
# shellcheck source=/dev/null
[ -r "$CLAUDE_ACCOUNTS_ROOT/config.sh" ] && source "$CLAUDE_ACCOUNTS_ROOT/config.sh"

# isolated     profiles share nothing; every account configures itself
# two-way      a change on either side reaches the other
# from-default the default profile is the source of truth and is never written
CLAUDE_ACCOUNTS_SYNC_MODE="${CLAUDE_ACCOUNTS_SYNC_MODE:-two-way}"

# Files and directories each extra profile borrows from ~/.claude by symlink.
# .claude.json and .credentials.json are deliberately absent: those two hold
# the account identity and its tokens, and are what makes profiles separate.
#
# install.sh may set this in config.sh, including to an empty list for fully
# isolated profiles, so only fill it in when nothing else has.
# Tested with declare, not ${x+set}: that form inspects element zero, so an
# empty array reads as unset and the defaults below would override a deliberate
# "share nothing" choice.
if ! declare -p CLAUDE_ACCOUNTS_SHARED >/dev/null 2>&1; then
  CLAUDE_ACCOUNTS_SHARED=(
    CLAUDE.md
    skills
    plugins
    agents
    themes
    settings.json
    projects
    history.jsonl
    file-history
    shell-snapshots
    backups
    paste-cache
    sessions
    session-env
  )
fi

# Keys merged between the default profile's ~/.claude.json and a profile's own
# .claude.json, in both directions, just before launch.
#
# The rest of that file is deliberately left alone. oauthAccount, userID and the
# usage, model and entitlement caches describe WHICH account you are, and
# copying those across is what breaks a profile. Everything else in there is
# interface state that regenerates on its own.
#
# Set to just "mcpServers" to stop project state (trust decisions, per-directory
# prompt history) moving between accounts.
CLAUDE_ACCOUNTS_SYNC_KEYS="${CLAUDE_ACCOUNTS_SYNC_KEYS:-mcpServers projects}"

# Merge shared config between the default profile and one named profile, in both
# directions. See sync.py for how deletions and conflicts are handled.
_claude_sync_profile() {
  local dir="$1"
  [ "$CLAUDE_ACCOUNTS_SYNC_MODE" = "isolated" ] && return 0
  [ -n "${CLAUDE_ACCOUNTS_SYNC_KEYS:-}" ] || return 0
  [ -d "$dir" ] || return 0
  [ -r "$HOME/.claude.json" ] || return 0
  [ -r "$CLAUDE_ACCOUNTS_ROOT/sync.py" ] || return 0

  python3 "$CLAUDE_ACCOUNTS_ROOT/sync.py" --mode "$CLAUDE_ACCOUNTS_SYNC_MODE" \
    "$HOME/.claude.json" "$dir" $CLAUDE_ACCOUNTS_SYNC_KEYS
}

# Print the email a profile is signed in as, or a placeholder.
_claude_profile_email() {
  local dir="$1" json
  if [ "$1" = "default" ]; then json="$HOME/.claude.json"; else json="$dir/.claude.json"; fi
  [ -r "$json" ] || { echo "not signed in"; return; }
  python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(d.get('oauthAccount',{}).get('emailAddress') or 'not signed in')
except Exception:
    print('not signed in')
" "$json" 2>/dev/null || echo "not signed in"
}

# List profile names, default first. Directories starting with "_" or "." are
# not profiles, so __pycache__ and similar strays never show up as accounts.
_claude_profile_names() {
  echo default
  [ -d "$CLAUDE_ACCOUNTS_ROOT" ] || return
  local d name
  for d in "$CLAUDE_ACCOUNTS_ROOT"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in
      _*|.*) continue ;;
    esac
    echo "$name"
  done
}

# Create a new profile and link it to the shared config.
claude-profile-add() {
  local name="$1"
  if [ -z "$name" ] || [ "$name" = "default" ]; then
    echo "usage: claude-profile-add <name>   (name cannot be 'default')" >&2
    return 1
  fi
  local dir="$CLAUDE_ACCOUNTS_ROOT/$name"
  if [ -e "$dir" ]; then
    echo "profile '$name' already exists at $dir" >&2
    return 1
  fi
  mkdir -p "$dir"
  local item
  for item in "${CLAUDE_ACCOUNTS_SHARED[@]}"; do
    [ -e "$HOME/.claude/$item" ] || continue
    ln -s "$HOME/.claude/$item" "$dir/$item"
  done
  _claude_sync_profile "$dir"
  echo "Created profile '$name' at $dir"
  echo
  echo "MCP servers and project trust are synced from the default profile on"
  echo "every launch, so there is nothing else to configure."
  echo
  echo "Next:  claude @$name    then run /login as the second account"
}

# Remove a profile. Only deletes the profile directory, never ~/.claude.
claude-profile-remove() {
  local name="$1"
  if [ -z "$name" ] || [ "$name" = "default" ]; then
    echo "usage: claude-profile-remove <name>   (cannot remove 'default')" >&2
    return 1
  fi
  local dir="$CLAUDE_ACCOUNTS_ROOT/$name"
  [ -d "$dir" ] || { echo "no such profile: $name" >&2; return 1; }
  echo "This deletes $dir (symlinks and this profile's sign-in). ~/.claude is untouched."
  read -r -p "Remove profile '$name'? [y/N] " reply
  case "$reply" in
    [yY]*) rm -rf "$dir"; echo "removed $name" ;;
    *) echo "cancelled" ;;
  esac
}

# Show every profile and who it is signed in as.
claude-profile-list() {
  local name dir email marker
  while read -r name; do
    [ -n "$name" ] || continue
    if [ "$name" = "default" ]; then dir="default"; else dir="$CLAUDE_ACCOUNTS_ROOT/$name"; fi
    email="$(_claude_profile_email "$dir" "$name")"
    if [ "$name" = "default" ]; then marker="~/.claude"; else marker="$dir"; fi
    printf '  %-12s %-28s %s\n' "$name" "$email" "$marker"
  done < <(_claude_profile_names)
}

# Run claude under a named profile.
_claude_run_profile() {
  local name="$1"; shift
  if [ "$name" = "default" ]; then
    command claude "$@"
  else
    local dir="$CLAUDE_ACCOUNTS_ROOT/$name"
    if [ ! -d "$dir" ]; then
      echo "no such profile: $name  (run 'claude-profile-list' to see them)" >&2
      return 1
    fi
    _claude_sync_profile "$dir"
    CLAUDE_CONFIG_DIR="$dir" command claude "$@"
  fi
}

claude() {
  # Explicit profile:  claude @work [args...]
  if [ "${1#@}" != "$1" ]; then
    local want="${1#@}"; shift
    _claude_run_profile "$want" "$@"
    return
  fi

  # Env override:  CLAUDE_PROFILE=work claude [args...]
  if [ -n "${CLAUDE_PROFILE:-}" ]; then
    _claude_run_profile "$CLAUDE_PROFILE" "$@"
    return
  fi

  # Any arguments at all means a subcommand, a flag, or a one-shot prompt.
  # Those must never block on a picker, so they go straight to the default.
  if [ "$#" -gt 0 ]; then
    command claude "$@"
    return
  fi

  # Bare `claude`: choose an account.
  local names=()
  while read -r n; do [ -n "$n" ] && names+=("$n"); done < <(_claude_profile_names)

  # Only one profile exists, so there is nothing to choose.
  if [ "${#names[@]}" -le 1 ]; then
    command claude
    return
  fi

  local labels=() name dir email
  for name in "${names[@]}"; do
    if [ "$name" = "default" ]; then dir="default"; else dir="$CLAUDE_ACCOUNTS_ROOT/$name"; fi
    email="$(_claude_profile_email "$dir" "$name")"
    labels+=("$name   $email")
  done

  local picked=""
  if command -v gum >/dev/null 2>&1; then
    picked="$(printf '%s\n' "${labels[@]}" | gum choose --header "Claude account")"
  elif command -v fzf >/dev/null 2>&1; then
    picked="$(printf '%s\n' "${labels[@]}" | fzf --prompt="Claude account > " --height=~10)"
  else
    echo "Claude account:"
    local i=1
    for l in "${labels[@]}"; do echo "  $i) $l"; i=$((i+1)); done
    read -r -p "> " i
    case "$i" in
      ''|*[!0-9]*) echo "cancelled" >&2; return 1 ;;
      *) picked="${labels[$((i-1))]}" ;;
    esac
  fi

  [ -n "$picked" ] || { echo "cancelled" >&2; return 1; }
  _claude_run_profile "${picked%% *}"
}
