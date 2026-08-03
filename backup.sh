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
#   --recipient KEY    encrypt with age; KEY is an age public key or a file of
#                      recipients. The plaintext dump NEVER touches disk.
#   --identity FILE    age identity used to SELF-CHECK the encrypted artefact
#                      right now (proves the key decrypts today, not in six
#                      months). Optional; without it the artefact is written
#                      but not decryption-checked, and the script says so.
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
RECIPIENT=""
IDENTITY=""

usage() { sed -n '2,/^#   -h, --help/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --container) CONTAINER="${2:-}"; shift 2;;
            --db)        DB="${2:-}"; shift 2;;
            --out)       OUT_DIR="${2:-}"; shift 2;;
            --keep)      KEEP="${2:-0}"; shift 2;;
            --label)     LABEL="${2:-}"; shift 2;;
            --recipient) RECIPIENT="${2:-}"; shift 2;;
            --identity)  IDENTITY="${2:-}"; shift 2;;
            -h|--help)   usage 0;;
            *)           printf 'unknown option: %s\n' "$1" >&2; usage 1;;
        esac
    done
    [ -n "$CONTAINER" ] || die "--container is required"
    [ -n "$DB" ] || die "--db is required"
    case "$KEEP" in
        ''|*[!0-9]*) die "--keep must be a non-negative integer, got '$KEEP'";;
    esac
    if [ -n "$IDENTITY" ] && [ -z "$RECIPIENT" ]; then
        die "--identity only makes sense with --recipient (there is nothing to decrypt)"
    fi
}

# Record what the source contains, table by table, BEFORE dumping. This is the
# yardstick verify.sh measures the restored copy against.
write_manifest() {
    local artefact="$1" manifest="$2" tables table fp first=1
    tables=$(psql_in "$CONTAINER" "$DB" "$(list_tables_sql)")

    {
        printf '{\n'
        printf '  "schema": 2,\n'
        printf '  "database": "%s",\n' "$DB"
        printf '  "created_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "artefact": "%s",\n' "$(basename "$artefact")"
        printf '  "bytes": %s,\n' "$(stat -c%s "$artefact")"
        printf '  "sha256": "%s",\n' "$(sha256_of "$artefact")"
        printf '  "pg_version": "%s",\n' "$(psql_in "$CONTAINER" "$DB" 'SHOW server_version;' | tr -d '\n')"
        # Recorded so verify.sh knows it needs an identity, and so a human can
        # tell WHICH key opens this file. A recipient is a public key: safe here.
        printf '  "encryption": "%s",\n' "$([ -n "$RECIPIENT" ] && echo age || echo none)"
        printf '  "recipient": "%s",\n' "$([ -f "$RECIPIENT" ] && basename "$RECIPIENT" || printf '%s' "$RECIPIENT")"
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
        printf '  },\n'
        # Schema objects: the half a row-count comparison cannot see. Recorded
        # as "<count>:<md5>" per class so a mismatch can name the numbers.
        printf '  "objects": {\n'
        local class first_obj=1
        for class in $SCHEMA_CLASSES; do
            [ "$first_obj" -eq 1 ] || printf ',\n'
            first_obj=0
            printf '    "%s": "%s"' "$class" "$(schema_digest "$CONTAINER" "$DB" "$class")"
        done
        printf '\n  }\n'
        printf '}\n'
    } > "$manifest"

    local count
    count=$(printf '%s\n' "$tables" | grep -c . || true)
    ok "manifest written: $count table fingerprint(s) + $(printf '%s' "$SCHEMA_CLASSES" | wc -w) object class(es)"
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
    for d in "$OUT_DIR/${DB}_"*.dump "$OUT_DIR/${DB}_"*.dump"$ENC_SUFFIX"; do
        [ -f "$(manifest_for "$d")" ] && dumps+=("$d")
    done
    shopt -u nullglob
    local total=${#dumps[@]}
    [ "$total" -gt "$KEEP" ] || { ok "retention: $total backup(s) on disk, keeping up to $KEEP"; return 0; }
    # Names carry a sortable UTC timestamp, so lexical order is chronological.
    local -a sorted=()
    while IFS= read -r d; do sorted+=("$d"); done < <(printf '%s\n' "${dumps[@]}" | sort)
    local to_delete=$((total - KEEP)) i
    for ((i = 0; i < to_delete; i++)); do
        rm -f -- "${sorted[$i]}" "$(manifest_for "${sorted[$i]}")"
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
    # A failure here must NOT leave a plausible artefact behind, hence the trap.
    trap 'rm -f -- "$artefact"' ERR
    if [ -n "$RECIPIENT" ]; then
        encryption_available || die "--recipient given but 'age' is not installed"
        artefact="$artefact$ENC_SUFFIX"
        manifest="$OUT_DIR/$base.json"
        # Built as an ARRAY here rather than returned from a helper: a shell
        # function can only hand back text, and `printf '%s\n%s'` without a
        # trailing newline makes `read` DROP the last line - age got "-r" with
        # no value on the very first run. Lists belong in arrays, not stdout.
        local -a recip_args=()
        if [ -f "$RECIPIENT" ]; then
            recip_args=(-R "$RECIPIENT")   # a file of recipients
        else
            recip_args=(-r "$RECIPIENT")   # an inline age1... public key
        fi
        # Piped ON PURPOSE, and it is the one pipe this repo allows: the
        # PLAINTEXT dump never touches disk, not even for an instant, so a
        # crash cannot leave an unencrypted copy behind. pipefail (set in
        # lib/common.sh) makes a failing pg_dump fail the pipeline, and
        # PIPESTATUS names which side broke instead of guessing.
        set +e
        docker exec "$CONTAINER" pg_dump -U postgres -d "$DB" -Fc < /dev/null \
            | age "${recip_args[@]}" > "$artefact"
        local -a st=("${PIPESTATUS[@]}")
        set -e
        if [ "${st[0]}" -ne 0 ] || [ "${st[1]}" -ne 0 ]; then
            rm -f -- "$artefact"
            die "encrypted dump failed (pg_dump rc=${st[0]}, age rc=${st[1]})"
        fi
    else
        # No pipe into gzip on purpose - see the pipefail note in lib/common.sh.
        docker exec -i "$CONTAINER" pg_dump -U postgres -d "$DB" -Fc > "$artefact"
    fi
    trap - ERR

    local size
    size=$(stat -c%s "$artefact")
    if [ "$size" -lt "$MIN_ARTEFACT_BYTES" ]; then
        rm -f -- "$artefact"
        die "artefact is only ${size} bytes (< $MIN_ARTEFACT_BYTES) - refusing to call that a backup"
    fi

    # Self-check: pg_restore --list parses the archive's table of contents, so a
    # truncated or corrupt artefact is caught here rather than in six months.
    if [ -n "$RECIPIENT" ]; then
        if [ -n "$IDENTITY" ]; then
            # Decrypt on the fly and parse. This proves the KEY WORKS TODAY -
            # the point of failure nobody discovers until a restore, six months
            # late. It also catches the empty-dump case that encryption alone
            # cannot: a failed pg_dump yields a valid ~200-byte .age that
            # decrypts happily to nothing (measured).
            set +e
            age -d -i "$IDENTITY" "$artefact" \
                | docker exec -i "$CONTAINER" pg_restore --list > /dev/null 2>&1
            local -a cst=("${PIPESTATUS[@]}")
            set -e
            if [ "${cst[0]}" -ne 0 ]; then
                rm -f -- "$artefact"
                die "the artefact does not decrypt with the given identity (age rc=${cst[0]}) - removed"
            fi
            if [ "${cst[1]}" -ne 0 ]; then
                rm -f -- "$artefact"
                die 'the decrypted artefact does not parse as a pg_dump archive - removed'
            fi
            ok "artefact: $artefact ($size bytes, encrypted, decrypts and parses)"
        else
            warn "artefact: $artefact ($size bytes, encrypted, NOT decryption-checked)"
            warn 'pass --identity to prove the key decrypts it now, rather than finding out at restore time'
        fi
    else
        if ! docker exec -i "$CONTAINER" pg_restore --list > /dev/null 2>&1 < "$artefact"; then
            rm -f -- "$artefact"
            die 'artefact does not parse as a pg_dump archive - removed'
        fi
        ok "artefact: $artefact ($size bytes, archive parses)"
    fi

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
