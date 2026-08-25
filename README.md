# claude-account-switcher

Run more than one Claude account from one machine, pick which one at launch, and
keep your config in sync between them.

Claude Code stores its sign-in in one place. Signing into a second account means
signing out of the first, and signing back in later. If you have a personal
account and a work one, or you want to spread usage across two subscriptions,
that gets old fast.

This gives you named profiles instead:

```
$ claude
┌ Claude account
│ > default   you@personal.com
│   work      you@company.com
└
```

Sessions on different accounts run at the same time without interfering, because
each profile has its own config directory and its own credentials.

## What it does

- **A picker on launch.** Bare `claude` asks which account. `claude @work` skips
  the question. Anything with arguments (`claude mcp list`, `claude -p`, a hook,
  a script) goes straight to your default account and never blocks on a prompt.
- **Shared config.** Profiles borrow your `CLAUDE.md`, skills, plugins, agents,
  settings and session history by symlink, so a second account is not a stock
  install. You choose what gets shared at install time.
- **Synced MCP servers and project trust.** These live inside `.claude.json`,
  which cannot be symlinked, so they are merged between profiles instead. The
  merge runs in both directions and handles deletions.
- **A status line badge** showing which account the session is on, in its own
  colour per profile.
- **An optional keyboard shortcut** that opens the picker in a new terminal.

## What it does not do

- **It does not share connectors.** Gmail, Drive, Slack and the rest configured
  on claude.ai are held server-side against the account, and Claude Code fetches
  them with that account's token. Nothing local can move them. Connect them once
  per account.
- **It does not touch `~/.claude`.** Your existing account stays exactly where it
  is, as the profile named `default`. Uninstalling leaves it untouched.
- **It does not handle your credentials.** You sign in with `/login` as normal.
  The tool only decides which directory Claude Code reads and writes.

## Requirements

- Claude Code, already signed in once
- `bash` and `python3`
- `jq` for the status line
- `gum` or `fzf` for a nicer picker (optional, falls back to a numbered menu)

## Install

```bash
git clone https://github.com/TheAmbitiousCorry/claude-account-switcher.git && cd claude-account-switcher && ./install.sh
```

The installer asks what to share, whether to merge one way or both, whether you
want the status line, and whether to bind a keyboard shortcut. Re-run it any time
to change your answers. Every file it edits outside `~/.claude-accounts` is
backed up first.

The scripts are copied into `~/.claude-accounts` and `~/.local/bin`, so the
clone is disposable once the installer finishes. Updating means pulling and
re-running it:

```bash
cd claude-account-switcher && git pull && ./install.sh   # also how you change answers
clp version                                              # what is installed, and if it is behind
./uninstall.sh                                           # reverses everything
```

Working on this repo? `./install.sh --link` symlinks the scripts instead, so
edits are live. The checkout is then part of the installation, and moving or
deleting it breaks the switcher.

Then:

```bash
exec bash                    # pick up the shell function
clp add work                 # create a second profile
clp use work                 # launch it, then run /login
```

## Usage

```bash
claude                       # pick an account
claude @work                 # launch a specific one
claude mcp list              # no picker, uses default
CLAUDE_PROFILE=work claude   # pick via environment

clp list                     # who each profile is signed in as
clp add <name>               # create one
clp use <name> [args...]     # launch it, same as claude @<name>
clp remove <name>            # delete one, with a confirmation
clp backups                  # what has been saved, and where
```

The command is `clp`, not `cp`: shadowing coreutils `cp` in every interactive
shell is not worth two saved keystrokes.

## Backups

Nothing here asks you to copy files aside first. Before anything overwrites or
deletes config that you did not ask it to change, it is saved to
`~/.claude-accounts/backups/`:

- `~/.claude.json`, before a two-way sync merges the other account's servers in
- a profile's own `.claude.json`, on the same merge
- a profile's `.claude.json` and `.credentials.json`, before `clp remove`
  deletes it

An unchanged file is not copied again, so frequent launches do not push real
history out. The newest ten per file are kept, set `CLAUDE_ACCOUNTS_BACKUP_KEEP`
in `config.sh` to change that or `0` to turn it off. The directory is `0700` and
the copies `0600`, because credential files are sign-in tokens.

Restore by copying one back:

```bash
clp backups
cp ~/.claude-accounts/backups/default-claude-20260101-120000-00.json ~/.claude.json
```

## How it works

`CLAUDE_CONFIG_DIR` relocates everything Claude Code keeps per user: settings,
credentials, session history, and `.claude.json`. Point it at a different
directory and you get a completely separate installation, including a separate
sign-in.

That isolation is total, which is the point and also the problem. A fresh profile
has no `CLAUDE.md`, no skills, no plugins, no MCP servers. So each profile
symlinks the shared pieces back to `~/.claude`, and `.claude.json` gets a
three-way merge for the two keys that matter.

`.claude.json` cannot be symlinked because it holds both shared config
(`mcpServers`, `projects`) and account identity (`oauthAccount`, `userID`, usage
and entitlement caches) in one file. Share the whole thing and whichever account
signed in last overwrites the identity for both. So only the shared keys move,
and identity is never copied.

Full detail in [docs/how-it-works.md](docs/how-it-works.md).

## Configuration

`~/.claude-accounts/config.sh`, written by the installer and safe to hand-edit:

```bash
CLAUDE_ACCOUNTS_SYNC_MODE=two-way        # two-way | from-default | isolated
CLAUDE_ACCOUNTS_SYNC_KEYS="mcpServers projects"

CLAUDE_ACCOUNTS_SHARED=(
  CLAUDE.md
  skills
  plugins
  settings.json
)
```

`two-way` propagates additions and deletions in both directions. Where both sides
changed the same entry since the last sync, the default wins and says so on
stderr. `from-default` treats your main account as the source of truth and never
writes to it. `isolated` shares nothing.

Status line colours, if you want to override the automatic ones, go in
`~/.claude-accounts/colors.conf` as 256-colour codes:

```
work=196
client=21
```

## Caveats

- **`projects` is noisy.** It carries trust decisions and allowed tools, which
  rarely collide, but also per-directory prompt history, which changes every
  session. Use both accounts in the same directory and you will hit the conflict
  path often. Drop `projects` from `CLAUDE_ACCOUNTS_SYNC_KEYS` if that bothers
  you; session transcripts are unaffected either way.
- **External wrappers bypass the picker.** `timeout claude`, `env claude`,
  `xargs`, `sudo` and `nohup` invoke the binary directly, because none of them
  can call a shell function. Those get your default account. Use `claude @work`
  or `CLAUDE_PROFILE` when you need a wrapper.
- **A custom status line hides footer hints.** Claude Code stops showing most
  footer keyboard hints when one is configured, including `esc to interrupt` and
  `? for shortcuts`. Skip the status line at install time if you would rather
  keep them.
- **There is a small write race.** In `two-way` mode the sync writes
  `~/.claude.json`, and a live session on your default account writes it too. The
  file is re-read immediately before writing to keep the window small, but it
  cannot be closed entirely without a lock Claude Code does not participate in.

## Uninstall

```bash
./uninstall.sh
```

Removes the shell hook, the status line setting, the keybinding and the installed
symlinks, and asks before deleting profile directories, since deleting one throws
away that account's sign-in. `~/.claude` and `~/.claude.json` are not modified.

## License

MIT. See [LICENSE](LICENSE).
