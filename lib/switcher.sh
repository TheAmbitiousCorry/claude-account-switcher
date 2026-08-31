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
# Run sync.py with the settings it reads from the environment. These are plain
# shell variables here, so without passing them across, a custom root or
# retention would be silently ignored and backups would land somewhere else.
_clp_sync_py() {
  [ -r "$CLAUDE_ACCOUNTS_ROOT/sync.py" ] || return 1
  CLAUDE_ACCOUNTS_ROOT="$CLAUDE_ACCOUNTS_ROOT" \
  CLAUDE_ACCOUNTS_BACKUP_DIR="${CLAUDE_ACCOUNTS_BACKUP_DIR:-}" \
  CLAUDE_ACCOUNTS_BACKUP_KEEP="${CLAUDE_ACCOUNTS_BACKUP_KEEP:-}" \
    python3 "$CLAUDE_ACCOUNTS_ROOT/sync.py" "$@"
}

_claude_sync_profile() {
  local dir="$1"
  [ "$CLAUDE_ACCOUNTS_SYNC_MODE" = "isolated" ] && return 0
  [ -n "${CLAUDE_ACCOUNTS_SYNC_KEYS:-}" ] || return 0
  [ -d "$dir" ] || return 0
  [ -r "$HOME/.claude.json" ] || return 0

  _clp_sync_py --mode "$CLAUDE_ACCOUNTS_SYNC_MODE" \
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

# Directory names inside the accounts root that are ours, not accounts.
CLAUDE_ACCOUNTS_RESERVED="backups"

# List profile names, default first. Directories starting with "_" or ".", and
# the ones we own, are not profiles, so __pycache__, backups and similar strays
# never show up as accounts or in the picker.
_claude_profile_names() {
  echo default
  [ -d "$CLAUDE_ACCOUNTS_ROOT" ] || return
  local d name reserved
  for d in "$CLAUDE_ACCOUNTS_ROOT"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in
      _*|.*) continue ;;
    esac
    for reserved in $CLAUDE_ACCOUNTS_RESERVED; do
      [ "$name" = "$reserved" ] && continue 2
    done
    echo "$name"
  done
}

# Copy a file aside before something destroys it. Naming and retention live in
# sync.py, so removal and sync cannot drift into two different policies.
_clp_backup() {
  local label="$1"; shift
  _clp_sync_py --backup "$label" "$@" >/dev/null 2>&1
}

# clp add <name>
# Create a profile and link it to the shared config.
_clp_add() {
  local name="$1"
  if [ -z "$name" ] || [ "$name" = "default" ]; then
    echo "usage: clp add <name>   (name cannot be 'default')" >&2
    return 1
  fi
  case "$name" in
    _*|.*|*/*) echo "clp: invalid profile name: $name" >&2; return 1 ;;
  esac
  local reserved
  for reserved in $CLAUDE_ACCOUNTS_RESERVED; do
    if [ "$name" = "$reserved" ]; then
      echo "clp: '$name' is reserved, pick another name" >&2
      return 1
    fi
  done
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
  echo "Next:  clp use $name    then run /login as the second account"
}

# clp remove <name>
# Delete a profile directory. Never touches ~/.claude.
_clp_remove() {
  local name="$1"
  if [ -z "$name" ] || [ "$name" = "default" ]; then
    echo "usage: clp remove <name>   (cannot remove 'default')" >&2
    return 1
  fi
  local dir="$CLAUDE_ACCOUNTS_ROOT/$name"
  [ -d "$dir" ] || { echo "no such profile: $name" >&2; return 1; }
  echo "This deletes $dir (symlinks and this profile's sign-in). ~/.claude is untouched."
  echo "Its config and credentials are backed up first: clp backups"
  read -r -p "Remove profile '$name'? [y/N] " reply
  case "$reply" in
    [yY]*)
      # Both, and before the delete: the sign-in is the part that cannot be
      # recreated without logging in again.
      _clp_backup "$name" "$dir/.claude.json" "$dir/.credentials.json"
      rm -rf "$dir"
      echo "removed $name"
      ;;
    *) echo "cancelled" ;;
  esac
}

# clp list
# Show every profile and who it is signed in as.
_clp_list() {
  local name dir email marker
  while read -r name; do
    [ -n "$name" ] || continue
    if [ "$name" = "default" ]; then dir="default"; else dir="$CLAUDE_ACCOUNTS_ROOT/$name"; fi
    email="$(_claude_profile_email "$dir" "$name")"
    # ~ rather than the full path: these lines are mostly $HOME, and the part
    # that identifies the profile is at the end.
    if [ "$name" = "default" ]; then marker="~/.claude"; else marker="${dir/#$HOME/\~}"; fi
    printf '  %-12s %-28s %s\n' "$name" "$email" "$marker"
  done < <(_claude_profile_names)
}

# clp use <name> [args...]
# Launch Claude Code under one profile. Same as `claude @<name>`.
_clp_use() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "usage: clp use <name> [claude args...]" >&2
    return 1
  fi
  shift
  _claude_run_profile "$name" "$@"
}

# clp backups
# What has been saved, oldest first, with the path to copy back from.
_clp_backups() {
  local out
  out="$(_clp_sync_py --list-backups)" || return 0
  if [ -z "$out" ]; then
    echo "  no backups yet"
    return 0
  fi
  local when size path
  while IFS=$'\t' read -r when size path; do
    printf '  %s  %7s  %s\n' "$when" "$size" "$path"
  done <<< "$out"
  echo
  echo "Restore by copying one back, for example:"
  echo "  cp <path> ~/.claude.json"
}

# clp version
# What is installed, from where, and whether the checkout has moved on.
_clp_version() {
  local info="$CLAUDE_ACCOUNTS_ROOT/.install-info"
  if [ ! -r "$info" ]; then
    echo "  no install info found at $info"
    return 0
  fi
  local CAS_INSTALL_MODE="" CAS_INSTALL_REPO="" CAS_INSTALL_COMMIT="" CAS_INSTALL_DATE=""
  # shellcheck source=/dev/null
  source "$info"
  printf '  installed  %s (%s)\n' "${CAS_INSTALL_COMMIT:-unknown}" "${CAS_INSTALL_MODE:-unknown}"
  printf '  from       %s\n' "${CAS_INSTALL_REPO:-unknown}"
  printf '  on         %s\n' "${CAS_INSTALL_DATE:-unknown}"

  # A copy install goes stale quietly: git pull updates the checkout, not the
  # files actually being run.
  if [ ! -d "$CAS_INSTALL_REPO" ]; then
    echo
    echo "  that checkout is gone, which is fine for a copy install"
    echo "  clone the repo again to update"
    return 0
  fi
  if [ "$CAS_INSTALL_MODE" = "copy" ] && [ -d "$CAS_INSTALL_REPO/.git" ]; then
    local head
    head="$(git -C "$CAS_INSTALL_REPO" rev-parse --short HEAD 2>/dev/null)"
    if [ -n "$head" ] && [ "$head" != "$CAS_INSTALL_COMMIT" ]; then
      echo
      echo "  the checkout is at $head now"
      echo "  re-run ./install.sh there to update what is installed"
    fi
  fi
}

_clp_help() {
  cat <<'EOF'
clp - Claude Code account profiles

  clp list             every profile and the account it is signed in as
  clp add <name>       create a profile, then sign in with /login
  clp use <name>       launch Claude Code on that profile
  clp remove <name>    delete a profile, after backing up its sign-in
  clp backups          config and credential copies kept automatically
  clp version          what is installed, and whether it is behind

Also:
  claude               bare, with more than one profile, asks which to use
  claude @<name>       same as clp use <name>
EOF
}

clp() {
  local cmd="${1:-help}"
  [ "$#" -gt 0 ] && shift
  case "$cmd" in
    add)            _clp_add "$@" ;;
    list|ls)        _clp_list "$@" ;;
    remove|rm)      _clp_remove "$@" ;;
    use)            _clp_use "$@" ;;
    backups)        _clp_backups "$@" ;;
    version)        _clp_version "$@" ;;
    help|-h|--help) _clp_help ;;
    *)
      echo "clp: unknown command '$cmd'" >&2
      _clp_help >&2
      return 1
      ;;
  esac
}

# Complete subcommands first, profile names after the ones that take them.
_clp_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  if [ "$COMP_CWORD" -le 1 ]; then
    COMPREPLY=($(compgen -W "list add use remove backups version help" -- "$cur"))
    return
  fi
  case "${COMP_WORDS[1]}" in
    use|remove|rm)
      COMPREPLY=($(compgen -W "$(_claude_profile_names | tr '\n' ' ')" -- "$cur"))
      ;;
    *) COMPREPLY=() ;;
  esac
}
complete -F _clp_complete clp 2>/dev/null

# Claude Code records each marketplace's installLocation as an absolute path
# under whichever profile added it, and validates it as a string against the
# active CLAUDE_CONFIG_DIR. With plugins shared by symlink one registry file
# serves every profile, so the recorded spelling can match only one of them
# and `/plugin` refresh fails on the rest with a "corrupted installLocation"
# error. Rewrite the spellings to the active profile before every launch. The
# realpath guard leaves genuinely separate marketplace directories (isolated
# profiles) untouched; the dead-path arm repairs a location whose directory no
# longer exists when the active one does.
_clp_normalize_marketplaces() {
  local cfg="$1" km="$1/plugins/known_marketplaces.json"
  [ -r "$km" ] || return 0
  python3 - "$km" "$cfg/plugins" <<'PY' 2>/dev/null
import json, os, sys
path, plugroot = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
changed = False
for name, entry in d.items():
    loc = entry.get("installLocation")
    if not isinstance(loc, str):
        continue
    want = os.path.join(plugroot, "marketplaces", name)
    if loc == want or not os.path.isdir(want):
        continue
    same = os.path.realpath(loc) == os.path.realpath(want)
    dead = not os.path.exists(loc)
    if same or dead:
        entry["installLocation"] = want
        changed = True
if changed:
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
    os.replace(tmp, path)
PY
  return 0
}

# Ask which profile to use. Prints the chosen name; returns 1 on cancel.
# With a single profile there is nothing to ask, so it answers immediately.
_claude_pick_profile() {
  local header="${1:-Claude account}"
  local names=() n
  while read -r n; do [ -n "$n" ] && names+=("$n"); done < <(_claude_profile_names)
  if [ "${#names[@]}" -le 1 ]; then
    echo "${names[0]:-default}"
    return 0
  fi

  local labels=() name dir email
  for name in "${names[@]}"; do
    if [ "$name" = "default" ]; then dir="default"; else dir="$CLAUDE_ACCOUNTS_ROOT/$name"; fi
    email="$(_claude_profile_email "$dir" "$name")"
    labels+=("$name   $email")
  done

  local picked=""
  if command -v gum >/dev/null 2>&1; then
    picked="$(printf '%s\n' "${labels[@]}" | gum choose --header "$header")"
  elif command -v fzf >/dev/null 2>&1; then
    picked="$(printf '%s\n' "${labels[@]}" | fzf --prompt="$header > " --height=~10)"
  else
    echo "$header:" >&2
    local i=1 l
    for l in "${labels[@]}"; do echo "  $i) $l" >&2; i=$((i+1)); done
    read -r -p "> " i
    case "$i" in
      ''|*[!0-9]*) return 1 ;;
      *) picked="${labels[$((i-1))]}" ;;
    esac
  fi

  [ -n "$picked" ] || return 1
  echo "${picked%% *}"
}

# Run claude under a named profile.
_claude_run_profile() {
  local name="$1"; shift
  if [ "$name" = "default" ]; then
    _clp_normalize_marketplaces "$HOME/.claude"
    command claude "$@"
  else
    local dir="$CLAUDE_ACCOUNTS_ROOT/$name"
    if [ ! -d "$dir" ]; then
      echo "no such profile: $name  (run 'clp list' to see them)" >&2
      return 1
    fi
    _claude_sync_profile "$dir"
    _clp_normalize_marketplaces "$dir"
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

  # Subcommands that write account-owned state get asked which account they
  # apply to, so an MCP server or a plugin does not silently land on the
  # default. Only when a terminal is there to ask on; scripts and pipes fall
  # through to the default exactly as before. Override the list in config.sh,
  # or set it empty to never ask.
  if [ "$#" -gt 0 ] && [ -t 0 ]; then
    case " ${CLAUDE_ACCOUNTS_PICK_SUBCOMMANDS-mcp plugin config} " in
      *" $1 "*)
        local want
        want="$(_claude_pick_profile "Run 'claude $1' on which account?")" || {
          echo "cancelled" >&2
          return 1
        }
        _claude_run_profile "$want" "$@"
        return
        ;;
    esac
  fi

  # Everything else with arguments is a flag or a one-shot prompt. Those must
  # never block on a picker, so they go straight to the default.
  if [ "$#" -gt 0 ]; then
    command claude "$@"
    return
  fi

  # Bare `claude`: choose an account.
  local picked
  picked="$(_claude_pick_profile "Claude account")" || { echo "cancelled" >&2; return 1; }
  _claude_run_profile "$picked"
}
