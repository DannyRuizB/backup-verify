#!/usr/bin/env bash
# =============================================================================
# pitr.sh - point-in-time recovery you can PROVE, not hope.
#
# backup.sh proves a dump restores. This proves something stronger: that a
# base backup plus a WAL archive can reproduce a NAMED INSTANT, exactly.
# Every design choice below answers something MEASURED against a real
# Postgres before a line was written (README, "Point-in-time recovery has
# its own ways of lying"):
#
#   * recovery "to latest" came up green missing 100 of 600 rows - the tail
#     of history since the last archived segment simply did not exist, and
#     nothing said so. Hence `mark`: an instant only counts once its WAL
#     provably sits in the archive.
#   * a hole in the chain plus NO target = silent truncation, rc 0; the SAME
#     hole plus a NAMED target = FATAL. That asymmetry is this script's
#     spine: every recovery here has a name it must reach or die trying.
#   * a dead archive is silent to the application (600 commits, rc 0 each,
#     while failed_count climbed and the archive froze). Hence `check`, which
#     reads the only witness there is.
#
# PostgreSQL only, on purpose. WAL archiving is a PostgreSQL mechanism;
# MySQL's binlogs are a different animal, and pretending one interface covers
# both would claim a generality this repo has not measured.
#
# Usage:
#   ./pitr.sh base   --container NAME --db NAME --archive DIR [--out DIR]
#   ./pitr.sh mark   --container NAME --db NAME --archive DIR [--out DIR]
#   ./pitr.sh check  --archive DIR [--container NAME]
#   ./pitr.sh check  --remote REMOTE [--db NAME]
#   ./pitr.sh verify --base FILE --mark FILE --archive DIR [--image IMAGE]
#   ./pitr.sh push   --base FILE --mark FILE --archive DIR --remote REMOTE
#   ./pitr.sh pull   --db NAME --remote REMOTE --archive DIR [--out DIR]
#
# Subcommands:
#   base    take a pg_basebackup (tar, no WAL of its own - the archive is the
#           other half on purpose) plus a manifest binding the two together
#   mark    fingerprint every table, drop a named restore point, and WAIT
#           until its WAL segment provably lands in the archive - only then
#           is the mark manifest written. A mark you cannot recover to is
#           not written at all. The mark also records one sha256 per archived
#           segment it stands on: the inventory every later audit hashes
#           against.
#   check   audit the archive TODAY: holes, wrong-size segments, strays -
#           and, with --container, whether the archiver is behind or failing
#           right now (the server never volunteers either). With --remote,
#           audit the off-site copy instead: every segment the newest mark
#           stands on, hashed AT the remote against the mark's inventory.
#   verify  the drill: boot a throwaway instance from the base backup,
#           recover THROUGH the archive to the mark by name, and compare
#           every fingerprint the mark recorded
#   push    ship a proven instant off the machine: base backup, every WAL
#           segment the mark stands on (each hashed at the remote before it
#           is named), and the mark manifest LAST - the receipt that its
#           chain arrived whole
#   pull    bring the newest provable instant back: fetch base + mark +
#           chain, re-hash everything after the transfer, never overwrite
#
# Options:
#   --container NAME  Docker container running the source database
#   --db NAME         database to mark / fingerprint
#   --archive DIR     the WAL archive directory (the server's archive_command
#                     must already deliver segments here)
#   --out DIR         where base/mark manifests are written (default ./backups)
#   --base FILE       base-backup manifest (verify)
#   --mark FILE       mark manifest to recover to (verify)
#   --image IMAGE     image for the throwaway instance (default: the major
#                     version recorded in the base manifest, -alpine)
#   --label TEXT      extra label in the base artefact name
#   --timeout SECONDS how long base/mark/verify wait on the archiver or the
#                     recovery (default 90)
#   --keep-container  leave the throwaway instance running (for debugging)
#   --remote REMOTE   user@host:/path (ssh) or /path (a mounted disk) -
#                     same remotes, same rem_* modules as offsite.sh
#   --ssh-opts OPTS   extra ssh options, e.g. "-p 2222 -i key" (ssh remotes)
#   -h, --help        this help
#
# Exit codes: 0 the claim was proven, non-zero otherwise. A mark or a base
# this script is not sure about is a FAILED one - nothing plausible-looking
# is left behind.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SUBCMD=""
CONTAINER=""
DB=""
ARCHIVE_DIR=""
OUT_DIR="./backups"
BASE_MANIFEST=""
MARK_MANIFEST=""
IMAGE=""
LABEL=""
TIMEOUT=90
KEEP_CONTAINER=0
PROBE=""
SCRATCH=""
REMOTE=""
SSH_OPTS_STR=""

usage() { sed -n '2,/^#   -h, --help/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
    case "${1:-}" in
        base|mark|check|verify|push|pull) SUBCMD="$1"; shift;;
        -h|--help) usage 0;;
        '')        printf 'a subcommand is required: base, mark, check, verify, push or pull\n' >&2; usage 1;;
        *)         printf 'unknown subcommand: %s\n' "$1" >&2; usage 1;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --container)      CONTAINER="${2:-}"; shift 2;;
            --db)             DB="${2:-}"; shift 2;;
            --archive)        ARCHIVE_DIR="${2:-}"; shift 2;;
            --out)            OUT_DIR="${2:-}"; shift 2;;
            --base)           BASE_MANIFEST="${2:-}"; shift 2;;
            --mark)           MARK_MANIFEST="${2:-}"; shift 2;;
            --image)          IMAGE="${2:-}"; shift 2;;
            --label)          LABEL="${2:-}"; shift 2;;
            --timeout)        TIMEOUT="${2:-}"; shift 2;;
            --keep-container) KEEP_CONTAINER=1; shift;;
            --remote)         REMOTE="${2:-}"; shift 2;;
            --ssh-opts)       SSH_OPTS_STR="${2:-}"; shift 2;;
            -h|--help)        usage 0;;
            *)                printf 'unknown option: %s\n' "$1" >&2; usage 1;;
        esac
    done
    # A remote check audits the off-site archive; every other invocation works
    # on the local one. pull CREATES its archive directory - disaster recovery
    # starts on a machine that has nothing.
    if [ "$SUBCMD" = check ] && [ -n "$REMOTE" ]; then
        [ -z "$ARCHIVE_DIR" ] || die "check audits either --archive (local) or --remote (off-site), not both at once"
    else
        [ -n "$ARCHIVE_DIR" ] || die "--archive is required (there is no PITR without a WAL archive)"
        if [ ! -d "$ARCHIVE_DIR" ]; then
            [ "$SUBCMD" = pull ] || die "archive directory not found: $ARCHIVE_DIR"
            mkdir -p "$ARCHIVE_DIR" || die "could not create archive directory: $ARCHIVE_DIR"
        fi
        ARCHIVE_DIR="$(cd "$ARCHIVE_DIR" && pwd)"   # docker -v needs it absolute
    fi
    case "$TIMEOUT" in
        ''|*[!0-9]*) die "--timeout must be a non-negative integer, got '$TIMEOUT'";;
    esac
    case "$SUBCMD" in
        base|mark)
            [ -n "$CONTAINER" ] || die "$SUBCMD needs --container (where the database lives)"
            [ -n "$DB" ] || die "$SUBCMD needs --db";;
        verify)
            [ -n "$BASE_MANIFEST" ] || die "verify needs --base (the base-backup manifest)"
            [ -n "$MARK_MANIFEST" ] || die "verify needs --mark (the instant to prove)";;
        push)
            [ -n "$BASE_MANIFEST" ] || die "push needs --base (the base-backup manifest)"
            [ -n "$MARK_MANIFEST" ] || die "push needs --mark (the instant the remote must be able to prove)"
            [ -n "$REMOTE" ] || die "push needs --remote (where the copy is going)";;
        pull)
            [ -n "$DB" ] || die "pull needs --db (which database to bring back)"
            [ -n "$REMOTE" ] || die "pull needs --remote (where the copy lives)";;
    esac
}

# The one witness a dying archive has. Printed whenever a wait on the archiver
# fails, because the application layer will never mention any of it (measured:
# 600 commits, rc 0 each, while failed_count climbed and the archive froze).
archiver_diagnosis() {
    local stats
    stats=$(eng_query "$CONTAINER" postgres "SELECT 'last archived: ' || coalesce(last_archived_wal, 'never')
        || ', failed attempts: ' || failed_count
        || coalesce(', last failure: ' || last_failed_wal, '') FROM pg_stat_archiver;" 2>/dev/null) || return 0
    warn "pg_stat_archiver says: $stats"
}

assert_archiving_on() {
    local mode
    mode=$(eng_query "$CONTAINER" postgres 'SHOW archive_mode;' | tr -d '\n')
    case "$mode" in
        on|always) ;;
        *) die "archive_mode is '$mode' on '$CONTAINER' - the server is not archiving WAL, so there is nothing to mark or recover through";;
    esac
    [ -n "$(eng_query "$CONTAINER" postgres 'SHOW archive_command;' | tr -d '\n')" ] \
        || die "archive_command is empty on '$CONTAINER' - archive_mode is on but nothing delivers segments anywhere"
}

wal_segment_bytes() {
    eng_query "$CONTAINER" postgres "SELECT setting FROM pg_settings WHERE name = 'wal_segment_size';" | tr -d '\n'
}

# --- base ---------------------------------------------------------------------

cmd_base() {
    need docker
    need tar
    eng_preflight "$CONTAINER"
    assert_archiving_on
    mkdir -p "$OUT_DIR"

    local stamp base artefact manifest seg_bytes version
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    base="${DB}_${stamp}${LABEL:+_$LABEL}_base"
    artefact="$OUT_DIR/$base.tar"
    manifest="$OUT_DIR/$base.json"
    seg_bytes=$(wal_segment_bytes)
    version=$(eng_query "$CONTAINER" postgres 'SHOW server_version;' | tr -d '\n')

    log "taking a base backup of '$CONTAINER' (pg_basebackup, tar to stdout)"
    # -X none on purpose: the base carries no WAL of its own, so it cannot even
    # START without the archive (measured: "could not locate required
    # checkpoint record"). That is the point - verify proves base AND archive
    # together, because a disaster needs both. pg_basebackup itself WAITS until
    # the WAL its backup needs has been archived (measured NOTICE), so a wedged
    # archiver turns "backup" into "hang" - the timeout turns the hang into a
    # failure with a name.
    trap 'rm -f -- "$artefact"' ERR
    local rc=0 errfile="$OUT_DIR/.bb-stderr.$$"
    timeout "$TIMEOUT" docker exec "$CONTAINER" pg_basebackup -U postgres -Ft -X none -D - \
        > "$artefact" 2> "$errfile" < /dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        sed 's/^/      /' "$errfile"; rm -f -- "$errfile" "$artefact"
        if [ "$rc" -eq 124 ]; then
            archiver_diagnosis
            die "pg_basebackup did not finish in ${TIMEOUT}s. With -X none it waits for its WAL to be ARCHIVED - a failing archiver hangs it, and hanging here is the honest outcome: the archive could not hold this backup's other half."
        fi
        die "pg_basebackup failed (rc $rc) - no artefact was left behind"
    fi
    sed 's/^/      /' "$errfile"   # the measured NOTICE: "all required WAL segments have been archived"
    rm -f -- "$errfile"
    trap - ERR

    local size floor="${ENG_MIN_ARTEFACT_BYTES:-$MIN_ARTEFACT_BYTES}"
    size=$(stat -c%s "$artefact")
    if [ "$size" -lt "$floor" ]; then
        rm -f -- "$artefact"
        die "base backup is only ${size} bytes (< $floor) - refusing to call that a base backup"
    fi
    if ! tar -tf "$artefact" > /dev/null 2>&1; then
        rm -f -- "$artefact"
        die "the base backup does not parse as a tar archive - removed"
    fi

    # backup_label is the base's birth certificate: the first WAL segment
    # recovery will ask the archive for. The continuity gate starts there.
    local label_text wal_start_file
    label_text=$(tar -xOf "$artefact" backup_label 2>/dev/null) \
        || { rm -f -- "$artefact"; die "the base backup contains no backup_label - removed"; }
    wal_start_file=$(printf '%s\n' "$label_text" | sed -n 's/^START WAL LOCATION: .* (file \([0-9A-F]*\)).*/\1/p')
    [ -n "$wal_start_file" ] || { rm -f -- "$artefact"; die "backup_label names no start WAL file - removed"; }

    {
        printf '{\n'
        printf '  "schema": 3,\n'
        printf '  "kind": "pitr-base",\n'
        printf '  "database": "%s",\n' "$DB"
        printf '  "created_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "artefact": "%s",\n' "$(basename "$artefact")"
        printf '  "bytes": %s,\n' "$size"
        printf '  "sha256": "%s",\n' "$(sha256_of "$artefact")"
        printf '  "engine": "%s",\n' "$ENG_NAME"
        printf '  "server_version": "%s",\n' "${version%%.*}"
        printf '  "wal_segment_bytes": %s,\n' "$seg_bytes"
        printf '  "wal_start_file": "%s"\n' "$wal_start_file"
        printf '}\n'
    } > "$manifest"

    ok "base backup: $artefact ($size bytes, parses, recovery starts at $wal_start_file)"
    ok "a base backup alone cannot even start (measured) - it is HALF a backup. Name an instant:"
    printf '      ./pitr.sh mark --container %s --db %s --archive %s\n' "$CONTAINER" "$DB" "$ARCHIVE_DIR"
}

# --- mark ----------------------------------------------------------------------

cmd_mark() {
    need docker
    eng_preflight "$CONTAINER"
    assert_archiving_on
    mkdir -p "$OUT_DIR"

    local stamp mark_name manifest seg_bytes
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    mark_name="bv_${DB}_${stamp}"
    manifest="$OUT_DIR/${DB}_${stamp}_mark.json"
    seg_bytes=$(wal_segment_bytes)

    local tables table fp count
    tables=$(eng_list_tables "$CONTAINER" "$DB")
    count=$(printf '%s\n' "$tables" | grep -c . || true)
    [ "$count" -gt 0 ] || die "the source contains no tables - a mark of nothing proves nothing"

    # Fingerprint FIRST, then drop the restore point: the fingerprints define
    # what "the instant" contains, the restore point names it. Any write
    # landing in between makes the two describe different moments, so the WAL
    # position brackets the whole thing and disagreement is reported, not
    # hidden. Mark on a quiet moment; verify will fail honestly otherwise.
    local lsn_before lsn_after quiesced tables_block="" objects_block="" first=1
    lsn_before=$(eng_query "$CONTAINER" "$DB" 'SELECT pg_current_wal_lsn();' | tr -d '\n')
    log "fingerprinting '$DB' ($count tables) - the yardstick the recovery drill will be measured against"
    while IFS= read -r table; do
        [ -n "$table" ] || continue
        fp=$(eng_table_fingerprint "$CONTAINER" "$DB" "$table" | tr -d '\n')
        assert_fingerprint "$table" "$fp"
        [ "$first" -eq 1 ] || tables_block+=$',\n'
        first=0
        tables_block+=$(printf '    "%s": "%s"' "$table" "$fp")
    done <<EOF
$tables
EOF
    # The one class swapped out relative to backup.sh: a recovered sequence
    # sits up to 32 ahead of the marked instant BY DESIGN (nextval pre-logs
    # 32 values for crash safety - measured), so the mark records sequence
    # NAMES and leaves usability to verify's writable probe. verify compares
    # whatever classes the manifest recorded, so both sides agree for free.
    local pitr_classes=${SCHEMA_CLASSES/sequences/sequence_names}
    local class first_obj=1
    for class in $pitr_classes; do
        [ "$first_obj" -eq 1 ] || objects_block+=$',\n'
        first_obj=0
        objects_block+=$(printf '    "%s": "%s"' "$class" "$(eng_schema_digest "$CONTAINER" "$DB" "$class")")
    done
    lsn_after=$(eng_query "$CONTAINER" "$DB" 'SELECT pg_current_wal_lsn();' | tr -d '\n')
    if [ "$lsn_before" = "$lsn_after" ]; then
        quiesced="yes"
    else
        quiesced="no"
        warn "WAL advanced while fingerprinting ($lsn_before -> $lsn_after): writes are landing, and the fingerprints and the restore point may straddle them"
    fi

    local row mark_lsn mark_file
    row=$(eng_query "$CONTAINER" "$DB" "SELECT lsn || '|' || pg_walfile_name(lsn)
        FROM (SELECT pg_create_restore_point('$mark_name') AS lsn) s;" | tr -d '\n')
    mark_lsn=${row%%|*}
    mark_file=${row##*|}
    log "restore point '$mark_name' written at $mark_lsn (segment $mark_file)"

    # The switch, and the wait, ARE the feature. Without them the mark's
    # segment stays open and unarchived - measured: a recovery that came up
    # green missing every transaction in that open segment. The default 16MB
    # segment only closes when it fills, and archive_timeout defaults to 0:
    # on a quiet system the instant you just named could stay unrecoverable
    # for DAYS while everything reports success.
    eng_query "$CONTAINER" "$DB" 'SELECT pg_walfile_name(pg_switch_wal());' > /dev/null
    log "waiting for $mark_file to land in the archive (a mark you cannot recover to must not exist)"
    local waited=0 size
    while :; do
        if [ -f "$ARCHIVE_DIR/$mark_file" ]; then
            size=$(stat -c%s "$ARCHIVE_DIR/$mark_file")
            [ "$size" -eq "$seg_bytes" ] && break   # a growing file is a copy in flight
        fi
        waited=$((waited + 1))
        if [ "$waited" -gt "$TIMEOUT" ]; then
            archiver_diagnosis
            die "segment $mark_file never reached the archive in ${TIMEOUT}s - this mark CANNOT be recovered to, so no manifest was written. The application will not tell you either: the commits it holds all returned success (measured)."
        fi
        sleep 1
    done
    ok "segment $mark_file is in the archive, all $seg_bytes bytes of it"

    # The mark doubles as the archive's INVENTORY: one sha256 per segment it
    # stands on (everything on its timeline up to and including its own
    # segment - the archiver delivers in order, so once the mark's segment is
    # whole, everything before it is too), plus any timeline history files.
    # Measured, and the reason this block exists: rot in a segment PAST a mark
    # leaves that mark's drill green - a passing recovery proves the chain it
    # replayed, not the archive. Only hashes checked TODAY prove the archive.
    # Segments land unreadable to the host (0600, the server's uid - measured),
    # so the hashing runs in a sidecar of the source's own image.
    local sidecar mark_tl inv_files wal_block="" first_wal=1 hline
    sidecar=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")
    mark_tl=$(wal_name_timeline "$mark_file")
    inv_files=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort \
        | awk -v tl="$mark_tl" -v mark="$mark_file" '
            /^[0-9A-F]{24}$/ { if (substr($0, 1, 8) == tl && $0 <= mark) print; next }
            /^[0-9A-F]{8}\.history$/ { print }')
    log "fingerprinting the chain the mark stands on ($(printf '%s\n' "$inv_files" | grep -c .) file(s), hashed in a $sidecar sidecar)"
    while IFS= read -r hline; do
        [ -n "$hline" ] || continue
        [ "$first_wal" -eq 1 ] || wal_block+=$',\n'
        first_wal=0
        wal_block+=$(printf '    "%s": "%s"' "${hline##* }" "${hline%% *}")
    done < <(printf '%s\n' "$inv_files" | sed 's|^|/archive/|' \
        | docker run --rm -i -u root --entrypoint sh -v "$ARCHIVE_DIR:/archive:ro" "$sidecar" \
            -c 'xargs -r sha256sum' | sed 's|/archive/||')
    printf '%s' "$wal_block" | grep -qF "\"$mark_file\":" \
        || die "the sidecar never hashed $mark_file - refusing to write a mark whose own segment is missing from its inventory"

    {
        printf '{\n'
        printf '  "schema": 3,\n'
        printf '  "kind": "pitr-mark",\n'
        printf '  "database": "%s",\n' "$DB"
        printf '  "created_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "engine": "%s",\n' "$ENG_NAME"
        printf '  "mark_name": "%s",\n' "$mark_name"
        printf '  "lsn": "%s",\n' "$mark_lsn"
        printf '  "wal_file": "%s",\n' "$mark_file"
        printf '  "quiesced": "%s",\n' "$quiesced"
        printf '  "wal": {\n%s\n  },\n' "$wal_block"
        printf '  "tables": {\n%s\n  },\n' "$tables_block"
        printf '  "objects": {\n%s\n  }\n' "$objects_block"
        printf '}\n'
    } > "$manifest"

    ok "mark '$mark_name' is archived and fingerprinted: $count table(s) + $(printf '%s' "$SCHEMA_CLASSES" | wc -w) object class(es)"
    ok "Prove the archive can reproduce it:"
    printf '      ./pitr.sh verify --base BASE_MANIFEST --mark %s --archive %s\n' "$manifest" "$ARCHIVE_DIR"
}

# --- check ---------------------------------------------------------------------

# The off-site audit: for the newest mark of each database at the remote (or
# the one named by --db), every file in the mark's inventory must be there and
# hash back to it - hashed AT the remote, because fetching bytes to hash them
# locally would prove the transfer, not the remote. Size is not consulted:
# every complete segment measures exactly the same (measured), so at a WAL
# archive size is blind to rot BY CONSTRUCTION. A mark's drill passing is no
# substitute either: rot PAST the mark leaves that drill green (measured).
cmd_check_remote() {
    load_remote
    rem_preflight ro
    local listing problems=0 name mark tmp
    listing=$(rem_list)

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        case "$name" in
            *.part)
                printf '  %sFAIL%s %s - a crashed upload nothing vouches for\n' "$c_red" "$c_reset" "$name"
                problems=$((problems + 1));;
        esac
    done <<< "$listing"

    local mark_list
    mark_list=$(printf '%s\n' "$listing" | { grep -E '_[0-9]{8}T[0-9]{6}Z_mark\.json$' || true; })
    if [ -n "$DB" ]; then
        mark_list=$(printf '%s\n' "$mark_list" | { grep -E "^${DB}_[0-9]{8}T[0-9]{6}Z_mark\.json$" || true; })
        [ -n "$mark_list" ] || die "the remote holds no mark manifest for '$DB' - it cannot prove any instant of it"
    else
        [ -n "$mark_list" ] || die "the remote holds no mark manifests at all - it cannot prove any instant"
    fi

    # Newest mark per database, decided by NAME: the stamp sorts, and a remote
    # mtime is the upload time, not the backup time (measured, offsite.sh).
    local -a newest=()
    while IFS= read -r mark; do
        [ -n "$mark" ] || continue
        newest+=("$mark")
    done < <(printf '%s\n' "$mark_list" | LC_ALL=C sort \
        | awk '{db = $0; sub(/_[0-9]{8}T[0-9]{6}Z_mark\.json$/, "", db); latest[db] = $0}
               END {for (d in latest) print latest[d]}' | LC_ALL=C sort)

    tmp=$(mktemp -d)
    local entries iname isha rsha before mark_db
    for mark in "${newest[@]}"; do
        before=$problems
        if ! rem_get "$mark" "$tmp/$mark"; then
            printf '  %sFAIL%s %s - named by the remote listing but it could not be fetched\n' "$c_red" "$c_reset" "$mark"
            problems=$((problems + 1))
            continue
        fi
        mark_db=$(json_str "$tmp/$mark" database)
        entries=$(manifest_section "$tmp/$mark" wal)
        if [ -z "$entries" ]; then
            printf '  %sFAIL%s %s - records no WAL inventory, so nothing can vouch for the chain it stands on (re-mark and re-push)\n' "$c_red" "$c_reset" "$mark"
            problems=$((problems + 1))
            continue
        fi
        # First, something for the chain to stand on: the newest intact base
        # at the remote that can reach this mark. Its start also decides WHAT
        # to audit - the range this pair actually replays, the same set push
        # ships and pull fetches (the inventory may reach further back; those
        # segments are not part of this pair's claim).
        local mark_file base_ok=0 bname bstart="" bbytes="" akind
        mark_file=$(json_str "$tmp/$mark" wal_file)
        while IFS= read -r bname; do
            [ -n "$bname" ] || continue
            rem_get "$bname" "$tmp/$bname" 2>/dev/null || continue
            akind=$(json_str "$tmp/$bname" kind)
            bstart=$(json_str "$tmp/$bname" wal_start_file)
            bbytes=$(json_num "$tmp/$bname" wal_segment_bytes)
            [ "$akind" = "pitr-base" ] || continue
            [ "$(wal_name_timeline "$bstart")" = "$(wal_name_timeline "$mark_file")" ] || continue
            [ "$(wal_name_index "$bstart" "$bbytes")" -le "$(wal_name_index "$mark_file" "$bbytes")" ] || continue
            if [ "$(rem_sha256 "$(json_str "$tmp/$bname" artefact)" || true)" = "$(json_str "$tmp/$bname" sha256)" ]; then
                base_ok=1
                break
            fi
        done < <(printf '%s\n' "$listing" | { grep -E "^${mark_db}_[0-9]{8}T[0-9]{6}Z(_.*)?_base\.json$" || true; } | LC_ALL=C sort -r)

        # The audit set: base..mark plus history files when a base was found;
        # the whole inventory otherwise (best effort - the failure is already
        # named, but "which bytes are also rotten" is worth knowing today).
        local -A inv=()
        while IFS=$'\t' read -r iname isha; do
            [ -n "$iname" ] || continue
            inv["$iname"]="$isha"
        done <<< "$entries"
        local -a audit=()
        local idx
        if [ "$base_ok" -eq 1 ]; then
            for ((idx = $(wal_name_index "$bstart" "$bbytes"); idx <= $(wal_name_index "$mark_file" "$bbytes"); idx++)); do
                audit+=("$(wal_index_name "$(wal_name_timeline "$mark_file")" "$idx" "$bbytes")")
            done
            for iname in "${!inv[@]}"; do
                case "$iname" in *.history) audit+=("$iname");; esac
            done
        else
            printf '  %sFAIL%s %s - no intact base backup at the remote can reach this mark, so its chain has nothing to stand on\n' "$c_red" "$c_reset" "$mark"
            problems=$((problems + 1))
            for iname in "${!inv[@]}"; do audit+=("$iname"); done
        fi
        while IFS= read -r iname; do
            [ -n "$iname" ] || continue
            isha="${inv[$iname]:-}"
            if [ -z "$isha" ]; then
                printf '  %sFAIL%s %s - the pair needs it and the mark'\''s inventory never stood on it\n' "$c_red" "$c_reset" "$iname"
                problems=$((problems + 1))
            elif ! printf '%s\n' "$listing" | grep -qxF "$iname"; then
                printf '  %sFAIL%s %s - the mark stands on it and the remote does not hold it\n' "$c_red" "$c_reset" "$iname"
                problems=$((problems + 1))
            elif [ "$(rem_sha256 "$iname" || true)" != "$isha" ]; then
                printf '  %sFAIL%s %s - the remote'\''s bytes do not hash back to the mark'\''s inventory (rot or a partial upload; only the hash can see this)\n' "$c_red" "$c_reset" "$iname"
                problems=$((problems + 1))
            fi
        done < <(printf '%s\n' "${audit[@]}" | LC_ALL=C sort -u)
        if [ "$problems" -eq "$before" ]; then
            printf '  %sOK%s   %s - base intact, every file the pair stands on present and hashing true at the remote\n' "$c_green" "$c_reset" "$mark"
        fi
    done
    rm -rf "$tmp"

    printf '\n'
    if [ "$problems" -gt 0 ]; then
        die "REMOTE ARCHIVE CHECK FAILED: $problems problem(s). A disaster recovery from this remote would stop early or die - this is the cheap day to find out."
    fi
    ok "the remote can prove every instant it claims (${#newest[@]} mark(s) audited)"
}

cmd_check() {
    if [ -n "$REMOTE" ]; then
        cmd_check_remote
        return
    fi
    local problems=0 name size seg_bytes=""
    local -a segments=() strays=()

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [[ "$name" =~ ^[0-9A-F]{24}$ ]]; then
            segments+=("$name")
        elif [[ "$name" =~ ^[0-9A-F]{24}\.[0-9A-F]{8}\.backup$ ]] || [[ "$name" =~ ^[0-9A-F]{8}\.history$ ]]; then
            :   # backup history and timeline history files: small by design, expected
        else
            strays+=("$name")
        fi
    done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -printf '%f\n' | sort)

    [ "${#segments[@]}" -gt 0 ] \
        || die "the archive holds no WAL segments at all - nothing could ever be recovered from it"

    # A stray is either debris (a .partial, an archive_command temp file that
    # outlived its crash) or a squatter on a future segment's name - and the
    # measured poison: the documented `test ! -f && cp` archive_command can
    # NEVER archive past a squatted name. failed_count climbs forever, WAL
    # piles up on the primary, and the application hears nothing.
    for name in ${strays[@]+"${strays[@]}"}; do
        printf '  %sFAIL%s %s - not a WAL segment, and the archiver will not overwrite a squatted name (measured: it retries forever instead)\n' \
            "$c_red" "$c_reset" "$name"
        problems=$((problems + 1))
    done

    # The segment size: asked of the server when one is offered, otherwise the
    # largest present (a segment cannot be larger than the true size).
    if [ -n "$CONTAINER" ]; then
        seg_bytes=$(wal_segment_bytes)
    else
        for name in "${segments[@]}"; do
            size=$(stat -c%s "$ARCHIVE_DIR/$name")
            [ -n "$seg_bytes" ] && [ "$size" -le "$seg_bytes" ] || seg_bytes=$size
        done
        log "assuming ${seg_bytes}-byte segments (largest present; pass --container to ask the server)"
    fi

    # Continuity, per timeline: every segment between the oldest and newest
    # present, each one exactly full-size. This is the cheap version of the
    # loud failure recovery would eventually produce - months earlier.
    local timeline first last line
    local -a range_problems=()
    for timeline in $(printf '%s\n' "${segments[@]}" | cut -c1-8 | sort -u); do
        first=""; last=""
        for name in "${segments[@]}"; do
            case "$name" in
                "$timeline"*)
                    [ -n "$first" ] || first="$name"
                    last="$name";;
            esac
        done
        mapfile -t range_problems < <(wal_range_problems "$ARCHIVE_DIR" "$first" "$last" "$seg_bytes")
        for line in ${range_problems[@]+"${range_problems[@]}"}; do
            printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$line"
            problems=$((problems + 1))
        done
    done

    # With the source at hand, read the one witness of a dying archiver.
    if [ -n "$CONTAINER" ]; then
        eng_preflight "$CONTAINER"
        assert_archiving_on
        local last_archived failed_count last_failed current behind=0
        read -r last_archived failed_count last_failed < <(eng_query "$CONTAINER" postgres \
            "SELECT coalesce(last_archived_wal, 'never') || ' ' || failed_count || ' ' || coalesce(last_failed_wal, '-') FROM pg_stat_archiver;")
        current=$(eng_query "$CONTAINER" postgres 'SELECT pg_walfile_name(pg_current_wal_lsn());' | tr -d '\n')
        if [ "$last_archived" = "never" ]; then
            printf '  %sFAIL%s the server has never archived a single segment (failed attempts so far: %s)\n' \
                "$c_red" "$c_reset" "$failed_count"
            problems=$((problems + 1))
        else
            behind=$(( $(wal_name_index "$current" "$seg_bytes") - $(wal_name_index "${last_archived:0:24}" "$seg_bytes") - 1 ))
            if [ "$behind" -gt 0 ]; then
                # One recheck: a segment legitimately in flight clears in moments.
                sleep 3
                read -r last_archived failed_count last_failed < <(eng_query "$CONTAINER" postgres \
                    "SELECT coalesce(last_archived_wal, 'never') || ' ' || failed_count || ' ' || coalesce(last_failed_wal, '-') FROM pg_stat_archiver;")
                behind=$(( $(wal_name_index "$current" "$seg_bytes") - $(wal_name_index "${last_archived:0:24}" "$seg_bytes") - 1 ))
            fi
            if [ "$behind" -gt 0 ]; then
                printf '  %sFAIL%s the archive is %s completed segment(s) behind the server (last archived %s, server writing %s) - the application will never mention this\n' \
                    "$c_red" "$c_reset" "$behind" "$last_archived" "$current"
                [ "$last_failed" = "-" ] || printf '        the archiver last choked on %s (failed attempts: %s)\n' "$last_failed" "$failed_count"
                problems=$((problems + 1))
            elif [ "$failed_count" -gt 0 ]; then
                log "archiver history: $failed_count failed attempt(s), last on ${last_failed} - it recovered, and the counter never resets (measured)"
            fi
        fi
    fi

    printf '\n'
    if [ "$problems" -gt 0 ]; then
        die "ARCHIVE CHECK FAILED: $problems problem(s). A recovery through this archive would stop early or die - this is the cheap day to find out."
    fi
    ok "archive is continuous: ${#segments[@]} segment(s), every one the full $seg_bytes bytes"
    log 'continuous is not recoverable - prove an instant with: ./pitr.sh verify'
}

# --- push ----------------------------------------------------------------------

# Ship a proven instant off the machine: base backup, every WAL file the
# mark's inventory stands on, and the manifests - the mark LAST, so a mark
# manifest at the remote is a receipt that everything it needs arrived whole
# (the offsite.sh protocol; a WAL archive is just many small artefacts).
# Incremental by HASH, never by name: "the file is already there" signs off
# partials and rot, and at a WAL archive every complete segment has the same
# size, so nothing short of the hash can tell them apart (measured, both).
cmd_push() {
    need docker
    load_remote
    rem_preflight rw

    local kind db base_db dir artefact seg_bytes start_file mark_file
    [ -f "$BASE_MANIFEST" ] || die "base manifest not found: $BASE_MANIFEST"
    [ -f "$MARK_MANIFEST" ] || die "mark manifest not found: $MARK_MANIFEST"
    kind="$(json_str "$BASE_MANIFEST" kind)"
    [ "$kind" = "pitr-base" ] \
        || die "'$BASE_MANIFEST' is not a base-backup manifest (kind '${kind:-none}') - dump backups travel with ./offsite.sh"
    kind="$(json_str "$MARK_MANIFEST" kind)"
    [ "$kind" = "pitr-mark" ] \
        || die "'$MARK_MANIFEST' is not a mark manifest (kind '${kind:-none}') - pass the instant the remote must be able to prove"
    db="$(json_str "$MARK_MANIFEST" database)"
    base_db="$(json_str "$BASE_MANIFEST" database)"
    [ "$db" = "$base_db" ] \
        || die "the base backup is of '$base_db' but the mark is of '$db' - these describe different databases"
    dir="$(cd "$(dirname "$BASE_MANIFEST")" && pwd)"
    artefact="$dir/$(json_str "$BASE_MANIFEST" artefact)"
    [ -f "$artefact" ] || die "artefact named by the base manifest is missing: $artefact"
    seg_bytes="$(json_num "$BASE_MANIFEST" wal_segment_bytes)"
    start_file="$(json_str "$BASE_MANIFEST" wal_start_file)"
    mark_file="$(json_str "$MARK_MANIFEST" wal_file)"

    # The same refusals verify makes, in the same order of cost: a pair that
    # can never recover must not be shipped looking like one that can.
    [ "$(wal_name_timeline "$mark_file")" = "$(wal_name_timeline "$start_file")" ] \
        || die "the mark lives on timeline $(wal_name_timeline "$mark_file") but the base starts on $(wal_name_timeline "$start_file") - this pair can never recover, and pushing it would ship that lie off-site"
    [ "$(wal_name_index "$mark_file" "$seg_bytes")" -ge "$(wal_name_index "$start_file" "$seg_bytes")" ] \
        || die "the mark predates the base backup - this pair can never recover; nothing was pushed"
    assert_pair_intact "$BASE_MANIFEST" "$artefact" "push"

    local -a inv_lines=()
    local line
    mapfile -t inv_lines < <(manifest_section "$MARK_MANIFEST" wal)
    [ "${#inv_lines[@]}" -gt 0 ] \
        || die "this mark records no WAL inventory (an older mark) - push cannot promise what nothing can audit; take a fresh mark"
    local -A inv=()
    for line in "${inv_lines[@]}"; do
        inv["${line%%$'\t'*}"]="${line##*$'\t'}"
    done

    local -a range_problems=()
    mapfile -t range_problems < <(wal_range_problems "$ARCHIVE_DIR" "$start_file" "$mark_file" "$seg_bytes")
    if [ "${#range_problems[@]}" -gt 0 ]; then
        for line in "${range_problems[@]}"; do
            printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$line"
        done
        die "the LOCAL chain $start_file .. $mark_file cannot replay - pushing it would replicate the hole off-site with a clean exit code"
    fi

    # What travels: the range this pair replays, plus every history file the
    # inventory recorded. Each must be vouched for by the inventory - push
    # ships claims, not bytes.
    local tl idx start_idx mark_idx fname
    local -a to_ship=()
    tl=$(wal_name_timeline "$start_file")
    start_idx=$(wal_name_index "$start_file" "$seg_bytes")
    mark_idx=$(wal_name_index "$mark_file" "$seg_bytes")
    for ((idx = start_idx; idx <= mark_idx; idx++)); do
        to_ship+=("$(wal_index_name "$tl" "$idx" "$seg_bytes")")
    done
    for line in "${inv_lines[@]}"; do
        case "${line%%$'\t'*}" in *.history) to_ship+=("${line%%$'\t'*}");; esac
    done
    for fname in "${to_ship[@]}"; do
        [ -n "${inv[$fname]:-}" ] \
            || die "the chain needs $fname and the mark's inventory never stood on it - was the base taken after the mark's inventory was written? Take a fresh mark."
    done

    # Stage through a sidecar (the host cannot read the segments - they land
    # 0600, the server's uid) and prove the STAGED bytes against the inventory
    # BEFORE shipping: rot replicates as happily as data, rc 0 either way.
    local sidecar staging
    sidecar="postgres:$(json_str "$BASE_MANIFEST" server_version)-alpine"
    staging=$(mktemp -d)
    docker run --rm -u root --entrypoint sh -v "$ARCHIVE_DIR:/archive:ro" -v "$staging:/stage" "$sidecar" \
        -c "cp $(printf '/archive/%q ' "${to_ship[@]}") /stage/ && chown -R $(id -u):$(id -g) /stage" \
        || { rm -rf "$staging"; die "could not stage the chain out of the archive"; }
    for fname in "${to_ship[@]}"; do
        [ "$(sha256_of "$staging/$fname")" = "${inv[$fname]}" ] \
            || { rm -rf "$staging"; die "$fname does not hash back to the mark's inventory IN THE LOCAL ARCHIVE - refusing to replicate rot off-site"; }
    done
    ok "the local chain hashes back to the mark's inventory (${#to_ship[@]} file(s))"

    local listing pushed=0 skipped=0
    listing=$(rem_list)
    for fname in "${to_ship[@]}"; do
        if printf '%s\n' "$listing" | grep -qxF "$fname"; then
            if [ "$(rem_sha256 "$fname" || true)" = "${inv[$fname]}" ]; then
                skipped=$((skipped + 1))
                continue
            fi
            warn "$fname sits at the remote with the WRONG bytes (rot, or a crashed upload under the final name) - re-shipping it"
        fi
        upload_checked "$staging/$fname" "$fname" "${inv[$fname]}"
        pushed=$((pushed + 1))
    done
    rm -rf "$staging"

    local aname asha
    aname=$(json_str "$BASE_MANIFEST" artefact)
    asha=$(json_str "$BASE_MANIFEST" sha256)
    if printf '%s\n' "$listing" | grep -qxF "$aname" && [ "$(rem_sha256 "$aname" || true)" = "$asha" ]; then
        ok "base artefact already at the remote, hashed true there"
    else
        upload_checked "$artefact" "$aname" "$asha"
    fi

    # Manifests last, mark VERY last: a mark manifest at the remote is the
    # receipt that everything it stands on arrived and hashed true. A push
    # that dies anywhere above leaves bytes, but no claim about them.
    upload_checked "$BASE_MANIFEST" "$(basename "$BASE_MANIFEST")" "$(sha256_of "$BASE_MANIFEST")"
    upload_checked "$MARK_MANIFEST" "$(basename "$MARK_MANIFEST")" "$(sha256_of "$MARK_MANIFEST")"
    ok "PUSHED: $pushed file(s) shipped, $skipped already proven at the remote - it can now prove '$(json_str "$MARK_MANIFEST" mark_name)'"
}

# --- pull ----------------------------------------------------------------------

# Disaster recovery: bring back the newest instant the remote can PROVE - the
# newest mark manifest by NAME, because push writes the mark last, after
# everything it stands on landed and hashed true. Everything is re-hashed
# after the transfer (a download is a transfer too, measured on the way in)
# and nothing is ever overwritten: this runs on the worst day, when a local
# file with the same name might be the only other copy of anything.
cmd_pull() {
    load_remote
    rem_preflight ro
    mkdir -p "$OUT_DIR"

    local listing newest_mark mark_local
    listing=$(rem_list)
    newest_mark=$(printf '%s\n' "$listing" | { grep -E "^${DB}_[0-9]{8}T[0-9]{6}Z_mark\.json$" || true; } | LC_ALL=C sort | tail -1)
    [ -n "$newest_mark" ] || die "the remote holds no mark manifest for '$DB' - it cannot prove any instant of it"
    mark_local="$OUT_DIR/$newest_mark"
    [ ! -e "$mark_local" ] || die "refusing to overwrite $mark_local - it may be the only other copy of anything"
    rem_get "$newest_mark" "$mark_local" || die "could not fetch $newest_mark"
    if [ "$(json_str "$mark_local" kind)" != "pitr-mark" ]; then
        rm -f "$mark_local"
        die "$newest_mark is not a mark manifest - the fetched copy was removed"
    fi

    local mark_file mark_tl
    mark_file=$(json_str "$mark_local" wal_file)
    mark_tl=$(wal_name_timeline "$mark_file")
    local -a inv_lines=()
    local line
    mapfile -t inv_lines < <(manifest_section "$mark_local" wal)
    if [ "${#inv_lines[@]}" -eq 0 ]; then
        rm -f "$mark_local"
        die "$newest_mark records no WAL inventory - nothing can vouch for its chain; the fetched copy was removed"
    fi
    ok "newest provable instant of '$DB' at the remote: '$(json_str "$mark_local" mark_name)'"

    # The newest base this mark can recover from: same timeline, started at or
    # before the mark. Manifests are small - fetch newest-first until one fits.
    local base_local="" bname btmp bstart bbytes
    while IFS= read -r bname; do
        [ -n "$bname" ] || continue
        btmp="$OUT_DIR/.$bname.pulling"
        rem_get "$bname" "$btmp" 2>/dev/null || { rm -f "$btmp"; continue; }
        bstart=$(json_str "$btmp" wal_start_file)
        bbytes=$(json_num "$btmp" wal_segment_bytes)
        if [ "$(json_str "$btmp" kind)" = "pitr-base" ] && [ -n "$bstart" ] && [ -n "$bbytes" ] \
            && [ "$(wal_name_timeline "$bstart")" = "$mark_tl" ] \
            && [ "$(wal_name_index "$bstart" "$bbytes")" -le "$(wal_name_index "$mark_file" "$bbytes")" ]; then
            if [ -e "$OUT_DIR/$bname" ]; then
                rm -f "$btmp"
                die "refusing to overwrite $OUT_DIR/$bname - it may be the only other copy of anything"
            fi
            mv "$btmp" "$OUT_DIR/$bname"
            base_local="$OUT_DIR/$bname"
            break
        fi
        rm -f "$btmp"
    done < <(printf '%s\n' "$listing" | { grep -E "^${DB}_[0-9]{8}T[0-9]{6}Z(_.*)?_base\.json$" || true; } | LC_ALL=C sort -r)
    if [ -z "$base_local" ]; then
        rm -f "$mark_local"
        die "no base backup at the remote can reach this mark - the remote holds a claim it cannot honor (run ./pitr.sh check --remote)"
    fi

    local aname asha artefact_tmp
    aname=$(json_str "$base_local" artefact)
    asha=$(json_str "$base_local" sha256)
    [ ! -e "$OUT_DIR/$aname" ] || die "refusing to overwrite $OUT_DIR/$aname - it may be the only other copy of anything"
    artefact_tmp="$OUT_DIR/.$aname.pulling"
    if ! rem_get "$aname" "$artefact_tmp"; then
        rm -f "$artefact_tmp"
        die "could not fetch $aname"
    fi
    if [ "$(sha256_of "$artefact_tmp")" != "$asha" ]; then
        rm -f "$artefact_tmp"
        die "$aname did not survive the transfer (or rotted at the remote) - the fetched copy was removed instead of left looking like a backup"
    fi
    mv "$artefact_tmp" "$OUT_DIR/$aname"
    ok "base backup fetched and re-hashed: $aname"

    # What comes back is what this PAIR replays: the range from the chosen
    # base to the mark, plus the history files - the same set push ships and
    # check audits. The inventory may reach further back (it records the whole
    # archive as the mark saw it); those segments are not needed by this pair.
    # Every fetched file is re-hashed against the inventory, and a file
    # already in the local archive must hash true too - "same name" proves
    # nothing (measured, in four different shapes by now).
    local -A inv=()
    for line in "${inv_lines[@]}"; do
        inv["${line%%$'\t'*}"]="${line##*$'\t'}"
    done
    local -a needed=()
    local idx bstart_idx bmark_idx
    bstart_idx=$(wal_name_index "$(json_str "$base_local" wal_start_file)" "$(json_num "$base_local" wal_segment_bytes)")
    bmark_idx=$(wal_name_index "$mark_file" "$(json_num "$base_local" wal_segment_bytes)")
    for ((idx = bstart_idx; idx <= bmark_idx; idx++)); do
        needed+=("$(wal_index_name "$mark_tl" "$idx" "$(json_num "$base_local" wal_segment_bytes)")")
    done
    for line in "${inv_lines[@]}"; do
        case "${line%%$'\t'*}" in *.history) needed+=("${line%%$'\t'*}");; esac
    done
    local iname isha fetched=0 already=0 tmpf
    for iname in "${needed[@]}"; do
        isha="${inv[$iname]:-}"
        [ -n "$isha" ] \
            || die "the pair needs $iname and the mark's inventory never stood on it - nothing can vouch for those bytes; pull refuses to guess"
        if [ -e "$ARCHIVE_DIR/$iname" ]; then
            [ "$(sha256_of "$ARCHIVE_DIR/$iname" 2>/dev/null || echo unreadable)" = "$isha" ] \
                || die "$ARCHIVE_DIR/$iname already exists and is NOT the file the mark stands on - refusing to overwrite it or to trust it"
            already=$((already + 1))
            continue
        fi
        tmpf="$ARCHIVE_DIR/.$iname.pulling"
        if ! rem_get "$iname" "$tmpf"; then
            rm -f "$tmpf"
            die "could not fetch $iname - the chain is incomplete, and an incomplete chain recovers to a lie"
        fi
        if [ "$(sha256_of "$tmpf")" != "$isha" ]; then
            rm -f "$tmpf"
            die "$iname did not survive the transfer (or rotted at the remote) - the fetched copy was removed"
        fi
        mv "$tmpf" "$ARCHIVE_DIR/$iname"
        # The throwaway's own postgres user must be able to read what the
        # host just fetched. A dir remote's cp carries the source's 0600
        # over; ssh's redirect leaves 0644 - the recovery would then work on
        # one transport and die on the other with the SAME bytes (caught by
        # the fire drill, dir kind). An explicit mode makes both transports
        # tell the same story.
        chmod 644 "$ARCHIVE_DIR/$iname"
        fetched=$((fetched + 1))
    done
    ok "PULLED: chain of ${#needed[@]} file(s) ($fetched fetched, $already already here and hashing true)"
    ok "Prove the instant:"
    printf '      ./pitr.sh verify --base %s --mark %s --archive %s\n' "$base_local" "$mark_local" "$ARCHIVE_DIR"
}

# --- verify --------------------------------------------------------------------

cleanup() {
    if [ -n "$PROBE" ] && [ "$KEEP_CONTAINER" -eq 0 ]; then
        docker rm -f "$PROBE" > /dev/null 2>&1 || true
    elif [ -n "$PROBE" ]; then
        warn "throwaway instance left in place: $PROBE (data dir: $SCRATCH)"
        return 0
    fi
    if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then
        # The image's entrypoint chowns the extracted cluster - INCLUDING the
        # mount point itself - to its own postgres user, so the host cannot
        # delete any of it back: /tmp's sticky bit forbids unlinking an entry
        # you no longer own (measured, the hard way). Ask the same image to
        # remove what it created AND to hand the directory back.
        rm -rf -- "$SCRATCH" 2>/dev/null || {
            docker run --rm -u root --entrypoint sh -v "$SCRATCH:/wipe" "$IMAGE" \
                -c "rm -rf /wipe/* /wipe/.[!.]* /wipe/..?* && chown $(id -u):$(id -g) /wipe" > /dev/null 2>&1 || true
            rm -rf -- "$SCRATCH" 2>/dev/null || warn "could not remove $SCRATCH"
        }
    fi
}

cmd_verify() {
    need docker
    need tar
    [ -f "$BASE_MANIFEST" ] || die "base manifest not found: $BASE_MANIFEST"
    [ -f "$MARK_MANIFEST" ] || die "mark manifest not found: $MARK_MANIFEST"

    local kind
    kind="$(json_str "$BASE_MANIFEST" kind)"
    [ "$kind" = "pitr-base" ] \
        || die "'$BASE_MANIFEST' is not a base-backup manifest (kind '${kind:-none}') - a dump manifest verifies with ./verify.sh"
    kind="$(json_str "$MARK_MANIFEST" kind)"
    [ "$kind" = "pitr-mark" ] \
        || die "'$MARK_MANIFEST' is not a mark manifest (kind '${kind:-none}') - pass the mark to recover to"

    local db base_db dir artefact seg_bytes start_file mark_file mark_name
    db="$(json_str "$MARK_MANIFEST" database)"
    base_db="$(json_str "$BASE_MANIFEST" database)"
    [ "$db" = "$base_db" ] \
        || die "the base backup is of '$base_db' but the mark is of '$db' - these describe different databases"
    dir="$(cd "$(dirname "$BASE_MANIFEST")" && pwd)"
    artefact="$dir/$(json_str "$BASE_MANIFEST" artefact)"
    [ -f "$artefact" ] || die "artefact named by the base manifest is missing: $artefact"
    seg_bytes="$(json_num "$BASE_MANIFEST" wal_segment_bytes)"
    start_file="$(json_str "$BASE_MANIFEST" wal_start_file)"
    mark_file="$(json_str "$MARK_MANIFEST" wal_file)"
    mark_name="$(json_str "$MARK_MANIFEST" mark_name)"
    if [ -z "$seg_bytes" ] || [ -z "$start_file" ] || [ -z "$mark_file" ] || [ -z "$mark_name" ]; then
        die "the manifests are missing PITR fields - were they written by an older backup.sh?"
    fi
    if [ -z "$IMAGE" ]; then
        # A base backup is bytes from ONE major version; recovery must run the
        # same one. The manifest remembers so nobody has to.
        IMAGE="postgres:$(json_str "$BASE_MANIFEST" server_version)-alpine"
    fi

    log "verifying that base + archive reproduce '$mark_name' ($db)"

    # --- Gate 1: the base backup is byte-identical to what was taken ---------
    assert_pair_intact "$BASE_MANIFEST" "$artefact" "gate 1"
    ok "base backup matches its manifest ($(stat -c%s "$artefact") bytes, sha256 verified)"

    # --- Gate 2: the mark is reachable from this base ------------------------
    # Recovery starts AT the base and only rolls FORWARD. A mark taken before
    # the base backup, or on another timeline, will never be reached - and a
    # named target that is never reached is a FATAL (measured), so refuse in
    # milliseconds what the recovery would refuse in minutes.
    [ "$(wal_name_timeline "$mark_file")" = "$(wal_name_timeline "$start_file")" ] \
        || die "the mark lives on timeline $(wal_name_timeline "$mark_file") but the base backup starts on $(wal_name_timeline "$start_file") - a recovery in between changed history; take a fresh base backup"
    [ "$(wal_name_index "$mark_file" "$seg_bytes")" -ge "$(wal_name_index "$start_file" "$seg_bytes")" ] \
        || die "the mark predates the base backup (segment $mark_file < $start_file) - recovery rolls forward only, so this mark can never be reached from this base"
    ok "the mark sits in this base backup's future ($start_file .. $mark_file)"

    # --- Gate 3: the chain between them actually exists ----------------------
    local -a range_problems=()
    local line
    mapfile -t range_problems < <(wal_range_problems "$ARCHIVE_DIR" "$start_file" "$mark_file" "$seg_bytes")
    if [ "${#range_problems[@]}" -gt 0 ]; then
        for line in "${range_problems[@]}"; do
            printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$line"
        done
        die "PITR VERIFICATION FAILED: the WAL chain $start_file .. $mark_file cannot replay (${#range_problems[@]} problem(s)) - refusing to boot what the archive already refutes"
    fi
    ok "WAL chain $start_file .. $mark_file is present, every segment the full $seg_bytes bytes"

    # --- Gate 3b: the bytes are the ones the mark stood on --------------------
    # Continuity proves the chain LOOKS whole - and that is all it can prove:
    # every complete segment measures exactly seg_bytes, so size is blind to
    # rot BY CONSTRUCTION (measured: stat identical, bytes different). Worse,
    # rot in a segment PAST a mark leaves that mark's drill green, so a passing
    # recovery proves the chain it replayed, not the archive. This gate hashes
    # the range against the mark's own inventory TODAY, before anything boots.
    # The host often cannot read the segments (0600, the server's uid), so the
    # hashing runs in a sidecar of the recovery image itself.
    local -a inv_lines=()
    mapfile -t inv_lines < <(manifest_section "$MARK_MANIFEST" wal)
    if [ "${#inv_lines[@]}" -eq 0 ]; then
        warn "this mark records no WAL inventory (an older mark) - rot in the archive stays invisible until a recovery trips over it; re-mark to close that window"
    else
        local -A inv=()
        for line in "${inv_lines[@]}"; do
            inv["${line%%$'\t'*}"]="${line##*$'\t'}"
        done
        local idx start_idx mark_idx tl hash_fail=0 rname rsha hline
        tl=$(wal_name_timeline "$start_file")
        start_idx=$(wal_name_index "$start_file" "$seg_bytes")
        mark_idx=$(wal_name_index "$mark_file" "$seg_bytes")
        local -a range_names=()
        for ((idx = start_idx; idx <= mark_idx; idx++)); do
            range_names+=("$(wal_index_name "$tl" "$idx" "$seg_bytes")")
        done
        while IFS= read -r hline; do
            [ -n "$hline" ] || continue
            rname=${hline##* }
            rsha=${hline%% *}
            if [ -z "${inv[$rname]:-}" ]; then
                printf '  %sFAIL%s %s - in the archive, but the mark'\''s inventory never stood on it\n' "$c_red" "$c_reset" "$rname"
                hash_fail=$((hash_fail + 1))
            elif [ "${inv[$rname]}" != "$rsha" ]; then
                printf '  %sFAIL%s %s - these are not the bytes the mark stood on (rot, or a partial re-upload; the size cannot see this)\n' "$c_red" "$c_reset" "$rname"
                hash_fail=$((hash_fail + 1))
            fi
        done < <(printf '/archive/%s\n' "${range_names[@]}" \
            | docker run --rm -i -u root --entrypoint sh -v "$ARCHIVE_DIR:/archive:ro" "$IMAGE" \
                -c 'xargs -r sha256sum' | sed 's|/archive/||')
        [ "$hash_fail" -eq 0 ] \
            || die "PITR VERIFICATION FAILED: $hash_fail segment(s) do not hash back to the mark's inventory - refusing to recover through bytes the mark never stood on"
        ok "every segment in the range hashes back to the mark's inventory (${#range_names[@]} segment(s))"
    fi

    # --- Gate 4: the recovery itself, to the mark BY NAME --------------------
    # Always a named target. A nameless recovery ends wherever the archive
    # ends and calls that success - measured: rc 0, promoted, 100 rows short
    # with a hole in the chain, silent. Named, the same hole is FATAL.
    SCRATCH=$(mktemp -d)
    PROBE="bv-pitr-$$"
    trap cleanup EXIT
    tar -xf "$artefact" -C "$SCRATCH"
    {
        printf "restore_command = 'cp /archive/%%f %%p'\n"
        printf "recovery_target_name = '%s'\n" "$mark_name"
        printf "recovery_target_action = 'promote'\n"
    } >> "$SCRATCH/postgresql.auto.conf"
    touch "$SCRATCH/recovery.signal"

    log "booting a throwaway $IMAGE as '$PROBE' - recovery must reach '$mark_name' or die trying"
    docker run -d --name "$PROBE" -e POSTGRES_PASSWORD=verify \
        -v "$SCRATCH:/var/lib/postgresql/data" -v "$ARCHIVE_DIR:/archive:ro" \
        "$IMAGE" -c archive_mode=off > /dev/null

    local waited=0 state in_recovery
    while :; do
        state=$(docker inspect --format '{{.State.Running}}' "$PROBE" 2>/dev/null || echo false)
        if [ "$state" != "true" ]; then
            printf '\n'
            docker logs "$PROBE" 2>&1 | grep -E 'FATAL|PANIC|invalid' | tail -5 | sed 's/^/      /'
            die "recovery DIED before reaching '$mark_name' - the archive cannot reproduce this mark (rc $(docker inspect --format '{{.State.ExitCode}}' "$PROBE" 2>/dev/null || echo '?'))"
        fi
        in_recovery=$(eng_query "$PROBE" "$db" 'SELECT pg_is_in_recovery();' 2>/dev/null | tr -d '\n' || true)
        [ "$in_recovery" = "f" ] && break
        waited=$((waited + 1))
        [ "$waited" -le "$TIMEOUT" ] \
            || die "recovery did not reach '$mark_name' within ${TIMEOUT}s - still replaying, or stuck asking the archive for a segment that never comes"
        sleep 1
    done

    # The receipt: the server's own statement of WHERE it stopped. Reaching
    # "promoted" alone is not the claim - stopped AT THE MARK is.
    if ! docker logs "$PROBE" 2>&1 | grep -F "recovery stopping at restore point \"$mark_name\"" > /dev/null; then
        die "the instance promoted but never logged stopping at '$mark_name' - refusing to call that a verified recovery"
    fi
    docker logs "$PROBE" 2>&1 | grep -E 'recovery stopping at restore point|last completed transaction' | sed 's/^/      /'
    ok "recovery stopped AT the mark, then promoted"

    # --- Gates 5-7: the same yardstick verify.sh uses -------------------------
    # Content, schema objects, extra tables, writability - shared from
    # lib/common.sh, because one repo gets exactly one definition of "matches".
    local failures=0 gate_fail=0 checked
    compare_tables "$PROBE" "$db" "$MARK_MANIFEST" || gate_fail=$?
    failures=$((failures + gate_fail))
    checked=$COMPARED_TABLES
    [ "$checked" -gt 0 ] || die "the mark lists no tables - nothing was verified, so nothing is proven"

    gate_fail=0
    compare_objects "$PROBE" "$db" "$MARK_MANIFEST" || gate_fail=$?
    failures=$((failures + gate_fail))

    gate_fail=0
    compare_extra_tables "$PROBE" "$db" "$checked" || gate_fail=$?
    failures=$((failures + gate_fail))

    printf '\n'
    if [ "$failures" -gt 0 ]; then
        die "PITR VERIFICATION FAILED: $failures problem(s) across $checked table(s). The archive does NOT reproduce '$mark_name'."
    fi

    local write_problems=0
    writable_probe_report "$PROBE" "$db" || write_problems=$?
    if [ "$write_problems" -gt 0 ]; then
        die "PITR VERIFICATION FAILED: $write_problems write problem(s) - the instant came back and the next INSERT collides."
    fi

    ok "PITR VERIFIED: base backup + WAL archive reproduce '$mark_name' exactly ($checked table(s), byte-for-byte)."
}

main() {
    need sha256sum
    # PostgreSQL by declaration, not by detection - see the header.
    load_engine postgres
    case "$SUBCMD" in
        base)   cmd_base;;
        mark)   cmd_mark;;
        check)  cmd_check;;
        verify) cmd_verify;;
        push)   cmd_push;;
        pull)   cmd_pull;;
    esac
}

# Guarded so the tests can source this file and exercise parse_args without
# touching Docker (the harness idiom of the whole family).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    parse_args "$@"
    main
fi
