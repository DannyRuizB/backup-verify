#!/usr/bin/env bash
# =============================================================================
# backup.sh - take a PostgreSQL backup that can be VERIFIED later.
#
# The artefact is a custom-format pg_dump plus a manifest that records what the
# source looked like at dump time: size, sha256, and a content fingerprint per
# table. verify.sh restores the artefact into a throwaway instance and compares
# against that manifest - which is the only way to know a backup restores.
#
# Usage:
#   ./backup.sh --container <name> --db <database> [--out DIR] [--keep N]
#
# Options:
#   --container NAME   Docker container running Postgres (source)
#   --db NAME          database to dump
#   --out DIR          output directory (default ./backups)
#   --keep N           keep only the N most recent backups of this database
#   --label TEXT       extra label in the artefact name
#   -h, --help         this help
#
# Exit codes: 0 backup written and self-checked, non-zero otherwise. A backup
# this script is not sure about is a FAILED backup - it never leaves a
# plausible-looking artefact behind and reports success.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CONTAINER=""
DB=""
OUT_DIR="./backups"
KEEP=0
LABEL=""

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --container) CONTAINER="${2:-}"; shift 2;;
            --db)        DB="${2:-}"; shift 2;;
            --out)       OUT_DIR="${2:-}"; shift 2;;
            --keep)      KEEP="${2:-0}"; shift 2;;
            --label)     LABEL="${2:-}"; shift 2;;
            -h|--help)   usage 0;;
            *)           printf 'unknown option: %s\n' "$1" >&2; usage 1;;
        esac
    done
    [ -n "$CONTAINER" ] || die "--container is required"
    [ -n "$DB" ] || die "--db is required"
    case "$KEEP" in
        ''|*[!0-9]*) die "--keep must be a non-negative integer, got '$KEEP'";;
    esac
}

# Record what the source contains, table by table, BEFORE dumping. This is the
# yardstick verify.sh measures the restored copy against.
write_manifest() {
    local artefact="$1" manifest="$2" tables table fp first=1
    tables=$(psql_in "$CONTAINER" "$DB" "$(list_tables_sql)")

    {
        printf '{\n'
        printf '  "schema": 1,\n'
        printf '  "database": "%s",\n' "$DB"
        printf '  "created_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "artefact": "%s",\n' "$(basename "$artefact")"
        printf '  "bytes": %s,\n' "$(stat -c%s "$artefact")"
        printf '  "sha256": "%s",\n' "$(sha256_of "$artefact")"
        printf '  "pg_version": "%s",\n' "$(psql_in "$CONTAINER" "$DB" 'SHOW server_version;' | tr -d '\n')"
        printf '  "tables": {\n'
        if [ -n "$tables" ]; then
            while IFS= read -r table; do
                [ -n "$table" ] || continue
                fp=$(psql_in "$CONTAINER" "$DB" "$(fingerprint_sql "\"$table\"")" | tr -d '\n')
                [ "$first" -eq 1 ] || printf ',\n'
                first=0
                printf '    "%s": "%s"' "$table" "$fp"
            done <<EOF
$tables
EOF
            printf '\n'
        fi
        printf '  }\n'
        printf '}\n'
    } > "$manifest"

    local count
    count=$(printf '%s\n' "$tables" | grep -c . || true)
    ok "manifest written: $count table fingerprint(s)"
}

# Delete the oldest artefacts of THIS database, keeping the newest N. Only
# artefact+manifest pairs are considered, so a half-written pair is never
# counted as a keeper.
prune_old() {
    [ "$KEEP" -gt 0 ] || return 0
    local -a dumps=()
    local d
    # The glob goes straight into the `for`: assigning it to a variable stores
    # it LITERALLY (shellcheck SC2125) and only works by accident through word
    # splitting. nullglob so a database with no backups yet yields nothing
    # rather than the unexpanded pattern.
    shopt -s nullglob
    for d in "$OUT_DIR/${DB}_"*.dump; do
        [ -f "${d%.dump}.json" ] && dumps+=("$d")
    done
    shopt -u nullglob
    local total=${#dumps[@]}
    [ "$total" -gt "$KEEP" ] || { ok "retention: $total backup(s) on disk, keeping up to $KEEP"; return 0; }
    # Names carry a sortable UTC timestamp, so lexical order is chronological.
    local -a sorted=()
    while IFS= read -r d; do sorted+=("$d"); done < <(printf '%s\n' "${dumps[@]}" | sort)
    local to_delete=$((total - KEEP)) i
    for ((i = 0; i < to_delete; i++)); do
        rm -f -- "${sorted[$i]}" "${sorted[$i]%.dump}.json"
        warn "retention: removed $(basename "${sorted[$i]}") (and its manifest)"
    done
    ok "retention: kept the newest $KEEP of $total"
}

main() {
    need docker
    need sha256sum
    docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container '$CONTAINER' not found"

    mkdir -p "$OUT_DIR"
    local stamp base artefact manifest
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    base="${DB}_${stamp}${LABEL:+_$LABEL}"
    artefact="$OUT_DIR/$base.dump"
    manifest="$OUT_DIR/$base.json"

    log "dumping database '$DB' from container '$CONTAINER'"
    # Custom format (-Fc): compressed, and pg_restore can read it selectively.
    # No pipe into gzip on purpose - see the pipefail note in lib/common.sh.
    # A failure here must NOT leave a plausible artefact behind, hence the trap.
    trap 'rm -f -- "$artefact"' ERR
    docker exec -i "$CONTAINER" pg_dump -U postgres -d "$DB" -Fc > "$artefact"
    trap - ERR

    local size
    size=$(stat -c%s "$artefact")
    if [ "$size" -lt "$MIN_ARTEFACT_BYTES" ]; then
        rm -f -- "$artefact"
        die "artefact is only ${size} bytes (< $MIN_ARTEFACT_BYTES) - refusing to call that a backup"
    fi

    # Self-check: pg_restore --list parses the archive's table of contents, so a
    # truncated or corrupt artefact is caught here rather than in six months.
    if ! docker exec -i "$CONTAINER" pg_restore --list > /dev/null 2>&1 < "$artefact"; then
        rm -f -- "$artefact"
        die 'artefact does not parse as a pg_dump archive - removed'
    fi
    ok "artefact: $artefact ($size bytes, archive parses)"

    write_manifest "$artefact" "$manifest"
    prune_old

    ok "Backup complete. Prove it restores with:"
    printf '      ./verify.sh --manifest %s\n' "$manifest"
}

# Guarded so the tests can source this file and exercise parse_args without
# running a backup (the harness idiom from the debian-hardening siblings).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    parse_args "$@"
    main
fi
