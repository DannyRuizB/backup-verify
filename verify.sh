#!/usr/bin/env bash
# =============================================================================
# verify.sh - prove a backup restores, by restoring it.
#
# Boots a THROWAWAY instance (a database container, or a scratch directory
# for the files engine - the engine is read from the manifest), restores the
# artefact into it, and compares every table's or file's content fingerprint
# against the manifest written at backup time. Nothing is trusted: not the file
# size, not the exit code of the restore tool, not the presence of rows.
#
# Why the whole content and not a row count: a TRUNCATED dump makes pg_restore
# exit non-zero but STILL LEAVES THE TABLE POPULATED (measured on a real
# Postgres: 500 of 500 customers restored from an archive cut in half). Anyone
# checking "does the table have rows?" would sign that backup off. This script
# refuses to ever answer the question that way.
#
# Usage:
#   ./verify.sh --manifest backups/app_2026....json [--image postgres:17-alpine]
#
# Options:
#   --manifest FILE   manifest produced by backup.sh (the artefact sits beside it)
#   --identity FILE   age identity, required when the backup is encrypted
#   --image IMAGE     container image for the throwaway instance (engine default
#                     if omitted)
#   --keep-container  leave the throwaway container running (for debugging)
#   -h, --help        this help
#
# Exit codes: 0 every table matched, non-zero otherwise.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

MANIFEST=""
IDENTITY=""
IMAGE=""  # engine default unless overridden
KEEP_CONTAINER=0
PROBE=""

usage() { sed -n '2,/^#   -h, --help/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --manifest)       MANIFEST="${2:-}"; shift 2;;
            --identity)       IDENTITY="${2:-}"; shift 2;;
            --image)          IMAGE="${2:-}"; shift 2;;
            --keep-container) KEEP_CONTAINER=1; shift;;
            -h|--help)        usage 0;;
            *)                printf 'unknown option: %s\n' "$1" >&2; usage 1;;
        esac
    done
    [ -n "$MANIFEST" ] || die "--manifest is required"
}

# The manifest readers (json_str, json_num, manifest_section, manifest_tables)
# live in lib/common.sh: offsite.sh reads manifests too, and two copies of a
# parser is how two scripts end up disagreeing about what a manifest says.

cleanup() {
    # The engine knows what its throwaway instance is (a container, a scratch
    # directory) and how to remove it. It never touches a user-supplied path.
    if [ -n "$PROBE" ] && [ "$KEEP_CONTAINER" -eq 0 ]; then
        eng_teardown "$PROBE"
    elif [ -n "$PROBE" ]; then
        warn "throwaway instance left in place: $PROBE"
    fi
}

main() {
    need sha256sum
    [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

    # A PITR manifest describes a base backup bound to a WAL archive, not a
    # dump artefact - restoring it needs a recovery, not a pg_restore.
    local kind
    kind="$(json_str "$MANIFEST" kind)"
    case "$kind" in
        pitr-*)   die "this is a PITR manifest (kind '$kind') - prove it with: ./pitr.sh verify";;
        binlog-*) die "this is a MySQL binlog PITR manifest (kind '$kind') - prove it with: ./binlog.sh verify";;
    esac

    local dir db artefact engine
    # The manifest says which engine wrote it: verification never has to be told
    # twice, and a Postgres backup cannot accidentally be checked as MySQL.
    engine="$(json_str "$MANIFEST" engine)"
    [ -n "$engine" ] || engine="postgres"   # schema 1/2 manifests predate the field
    load_engine "$engine"
    [ -n "$IMAGE" ] || IMAGE="$ENG_DEFAULT_IMAGE"
    dir="$(cd "$(dirname "$MANIFEST")" && pwd)"
    db="$(json_str "$MANIFEST" database)"
    artefact="$dir/$(json_str "$MANIFEST" artefact)"
    [ -n "$db" ] || die "manifest has no database name"
    [ -f "$artefact" ] || die "artefact named by the manifest is missing: $artefact"

    # An encrypted backup cannot be verified without the key, and pretending
    # otherwise is exactly the kind of comfortable lie this repo exists to kill.
    local encryption
    encryption="$(json_str "$MANIFEST" encryption)"
    if [ "$encryption" = "age" ]; then
        [ -n "$IDENTITY" ] || die "this backup is encrypted with age: pass --identity FILE. Without the key it CANNOT be verified - and a backup you cannot decrypt is not a backup."
        [ -f "$IDENTITY" ] || die "identity file not found: $IDENTITY"
        encryption_available || die "the backup is age-encrypted but 'age' is not installed"
    elif [ -n "$IDENTITY" ]; then
        warn '--identity given but this backup is not encrypted - ignoring it'
    fi

    log "verifying $ENG_NAME backup of '$db' -> $(basename "$artefact")"

    # --- Gate 1: the artefact is byte-identical to what was backed up --------
    # Cheap, and it separates "the backup was born broken" from "the file rotted
    # on disk afterwards" - two different problems with different fixes. The
    # same shared gate guards offsite.sh's uploads and downloads.
    assert_pair_intact "$MANIFEST" "$artefact" "gate 1"
    ok "artefact matches its manifest ($(stat -c%s "$artefact") bytes, sha256 verified)"

    # --- Gate 2: restore into a genuinely clean instance ---------------------
    # Clean matters: restoring over existing data makes pg_restore report
    # "already exists" errors and leaves an ambiguous mixture (measured). A
    # verification that cannot tell restored data from pre-existing data proves
    # nothing, so the target is always a fresh container.
    PROBE="bv-verify-$$"
    trap cleanup EXIT
    log "booting a throwaway $IMAGE as '$PROBE'"
    eng_boot "$PROBE" "$db" "$IMAGE"
    eng_wait_ready "$PROBE"

    local pre
    pre=$(eng_count_relations "$PROBE" "$db" | tr -d '\n')
    [ "$pre" = "0" ] || die "the throwaway instance is not clean ($pre ${ENG_UNIT}s) - aborting"
    ok "throwaway instance is empty (0 ${ENG_UNIT}s)"

    # --- Gate 3: the restore itself -----------------------------------------
    # The exit code is recorded but NOT treated as the answer: a truncated
    # archive fails here and still leaves data behind. The fingerprints below
    # are the answer.
    local restore_rc=0
    log 'restoring...'
    if [ "$encryption" = "age" ]; then
        # Decrypt straight into pg_restore: the plaintext never lands on disk,
        # here either. PIPESTATUS separates "the key is wrong / the file is
        # corrupt" from "the archive restored badly" - two different verdicts a
        # single exit code would blur.
        set +e
        age -d -i "$IDENTITY" "$artefact" \
            | eng_restore "$PROBE" "$db" >/tmp/bv-restore-$$.log 2>&1
        local -a rst=("${PIPESTATUS[@]}")
        set -e
        if [ "${rst[0]}" -ne 0 ]; then
            sed -n '1,5p' /tmp/bv-restore-$$.log | sed 's/^/      /'
            rm -f /tmp/bv-restore-$$.log
            die "decryption FAILED (age rc=${rst[0]}) - wrong identity, or the ciphertext is corrupt. age authenticates its payload, so a truncated .age cannot decrypt at all."
        fi
        restore_rc=${rst[1]}
        ok 'decrypted with the given identity'
    else
        eng_restore "$PROBE" "$db" < "$artefact" >/tmp/bv-restore-$$.log 2>&1 || restore_rc=$?
    fi
    if [ "$restore_rc" -eq 0 ]; then
        ok 'the restore finished cleanly'
    else
        warn "the restore exited $restore_rc - continuing, because the content comparison is what decides"
        sed -n '1,5p' /tmp/bv-restore-$$.log | sed 's/^/      /'
    fi
    rm -f /tmp/bv-restore-$$.log

    # --- Gates 4-6 live in lib/common.sh ------------------------------------
    # The comparison gates (content, schema objects, extra tables, writability)
    # are shared with pitr.sh: this repo has exactly ONE definition of "the
    # restored copy matches the manifest", because two comparison loops is how
    # two verifiers end up believing different things.

    # --- Gate 4: content, table by table ------------------------------------
    local failures=0 gate_fail=0 checked
    compare_tables "$PROBE" "$db" "$MANIFEST" || gate_fail=$?
    failures=$((failures + gate_fail))
    checked=$COMPARED_TABLES

    [ "$checked" -gt 0 ] || die "the manifest lists no ${ENG_UNIT}s - nothing was verified, so nothing is proven"

    # --- Gate 5: schema objects, then the extra-table guard ------------------
    gate_fail=0
    compare_objects "$PROBE" "$db" "$MANIFEST" || gate_fail=$?
    failures=$((failures + gate_fail))

    gate_fail=0
    compare_extra_tables "$PROBE" "$db" "$checked" || gate_fail=$?
    failures=$((failures + gate_fail))

    printf '\n'
    if [ "$failures" -gt 0 ]; then
        die "VERIFICATION FAILED: $failures problem(s) across $checked ${ENG_UNIT}(s). This backup does NOT restore."
    fi
    # --- Gate 6: can the application actually WRITE to it? -------------------
    # Deliberately LAST, after every comparison, because it may modify the
    # restored copy. The engine module knows what to ask: Postgres advances each
    # sequence, MySQL compares every AUTO_INCREMENT counter against the largest
    # value its column actually holds. Both answer the same question - a counter
    # restored BEHIND its data means every row is present and the application
    # breaks on its first INSERT.
    local write_problems=0
    writable_probe_report "$PROBE" "$db" || write_problems=$?
    if [ "$write_problems" -gt 0 ]; then
        die "VERIFICATION FAILED: $write_problems write problem(s) - the data is there but the next INSERT collides."
    fi

    ok "VERIFIED: $checked ${ENG_UNIT}(s) restored byte-for-byte identical to the source."
    if [ "$restore_rc" -ne 0 ]; then
        warn "note: the restore exited $restore_rc yet the content matched - inspect before trusting"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    parse_args "$@"
    main
fi
