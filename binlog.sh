#!/usr/bin/env bash
# =============================================================================
# binlog.sh - MySQL point-in-time recovery you can PROVE, not hope.
#
# pitr.sh proves a Postgres instant; this proves a MySQL one - and it is a
# SEPARATE script because the animal measured is genuinely different. Every
# design choice answers something MEASURED against a real MySQL 8.4 before a
# line was written (README, "MySQL point-in-time has its own ways of lying"):
#
#   * a --stop-position PAST the end of the binlogs exits 0 with an EMPTY
#     stderr - the "named target" is a hint, not a promise. Postgres dies
#     FATAL when a named target is not reached; MySQL says nothing. So this
#     script's verify does not trust silence: ARRIVAL is proven by content,
#     with the mark's own fingerprints.
#   * a missing file in the middle of the replay list is STITCHED OVER:
#     rc 0, empty stderr, and the middle file's transactions silently gone
#     (measured: 100 of 300 rows vanished). Continuity is proven by NAME
#     before anything replays.
#   * mysqlbinlog does not verify event checksums unless asked: a corrupted
#     binlog sails through rc 0 WITHOUT --verify-binlog-checksum and dies
#     loudly WITH it (measured). The flag is not optional here.
#   * a dump without --source-data records NO anchor: a replay that starts
#     "from the beginning" re-runs history it already contains (measured:
#     it died on the first DDL collision, leaving an ambiguous half-replay).
#   * the official mysql image cannot read its own binlogs - mysqlbinlog is
#     not in it. The exact-version binary from the official client RPM rides
#     into throwaway containers read-only (the static-age lesson, again).
#
# Usage:
#   ./binlog.sh base   --container NAME --db NAME [--out DIR]
#   ./binlog.sh mark   --container NAME --db NAME --archive DIR [--out DIR]
#   ./binlog.sh check  --archive DIR [--container NAME]
#   ./binlog.sh check  --remote REMOTE [--db NAME]
#   ./binlog.sh verify --base FILE --mark FILE --archive DIR --tools DIR
#                      [--image IMAGE]
#   ./binlog.sh push   --base FILE --mark FILE --archive DIR --remote REMOTE
#   ./binlog.sh pull   --db NAME --remote REMOTE --archive DIR [--out DIR]
#
# Subcommands:
#   base    mysqldump with --source-data: the dump plus its ANCHOR (the
#           binlog file and position the replay must start from). A dump
#           without an anchor cannot be recovered forward - measured.
#   mark    fingerprint every table, capture the binlog position, FLUSH the
#           active file closed, and ARCHIVE every closed binlog the mark
#           stands on - each copy hash-verified against the server's own
#           bytes. The mark records one sha256 per archived file: MySQL has
#           no archive_command, so the mark IS the archiver.
#   check   audit the archive TODAY: numbering holes, strays, and - with
#           --container - whether the server's closed binlogs match the
#           archived copies byte for byte.
#   verify  the drill: boot a throwaway MySQL, load the dump, replay the
#           chain from the anchor to the mark position (checksums verified),
#           then prove ARRIVAL with the mark's fingerprints - because the
#           replay's own exit code cannot be trusted (measured).
#   push    ship a provable instant off the machine: the anchored dump, the
#           chain its mark replays (each file hashed at the remote before it
#           is named), and the mark manifest LAST - the receipt
#   pull    bring the newest provable instant back: dump + mark + chain,
#           re-hashed after the transfer, never overwriting anything
#
# Options:
#   --container NAME  Docker container running the source database
#   --db NAME         database to dump / mark / fingerprint
#   --archive DIR     where archived binlogs live (mark writes it, the rest
#                     read it)
#   --out DIR         where manifests are written (default ./backups)
#   --base FILE       base-dump manifest (verify)
#   --mark FILE       mark manifest to recover to (verify)
#   --tools DIR       directory holding a mysqlbinlog binary matching the
#                     server major (the official image ships none; extract it
#                     from the official mysql-community-client RPM)
#   --image IMAGE     image for the throwaway instance (default: mysql:<major>
#                     from the base manifest)
#   --label TEXT      extra label in the base artefact name
#   --timeout SECONDS how long mark/verify wait (default 90)
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
TOOLS_DIR=""
PROBE=""
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
            --tools)          TOOLS_DIR="${2:-}"; shift 2;;
            --remote)         REMOTE="${2:-}"; shift 2;;
            --ssh-opts)       SSH_OPTS_STR="${2:-}"; shift 2;;
            --keep-container) KEEP_CONTAINER=1; shift;;
            -h|--help)        usage 0;;
            *)                printf 'unknown option: %s\n' "$1" >&2; usage 1;;
        esac
    done
    case "$TIMEOUT" in
        ''|*[!0-9]*) die "--timeout must be a non-negative integer, got '$TIMEOUT'";;
    esac
    # base needs no archive: the dump carries its anchor, the binlogs come
    # with the first mark. A remote check audits the off-site copy; pull
    # CREATES its archive directory - disaster recovery starts with nothing.
    if [ "$SUBCMD" = check ] && [ -n "$REMOTE" ]; then
        [ -z "$ARCHIVE_DIR" ] || die "check audits either --archive (local) or --remote (off-site), not both at once"
    elif [ "$SUBCMD" != base ]; then
        [ -n "$ARCHIVE_DIR" ] || die "--archive is required (the archived binlogs are the other half of the backup)"
        if [ ! -d "$ARCHIVE_DIR" ]; then
            case "$SUBCMD" in
                mark|pull) mkdir -p "$ARCHIVE_DIR" || die "could not create archive directory: $ARCHIVE_DIR";;
                *)         die "archive directory not found: $ARCHIVE_DIR";;
            esac
        fi
        ARCHIVE_DIR="$(cd "$ARCHIVE_DIR" && pwd)"
    fi
    case "$SUBCMD" in
        base|mark)
            [ -n "$CONTAINER" ] || die "$SUBCMD needs --container (where the database lives)"
            [ -n "$DB" ] || die "$SUBCMD needs --db";;
        verify)
            [ -n "$BASE_MANIFEST" ] || die "verify needs --base (the base-dump manifest)"
            [ -n "$MARK_MANIFEST" ] || die "verify needs --mark (the instant to prove)"
            [ -n "$TOOLS_DIR" ] || die "verify needs --tools (a directory holding mysqlbinlog - the official image ships none; see the header)"
            [ -x "$TOOLS_DIR/mysqlbinlog" ] || die "no executable mysqlbinlog in $TOOLS_DIR";;
        push)
            [ -n "$BASE_MANIFEST" ] || die "push needs --base (the base-dump manifest)"
            [ -n "$MARK_MANIFEST" ] || die "push needs --mark (the instant the remote must be able to prove)"
            [ -n "$REMOTE" ] || die "push needs --remote (where the copy is going)";;
        pull)
            [ -n "$DB" ] || die "pull needs --db (which database to bring back)"
            [ -n "$REMOTE" ] || die "pull needs --remote (where the copy lives)";;
    esac
}

# --- binlog name arithmetic ------------------------------------------------
# Names are <prefix>.<6+ digits>. Unlike WAL names there is no timeline and no
# carry: one decimal counter. The prefix is whatever log_bin_basename says -
# read from the files themselves, never assumed.

binlog_prefix_of() { printf '%s' "${1%.*}"; }
binlog_index_of()  { printf '%s' "$((10#${1##*.}))"; }
binlog_name()      { printf '%s.%06d' "$1" "$2"; }

assert_binlog_on() {
    [ "$(eng_query "$CONTAINER" mysql 'SELECT @@log_bin;' | tr -d '\n')" = "1" ] \
        || die "the server in '$CONTAINER' is not writing a binary log - there is no history to recover through"
}

binlog_status() {
    # SHOW MASTER STATUS is REMOVED in 8.4 (measured) - this is its successor.
    eng_query "$CONTAINER" mysql 'SHOW BINARY LOG STATUS;' | awk '{print $1, $2}'
}

container_sha256() {
    docker exec "$CONTAINER" sha256sum "/var/lib/mysql/$1" < /dev/null 2>/dev/null | awk '{print $1}'
}

# --- base --------------------------------------------------------------------

cmd_base() {
    need docker
    eng_preflight "$CONTAINER"
    assert_binlog_on
    mkdir -p "$OUT_DIR"

    local stamp base artefact manifest version
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    base="${DB}_${stamp}${LABEL:+_$LABEL}_binlogbase"
    artefact="$OUT_DIR/$base.sql"
    manifest="$OUT_DIR/$base.json"
    version=$(eng_query "$CONTAINER" mysql 'SELECT VERSION();' | tr -d '\n')

    log "dumping '$DB' with its replay anchor (mysqldump --single-transaction --source-data)"
    trap 'rm -f -- "$artefact"' ERR
    # --source-data=2 writes the anchor as a comment: the binlog file and
    # position this dump is consistent AT. Without it the dump is the
    # tutorial's dump, and a replay has nowhere honest to start (measured:
    # starting from the beginning re-runs history the dump already contains).
    docker exec -e MYSQL_PWD=verify "$CONTAINER" mysqldump -uroot \
        --single-transaction --source-data=2 --routines --events --triggers \
        --databases "$DB" < /dev/null 2> /dev/null > "$artefact" \
        || { rm -f -- "$artefact"; die "mysqldump failed - no artefact was left behind"; }
    trap - ERR

    local size floor="${ENG_MIN_ARTEFACT_BYTES:-$MIN_ARTEFACT_BYTES}"
    size=$(stat -c%s "$artefact")
    if [ "$size" -lt "$floor" ]; then
        rm -f -- "$artefact"
        die "base dump is only ${size} bytes (< $floor) - refusing to call that a base"
    fi
    if ! eng_archive_parses "$CONTAINER" < "$artefact"; then
        rm -f -- "$artefact"
        die "the base dump does not parse as a complete mysqldump (no trailing 'Dump completed') - removed"
    fi

    local anchor_line anchor_file anchor_pos
    anchor_line=$(grep -m1 'CHANGE REPLICATION SOURCE TO' "$artefact" || true)
    anchor_file=$(printf '%s' "$anchor_line" | grep -o "SOURCE_LOG_FILE='[^']*'" | cut -d"'" -f2)
    anchor_pos=$(printf '%s' "$anchor_line" | grep -o 'SOURCE_LOG_POS=[0-9]*' | cut -d= -f2)
    if [ -z "$anchor_file" ] || [ -z "$anchor_pos" ]; then
        rm -f -- "$artefact"
        die "the dump carries no replay anchor - a base that cannot be rolled forward is just a dump; removed (is the server logging binary?)"
    fi

    {
        printf '{\n'
        printf '  "schema": 3,\n'
        printf '  "kind": "binlog-base",\n'
        printf '  "database": "%s",\n' "$DB"
        printf '  "created_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "artefact": "%s",\n' "$(basename "$artefact")"
        printf '  "bytes": %s,\n' "$size"
        printf '  "sha256": "%s",\n' "$(sha256_of "$artefact")"
        printf '  "engine": "%s",\n' "$ENG_NAME"
        printf '  "server_version": "%s",\n' "$(printf '%s' "$version" | cut -d. -f1-2)"
        printf '  "anchor_file": "%s",\n' "$anchor_file"
        printf '  "anchor_pos": %s\n' "$anchor_pos"
        printf '}\n'
    } > "$manifest"

    ok "base dump: $artefact ($size bytes, parses, replay starts at $anchor_file:$anchor_pos)"
    ok "a base alone is one instant - name the instants it must roll forward to:"
    printf '      ./binlog.sh mark --container %s --db %s --archive ARCHIVE_DIR\n' "$CONTAINER" "$DB"
}

# --- mark --------------------------------------------------------------------

cmd_mark() {
    need docker
    eng_preflight "$CONTAINER"
    assert_binlog_on
    mkdir -p "$OUT_DIR"

    local stamp manifest
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    manifest="$OUT_DIR/${DB}_${stamp}_binlogmark.json"

    local tables table fp count
    tables=$(eng_list_tables "$CONTAINER" "$DB")
    count=$(printf '%s\n' "$tables" | grep -c . || true)
    [ "$count" -gt 0 ] || die "the source contains no tables - a mark of nothing proves nothing"

    # Fingerprint FIRST, then read the position: the fingerprints define what
    # the instant contains, the position names it. The status before and
    # after bracket the fingerprinting, so writes landing in between are
    # reported, not hidden.
    local pos_before tables_block="" objects_block="" first=1
    pos_before=$(binlog_status)
    log "fingerprinting '$DB' ($count tables) - the yardstick the replay will be measured against"
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
    local class first_obj=1
    for class in $SCHEMA_CLASSES; do
        [ "$first_obj" -eq 1 ] || objects_block+=$',\n'
        first_obj=0
        objects_block+=$(printf '    "%s": "%s"' "$class" "$(eng_schema_digest "$CONTAINER" "$DB" "$class")")
    done

    local mark_file mark_pos quiesced
    read -r mark_file mark_pos <<< "$(binlog_status)"
    if [ "$pos_before" = "$mark_file $mark_pos" ]; then
        quiesced="yes"
    else
        quiesced="no"
        warn "the binlog advanced while fingerprinting ($pos_before -> $mark_file $mark_pos): writes are landing, and the fingerprints and the position may straddle them"
    fi
    log "the instant is $mark_file:$mark_pos"

    # FLUSH closes the mark's file. An ACTIVE binlog keeps growing under any
    # copy (measured) - only a closed file has final bytes worth hashing.
    eng_query "$CONTAINER" mysql 'FLUSH BINARY LOGS;' > /dev/null
    local waited=0 current_file
    while :; do
        read -r current_file _ <<< "$(binlog_status)"
        [ "$(binlog_index_of "$current_file")" -gt "$(binlog_index_of "$mark_file")" ] && break
        waited=$((waited + 1))
        [ "$waited" -le "$TIMEOUT" ] || die "the server never rotated past $mark_file in ${TIMEOUT}s - this mark cannot be archived, so no manifest was written"
        sleep 1
    done

    # MySQL has no archive_command: the mark IS the archiver. Every closed
    # file the mark stands on is copied out and the copy hash-verified
    # against the server's own bytes - a copy nothing vouches for is the
    # off-site lesson replayed locally. Files already archived must STILL
    # hash true: binlogs are immutable once closed, so a mismatch is rot,
    # here or there, and naming it beats propagating it.
    local name src_sha dst_sha archived=0 already=0
    local inv_block="" first_inv=1
    while IFS=$'\t' read -r name _; do
        [ -n "$name" ] || continue
        [ "$(binlog_index_of "$name")" -le "$(binlog_index_of "$mark_file")" ] || continue
        src_sha=$(container_sha256 "$name")
        [ -n "$src_sha" ] || die "could not hash $name inside the container"
        if [ -e "$ARCHIVE_DIR/$name" ]; then
            dst_sha=$(sha256_of "$ARCHIVE_DIR/$name")
            [ "$dst_sha" = "$src_sha" ] \
                || die "$name is already archived with DIFFERENT bytes (archive $dst_sha, server $src_sha) - a closed binlog is immutable, so one of the two has rotted; refusing to write a mark over it"
            already=$((already + 1))
        else
            docker cp "$CONTAINER:/var/lib/mysql/$name" "$ARCHIVE_DIR/.$name.copying" > /dev/null 2>&1 \
                || die "could not copy $name out of the container"
            dst_sha=$(sha256_of "$ARCHIVE_DIR/.$name.copying")
            if [ "$dst_sha" != "$src_sha" ]; then
                rm -f "$ARCHIVE_DIR/.$name.copying"
                die "$name did not survive the copy (server $src_sha, copy $dst_sha) - the partial was removed"
            fi
            mv "$ARCHIVE_DIR/.$name.copying" "$ARCHIVE_DIR/$name"
            chmod 644 "$ARCHIVE_DIR/$name"
            archived=$((archived + 1))
        fi
        [ "$first_inv" -eq 1 ] || inv_block+=$',\n'
        first_inv=0
        inv_block+=$(printf '    "%s": "%s:%s"' "$name" "$src_sha" "$(stat -c%s "$ARCHIVE_DIR/$name")")
    done < <(eng_query "$CONTAINER" mysql 'SHOW BINARY LOGS;' | awk -F'\t' '{print $1 "\t" $2}')
    printf '%s' "$inv_block" | grep -qF "\"$mark_file\":" \
        || die "the mark's own file $mark_file was never archived - refusing to write a mark that cannot be replayed to"
    ok "archived $archived file(s), $already already archived and hashing true"

    {
        printf '{\n'
        printf '  "schema": 3,\n'
        printf '  "kind": "binlog-mark",\n'
        printf '  "database": "%s",\n' "$DB"
        printf '  "created_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "engine": "%s",\n' "$ENG_NAME"
        printf '  "mark_file": "%s",\n' "$mark_file"
        printf '  "mark_pos": %s,\n' "$mark_pos"
        printf '  "quiesced": "%s",\n' "$quiesced"
        printf '  "binlogs": {\n%s\n  },\n' "$inv_block"
        printf '  "tables": {\n%s\n  },\n' "$tables_block"
        printf '  "objects": {\n%s\n  }\n' "$objects_block"
        printf '}\n'
    } > "$manifest"

    ok "mark at $mark_file:$mark_pos is archived and fingerprinted: $count table(s) + $(printf '%s' "$SCHEMA_CLASSES" | wc -w) object class(es)"
    ok "Prove the chain can reproduce it:"
    printf '      ./binlog.sh verify --base BASE_MANIFEST --mark %s --archive %s --tools TOOLS_DIR\n' "$manifest" "$ARCHIVE_DIR"
}

# --- check -------------------------------------------------------------------

cmd_check() {
    if [ -n "$REMOTE" ]; then
        cmd_check_remote
        return
    fi
    local problems=0 name prefix=""
    local -a files=() strays=()
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [[ "$name" =~ ^[A-Za-z0-9_-]+\.[0-9]{6,}$ ]]; then
            files+=("$name")
            if [ -z "$prefix" ]; then
                prefix=$(binlog_prefix_of "$name")
            elif [ "$prefix" != "$(binlog_prefix_of "$name")" ]; then
                die "the archive holds binlogs with TWO prefixes ('$prefix' and '$(binlog_prefix_of "$name")') - two servers have written here, and a replay across them is fiction; refusing"
            fi
        else
            strays+=("$name")
        fi
    done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)

    [ "${#files[@]}" -gt 0 ] \
        || die "the archive holds no binlogs at all - nothing could ever be replayed from it"

    for name in ${strays[@]+"${strays[@]}"}; do
        printf '  %sFAIL%s %s - not an archived binlog (a crashed copy, or a squatter a future mark would refuse to overwrite)\n' \
            "$c_red" "$c_reset" "$name"
        problems=$((problems + 1))
    done

    # Continuity by NUMBER: one decimal counter, no carry, no timeline. There
    # is NO size gate - binlogs are variable-length by nature, so bytes are
    # vouched for per file by each mark's inventory, not by shape.
    local i i0 i1
    i0=$(binlog_index_of "${files[0]}")
    i1=$(binlog_index_of "${files[${#files[@]}-1]}")
    for ((i = i0; i <= i1; i++)); do
        name=$(binlog_name "$prefix" "$i")
        if [ ! -e "$ARCHIVE_DIR/$name" ]; then
            printf '  %sFAIL%s missing %s - the chain is broken here, and a replay would STITCH OVER the hole silently (measured)\n' \
                "$c_red" "$c_reset" "$name"
            problems=$((problems + 1))
        fi
    done

    # With the source at hand: every closed file the server still has, that
    # the archive also has, must match byte for byte - and closed files the
    # archive does NOT have yet are named, because MySQL will not archive
    # them for you (there is no archive_command; the next mark does it).
    if [ -n "$CONTAINER" ]; then
        eng_preflight "$CONTAINER"
        assert_binlog_on
        local current_file src_sha dst_sha unarchived=0
        read -r current_file _ <<< "$(binlog_status)"
        while IFS=$'\t' read -r name _; do
            [ -n "$name" ] || continue
            [ "$name" != "$current_file" ] || continue   # the active file is still growing
            if [ -e "$ARCHIVE_DIR/$name" ]; then
                src_sha=$(container_sha256 "$name")
                dst_sha=$(sha256_of "$ARCHIVE_DIR/$name")
                if [ "$src_sha" != "$dst_sha" ]; then
                    printf '  %sFAIL%s %s - the archived copy does not match the server'\''s bytes (one of the two has rotted)\n' \
                        "$c_red" "$c_reset" "$name"
                    problems=$((problems + 1))
                fi
            else
                unarchived=$((unarchived + 1))
            fi
        done < <(eng_query "$CONTAINER" mysql 'SHOW BINARY LOGS;' | awk -F'\t' '{print $1 "\t" $2}')
        [ "$unarchived" -eq 0 ] \
            || log "$unarchived closed file(s) on the server are not archived yet - they travel with the next mark (MySQL has no archive_command; the mark is the archiver)"
    fi

    printf '\n'
    if [ "$problems" -gt 0 ]; then
        die "ARCHIVE CHECK FAILED: $problems problem(s). A replay through this archive would stitch over holes or apply rot - this is the cheap day to find out."
    fi
    ok "archive is continuous: ${#files[@]} binlog(s), $prefix.$(printf '%06d' "$i0") .. $prefix.$(printf '%06d' "$i1")"
    log 'continuous is not recoverable - prove an instant with: ./binlog.sh verify'
}

# --- push ----------------------------------------------------------------------

# Ship a provable instant: the anchored dump, every binlog in the range the
# pair replays, and the manifests - the mark LAST, so a mark at the remote is
# a receipt that everything it needs arrived whole (the offsite.sh protocol).
# Incremental by HASH, never by name: at a binlog archive even TRUNCATION has
# no shape - sizes vary by nature, and a binlog cut at an event boundary
# decodes clean, rc 0, stderr empty (measured). Only the hash sees anything.
cmd_push() {
    load_remote
    rem_preflight rw

    local kind db base_db dir artefact anchor_file anchor_pos mark_file mark_pos
    [ -f "$BASE_MANIFEST" ] || die "base manifest not found: $BASE_MANIFEST"
    [ -f "$MARK_MANIFEST" ] || die "mark manifest not found: $MARK_MANIFEST"
    kind="$(json_str "$BASE_MANIFEST" kind)"
    [ "$kind" = "binlog-base" ] \
        || die "'$BASE_MANIFEST' is not a binlog-base manifest (kind '${kind:-none}') - dump backups travel with ./offsite.sh, WAL pairs with ./pitr.sh push"
    kind="$(json_str "$MARK_MANIFEST" kind)"
    [ "$kind" = "binlog-mark" ] \
        || die "'$MARK_MANIFEST' is not a binlog-mark manifest (kind '${kind:-none}') - pass the instant the remote must be able to prove"
    db="$(json_str "$MARK_MANIFEST" database)"
    base_db="$(json_str "$BASE_MANIFEST" database)"
    [ "$db" = "$base_db" ] \
        || die "the base dump is of '$base_db' but the mark is of '$db' - these describe different databases"
    dir="$(cd "$(dirname "$BASE_MANIFEST")" && pwd)"
    artefact="$dir/$(json_str "$BASE_MANIFEST" artefact)"
    [ -f "$artefact" ] || die "artefact named by the base manifest is missing: $artefact"
    anchor_file="$(json_str "$BASE_MANIFEST" anchor_file)"
    anchor_pos="$(json_num "$BASE_MANIFEST" anchor_pos)"
    mark_file="$(json_str "$MARK_MANIFEST" mark_file)"
    mark_pos="$(json_num "$MARK_MANIFEST" mark_pos)"

    # The same refusals verify makes: a pair that can never replay must not
    # be shipped looking like one that can.
    [ "$(binlog_prefix_of "$mark_file")" = "$(binlog_prefix_of "$anchor_file")" ] \
        || die "the mark and the anchor name two different servers' histories - pushing this pair would ship that fiction off-site"
    local a_idx m_idx
    a_idx=$(binlog_index_of "$anchor_file")
    m_idx=$(binlog_index_of "$mark_file")
    if [ "$m_idx" -lt "$a_idx" ] || { [ "$m_idx" -eq "$a_idx" ] && [ "$mark_pos" -lt "$anchor_pos" ]; }; then
        die "the mark predates the base's anchor - this pair can never replay; nothing was pushed"
    fi
    assert_pair_intact "$BASE_MANIFEST" "$artefact" "push"

    local -a inv_lines=()
    local line
    mapfile -t inv_lines < <(manifest_section "$MARK_MANIFEST" binlogs)
    [ "${#inv_lines[@]}" -gt 0 ] \
        || die "this mark records no binlog inventory - push cannot promise what nothing can audit"
    local -A inv=()
    for line in "${inv_lines[@]}"; do
        inv["${line%%$'\t'*}"]="${line##*$'\t'}"
    done

    # The chain the pair replays, proven LOCALLY first: present, vouched for
    # by the inventory, and hashing true - rot replicates as happily as data.
    local idx name prefix
    prefix=$(binlog_prefix_of "$anchor_file")
    local -a to_ship=()
    for ((idx = a_idx; idx <= m_idx; idx++)); do
        name=$(binlog_name "$prefix" "$idx")
        to_ship+=("$name")
        [ -e "$ARCHIVE_DIR/$name" ] \
            || die "the chain needs $name and the local archive does not hold it - pushing would replicate the hole off-site (a replay stitches over holes with rc 0 - measured)"
        [ -n "${inv[$name]:-}" ] \
            || die "the chain needs $name and the mark's inventory never stood on it - take a fresh mark"
        [ "$(sha256_of "$ARCHIVE_DIR/$name")" = "${inv[$name]%%:*}" ] \
            || die "$name does not hash back to the mark's inventory IN THE LOCAL ARCHIVE - refusing to replicate rot off-site"
    done
    ok "the local chain hashes back to the mark's inventory (${#to_ship[@]} file(s))"

    local listing pushed=0 skipped=0
    listing=$(rem_list)
    for name in "${to_ship[@]}"; do
        if printf '%s\n' "$listing" | grep -qxF "$name"; then
            if [ "$(rem_sha256 "$name" || true)" = "${inv[$name]%%:*}" ]; then
                skipped=$((skipped + 1))
                continue
            fi
            warn "$name sits at the remote with the WRONG bytes (rot, truncation or a crashed upload - all shapeless here; only the hash sees them) - re-shipping it"
        fi
        upload_checked "$ARCHIVE_DIR/$name" "$name" "${inv[$name]%%:*}"
        pushed=$((pushed + 1))
    done

    local aname asha
    aname=$(json_str "$BASE_MANIFEST" artefact)
    asha=$(json_str "$BASE_MANIFEST" sha256)
    if printf '%s\n' "$listing" | grep -qxF "$aname" && [ "$(rem_sha256 "$aname" || true)" = "$asha" ]; then
        ok "base dump already at the remote, hashed true there"
    else
        upload_checked "$artefact" "$aname" "$asha"
    fi

    # Manifests last, mark VERY last: the receipt.
    upload_checked "$BASE_MANIFEST" "$(basename "$BASE_MANIFEST")" "$(sha256_of "$BASE_MANIFEST")"
    upload_checked "$MARK_MANIFEST" "$(basename "$MARK_MANIFEST")" "$(sha256_of "$MARK_MANIFEST")"
    ok "PUSHED: $pushed file(s) shipped, $skipped already proven at the remote - it can now prove $mark_file:$mark_pos"
}

# --- pull ----------------------------------------------------------------------

# Disaster recovery: bring back the newest instant the remote can PROVE - the
# newest mark manifest by NAME, because push writes the mark last. Everything
# is re-hashed after the transfer and nothing is ever overwritten.
cmd_pull() {
    load_remote
    rem_preflight ro
    mkdir -p "$OUT_DIR"

    local listing newest_mark mark_local
    listing=$(rem_list)
    newest_mark=$(printf '%s\n' "$listing" | { grep -E "^${DB}_[0-9]{8}T[0-9]{6}Z_binlogmark\.json$" || true; } | LC_ALL=C sort | tail -1)
    [ -n "$newest_mark" ] || die "the remote holds no binlog mark manifest for '$DB' - it cannot prove any instant of it"
    mark_local="$OUT_DIR/$newest_mark"
    [ ! -e "$mark_local" ] || die "refusing to overwrite $mark_local - it may be the only other copy of anything"
    rem_get "$newest_mark" "$mark_local" || die "could not fetch $newest_mark"
    if [ "$(json_str "$mark_local" kind)" != "binlog-mark" ]; then
        rm -f "$mark_local"
        die "$newest_mark is not a binlog-mark manifest - the fetched copy was removed"
    fi
    local mark_file mark_pos
    mark_file=$(json_str "$mark_local" mark_file)
    mark_pos=$(json_num "$mark_local" mark_pos)
    local -a inv_lines=()
    local line
    mapfile -t inv_lines < <(manifest_section "$mark_local" binlogs)
    if [ "${#inv_lines[@]}" -eq 0 ]; then
        rm -f "$mark_local"
        die "$newest_mark records no binlog inventory - nothing can vouch for its chain; the fetched copy was removed"
    fi
    ok "newest provable instant of '$DB' at the remote: $mark_file:$mark_pos"

    # The newest base this mark can replay from: same prefix, anchor at or
    # before the mark. Manifests are small - fetch newest-first until one fits.
    local base_local="" bname btmp bfile bpos
    while IFS= read -r bname; do
        [ -n "$bname" ] || continue
        btmp="$OUT_DIR/.$bname.pulling"
        rem_get "$bname" "$btmp" 2>/dev/null || { rm -f "$btmp"; continue; }
        bfile=$(json_str "$btmp" anchor_file)
        bpos=$(json_num "$btmp" anchor_pos)
        if [ "$(json_str "$btmp" kind)" = "binlog-base" ] && [ -n "$bfile" ] && [ -n "$bpos" ] \
            && [ "$(binlog_prefix_of "$bfile")" = "$(binlog_prefix_of "$mark_file")" ] \
            && { [ "$(binlog_index_of "$bfile")" -lt "$(binlog_index_of "$mark_file")" ] \
                 || { [ "$(binlog_index_of "$bfile")" -eq "$(binlog_index_of "$mark_file")" ] && [ "$bpos" -le "$mark_pos" ]; }; }; then
            if [ -e "$OUT_DIR/$bname" ]; then
                rm -f "$btmp"
                die "refusing to overwrite $OUT_DIR/$bname - it may be the only other copy of anything"
            fi
            mv "$btmp" "$OUT_DIR/$bname"
            base_local="$OUT_DIR/$bname"
            break
        fi
        rm -f "$btmp"
    done < <(printf '%s\n' "$listing" | { grep -E "^${DB}_[0-9]{8}T[0-9]{6}Z(_.*)?_binlogbase\.json$" || true; } | LC_ALL=C sort -r)
    if [ -z "$base_local" ]; then
        rm -f "$mark_local"
        die "no base dump at the remote can reach this mark - the remote holds a claim it cannot honor (run ./binlog.sh check --remote)"
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
        die "$aname did not survive the transfer (or rotted at the remote) - the fetched copy was removed"
    fi
    mv "$artefact_tmp" "$OUT_DIR/$aname"
    ok "base dump fetched and re-hashed: $aname"

    # The chain the pair replays: anchor..mark, re-hashed against the
    # inventory - the same set push ships and check --remote audits. A file
    # already in the local archive must hash true too.
    local -A inv=()
    for line in "${inv_lines[@]}"; do
        inv["${line%%$'\t'*}"]="${line##*$'\t'}"
    done
    local idx name isha fetched=0 already=0 tmpf prefix
    prefix=$(binlog_prefix_of "$mark_file")
    local a_idx m_idx
    a_idx=$(binlog_index_of "$(json_str "$base_local" anchor_file)")
    m_idx=$(binlog_index_of "$mark_file")
    for ((idx = a_idx; idx <= m_idx; idx++)); do
        name=$(binlog_name "$prefix" "$idx")
        isha="${inv[$name]:-}"
        [ -n "$isha" ] \
            || die "the pair needs $name and the mark's inventory never stood on it - pull refuses to guess"
        isha="${isha%%:*}"
        if [ -e "$ARCHIVE_DIR/$name" ]; then
            [ "$(sha256_of "$ARCHIVE_DIR/$name" 2>/dev/null || echo unreadable)" = "$isha" ] \
                || die "$ARCHIVE_DIR/$name already exists and is NOT the file the mark stands on - refusing to overwrite it or to trust it"
            already=$((already + 1))
            continue
        fi
        tmpf="$ARCHIVE_DIR/.$name.pulling"
        if ! rem_get "$name" "$tmpf"; then
            rm -f "$tmpf"
            die "could not fetch $name - the chain is incomplete, and a replay would stitch over the hole silently (measured)"
        fi
        if [ "$(sha256_of "$tmpf")" != "$isha" ]; then
            rm -f "$tmpf"
            die "$name did not survive the transfer (or rotted at the remote) - the fetched copy was removed"
        fi
        mv "$tmpf" "$ARCHIVE_DIR/$name"
        chmod 644 "$ARCHIVE_DIR/$name"
        fetched=$((fetched + 1))
    done
    ok "PULLED: chain of $((m_idx - a_idx + 1)) file(s) ($fetched fetched, $already already here and hashing true)"
    ok "Prove the instant:"
    printf '      ./binlog.sh verify --base %s --mark %s --archive %s --tools TOOLS_DIR\n' "$base_local" "$mark_local" "$ARCHIVE_DIR"
}

# --- check --remote --------------------------------------------------------------

# The off-site audit: for the newest mark of each database (or --db), every
# file the PAIR replays must be at the remote and hash back to the mark's
# inventory - hashed AT the remote. Size says nothing here even about
# truncation: a binlog cut at an event boundary decodes clean (measured), so
# the hash carries everything.
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
    mark_list=$(printf '%s\n' "$listing" | { grep -E '_[0-9]{8}T[0-9]{6}Z_binlogmark\.json$' || true; })
    if [ -n "$DB" ]; then
        mark_list=$(printf '%s\n' "$mark_list" | { grep -E "^${DB}_[0-9]{8}T[0-9]{6}Z_binlogmark\.json$" || true; })
        [ -n "$mark_list" ] || die "the remote holds no binlog mark manifest for '$DB' - it cannot prove any instant of it"
    else
        [ -n "$mark_list" ] || die "the remote holds no binlog mark manifests at all - it cannot prove any instant"
    fi

    local -a newest=()
    while IFS= read -r mark; do
        [ -n "$mark" ] || continue
        newest+=("$mark")
    done < <(printf '%s\n' "$mark_list" | LC_ALL=C sort \
        | awk '{db = $0; sub(/_[0-9]{8}T[0-9]{6}Z_binlogmark\.json$/, "", db); latest[db] = $0}
               END {for (d in latest) print latest[d]}' | LC_ALL=C sort)

    tmp=$(mktemp -d)
    local entries iname isha before mark_db
    for mark in "${newest[@]}"; do
        before=$problems
        if ! rem_get "$mark" "$tmp/$mark"; then
            printf '  %sFAIL%s %s - named by the remote listing but it could not be fetched\n' "$c_red" "$c_reset" "$mark"
            problems=$((problems + 1))
            continue
        fi
        mark_db=$(json_str "$tmp/$mark" database)
        entries=$(manifest_section "$tmp/$mark" binlogs)
        if [ -z "$entries" ]; then
            printf '  %sFAIL%s %s - records no binlog inventory, so nothing can vouch for its chain\n' "$c_red" "$c_reset" "$mark"
            problems=$((problems + 1))
            continue
        fi
        local -A inv=()
        while IFS=$'\t' read -r iname isha; do
            [ -n "$iname" ] || continue
            inv["$iname"]="$isha"
        done <<< "$entries"

        # Something for the chain to replay from: the newest intact base at
        # the remote that can reach this mark. Its anchor decides WHAT to
        # audit - the same range push ships and pull fetches.
        local mark_file mark_pos base_ok=0 bname bfile bpos
        mark_file=$(json_str "$tmp/$mark" mark_file)
        mark_pos=$(json_num "$tmp/$mark" mark_pos)
        while IFS= read -r bname; do
            [ -n "$bname" ] || continue
            rem_get "$bname" "$tmp/$bname" 2>/dev/null || continue
            bfile=$(json_str "$tmp/$bname" anchor_file)
            bpos=$(json_num "$tmp/$bname" anchor_pos)
            [ "$(json_str "$tmp/$bname" kind)" = "binlog-base" ] || continue
            if [ -z "$bfile" ] || [ -z "$bpos" ]; then continue; fi
            [ "$(binlog_prefix_of "$bfile")" = "$(binlog_prefix_of "$mark_file")" ] || continue
            if [ "$(binlog_index_of "$bfile")" -lt "$(binlog_index_of "$mark_file")" ] \
                || { [ "$(binlog_index_of "$bfile")" -eq "$(binlog_index_of "$mark_file")" ] && [ "$bpos" -le "$mark_pos" ]; }; then
                if [ "$(rem_sha256 "$(json_str "$tmp/$bname" artefact)" || true)" = "$(json_str "$tmp/$bname" sha256)" ]; then
                    base_ok=1
                    break
                fi
            fi
        done < <(printf '%s\n' "$listing" | { grep -E "^${mark_db}_[0-9]{8}T[0-9]{6}Z(_.*)?_binlogbase\.json$" || true; } | LC_ALL=C sort -r)

        local -a audit=()
        local idx
        if [ "$base_ok" -eq 1 ]; then
            for ((idx = $(binlog_index_of "$bfile"); idx <= $(binlog_index_of "$mark_file"); idx++)); do
                audit+=("$(binlog_name "$(binlog_prefix_of "$mark_file")" "$idx")")
            done
        else
            printf '  %sFAIL%s %s - no intact base dump at the remote can reach this mark, so its chain has nothing to replay from\n' "$c_red" "$c_reset" "$mark"
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
            elif [ "$(rem_sha256 "$iname" || true)" != "${isha%%:*}" ]; then
                printf '  %sFAIL%s %s - the remote'\''s bytes do not hash back to the mark'\''s inventory (rot, truncation or a partial upload - all shapeless at a binlog archive; only the hash sees them)\n' "$c_red" "$c_reset" "$iname"
                problems=$((problems + 1))
            fi
        done < <(printf '%s\n' "${audit[@]}" | LC_ALL=C sort -u)
        if [ "$problems" -eq "$before" ]; then
            printf '  %sOK%s   %s - base intact, every file the pair replays present and hashing true at the remote\n' "$c_green" "$c_reset" "$mark"
        fi
    done
    rm -rf "$tmp"

    printf '\n'
    if [ "$problems" -gt 0 ]; then
        die "REMOTE ARCHIVE CHECK FAILED: $problems problem(s). A disaster recovery from this remote would stitch, rot or stop short - this is the cheap day to find out."
    fi
    ok "the remote can prove every instant it claims (${#newest[@]} mark(s) audited)"
}

# --- verify ------------------------------------------------------------------

cleanup() {
    if [ -n "$PROBE" ] && [ "$KEEP_CONTAINER" -eq 0 ]; then
        eng_teardown "$PROBE"
    elif [ -n "$PROBE" ]; then
        warn "throwaway instance left in place: $PROBE"
    fi
}

cmd_verify() {
    need docker
    local kind
    [ -f "$BASE_MANIFEST" ] || die "base manifest not found: $BASE_MANIFEST"
    [ -f "$MARK_MANIFEST" ] || die "mark manifest not found: $MARK_MANIFEST"
    kind="$(json_str "$BASE_MANIFEST" kind)"
    [ "$kind" = "binlog-base" ] \
        || die "'$BASE_MANIFEST' is not a binlog-base manifest (kind '${kind:-none}') - pitr-* manifests verify with ./pitr.sh, dump manifests with ./verify.sh"
    kind="$(json_str "$MARK_MANIFEST" kind)"
    [ "$kind" = "binlog-mark" ] \
        || die "'$MARK_MANIFEST' is not a binlog-mark manifest (kind '${kind:-none}') - pass the instant to prove"

    local db base_db dir artefact anchor_file anchor_pos mark_file mark_pos
    db="$(json_str "$MARK_MANIFEST" database)"
    base_db="$(json_str "$BASE_MANIFEST" database)"
    [ "$db" = "$base_db" ] \
        || die "the base dump is of '$base_db' but the mark is of '$db' - these describe different databases"
    dir="$(cd "$(dirname "$BASE_MANIFEST")" && pwd)"
    artefact="$dir/$(json_str "$BASE_MANIFEST" artefact)"
    [ -f "$artefact" ] || die "artefact named by the base manifest is missing: $artefact"
    anchor_file="$(json_str "$BASE_MANIFEST" anchor_file)"
    anchor_pos="$(json_num "$BASE_MANIFEST" anchor_pos)"
    mark_file="$(json_str "$MARK_MANIFEST" mark_file)"
    mark_pos="$(json_num "$MARK_MANIFEST" mark_pos)"
    if [ -z "$anchor_file" ] || [ -z "$anchor_pos" ] || [ -z "$mark_file" ] || [ -z "$mark_pos" ]; then
        die "the manifests are missing binlog PITR fields - were they written by something else?"
    fi
    if [ -z "$IMAGE" ]; then
        IMAGE="mysql:$(json_str "$BASE_MANIFEST" server_version)"
    fi

    log "verifying that base + archived binlogs reproduce $mark_file:$mark_pos ($db)"

    # --- Gate 1: the base dump is byte-identical to what was taken -----------
    assert_pair_intact "$BASE_MANIFEST" "$artefact" "gate 1"
    ok "base dump matches its manifest ($(stat -c%s "$artefact") bytes, sha256 verified)"

    # --- Gate 2: the mark is reachable from this base -------------------------
    [ "$(binlog_prefix_of "$mark_file")" = "$(binlog_prefix_of "$anchor_file")" ] \
        || die "the mark lives in '$(binlog_prefix_of "$mark_file")' files but the anchor in '$(binlog_prefix_of "$anchor_file")' - two different servers wrote these; a replay across them is fiction"
    local a_idx m_idx
    a_idx=$(binlog_index_of "$anchor_file")
    m_idx=$(binlog_index_of "$mark_file")
    if [ "$m_idx" -lt "$a_idx" ] || { [ "$m_idx" -eq "$a_idx" ] && [ "$mark_pos" -lt "$anchor_pos" ]; }; then
        die "the mark ($mark_file:$mark_pos) predates the base's anchor ($anchor_file:$anchor_pos) - a replay rolls forward only, so this instant can never be reached from this base"
    fi
    ok "the mark sits in this base's future ($anchor_file:$anchor_pos .. $mark_file:$mark_pos)"

    # --- Gate 3: the chain exists AND holds the bytes the mark stood on ------
    # Continuity by name first (a hole would be STITCHED OVER silently -
    # measured), then every file re-hashed against the mark's inventory
    # (sizes vary by nature, so the hash carries all the weight).
    local -a inv_lines=()
    local line
    mapfile -t inv_lines < <(manifest_section "$MARK_MANIFEST" binlogs)
    [ "${#inv_lines[@]}" -gt 0 ] \
        || die "the mark records no binlog inventory - nothing can vouch for the chain; was this manifest written by something else?"
    local -A inv=()
    for line in "${inv_lines[@]}"; do
        inv["${line%%$'\t'*}"]="${line##*$'\t'}"
    done
    local idx name fsha problems=0 prefix
    prefix=$(binlog_prefix_of "$anchor_file")
    local -a replay_files=()
    for ((idx = a_idx; idx <= m_idx; idx++)); do
        name=$(binlog_name "$prefix" "$idx")
        replay_files+=("$name")
        if [ ! -e "$ARCHIVE_DIR/$name" ]; then
            printf '  %sFAIL%s missing %s - a replay would stitch over this hole with rc 0 (measured)\n' "$c_red" "$c_reset" "$name"
            problems=$((problems + 1))
            continue
        fi
        if [ -z "${inv[$name]:-}" ]; then
            printf '  %sFAIL%s %s - in the archive, but the mark'\''s inventory never stood on it\n' "$c_red" "$c_reset" "$name"
            problems=$((problems + 1))
            continue
        fi
        fsha=$(sha256_of "$ARCHIVE_DIR/$name")
        if [ "$fsha" != "${inv[$name]%%:*}" ]; then
            printf '  %sFAIL%s %s - these are not the bytes the mark stood on (rot or a partial copy; mysqlbinlog would replay them anyway - measured)\n' "$c_red" "$c_reset" "$name"
            problems=$((problems + 1))
        fi
    done
    [ "$problems" -eq 0 ] \
        || die "BINLOG VERIFICATION FAILED: $problems problem(s) in the chain $anchor_file .. $mark_file - refusing to replay what the inventory already refutes"
    ok "chain $anchor_file .. $mark_file is present and hashes back to the mark's inventory (${#replay_files[@]} file(s))"

    # --- Gate 4: the replay ---------------------------------------------------
    # First, the tool: it must be the server's own major - a version-skewed
    # mysqlbinlog reading newer binlogs is exactly the kind of quiet risk this
    # repo exists to kill. And it must actually RUN inside the image it will
    # be mounted into (the static-age lesson: prove it, never assume it).
    local tool_ver want_ver
    tool_ver=$(docker run --rm -v "$TOOLS_DIR/mysqlbinlog:/usr/bin/mysqlbinlog:ro" --entrypoint mysqlbinlog "$IMAGE" --version 2>/dev/null | grep -oE 'Ver [0-9]+\.[0-9]+' | awk '{print $2}') \
        || true
    want_ver="$(json_str "$BASE_MANIFEST" server_version)"
    [ -n "$tool_ver" ] \
        || die "the mysqlbinlog in $TOOLS_DIR does not run inside $IMAGE - the drill needs the official linux build (see the header)"
    [ "$tool_ver" = "$want_ver" ] \
        || die "mysqlbinlog is $tool_ver but the base was taken from a $want_ver server - a version-skewed replay is a guess, and this tool does not guess"

    PROBE="bv-binlog-$$"
    trap cleanup EXIT
    log "booting a throwaway $IMAGE as '$PROBE'"
    eng_boot "$PROBE" "$db" "$IMAGE"
    eng_wait_ready "$PROBE"
    [ "$(eng_count_tables "$PROBE" "$db" | tr -d '\n')" = "0" ] \
        || die "the throwaway instance is not empty - refusing an ambiguous restore (measured on the dump side)"

    log "loading the base dump"
    docker exec -e MYSQL_PWD=verify -i "$PROBE" mysql -uroot < "$artefact" > /dev/null 2>&1 \
        || die "the base dump did not load cleanly - the replay has nothing sane to stand on"

    # --verify-binlog-checksum is NOT optional: without it a corrupted event
    # sails into the replay with rc 0 (measured). The inventory above already
    # proved these bytes, so a failure here is mysqlbinlog disagreeing with
    # the mark - worth dying on either way.
    log "replaying ${#replay_files[@]} file(s) to $mark_file:$mark_pos (checksums verified)"
    local replay_sql
    replay_sql=$(mktemp)
    if ! docker run --rm -v "$ARCHIVE_DIR:/archive:ro" \
            -v "$TOOLS_DIR/mysqlbinlog:/usr/bin/mysqlbinlog:ro" \
            --entrypoint sh "$IMAGE" \
            -c "cd /archive && mysqlbinlog --verify-binlog-checksum --start-position=$anchor_pos --stop-position=$mark_pos $(printf '%s ' "${replay_files[@]}")" \
            > "$replay_sql" 2> "$replay_sql.err"; then
        sed 's/^/      /' "$replay_sql.err" | head -5
        rm -f "$replay_sql" "$replay_sql.err"
        die "mysqlbinlog refused the chain - the history cannot even be decoded"
    fi
    rm -f "$replay_sql.err"
    if ! docker exec -e MYSQL_PWD=verify -i "$PROBE" mysql -uroot "$db" < "$replay_sql" > /dev/null 2> "$replay_sql.apply-err"; then
        sed 's/^/      /' "$replay_sql.apply-err" | head -5
        rm -f "$replay_sql" "$replay_sql.apply-err"
        die "the replay did not apply cleanly - an ambiguous half-replayed instance is not a recovery"
    fi
    rm -f "$replay_sql" "$replay_sql.apply-err"

    # --- Gate 5: ARRIVAL, proven by content -----------------------------------
    # The measured inversion this script exists for: a --stop-position past
    # the end of history exits 0 with an empty stderr. MySQL will not say
    # whether the replay ARRIVED - so the mark's own fingerprints do.
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
        die "BINLOG VERIFICATION FAILED: $failures problem(s) across $checked table(s). The replay ran clean and STILL did not reproduce the instant - which is exactly why arrival is proven by content, not by exit codes (measured)."
    fi

    local write_problems=0
    writable_probe_report "$PROBE" "$db" || write_problems=$?
    if [ "$write_problems" -gt 0 ]; then
        die "BINLOG VERIFICATION FAILED: $write_problems write problem(s) - the instant came back and the next INSERT collides."
    fi

    ok "BINLOG PITR VERIFIED: base dump + archived binlogs reproduce $mark_file:$mark_pos exactly ($checked table(s), byte-for-byte)."
}

main() {
    need sha256sum
    # MySQL by declaration, not by detection - the measured animal is
    # different enough from WAL archiving that sharing pitr.sh's interface
    # would blur every one of its promises. See the header.
    load_engine mysql
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
