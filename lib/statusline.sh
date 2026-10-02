#!/bin/bash
# Status line segment: which Claude account this session is signed in as.
#
# Claude Code pipes session JSON on stdin and renders whatever this prints.
# The account is not in that JSON, so it comes from CLAUDE_CONFIG_DIR, which the
# switcher sets per profile and Claude Code passes down to this script.
#
# Colours per profile live in ~/.claude-accounts/colors.conf as "name=N", where
# N is a 256-colour code. Anything not listed gets a stable colour derived from
# its name, so a new profile is still visually distinct without configuration.

set -uo pipefail

ROOT="$HOME/.claude-accounts"
PALETTE=(29 24 90 130 53 22 60 96)   # 256-colour codes, distinguishable on dark themes
DEFAULT_COLOR=29                      # green, for the primary account

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"

# Which profile is this.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  profile="$(basename "$CLAUDE_CONFIG_DIR")"
  config="$CLAUDE_CONFIG_DIR/.claude.json"
else
  profile="default"
  config="$HOME/.claude.json"
fi

# Unslop writes its resolved mode here at SessionStart, keyed by session. No
# file means the hook did not run for this session, so the badge stays off:
# it reports that the mode is live, not that the plugin is installed.
unslop_state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.unslop/${session_id:-none}"

# The account cannot change mid-session, so render once and reuse. This script
# runs on a 300ms debounce during active work and the config file is ~60KB;
# parsing it every time would be pure waste.
cache_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
cache=""
if [ -n "$session_id" ]; then
  cache="$cache_dir/claude-account-${session_id}-${profile}"
  if [ -s "$cache" ] && [ "$cache" -nt "$config" ] && [ ! "$unslop_state" -nt "$cache" ]; then
    cat "$cache"
    exit 0
  fi
fi

email="$(jq -r '.oauthAccount.emailAddress // empty' "$config" 2>/dev/null)"
[ -n "$email" ] || email="not signed in"

# Colour: explicit mapping first, then a stable fallback derived from the name.
color=""
if [ -r "$ROOT/colors.conf" ]; then
  # \{1,\} rather than \+, which is a GNU extension and a literal plus in BSD sed.
  color="$(sed -n "s/^${profile}=\([0-9]\{1,\}\).*/\1/p" "$ROOT/colors.conf" | head -1)"
fi
if [ -z "$color" ]; then
  if [ "$profile" = "default" ]; then
    color="$DEFAULT_COLOR"
  else
    sum=0
    while IFS= read -r -n1 ch; do
      [ -n "$ch" ] || continue
      sum=$(( (sum + $(printf '%d' "'$ch")) % 256 ))
    done <<< "$profile"
    color="${PALETTE[$(( sum % ${#PALETTE[@]} ))]}"
  fi
fi

badge=$'\033'"[48;5;${color}m"$'\033[38;5;231m'" ● ${profile} "$'\033[0m'
dim=$'\033[2m'"${email}"$'\033[0m'
out="${badge} ${dim}"

# Unslop segment. Absent state file renders nothing at all.
unslop_mode="$(cat "$unslop_state" 2>/dev/null)"
if [ -n "$unslop_mode" ]; then
  # Enforce reads bright, advisory stays dim, so the colour itself says which
  # mode is live rather than only the label text.
  case "$unslop_mode" in
    enforce)  unslop_label="unslop";                 unslop_sgr=$'\033[1;38;5;114m' ;;
    advisory) unslop_label="unslop?";                unslop_sgr=$'\033[2;38;5;108m' ;;
    *)        unslop_label="unslop:${unslop_mode}";  unslop_sgr=$'\033[38;5;179m' ;;
  esac
  out="${out} ${unslop_sgr}✎ ${unslop_label}"$'\033[0m'
fi

printf '%s' "$out"
[ -n "$cache" ] && printf '%s' "$out" > "$cache" 2>/dev/null

exit 0
