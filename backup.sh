#!/usr/bin/env bash
# =============================================================================
# backup.sh - take a database backup that can be VERIFIED later.
#
# The artefact is the engine's own dump format plus a manifest recording what
# the source looked like at dump time: size, sha256, a content fingerprint per
# table, and the schema objects. verify.sh restores the artefact into a
# throwaway instance and compares against that manifest - the only way to know
# a backup restores. Engines: postgres (pg_dump -Fc) and mysql (mysqldump, with
# --routines forced, because it omits them by default and says nothing).
#
# Usage:
#   ./backup.sh --container <name> --db <database> [--out DIR] [--keep N]
#   ./backup.sh --engine files --path <directory> [--out DIR] [--keep N]
#
# Options:
#   --engine NAME      postgres (default), mysql or files
#   --container NAME   Docker container running the database (source)
#   --db NAME          database to dump
#   --path DIR         source directory (files engine); the dataset name in
#                      the manifest defaults to its basename (--db overrides)
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

ENGINE="postgres"
CONTAINER=""
DB=""
SRC_PATH=""
OUT_DIR="./backups"
KEEP=0
LABEL=""
RECIPIENT=""
IDENTITY=""

usage() { sed -n '2,/^#   -h, --help/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --engine)    ENGINE="${2:-}"; shift 2;;
            --container) CONTAINER="${2:-}"; shift 2;;
            --db)        DB="${2:-}"; shift 2;;
            --path)      SRC_PATH="${2:-}"; shift 2;;
            --out)       OUT_DIR="${2:-}"; shift 2;;
            --keep)      KEEP="${2:-0}"; shift 2;;
            --label)     LABEL="${2:-}"; shift 2;;
            --recipient) RECIPIENT="${2:-}"; shift 2;;
            --identity)  IDENTITY="${2:-}"; shift 2;;
            -h|--help)   usage 0;;
            *)           printf 'unknown option: %s\n' "$1" >&2; usage 1;;
        esac
    done
    # --path is the files engine's source: it takes the --container slot (it
    # is where the data lives), made absolute so the engine never guesses, and
    # the dataset name defaults to its basename.
    if [ -n "$SRC_PATH" ]; then
        [ -z "$CONTAINER" ] || die "--path and --container are two different sources - give one"
        [ -d "$SRC_PATH" ] || die "source directory '$SRC_PATH' not found"
        CONTAINER="$(cd "$SRC_PATH" && pwd)"
        [ -n "$DB" ] || DB="$(basename "$CONTAINER")"
    fi
    [ -n "$CONTAINER" ] || die "--container (or --path) is required"
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
    tables=$(eng_list_tables "$CONTAINER" "$DB")

    {
        printf '{\n'
        printf '  "schema": 3,\n'
        printf '  "database": "%s",\n' "$DB"
        printf '  "created_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "artefact": "%s",\n' "$(basename "$artefact")"
        printf '  "bytes": %s,\n' "$(stat -c%s "$artefact")"
        printf '  "sha256": "%s",\n' "$(sha256_of "$artefact")"
        printf '  "engine": "%s",\n' "$ENG_NAME"
        # Recorded so verify.sh knows it needs an identity, and so a human can
        # tell WHICH key opens this file. A recipient is a public key: safe here.
        printf '  "encryption": "%s",\n' "$([ -n "$RECIPIENT" ] && echo age || echo none)"
        printf '  "recipient": "%s",\n' "$([ -f "$RECIPIENT" ] && basename "$RECIPIENT" || printf '%s' "$RECIPIENT")"
        printf '  "tables": {\n'
        if [ -n "$tables" ]; then
            while IFS= read -r table; do
                [ -n "$table" ] || continue
                fp=$(eng_table_fingerprint "$CONTAINER" "$DB" "$table" | tr -d '\n')
                assert_fingerprint "$table" "$fp"
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
            printf '    "%s": "%s"' "$class" "$(eng_schema_digest "$CONTAINER" "$DB" "$class")"
        done
        printf '\n  }\n'
        printf '}\n'
    } > "$manifest"

    local count
    count=$(printf '%s\n' "$tables" | grep -c . || true)
    # A backup of NOTHING is not a backup: an empty source produces a valid
    # 110-byte tar.gz and a 0-table dump produces a plausible archive, and
    # verify.sh would refuse both anyway ("nothing verified proves nothing").
    # Refusing here means nobody sleeps on an artefact that guards zero data.
    if [ "$count" -eq 0 ]; then
        rm -f -- "$artefact" "$manifest"
        die "the source contains no ${ENG_UNIT}s - refusing to call that a backup"
    fi
    ok "manifest written: $count ${ENG_UNIT} fingerprint(s) + $(printf '%s' "$SCHEMA_CLASSES" | wc -w) object class(es)"
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
    for d in "$OUT_DIR/${DB}_"*"$ENG_ARTEFACT_EXT" "$OUT_DIR/${DB}_"*"$ENG_ARTEFACT_EXT$ENC_SUFFIX"; do
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
    need sha256sum
    load_engine "$ENGINE"
    # The engine knows what a reachable source looks like (a running container,
    # a readable directory) and which tools it needs - docker is not a given.
    eng_preflight "$CONTAINER"

    mkdir -p "$OUT_DIR"
    local stamp base artefact manifest
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    base="${DB}_${stamp}${LABEL:+_$LABEL}"
    artefact="$OUT_DIR/$base$ENG_ARTEFACT_EXT"
    manifest="$OUT_DIR/$base.json"

    log "dumping '$DB' from '$CONTAINER' ($ENG_NAME)"
    # The engine module chooses the format (Postgres: custom, compressed and
    # selectively restorable; MySQL: SQL text with routines forced in).
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
        # lib/common.sh) makes a failing dump fail the pipeline, and PIPESTATUS
        # names which side broke instead of guessing.
        set +e
        eng_dump "$CONTAINER" "$DB" | age "${recip_args[@]}" > "$artefact"
        local -a st=("${PIPESTATUS[@]}")
        set -e
        if [ "${st[0]}" -ne 0 ] || [ "${st[1]}" -ne 0 ]; then
            rm -f -- "$artefact"
            die "encrypted dump failed (dump rc=${st[0]}, age rc=${st[1]})"
        fi
    else
        # No pipe into gzip on purpose - see the pipefail note in lib/common.sh.
        eng_dump "$CONTAINER" "$DB" > "$artefact"
    fi
    trap - ERR

    # The floor is per-engine when the engine says so: a legitimate two-file
    # tree gzips to 176 bytes (measured), which the database floor would refuse.
    local size floor="${ENG_MIN_ARTEFACT_BYTES:-$MIN_ARTEFACT_BYTES}"
    size=$(stat -c%s "$artefact")
    if [ "$size" -lt "$floor" ]; then
        rm -f -- "$artefact"
        die "artefact is only ${size} bytes (< $floor) - refusing to call that a backup"
    fi

    # Self-check: the engine parses its own archive, so a truncated or corrupt
    # artefact is caught here rather than in six months.
    if [ -n "$RECIPIENT" ]; then
        if [ -n "$IDENTITY" ]; then
            # Decrypt on the fly and parse. This proves the KEY WORKS TODAY -
            # the point of failure nobody discovers until a restore, six months
            # late. It also catches the empty-dump case that encryption alone
            # cannot: a failed dump yields a valid ~200-byte .age that
            # decrypts happily to nothing (measured).
            set +e
            age -d -i "$IDENTITY" "$artefact" | eng_archive_parses "$CONTAINER"
            local -a cst=("${PIPESTATUS[@]}")
            set -e
            if [ "${cst[0]}" -ne 0 ]; then
                rm -f -- "$artefact"
                die "the artefact does not decrypt with the given identity (age rc=${cst[0]}) - removed"
            fi
            if [ "${cst[1]}" -ne 0 ]; then
                rm -f -- "$artefact"
                die "the decrypted artefact does not parse as a $ENG_NAME dump - removed"
            fi
            ok "artefact: $artefact ($size bytes, encrypted, decrypts and parses)"
        else
            warn "artefact: $artefact ($size bytes, encrypted, NOT decryption-checked)"
            warn 'pass --identity to prove the key decrypts it now, rather than finding out at restore time'
        fi
    else
        if ! eng_archive_parses "$CONTAINER" < "$artefact"; then
            rm -f -- "$artefact"
            die "artefact does not parse as a $ENG_NAME dump - removed"
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
