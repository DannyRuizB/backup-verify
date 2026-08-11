#!/usr/bin/env bash
# =============================================================================
# ssh remote for offsite.sh: REMOTE looked like user@host:/path. Everything
# rides ONE channel - ssh with streamed stdin/stdout - rather than scp/rsync,
# for reasons this repo measured rather than assumed:
#
#   * rsync's size+mtime default re-syncs NOTHING over a remote copy that
#     rotted in place (rc 0, "up to date", corrupt forever) - and even
#     --checksum cannot hash a temporary BEFORE it is renamed into place,
#     which is the whole protocol here;
#   * scp takes the port as -P while ssh takes it as -p, and scp reads -p as
#     "preserve times" and quietly treats the port number as a FILENAME (the
#     probe for this feature hit exactly that) - one --ssh-opts string can
#     drive every operation only if every operation is ssh;
#   * the exit status of `ssh host 'cat > file'` IS the remote cat's exit
#     status, so a full remote disk fails the put loudly (measured).
#
# The far end needs only a POSIX shell with cat, mv, rm, find, mkdir and
# sha256sum - busybox qualifies. Auth must be key-based: BatchMode never
# prompts, because a backup tool that stops to ask for a password is a backup
# that silently never ran.
# =============================================================================
# shellcheck shell=bash
# Sourced by offsite.sh after it sets REM_HOST/REM_DIR/REM_SSH_OPTS.

# shellcheck disable=SC2034  # consumed by offsite.sh, which sources this
REM_KIND="ssh"

rem_describe() { printf '%s:%s (ssh)' "$REM_HOST" "$REM_DIR"; }

# %q-quoted for the remote shell, so a space in --remote does not become two
# arguments at the far end.
rem_path() { printf '%q' "$REM_DIR/$1"; }

# -n is not decoration: ssh without it SLURPS the caller's stdin, and check's
# while-read loop feeds these helpers from the very listing it is iterating -
# the first rem_get ate every line after the first manifest, check counted one
# clean pair and exited 0 over a remote full of planted leftovers. This repo
# already knew the lesson as bug #1 (docker exec -i eating a read loop) and
# wrote it down; CI caught the re-run because the runner's find order put the
# good manifest first, while the local order had hidden it. Only rem_put may
# read stdin - the file rides it.
rem_ssh()       { ssh -n "${REM_SSH_OPTS[@]}" -o BatchMode=yes "$REM_HOST" "$@"; }
rem_ssh_stdin() { ssh "${REM_SSH_OPTS[@]}" -o BatchMode=yes "$REM_HOST" "$@"; }

rem_preflight() {
    local mode="$1" qdir
    qdir=$(printf '%q' "$REM_DIR")
    rem_ssh true 2>/dev/null \
        || die "cannot reach $REM_HOST over ssh (key-based auth required - this tool never prompts)"
    rem_ssh "command -v sha256sum >/dev/null" \
        || die "$REM_HOST has no sha256sum - a remote that cannot hash what it holds cannot prove it holds anything"
    if [ "$mode" = rw ]; then
        rem_ssh "mkdir -p $qdir && [ -w $qdir ]" \
            || die "cannot create or write $REM_DIR on $REM_HOST"
    else
        rem_ssh "[ -d $qdir ]" || die "$REM_DIR does not exist on $REM_HOST - wrong --remote?"
    fi
}

rem_put()    { rem_ssh_stdin "cat > $(rem_path "$2")" < "$1"; }
rem_get()    { rem_ssh "cat $(rem_path "$1")" > "$2"; }
rem_rename() { rem_ssh "mv -f $(rem_path "$1") $(rem_path "$2")"; }
rem_delete() { rem_ssh "rm -f $(rem_path "$1")"; }
rem_sha256() { rem_ssh "sha256sum $(rem_path "$1")" | cut -d' ' -f1; }
rem_list()   { rem_ssh "find $(printf '%q' "$REM_DIR") -maxdepth 1 -type f" | sed 's|.*/||'; }
