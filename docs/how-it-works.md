# How it works

## The one mechanism everything rests on

`CLAUDE_CONFIG_DIR` relocates Claude Code's per-user state. The documentation
mentions it in passing, mostly for Windows, and the environment variable
reference page does not spell out how far it reaches. So this was established by
running it rather than reading about it:

```bash
$ CLAUDE_CONFIG_DIR=/tmp/empty claude mcp list
No MCP servers configured.

$ claude mcp list
semble: uvx --from semble[mcp]==0.5.5 semble - ✔ Connected
```

Pointed at an empty directory, Claude Code created its own `.claude.json` there
and reported no MCP servers, while the normal configuration reported two. The
isolation covers settings, credentials, session history, and `.claude.json`
itself. Two config directories really are two independent installations, each
with its own sign-in.

That is the whole trick. Everything else in this repo exists to undo the parts of
that isolation you did not want.

## Why profiles need symlinks

A fresh profile is a stock install. No `CLAUDE.md`, no skills, no plugins, no
agents, no themes, no history. For a second account belonging to the same person,
that is wrong: you want the same instructions and tooling, just a different
sign-in.

So `claude-profile-add` symlinks the shared pieces back to `~/.claude`. Which
pieces is your choice at install time.

One result is worth calling out. Symlinking `plugins` also carries plugin-provided
MCP servers:

```bash
$ CLAUDE_CONFIG_DIR=/tmp/profile claude mcp list
plugin:imagegen:imagegen: ... - ✔ Connected     # arrived via the plugins symlink
```

Only user-scoped servers, the ones in `.claude.json`, need the merge described
below.

## Why `.claude.json` cannot be shared

That file mixes two unrelated things:

| Shared configuration | Account identity |
|---|---|
| `mcpServers` | `oauthAccount` |
| `projects` (trust, allowed tools, history) | `userID` |
| interface state (tips, usage counters) | `cachedUsageUtilization` |
| | `passesEligibilityCache`, `modelAccessCache` |

Symlink the file and whichever account signed in last overwrites the identity for
both, leaving credentials that say one account and an identity block that says
another. Claude Code also writes to this file throughout a session, so two
concurrent sessions sharing one would clobber each other.

The answer is to merge the shared keys and never copy the identity ones. That is
what `lib/sync.py` does, and it runs immediately before a profile launches.

## Why the merge is three-way

A plain union in both directions cannot express deletion. Remove a server on one
profile and the next sync pulls it back from the other, forever.

So each profile keeps `.sync-base.json`, a snapshot of the state the two sides
last agreed on. With a base, each entry resolves cleanly:

| In base | In profile | In default | Result |
|---|---|---|---|
| any | same | same | unchanged |
| yes | changed | unchanged | profile's version wins |
| yes | unchanged | changed | default's version wins |
| yes | changed | changed | default wins, reported on stderr |
| no | present | absent | added on the profile, propagate |
| no | absent | present | added on the default, propagate |
| yes | absent | present | deleted on the profile, stays deleted |
| yes | present | absent | deleted on the default, stays deleted |

The base is written after every successful sync.

There is one subtlety in `from-default` mode. The default is never written, so
after a sync the two sides are not equal, and recording the merged result as the
base would make the next `two-way` run read every profile-only entry as deleted
by the default and drop it. In that mode the base records what the default
actually holds instead.

## Why the picker only fires on a bare `claude`

`claude` is not only the command you launch to start chatting. Hooks, scripts and
other tools shell out to it:

```bash
claude                    # you, starting a session      → picker
claude mcp list           # a subcommand that exits      → no picker
claude -p "…"             # one-shot, often scripted     → no picker
claude --version          # a version check              → no picker
```

If the picker fired on all of them, anything non-interactive would hang waiting
for a keypress. So the wrapper shows it only when invoked with no arguments.

The wrapper is a shell function, which has a second consequence worth knowing:
external programs cannot call it. `timeout claude`, `env claude`, `xargs`, `sudo`
and `nohup` all reach the real binary directly and get your default account. Use
`claude @work` or `CLAUDE_PROFILE=work` when something wraps the command.

Non-interactive shells never load the function at all, since the source line
lives in your rc file below its interactivity check. Scripts are unaffected by
design.

## How the status line knows the account

The JSON Claude Code pipes to a status line command has no account field. It
carries `cwd`, `session_id`, `model`, `workspace`, `cost`, `context_window` and
`version`, and nothing identifying who is signed in.

So `lib/statusline.sh` reads `CLAUDE_CONFIG_DIR`, which the switcher already set
when launching the profile, and pulls `oauthAccount.emailAddress` from the config
file it points at. Unset means the default profile.

The script runs on a 300ms debounce during active work, and `.claude.json` can be
60KB or more, so the rendered string is cached per session and only reparsed when
the config file is newer. Cold runs take about 4ms, cached ones about 2ms.

## What is not solvable here

Connectors configured on claude.ai are not local configuration. The only trace on
disk is a list of display names:

```json
"claudeAiMcpEverConnected": [
  "claude.ai Gmail", "claude.ai Google Drive", "claude.ai Slack"
]
```

No URLs, no endpoints, no tokens. The connector lives server-side against the
account, and Claude Code fetches it by presenting that account's OAuth token,
which carries a `user:mcp_servers` scope for exactly that purpose.

Copy that list to another profile and the other account still asks the server
with its own token, and gets its own connectors back. Connect them once per
account. Nothing local can change this.
