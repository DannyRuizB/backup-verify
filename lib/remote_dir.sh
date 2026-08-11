#!/usr/bin/env bash
# =============================================================================
# Directory remote for offsite.sh: REMOTE was a plain path - a mounted NAS,
# a USB disk, a second disk in the same box. It gets the SAME protocol as the
# ssh remote (temporary name, hash what landed, only then rename) because a
# mount fails in the same shapes a network does: a full disk still leaves a
# file with a plausible size under whatever name was being written, and the
# hash-after-write is what notices whatever the filesystem did not say.
# =============================================================================
# shellcheck shell=bash
# Sourced by offsite.sh after it sets REM_DIR; never run directly.

# shellcheck disable=SC2034  # consumed by offsite.sh, which sources this
REM_KIND="dir"

rem_describe() { printf '%s (local directory)' "$REM_DIR"; }

rem_preflight() {
    local mode="$1"
    if [ "$mode" = rw ]; then
        mkdir -p -- "$REM_DIR" 2>/dev/null || die "cannot create $REM_DIR"
        [ -w "$REM_DIR" ] || die "cannot write to $REM_DIR"
    else
        # Read paths never mkdir: a typo'd --remote must look like what it is
        # (no such remote), not like an empty one.
        [ -d "$REM_DIR" ] || die "$REM_DIR does not exist - wrong --remote?"
    fi
}

rem_put()    { cp -- "$1" "$REM_DIR/$2"; }
rem_get()    { cp -- "$REM_DIR/$1" "$2"; }
rem_rename() { mv -f -- "$REM_DIR/$1" "$REM_DIR/$2"; }
rem_delete() { rm -f -- "$REM_DIR/$1"; }
rem_sha256() { sha256_of "$REM_DIR/$1"; }
rem_list()   { find "$REM_DIR" -maxdepth 1 -type f | sed 's|.*/||'; }
