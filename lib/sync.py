#!/usr/bin/env python3
"""Merge shared Claude Code config between the default profile and one named profile.

Two-way, so a server added on either side reaches the other.

The merge is three-way against a snapshot of the last successful sync, kept in
<profile>/.sync-base.json. That snapshot is what makes deletion work: without it
there is no way to tell "added over there" from "removed over here", and every
removal comes straight back on the next launch.

Account identity is never touched. Only the keys named on the command line move,
and oauthAccount, userID and the usage and entitlement caches are not among them.
"""

import json
import os
import re
import shutil
import sys
import tempfile
import time

MISSING = object()

# Copies kept per label and file. Older ones are pruned on every backup.
BACKUP_KEEP = 10


def backup_dir():
    root = os.environ.get("CLAUDE_ACCOUNTS_ROOT") or os.path.expanduser(
        "~/.claude-accounts"
    )
    return os.environ.get("CLAUDE_ACCOUNTS_BACKUP_DIR") or os.path.join(
        root, "backups"
    )


def backup(path, label):
    """Copy a file aside before it is overwritten or deleted.

    Called for anything holding a sign-in or config the user did not ask us to
    change: ~/.claude.json, a profile's own .claude.json, and a profile's
    .credentials.json on removal. Never for .sync-base.json, which is our own
    bookkeeping and is rebuilt from the two sides on the next run.

    Failure here never blocks the caller. A backup that cannot be written is
    worth a warning, not a refused launch.
    """
    try:
        keep = int(os.environ.get("CLAUDE_ACCOUNTS_BACKUP_KEEP") or BACKUP_KEEP)
    except ValueError:
        keep = BACKUP_KEEP
    if keep <= 0:
        return None

    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None

    name = os.path.basename(path).lstrip(".")
    if name.endswith(".json"):
        name = name[: -len(".json")]
    prefix = "%s-%s-" % (label, name or "config")
    directory = backup_dir()

    try:
        # 0700, and enforced even if the directory already exists: these copies
        # include .credentials.json, so they are sign-in tokens sitting on disk.
        os.makedirs(directory, mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)
        existing = sorted(x for x in os.listdir(directory) if x.startswith(prefix))
    except OSError as e:
        sys.stderr.write("claude account backup: %s\n" % e)
        return None

    # Launches are frequent and most of them change nothing, so an identical
    # copy would push real history out of the retention window.
    if existing:
        try:
            with open(os.path.join(directory, existing[-1]), "rb") as f:
                if f.read() == data:
                    return None
        except OSError:
            pass

    # The counter is always present and zero padded. Without it two copies in
    # the same second sort by "-1" against ".json", which puts the older one
    # last and makes it look like the newest.
    # The counter is always present, zero padded, and starts above the highest
    # index already used this second. Starting at the first free slot instead
    # reuses a number that pruning released, and the name then sorts as the
    # oldest copy while holding the newest content.
    stamp = time.strftime("%Y%m%d-%H%M%S")
    n = 0
    for name in existing:
        m = re.match(re.escape(prefix + stamp) + r"-(\d+)\.json$", name)
        if m:
            n = max(n, int(m.group(1)) + 1)
    while True:
        dest = os.path.join(directory, "%s%s-%02d.json" % (prefix, stamp, n))
        if not os.path.exists(dest):
            break
        n += 1

    try:
        # copy, not move: the original must survive if this is a pre-write
        # backup and the write then fails.
        shutil.copy2(path, dest)
        # copy2 carries the source mode across, and not every source is 0600.
        os.chmod(dest, 0o600)
    except OSError as e:
        sys.stderr.write("claude account backup: %s\n" % e)
        return None

    for old in existing[: max(0, len(existing) + 1 - keep)]:
        try:
            os.unlink(os.path.join(directory, old))
        except OSError:
            pass

    return dest


def load(path):
    """Return parsed JSON, {} if absent, or None if unreadable or corrupt."""
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except (ValueError, OSError):
        return None


def write_atomic(path, data):
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".sync.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def merge(base, ours, theirs):
    """Three-way merge two flat dicts. Returns (merged, conflicting_keys).

    "ours" is the profile, "theirs" is the default. Where both sides changed the
    same entry since the last sync, the default wins and the key is reported.
    """
    merged = {}
    conflicts = []

    for key in set(ours) | set(theirs):
        o = ours.get(key, MISSING)
        t = theirs.get(key, MISSING)
        b = base.get(key, MISSING)

        if o is not MISSING and t is not MISSING:
            if o == t:
                merged[key] = o
            elif b == o:
                merged[key] = t          # only the default moved
            elif b == t:
                merged[key] = o          # only the profile moved
            else:
                merged[key] = t          # both moved
                conflicts.append(key)
        elif o is MISSING:
            if b is MISSING:
                merged[key] = t          # added on the default
            # otherwise it was removed on the profile, so it stays removed
        else:
            if b is MISSING:
                merged[key] = o          # added on the profile
            # otherwise it was removed on the default, so it stays removed

    return merged, conflicts


def main():
    argv = sys.argv[1:]

    # --backup <label> <path>...   copy files aside and prune, then stop.
    # Used by clp before it deletes a profile, so removal and sync share one
    # retention policy instead of two that drift.
    if argv and argv[0] == "--backup":
        label = argv[1] if len(argv) > 1 else "profile"
        for path in argv[2:]:
            dest = backup(path, label)
            if dest:
                print(dest)
        return 0

    # --list-backups   one per line: when, size in bytes, path.
    if argv and argv[0] == "--list-backups":
        directory = backup_dir()
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            return 0
        for name in names:
            full = os.path.join(directory, name)
            try:
                st = os.stat(full)
            except OSError:
                continue
            # The copy keeps the original's mtime, which says when the content
            # is from, not when it was saved. The stamp in the name is the one
            # that answers "how far back can I go", so prefer it.
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime))
            m = re.search(r"-(\d{8})-(\d{6})-\d+\.json$", name)
            if m:
                d, t = m.group(1), m.group(2)
                when = "%s-%s-%s %s:%s" % (d[0:4], d[4:6], d[6:8], t[0:2], t[2:4])
            print("%s\t%d\t%s" % (when, st.st_size, full))
        return 0

    # --mode two-way     merge in both directions (default)
    # --mode from-default  the default profile is the source of truth and is
    #                      never written; entries the profile alone has survive
    mode = "two-way"
    if "--mode" in argv:
        i = argv.index("--mode")
        if i + 1 < len(argv):
            mode = argv[i + 1]
            del argv[i:i + 2]

    if len(argv) < 3:
        return 0

    default_path, profile_dir = argv[0], argv[1]
    keys = argv[2:]
    profile_path = os.path.join(profile_dir, ".claude.json")
    base_path = os.path.join(profile_dir, ".sync-base.json")

    default_cfg = load(default_path)
    profile_cfg = load(profile_path)
    base_cfg = load(base_path)

    # A config we cannot parse is not ours to repair, and overwriting it would
    # destroy whatever Claude Code still has in there.
    if default_cfg is None or profile_cfg is None:
        return 0
    if base_cfg is None:
        base_cfg = {}

    new_base = {}
    all_conflicts = []
    default_changed = False
    profile_changed = False

    for key in keys:
        ours = profile_cfg.get(key)
        theirs = default_cfg.get(key)

        # Only dictionaries merge entry by entry. Anything else is left alone
        # rather than guessed at.
        if not isinstance(ours, dict) and not isinstance(theirs, dict):
            continue

        ours = ours if isinstance(ours, dict) else {}
        theirs = theirs if isinstance(theirs, dict) else {}
        base = base_cfg.get(key)
        base = base if isinstance(base, dict) else {}

        if mode == "from-default":
            # One-way: the default is authoritative, the profile keeps whatever
            # only it has, and nothing flows back.
            merged = dict(ours)
            merged.update(theirs)
            conflicts = []
        else:
            merged, conflicts = merge(base, ours, theirs)

        all_conflicts += ["%s.%s" % (key, c) for c in conflicts]

        # The base records the last state the two sides agreed on, and the next
        # run reads "in the base but gone now" as a deletion.
        #
        # After a two-way merge both sides equal the merged result, so that is
        # the agreed state. After from-default they do not: the default was
        # never written. Recording the merged result there would make the next
        # two-way run treat every profile-only entry as deleted by the default
        # and drop it. Record what the default actually holds instead.
        new_base[key] = merged if mode != "from-default" else dict(theirs)

        if profile_cfg.get(key) != merged:
            profile_cfg[key] = merged
            profile_changed = True
        if mode != "from-default" and default_cfg.get(key) != merged:
            default_cfg[key] = merged
            default_changed = True

    if profile_changed:
        backup(profile_path, os.path.basename(profile_dir.rstrip("/")) or "profile")
        write_atomic(profile_path, profile_cfg)

    if default_changed:
        # Re-read immediately before writing. A live session on the default
        # profile writes this file too, and this keeps the window where we could
        # overwrite its changes as small as possible.
        fresh = load(default_path)
        if fresh is not None:
            backup(default_path, "default")
            for key in new_base:
                fresh[key] = new_base[key]
            write_atomic(default_path, fresh)

    write_atomic(base_path, new_base)

    if all_conflicts:
        sys.stderr.write(
            "claude account sync: changed on both sides, kept the default's "
            "copy of: %s\n" % ", ".join(sorted(all_conflicts))
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
