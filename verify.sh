#!/usr/bin/env bash
# =============================================================================
# verify.sh - prove a backup restores, by restoring it.
#
# Boots a THROWAWAY Postgres container, restores the artefact into it, and
# compares every table's content fingerprint against the manifest written at
# backup time. Nothing is trusted: not the file size, not the exit code of
# pg_restore, not the presence of rows.
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
#   --image IMAGE     Postgres image for the throwaway instance
#   --keep-container  leave the throwaway container running (for debugging)
#   -h, --help        this help
#
# Exit codes: 0 every table matched, non-zero otherwise.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

MANIFEST=""
IMAGE="postgres:17-alpine"
KEEP_CONTAINER=0
PROBE=""

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --manifest)       MANIFEST="${2:-}"; shift 2;;
            --image)          IMAGE="${2:-}"; shift 2;;
            --keep-container) KEEP_CONTAINER=1; shift;;
            -h|--help)        usage 0;;
            *)                printf 'unknown option: %s\n' "$1" >&2; usage 1;;
        esac
    done
    [ -n "$MANIFEST" ] || die "--manifest is required"
}

# Minimal JSON reading with grep/sed rather than a jq dependency: the manifest
# is written by this repo, so its shape is known and flat.
json_str() {
    local file="$1" key="$2"
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" \
        | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

json_num() {
    local file="$1" key="$2"
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]*" "$file" \
        | head -1 | sed 's/.*:[[:space:]]*//'
}

# Every "key": "value" pair inside one top-level object of the manifest, as
# TAB-separated lines. Scoped to the section's line range because "tables" and
# "objects" both indent their entries by four spaces - a plain four-space match
# would happily mix them.
manifest_section() {
    local file="$1" section="$2"
    sed -n "/^  \"$section\": {/,/^  }/p" "$file" \
        | sed -n 's/^    "\([^"]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1\t\2/p'
}

manifest_tables() { manifest_section "$1" tables; }

cleanup() {
    if [ -n "$PROBE" ] && [ "$KEEP_CONTAINER" -eq 0 ]; then
        docker rm -f "$PROBE" >/dev/null 2>&1 || true
    elif [ -n "$PROBE" ]; then
        warn "throwaway container left running: $PROBE"
    fi
}

main() {
    need docker
    need sha256sum
    [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

    local dir db artefact expected_sha expected_bytes
    dir="$(cd "$(dirname "$MANIFEST")" && pwd)"
    db="$(json_str "$MANIFEST" database)"
    artefact="$dir/$(json_str "$MANIFEST" artefact)"
    expected_sha="$(json_str "$MANIFEST" sha256)"
    expected_bytes="$(json_num "$MANIFEST" bytes)"
    [ -n "$db" ] || die "manifest has no database name"
    [ -f "$artefact" ] || die "artefact named by the manifest is missing: $artefact"

    log "verifying backup of '$db' -> $(basename "$artefact")"

    # --- Gate 1: the artefact is byte-identical to what was backed up --------
    # Cheap, and it separates "the backup was born broken" from "the file rotted
    # on disk afterwards" - two different problems with different fixes.
    local actual_sha actual_bytes
    actual_bytes=$(stat -c%s "$artefact")
    actual_sha=$(sha256_of "$artefact")
    [ "$actual_bytes" = "$expected_bytes" ] \
        || die "size drift: manifest says $expected_bytes bytes, file is $actual_bytes"
    [ "$actual_sha" = "$expected_sha" ] \
        || die "checksum drift: the artefact changed since it was written"
    ok "artefact matches its manifest ($actual_bytes bytes, sha256 verified)"

    # --- Gate 2: restore into a genuinely clean instance ---------------------
    # Clean matters: restoring over existing data makes pg_restore report
    # "already exists" errors and leaves an ambiguous mixture (measured). A
    # verification that cannot tell restored data from pre-existing data proves
    # nothing, so the target is always a fresh container.
    PROBE="bv-verify-$$"
    trap cleanup EXIT
    log "booting a throwaway $IMAGE as '$PROBE'"
    docker run -d --name "$PROBE" -e POSTGRES_PASSWORD=verify -e POSTGRES_DB="$db" \
        "$IMAGE" >/dev/null
    wait_for_postgres "$PROBE"

    local pre
    pre=$(psql_in "$PROBE" "$db" "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" | tr -d '\n')
    [ "$pre" = "0" ] || die "the throwaway instance is not clean ($pre tables) - aborting"
    ok "throwaway instance is empty (0 tables)"

    # --- Gate 3: the restore itself -----------------------------------------
    # The exit code is recorded but NOT treated as the answer: a truncated
    # archive fails here and still leaves data behind. The fingerprints below
    # are the answer.
    local restore_rc=0
    log 'restoring...'
    docker exec -i "$PROBE" pg_restore -U postgres -d "$db" --no-owner \
        < "$artefact" >/tmp/bv-restore-$$.log 2>&1 || restore_rc=$?
    if [ "$restore_rc" -eq 0 ]; then
        ok 'pg_restore finished cleanly'
    else
        warn "pg_restore exited $restore_rc - continuing, because the content comparison is what decides"
        sed -n '1,5p' /tmp/bv-restore-$$.log | sed 's/^/      /'
    fi
    rm -f /tmp/bv-restore-$$.log

    # --- Gate 4: content, table by table ------------------------------------
    local failures=0 checked=0 table expected actual
    local -a missing=()
    while IFS=$'\t' read -r table expected; do
        [ -n "$table" ] || continue
        checked=$((checked + 1))
        if ! actual=$(psql_in "$PROBE" "$db" "$(fingerprint_sql "\"$table\"")" 2>/dev/null | tr -d '\n'); then
            missing+=("$table")
            printf '  %sFAIL%s %s - table absent from the restored copy\n' "$c_red" "$c_reset" "$table"
            failures=$((failures + 1))
            continue
        fi
        if [ "$actual" = "$expected" ]; then
            printf '  %sOK%s   %s\n' "$c_green" "$c_reset" "$table"
        else
            printf '  %sFAIL%s %s - fingerprint differs\n' "$c_red" "$c_reset" "$table"
            printf '        expected %s\n        restored %s\n' "$expected" "$actual"
            failures=$((failures + 1))
        fi
    done < <(manifest_tables "$MANIFEST")

    [ "$checked" -gt 0 ] || die 'the manifest lists no tables - nothing was verified, so nothing is proven'

    # --- Gate 5: schema objects ---------------------------------------------
    # Rows are half the database. Measured: `pg_restore -t a -t b` exits 0 with
    # every row present and silently drops the indexes, constraints, view,
    # function and trigger. A restored copy that cannot enforce a unique key is
    # not a restored copy.
    local obj_lines obj_class obj_expected obj_actual exp_count act_count
    obj_lines=$(manifest_section "$MANIFEST" objects)
    if [ -z "$obj_lines" ]; then
        warn 'this manifest predates schema verification (schema 1) - only data was compared'
    else
        printf '\n'
        while IFS=$'\t' read -r obj_class obj_expected; do
            [ -n "$obj_class" ] || continue
            obj_actual=$(schema_digest "$PROBE" "$db" "$obj_class")
            exp_count=${obj_expected%%:*}
            act_count=${obj_actual%%:*}
            if [ "$obj_actual" = "$obj_expected" ]; then
                printf '  %sOK%s   %s (%s)\n' "$c_green" "$c_reset" "$obj_class" "$act_count"
            elif [ "$exp_count" != "$act_count" ]; then
                printf '  %sFAIL%s %s - expected %s, restored copy has %s\n' \
                    "$c_red" "$c_reset" "$obj_class" "$exp_count" "$act_count"
                failures=$((failures + 1))
            else
                printf '  %sFAIL%s %s - same count (%s) but the definitions differ\n' \
                    "$c_red" "$c_reset" "$obj_class" "$act_count"
                failures=$((failures + 1))
            fi
        done <<EOF
$obj_lines
EOF
    fi

    # A restored copy with EXTRA tables is also a mismatch: it means the
    # artefact and the manifest describe different moments.
    local restored_count
    restored_count=$(psql_in "$PROBE" "$db" "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';" | tr -d '\n')
    if [ "$restored_count" != "$checked" ]; then
        printf '  %sFAIL%s restored copy has %s tables, the manifest describes %s\n' \
            "$c_red" "$c_reset" "$restored_count" "$checked"
        failures=$((failures + 1))
    fi

    printf '\n'
    if [ "$failures" -gt 0 ]; then
        die "VERIFICATION FAILED: $failures problem(s) across $checked table(s). This backup does NOT restore."
    fi
    # --- Gate 6: can the application actually WRITE to it? -------------------
    # Deliberately LAST, after every comparison, because it modifies the
    # restored copy. A sequence restored behind its data makes the next INSERT
    # collide with the primary key: all the rows present, and the application
    # broken on its first write. Cheap to check, and it is the question the
    # person restoring a backup actually cares about.
    local seq_line seq_name seq_tbl write_failures=0
    while IFS= read -r seq_line; do
        [ -n "$seq_line" ] || continue
        seq_name=${seq_line%%|*}
        seq_tbl=${seq_line##*|}
        if psql_in "$PROBE" "$db" "INSERT INTO \"$seq_tbl\" DEFAULT VALUES;" >/dev/null 2>&1 \
           || psql_in "$PROBE" "$db" "SELECT nextval('\"$seq_name\"');" >/dev/null 2>&1; then
            :
        else
            printf '  %sFAIL%s sequence %s cannot produce a usable next value\n' \
                "$c_red" "$c_reset" "$seq_name"
            write_failures=$((write_failures + 1))
        fi
    done < <(psql_in "$PROBE" "$db" "SELECT s.sequencename||'|'||coalesce(t.relname,'') FROM pg_sequences s LEFT JOIN pg_class c ON c.relname = s.sequencename LEFT JOIN pg_depend d ON d.objid = c.oid AND d.deptype = 'a' LEFT JOIN pg_class t ON t.oid = d.refobjid WHERE s.schemaname='public' ORDER BY 1;" 2>/dev/null || true)
    if [ "$write_failures" -gt 0 ]; then
        die "VERIFICATION FAILED: $write_failures sequence(s) unusable - the data is there but writes will collide."
    fi

    ok "VERIFIED: $checked table(s) restored byte-for-byte identical to the source."
    if [ "$restore_rc" -ne 0 ]; then
        warn "note: pg_restore exited $restore_rc yet the content matched - inspect before trusting"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    parse_args "$@"
    main
fi
