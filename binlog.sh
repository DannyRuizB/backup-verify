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
#   * the binlog is your rows: a seeded email reads IN CLEAR from the raw
#     file with one grep (measured - ROW format writes the row itself, and
#     8.4 neither compresses nor encrypts it by default). So the archive can
#     be encrypted end to end: mark encrypts each file as it archives it,
#     and where a PLAIN binlog truncated at an event boundary decodes clean
#     (the shapeless lie above), truncated ciphertext dies loudly at every
#     offset (measured) - encryption hands this archive the noisy truncation
#     it never had.
#   * GTID mode changes the replay's rules, so it was measured before it was
#     claimed: a GTID replay on a gtid_mode=OFF throwaway dies (ERROR 1781);
#     a REPEATED replay on a GTID throwaway exits 0, says nothing and
#     applies NOTHING (auto-skip - rc 0 means even less than before); and a
#     dump stripped of its GTID_PURGED re-executes history it already
#     contains ("Table already exists" - the purged set IS the GTID world's
#     anchor). GTID is read from the server and recorded in the manifests,
#     never taken from a flag: verify boots the throwaway to match, refuses
#     a pair whose halves disagree about the mode, and proves the replay's
#     history with GTID_SUBSET on top of the fingerprints.
#
# Usage:
#   ./binlog.sh base   --container NAME --db NAME [--out DIR]
#                      [--recipient KEY --identity FILE]
#   ./binlog.sh mark   --container NAME --db NAME --archive DIR [--out DIR]
#                      [--recipient KEY --identity FILE]
#   ./binlog.sh check  --archive DIR [--container NAME [--identity FILE]]
#   ./binlog.sh check  --remote REMOTE [--db NAME]
#   ./binlog.sh verify --base FILE --mark FILE --archive DIR --tools DIR
#                      [--image IMAGE] [--identity FILE]
#   ./binlog.sh push   --base FILE --mark FILE --archive DIR --remote REMOTE [--keep N]
#   ./binlog.sh pull   --db NAME --remote REMOTE --archive DIR [--out DIR]
#   ./binlog.sh prune  --db NAME --out DIR --archive DIR --keep N
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
#   --recipient KEY   (base, mark) encrypt with age; KEY is an age public key
#                     or a file of them. Requires --identity: base cannot even
#                     read its own anchor without it (the anchor lives INSIDE
#                     the dump), and mark decrypts every ciphertext it archives
#                     back and holds it against the server's own bytes - the
#                     key gets proven today, not on the day of the fire.
#   --identity FILE   age identity. Required by base/mark --recipient, by
#                     verify when the pair is encrypted, and by
#                     check --container over an encrypted archive. push and
#                     pull never take a key: they move opaque ciphertext.
#   --label TEXT      extra label in the base artefact name
#   --timeout SECONDS how long mark/verify wait (default 90)
#   --keep-container  leave the throwaway instance running (for debugging)
#   --remote REMOTE   user@host:/path (ssh) or /path (a mounted disk) -
#                     same remotes, same rem_* modules as offsite.sh
#   --ssh-opts OPTS   extra ssh options, e.g. "-p 2222 -i key" (ssh remotes)
#   --keep N          (push) keep the newest N anchored dumps at the remote;
#                     (prune) the same line drawn LOCALLY - newest N dumps in
#                     --out, everything below the oldest kept dump's anchor
#                     file retired from --archive and --out. N >= 1 for prune.
#                     Original push wording: keep the newest N anchored dumps
#                     at the remote and drop only what no kept dump can
#                     replay: older dumps, the binlog files below the oldest
#                     kept dump's anchor, the marks only they could prove.
#                     Decided by NAME and binlog arithmetic - never by mtime
#                     or by counting files (pitr.sh's rule, binlog names).
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
KEEP=0
TOOLS_DIR=""
PROBE=""
REMOTE=""
SSH_OPTS_STR=""
RECIPIENT=""
IDENTITY=""
KEYDIR=""

usage() { sed -n '2,/^#   -h, --help/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
    case "${1:-}" in
        base|mark|check|verify|push|pull|prune) SUBCMD="$1"; shift;;
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
            --keep)           KEEP="${2:-}"; shift 2;;
            --ssh-opts)       SSH_OPTS_STR="${2:-}"; shift 2;;
            --recipient)      RECIPIENT="${2:-}"; shift 2;;
            --identity)       IDENTITY="${2:-}"; shift 2;;
            --keep-container) KEEP_CONTAINER=1; shift;;
            -h|--help)        usage 0;;
            *)                printf 'unknown option: %s\n' "$1" >&2; usage 1;;
        esac
    done
    case "$TIMEOUT" in
        ''|*[!0-9]*) die "--timeout must be a non-negative integer, got '$TIMEOUT'";;
    esac
    case "$KEEP" in
        ''|*[!0-9]*) die "--keep must be a non-negative integer, got '$KEEP'";;
    esac
    [ "$KEEP" -eq 0 ] || [ "$SUBCMD" = push ] \
        || [ "$SUBCMD" = prune ] || die "--keep belongs to push (remote retention) and prune (local retention)"
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
    if [ -n "$IDENTITY" ] && [ ! -f "$IDENTITY" ]; then
        die "identity file not found: $IDENTITY"
    fi
    case "$SUBCMD" in
        base|mark)
            [ -n "$CONTAINER" ] || die "$SUBCMD needs --container (where the database lives)"
            [ -n "$DB" ] || die "$SUBCMD needs --db"
            if [ -n "$RECIPIENT" ] && [ -z "$IDENTITY" ]; then
                if [ "$SUBCMD" = base ]; then
                    die "base --recipient requires --identity: the replay anchor lives INSIDE the dump, so a base that cannot read its own ciphertext cannot even write its manifest - and the key gets proven today, not on the day of the fire"
                fi
                die "mark --recipient requires --identity: every ciphertext this mark archives is decrypted back and held against the server's own bytes - an archived ciphertext nothing has ever decrypted is a hope, and the key gets proven today"
            fi
            if [ -n "$IDENTITY" ] && [ -z "$RECIPIENT" ]; then
                die "--identity only makes sense with --recipient here (there is nothing to decrypt)"
            fi;;
        verify)
            [ -n "$BASE_MANIFEST" ] || die "verify needs --base (the base-dump manifest)"
            [ -n "$MARK_MANIFEST" ] || die "verify needs --mark (the instant to prove)"
            [ -n "$TOOLS_DIR" ] || die "verify needs --tools (a directory holding mysqlbinlog - the official image ships none; see the header)"
            [ -x "$TOOLS_DIR/mysqlbinlog" ] || die "no executable mysqlbinlog in $TOOLS_DIR"
            [ -z "$RECIPIENT" ] || die "--recipient is a backup-time option - verify only ever needs --identity";;
        check)
            [ -z "$RECIPIENT" ] || die "--recipient is a backup-time option - check only ever needs --identity";;
        push|pull)
            # Names and hashes are opaque at the remote on purpose: ciphertext
            # travels, the key never does. A key offered here is a key waved
            # around for nothing.
            if [ -n "$RECIPIENT" ] || [ -n "$IDENTITY" ]; then
                die "$SUBCMD moves opaque ciphertext - no key is needed, so none is accepted"
            fi;;
    esac
    case "$SUBCMD" in
        push)
            [ -n "$BASE_MANIFEST" ] || die "push needs --base (the base-dump manifest)"
            [ -n "$MARK_MANIFEST" ] || die "push needs --mark (the instant the remote must be able to prove)"
            [ -n "$REMOTE" ] || die "push needs --remote (where the copy is going)";;
        pull)
            [ -n "$DB" ] || die "pull needs --db (which database to bring back)"
            [ -n "$REMOTE" ] || die "pull needs --remote (where the copy lives)";;
        prune)
            [ -n "$DB" ] || die "prune needs --db (whose dumps and marks to count)"
            [ -n "$OUT_DIR" ] || die "prune needs --out (where the dumps live)"
            [ -n "$ARCHIVE_DIR" ] || die "prune needs --archive (where the binlogs live)"
            [ "$KEEP" -ge 1 ] || die "prune needs --keep N with N >= 1 (keeping nothing is not retention, it is deletion)";;
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

# "yes" when the server runs with GTIDs, "no" otherwise. Recorded in every
# manifest this script writes: verify must boot a throwaway that matches
# (measured: a GTID replay dies on a gtid_mode=OFF server, ERROR 1781).
server_gtid_mode() {
    case "$(eng_query "$CONTAINER" mysql 'SELECT @@gtid_mode;' | tr -d '\n')" in
        ON) printf 'yes';;
        *)  printf 'no';;
    esac
}

# The server's executed GTID set, on one line: the batch client escapes the
# set's internal newlines as literal backslash-n (measured), stripped here so
# the value survives a JSON string.
server_gtid_executed() {
    eng_query "$1" mysql 'SELECT @@gtid_executed;' | tr -d '\n' | sed 's/\\n//g'
}

container_sha256() {
    docker exec "$CONTAINER" sha256sum "/var/lib/mysql/$1" < /dev/null 2>/dev/null | awk '{print $1}'
}

# The archive decides its own form: every file is NAME (plain) or NAME.age
# (encrypted by the mark that archived it). Mixed contents mean two
# differently configured marks have written here, and a replay through a
# mixed chain is a coin toss - the WAL archive's rule, applied here.
archive_binlog_suffix() {
    local plain enc
    plain=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -printf '%f\n' \
        | { grep -cE '^[A-Za-z0-9_-]+\.[0-9]{6,}$' || true; })
    enc=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -printf '%f\n' \
        | { grep -cE '^[A-Za-z0-9_-]+\.[0-9]{6,}\.age$' || true; })
    if [ "$plain" -gt 0 ] && [ "$enc" -gt 0 ]; then
        die "the archive holds BOTH plain and .age binlogs - two differently configured marks have written here, and a replay through a mixed chain is a coin toss; refusing"
    fi
    if [ "$enc" -gt 0 ]; then printf '%s' "$ENC_SUFFIX"; fi
}

# The recipient flags as an ARRAY, filled in place: a shell function cannot
# hand back a list through a string (measured elsewhere in this repo - a
# missing trailing newline made `read` drop a line and age got a bare -r).
set_recip_args() {
    if [ -f "$RECIPIENT" ]; then
        RECIP_ARGS=(-R "$RECIPIENT")   # a file of recipients
    else
        RECIP_ARGS=(-r "$RECIPIENT")   # an inline age1... public key
    fi
}

# sha256 of what an archived ciphertext decrypts back to. A failed decrypt
# hashes as the empty stream - never equal to any real file's hash, so the
# comparison that follows fails honestly rather than exploding here.
decrypted_sha256() {
    { age -d -i "$IDENTITY" "$1" 2>/dev/null || true; } | sha256sum | awk '{print $1}'
}

# --- base --------------------------------------------------------------------

cmd_base() {
    need docker
    eng_preflight "$CONTAINER"
    assert_binlog_on
    mkdir -p "$OUT_DIR"

    local stamp base artefact manifest version gtid_mode
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    base="${DB}_${stamp}${LABEL:+_$LABEL}_binlogbase"
    artefact="$OUT_DIR/$base.sql"
    manifest="$OUT_DIR/$base.json"
    version=$(eng_query "$CONTAINER" mysql 'SELECT VERSION();' | tr -d '\n')
    gtid_mode=$(server_gtid_mode)

    log "dumping '$DB' with its replay anchor (mysqldump --single-transaction --source-data)"
    trap 'rm -f -- "$artefact"' ERR
    # --source-data=2 writes the anchor as a comment: the binlog file and
    # position this dump is consistent AT. Without it the dump is the
    # tutorial's dump, and a replay has nowhere honest to start (measured:
    # starting from the beginning re-runs history the dump already contains).
    if [ -n "$RECIPIENT" ]; then
        encryption_available || die "--recipient given but 'age' is not installed"
        artefact="$artefact$ENC_SUFFIX"
        RECIP_ARGS=()
        set_recip_args
        # The family pipe: the plaintext dump NEVER touches the disk -
        # mysqldump streams straight into age - and PIPESTATUS names which
        # side broke, because age exits 0 over a failed dump's empty stream
        # (measured: a valid ~200-byte .age that decrypts to nothing).
        set +e
        docker exec -e MYSQL_PWD=verify "$CONTAINER" mysqldump -uroot \
            --single-transaction --source-data=2 --routines --events --triggers \
            --databases "$DB" < /dev/null 2> /dev/null | age "${RECIP_ARGS[@]}" > "$artefact"
        local -a dst=("${PIPESTATUS[@]}")
        set -e
        if [ "${dst[0]}" -ne 0 ] || [ "${dst[1]}" -ne 0 ]; then
            rm -f -- "$artefact"
            die "encrypted dump failed (mysqldump rc=${dst[0]}, age rc=${dst[1]}) - no artefact was left behind"
        fi
    else
        docker exec -e MYSQL_PWD=verify "$CONTAINER" mysqldump -uroot \
            --single-transaction --source-data=2 --routines --events --triggers \
            --databases "$DB" < /dev/null 2> /dev/null > "$artefact" \
            || { rm -f -- "$artefact"; die "mysqldump failed - no artefact was left behind"; }
    fi
    trap - ERR

    local size floor="${ENG_MIN_ARTEFACT_BYTES:-$MIN_ARTEFACT_BYTES}"
    size=$(stat -c%s "$artefact")
    if [ "$size" -lt "$floor" ]; then
        rm -f -- "$artefact"
        die "base dump is only ${size} bytes (< $floor) - refusing to call that a base"
    fi
    local anchor_line anchor_file anchor_pos purged_in_dump
    if [ -n "$RECIPIENT" ]; then
        # Two reads through the identity, and both are the key being proven
        # TODAY: does the dump parse to its end, and what is its anchor -
        # which lives INSIDE the ciphertext, so a base --recipient without
        # the key could not even write its own manifest.
        set +e
        age -d -i "$IDENTITY" "$artefact" 2>/dev/null | eng_archive_parses "$CONTAINER"
        local -a pst=("${PIPESTATUS[@]}")
        set -e
        if [ "${pst[0]}" -ne 0 ]; then
            rm -f -- "$artefact"
            die "the artefact does not decrypt with the given identity (age rc=${pst[0]}) - removed"
        fi
        if [ "${pst[1]}" -ne 0 ]; then
            rm -f -- "$artefact"
            die "the decrypted dump does not parse as a complete mysqldump (no trailing 'Dump completed') - removed"
        fi
        # awk reads the WHOLE stream: grep -m1 would close the pipe early and
        # hand age a SIGPIPE that pipefail turns into a silent death. The one
        # pass also answers whether the dump carries its GTID_PURGED set.
        local probe_out
        probe_out=$(age -d -i "$IDENTITY" "$artefact" 2>/dev/null \
            | awk '/CHANGE REPLICATION SOURCE TO/ && !found { line = $0; found = 1 }
                   /GTID_PURGED/ { purged = 1 }
                   END { print (purged ? "yes" : "no") "\t" line }')
        purged_in_dump="${probe_out%%$'\t'*}"
        anchor_line="${probe_out#*$'\t'}"
    else
        if ! eng_archive_parses "$CONTAINER" < "$artefact"; then
            rm -f -- "$artefact"
            die "the base dump does not parse as a complete mysqldump (no trailing 'Dump completed') - removed"
        fi
        anchor_line=$(grep -m1 'CHANGE REPLICATION SOURCE TO' "$artefact" || true)
        purged_in_dump=$(grep -q 'GTID_PURGED' "$artefact" && echo yes || echo no)
    fi
    # On a GTID server the purged set IS the second anchor: a dump stripped
    # of it re-executes history it already contains (measured: the replay
    # died on "Table 'customers' already exists" after happily re-running
    # every pre-dump transaction).
    if [ "$gtid_mode" = yes ] && [ "$purged_in_dump" != yes ]; then
        rm -f -- "$artefact"
        die "the server runs with GTIDs but the dump carries no GTID_PURGED set - a replay over it would RE-EXECUTE history the dump already contains (measured); removed"
    fi
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
        # Recorded so verify knows it needs an identity, and so a human can
        # tell WHICH key opens this file. A recipient is a public key: safe here.
        printf '  "encryption": "%s",\n' "$([ -n "$RECIPIENT" ] && echo age || echo none)"
        printf '  "recipient": "%s",\n' "$([ -f "$RECIPIENT" ] && basename "$RECIPIENT" || printf '%s' "$RECIPIENT")"
        printf '  "server_version": "%s",\n' "$(printf '%s' "$version" | cut -d. -f1-2)"
        # verify boots the throwaway to MATCH this, and refuses a pair whose
        # halves disagree - a GTID replay on a plain server dies (measured).
        printf '  "gtid_mode": "%s",\n' "$gtid_mode"
        printf '  "anchor_file": "%s",\n' "$anchor_file"
        printf '  "anchor_pos": %s\n' "$anchor_pos"
        printf '}\n'
    } > "$manifest"

    if [ -n "$RECIPIENT" ]; then
        ok "base dump: $artefact ($size ciphertext bytes; decrypts with the given identity and parses; replay starts at $anchor_file:$anchor_pos)"
    else
        ok "base dump: $artefact ($size bytes, parses, replay starts at $anchor_file:$anchor_pos)"
    fi
    ok "a base alone is one instant - name the instants it must roll forward to:"
    printf '      ./binlog.sh mark --container %s --db %s --archive ARCHIVE_DIR\n' "$CONTAINER" "$DB"
}

# --- mark --------------------------------------------------------------------

cmd_mark() {
    need docker
    eng_preflight "$CONTAINER"
    assert_binlog_on
    mkdir -p "$OUT_DIR"

    # The archive's existing form binds this mark: encrypting into a plain
    # archive, or archiving plain into an encrypted one, would leave behind
    # the mixed chain no replay can be trusted through.
    local sfx
    sfx=$(archive_binlog_suffix)   # dies loudly on a MIXED archive
    if [ -n "$RECIPIENT" ]; then
        encryption_available || die "--recipient given but 'age' is not installed"
        if [ -z "$sfx" ] && find "$ARCHIVE_DIR" -maxdepth 1 -type f -printf '%f\n' \
                | grep -qE '^[A-Za-z0-9_-]+\.[0-9]{6,}$'; then
            die "this archive already holds PLAIN binlogs and the mark was told to encrypt - a mixed archive is a coin toss; refusing"
        fi
        sfx="$ENC_SUFFIX"
        RECIP_ARGS=()
        set_recip_args
    elif [ -n "$sfx" ]; then
        die "this archive is encrypted ($ENC_SUFFIX) and the mark was given no --recipient - a mixed archive is a coin toss; refusing"
    fi

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

    local mark_file mark_pos quiesced gtid_mode gtid_executed=""
    gtid_mode=$(server_gtid_mode)
    if [ "$gtid_mode" = yes ]; then
        # This set is the GTID name of the instant, and verify holds the
        # recovered history against it with GTID_SUBSET - because with GTIDs
        # a replay that applies NOTHING also exits 0 (measured: auto-skip is
        # silent). Read BEFORE the position on purpose: if a write straddles
        # the two reads, a set read AFTER would contain a transaction the
        # replay to the mark can never apply, and the history gate would
        # fail a healthy pair - read first, the set can only trail the
        # position, and the subset still holds.
        gtid_executed=$(server_gtid_executed "$CONTAINER")
    fi
    read -r mark_file mark_pos <<< "$(binlog_status)"
    if [ "$pos_before" = "$mark_file $mark_pos" ]; then
        quiesced="yes"
    else
        quiesced="no"
        warn "the binlog advanced while fingerprinting ($pos_before -> $mark_file $mark_pos): writes are landing, and the fingerprints and the position may straddle them"
    fi
    log "the instant is $mark_file:$mark_pos${gtid_executed:+ (executed GTIDs: $gtid_executed)}"

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
    #
    # With --recipient the copy leaves the server ALREADY encrypted: docker
    # exec streams the closed file straight into age, so the plaintext never
    # touches the host's disk - and the round trip is the copy check AND the
    # key being proven today: what was just encrypted must decrypt back to
    # exactly the bytes the server holds. The inventory then hashes the
    # CIPHERTEXT as archived: age is non-deterministic (measured: the same
    # binlog encrypted twice gives different bytes, same size), so
    # re-encrypting can never reproduce an archived file - the archived file
    # IS the identity, and only the inventory can vouch for it.
    local name aname src_sha dst_sha inv_sha archived=0 already=0
    local inv_block="" first_inv=1
    while IFS=$'\t' read -r name _; do
        [ -n "$name" ] || continue
        [ "$(binlog_index_of "$name")" -le "$(binlog_index_of "$mark_file")" ] || continue
        src_sha=$(container_sha256 "$name")
        [ -n "$src_sha" ] || die "could not hash $name inside the container"
        aname="$name$sfx"
        if [ -e "$ARCHIVE_DIR/$aname" ]; then
            if [ -n "$RECIPIENT" ]; then
                dst_sha=$(decrypted_sha256 "$ARCHIVE_DIR/$aname")
                [ "$dst_sha" = "$src_sha" ] \
                    || die "$aname is already archived but does not decrypt back to the server's bytes (decrypted $dst_sha, server $src_sha) - a closed binlog is immutable, so one of the two has rotted (or this is another key's ciphertext); refusing to write a mark over it"
            else
                dst_sha=$(sha256_of "$ARCHIVE_DIR/$aname")
                [ "$dst_sha" = "$src_sha" ] \
                    || die "$name is already archived with DIFFERENT bytes (archive $dst_sha, server $src_sha) - a closed binlog is immutable, so one of the two has rotted; refusing to write a mark over it"
            fi
            already=$((already + 1))
        else
            if [ -n "$RECIPIENT" ]; then
                set +e
                docker exec "$CONTAINER" cat "/var/lib/mysql/$name" < /dev/null 2>/dev/null \
                    | age "${RECIP_ARGS[@]}" > "$ARCHIVE_DIR/.$aname.copying"
                local -a cst=("${PIPESTATUS[@]}")
                set -e
                if [ "${cst[0]}" -ne 0 ] || [ "${cst[1]}" -ne 0 ]; then
                    rm -f "$ARCHIVE_DIR/.$aname.copying"
                    die "could not stream $name out of the container encrypted (cat rc=${cst[0]}, age rc=${cst[1]}) - the partial was removed"
                fi
                dst_sha=$(decrypted_sha256 "$ARCHIVE_DIR/.$aname.copying")
                if [ "$dst_sha" != "$src_sha" ]; then
                    rm -f "$ARCHIVE_DIR/.$aname.copying"
                    die "$name did not survive the encrypt-archive round trip (server $src_sha, decrypted copy $dst_sha) - the partial was removed"
                fi
            else
                docker cp "$CONTAINER:/var/lib/mysql/$name" "$ARCHIVE_DIR/.$aname.copying" > /dev/null 2>&1 \
                    || die "could not copy $name out of the container"
                dst_sha=$(sha256_of "$ARCHIVE_DIR/.$aname.copying")
                if [ "$dst_sha" != "$src_sha" ]; then
                    rm -f "$ARCHIVE_DIR/.$aname.copying"
                    die "$name did not survive the copy (server $src_sha, copy $dst_sha) - the partial was removed"
                fi
            fi
            mv "$ARCHIVE_DIR/.$aname.copying" "$ARCHIVE_DIR/$aname"
            chmod 644 "$ARCHIVE_DIR/$aname"
            archived=$((archived + 1))
        fi
        if [ -n "$RECIPIENT" ]; then
            inv_sha=$(sha256_of "$ARCHIVE_DIR/$aname")
        else
            inv_sha="$src_sha"
        fi
        [ "$first_inv" -eq 1 ] || inv_block+=$',\n'
        first_inv=0
        inv_block+=$(printf '    "%s": "%s:%s"' "$aname" "$inv_sha" "$(stat -c%s "$ARCHIVE_DIR/$aname")")
    done < <(eng_query "$CONTAINER" mysql 'SHOW BINARY LOGS;' | awk -F'\t' '{print $1 "\t" $2}')
    printf '%s' "$inv_block" | grep -qF "\"$mark_file$sfx\":" \
        || die "the mark's own file $mark_file was never archived - refusing to write a mark that cannot be replayed to"
    if [ -n "$RECIPIENT" ]; then
        ok "archived $archived file(s) as age ciphertext (round trip proven against the server's bytes), $already already archived and decrypting true"
    else
        ok "archived $archived file(s), $already already archived and hashing true"
    fi

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
        printf '  "gtid_mode": "%s",\n' "$gtid_mode"
        printf '  "gtid_executed": "%s",\n' "$gtid_executed"
        # Recorded so verify, push, pull and check all learn the archive's
        # form from the manifest, never by sniffing directories.
        printf '  "binlogs_encrypted": "%s",\n' "$([ -n "$RECIPIENT" ] && echo yes || echo no)"
        printf '  "recipient": "%s",\n' "$([ -f "$RECIPIENT" ] && basename "$RECIPIENT" || printf '%s' "$RECIPIENT")"
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
    # The archive names its own form; a mixed one is refused before anything
    # else is judged. When encrypted, all arithmetic runs on the STRIPPED
    # name - the counter does not care what wrapping the bytes wear.
    local sfx
    sfx=$(archive_binlog_suffix)   # dies loudly on a MIXED archive

    local problems=0 name prefix=""
    local -a files=() strays=()
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ -n "$sfx" ] && [[ "$name" =~ ^[A-Za-z0-9_-]+\.[0-9]{6,}\.age$ ]]; then
            name="${name%"$sfx"}"
        elif [ -n "$sfx" ] || ! [[ "$name" =~ ^[A-Za-z0-9_-]+\.[0-9]{6,}$ ]]; then
            strays+=("$name")
            continue
        fi
        files+=("$name")
        if [ -z "$prefix" ]; then
            prefix=$(binlog_prefix_of "$name")
        elif [ "$prefix" != "$(binlog_prefix_of "$name")" ]; then
            die "the archive holds binlogs with TWO prefixes ('$prefix' and '$(binlog_prefix_of "$name")') - two servers have written here, and a replay across them is fiction; refusing"
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
        if [ ! -e "$ARCHIVE_DIR/$name$sfx" ]; then
            printf '  %sFAIL%s missing %s - the chain is broken here, and a replay would STITCH OVER the hole silently (measured)\n' \
                "$c_red" "$c_reset" "$name$sfx"
            problems=$((problems + 1))
        fi
    done

    # With the source at hand: every closed file the server still has, that
    # the archive also has, must match byte for byte - and closed files the
    # archive does NOT have yet are named, because MySQL will not archive
    # them for you (there is no archive_command; the next mark does it).
    if [ -n "$CONTAINER" ]; then
        if [ -n "$sfx" ]; then
            # Ciphertext cannot be held against the server's bytes by eye:
            # the comparison runs through the key, or it does not run.
            [ -n "$IDENTITY" ] \
                || die "this archive is encrypted - comparing it against the server needs --identity; without the key this check would be a guess, and this tool does not guess"
            encryption_available || die "the archive is encrypted but 'age' is not installed"
        fi
        eng_preflight "$CONTAINER"
        assert_binlog_on
        local current_file src_sha dst_sha unarchived=0
        read -r current_file _ <<< "$(binlog_status)"
        while IFS=$'\t' read -r name _; do
            [ -n "$name" ] || continue
            [ "$name" != "$current_file" ] || continue   # the active file is still growing
            if [ -e "$ARCHIVE_DIR/$name$sfx" ]; then
                src_sha=$(container_sha256 "$name")
                if [ -n "$sfx" ]; then
                    dst_sha=$(decrypted_sha256 "$ARCHIVE_DIR/$name$sfx")
                else
                    dst_sha=$(sha256_of "$ARCHIVE_DIR/$name")
                fi
                if [ "$src_sha" != "$dst_sha" ]; then
                    printf '  %sFAIL%s %s - the archived copy does not %s the server'\''s bytes (one of the two has rotted)\n' \
                        "$c_red" "$c_reset" "$name$sfx" "$([ -n "$sfx" ] && echo 'decrypt back to' || echo 'match')"
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
    ok "archive is continuous: ${#files[@]} binlog(s)${sfx:+ (age ciphertext)}, $prefix.$(printf '%06d' "$i0") .. $prefix.$(printf '%06d' "$i1")"
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
    # An encrypted chain ships as-is: the inventory hashes are OF the
    # ciphertext, so nothing here needs a key - and none is accepted.
    local sfx=""
    [ "$(json_str "$MARK_MANIFEST" binlogs_encrypted)" != "yes" ] || sfx="$ENC_SUFFIX"
    local idx name prefix
    prefix=$(binlog_prefix_of "$anchor_file")
    local -a to_ship=()
    for ((idx = a_idx; idx <= m_idx; idx++)); do
        name="$(binlog_name "$prefix" "$idx")$sfx"
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
    ok "PUSHED: $pushed file(s) shipped, $skipped already proven at the remote - it can now prove $mark_file:$mark_pos${sfx:+ (ciphertext end to end; the key never travelled)}"
    [ "$KEEP" -eq 0 ] || prune_remote_binlog "$db"
}

# --- retention at the remote --------------------------------------------------

# pitr.sh's rule with binlog names: a binlog remote is CHAINS, not files. Every
# file there is either part of a chain some kept anchored dump can replay, or
# dead weight, and the line between the two is one number - the anchor file of
# the OLDEST KEPT dump. Dumps are counted by NAME (the stamp sorts; mtime is
# upload time), and everything below that anchor is unreachable from every
# kept dump: the older dumps and their manifests, the binlog files only they
# needed, the marks only they could prove. A mark IN the anchor file is kept
# (its position may still precede the anchor, and a file is the unit here).
# Runs only after the mark landed, so a prune never precedes the receipt.
prune_remote_binlog() {
    local db="$1" listing tmp total
    local -a bases=() drop=()
    listing=$(rem_list)
    mapfile -t bases < <(printf '%s\n' "$listing" | grep -E "^${db}_.*_binlogbase\.json$" | LC_ALL=C sort || true)
    total=${#bases[@]}
    if [ "$total" -le "$KEEP" ]; then
        ok "retention: $total anchored dump(s) at the remote, keeping up to $KEEP - nothing to drop"
        return 0
    fi
    drop=("${bases[@]:0:$((total - KEEP))}")
    local oldest_kept="${bases[$((total - KEEP))]}"
    tmp=$(mktemp -d)
    rem_get "$oldest_kept" "$tmp/oldest_kept.json" \
        || { rm -rf "$tmp"; die "retention: could not read $oldest_kept back from the remote - nothing was dropped"; }
    local cut_file cut_prefix cut_idx
    cut_file="$(json_str "$tmp/oldest_kept.json" anchor_file)"
    if [ -z "$cut_file" ]; then
        rm -rf "$tmp"
        die "retention: $oldest_kept carries no anchor_file - refusing to guess where the line is; nothing was dropped"
    fi
    cut_prefix=$(binlog_prefix_of "$cut_file")
    cut_idx=$(binlog_index_of "$cut_file")

    local name aname bare mfile idx removed_bases=0 removed_files=0 removed_marks=0
    for name in "${drop[@]}"; do
        if rem_get "$name" "$tmp/drop.json" 2>/dev/null; then
            aname="$(json_str "$tmp/drop.json" artefact)"
            [ -z "$aname" ] || rem_delete "$aname"
        else
            warn "retention: could not read $name back - dropping the manifest only, its artefact may linger"
        fi
        rem_delete "$name"
        removed_bases=$((removed_bases + 1))
        warn "retention: removed anchored dump $name (and its artefact) - every kept dump is newer"
    done
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        bare="${name%.age}"
        case "$bare" in
            "${db}_"*_binlogmark.json)
                rem_get "$name" "$tmp/mark.json" 2>/dev/null || continue
                mfile="$(json_str "$tmp/mark.json" mark_file)"
                [ -n "$mfile" ] || continue
                [ "$(binlog_prefix_of "$mfile")" = "$cut_prefix" ] || continue
                if [ "$(binlog_index_of "$mfile")" -lt "$cut_idx" ]; then
                    rem_delete "$name"
                    removed_marks=$((removed_marks + 1))
                    warn "retention: removed mark $name - it points below $cut_file, where no kept dump can reach"
                fi;;
            "$cut_prefix".*)
                idx="${bare##*.}"
                [[ "$idx" =~ ^[0-9]+$ ]] || continue
                if [ "$(binlog_index_of "$bare")" -lt "$cut_idx" ]; then
                    rem_delete "$name"
                    removed_files=$((removed_files + 1))
                fi;;
        esac
    done <<< "$listing"
    rm -rf "$tmp"
    ok "retention: kept the newest $KEEP anchored dump(s), line drawn at $cut_file - dropped $removed_bases dump(s), $removed_files binlog file(s), $removed_marks mark(s) no kept dump could replay"
}

# --- prune (local retention) ------------------------------------------------------

# The archive grows until the disk says otherwise; the answer is push --keep's
# line drawn at home. Keep the newest N anchored dumps in --out, and retire
# everything BELOW the oldest kept dump's anchor file: the older dumps and their
# artefacts, the marks only they could prove, and the archived binlogs (same
# prefix, lower index) no kept dump can replay. Binlogs in the archive are
# host-readable (mark copies them there), so no sidecar is needed - the files
# are found and removed directly. Refuses to guess without anchor_file, and
# refuses --keep 0. History across two server prefixes is out of scope: only
# the anchor's prefix is pruned.
cmd_prune() {
    [ -d "$OUT_DIR" ] || die "backup directory not found: $OUT_DIR"
    [ -d "$ARCHIVE_DIR" ] || die "archive directory not found: $ARCHIVE_DIR"
    local -a all=() dumps=()
    mapfile -t all < <(find "$OUT_DIR" -maxdepth 1 -name "${DB}_*_binlogbase.json" -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
    local name
    for name in ${all[@]+"${all[@]}"}; do
        [ "$(json_str "$OUT_DIR/$name" kind)" = "binlog-base" ] && dumps+=("$name")
    done
    local total=${#dumps[@]}
    if [ "$total" -le "$KEEP" ]; then
        ok "retention: $total anchored dump(s) of '$DB' in $OUT_DIR, keeping up to $KEEP - nothing to drop"
        return 0
    fi
    local oldest_kept="${dumps[$((total - KEEP))]}"
    local cut_file cut_prefix cut_idx
    cut_file="$(json_str "$OUT_DIR/$oldest_kept" anchor_file)"
    [ -n "$cut_file" ] || die "retention: $oldest_kept carries no anchor_file - refusing to guess where the line is; nothing was dropped"
    cut_prefix=$(binlog_prefix_of "$cut_file")
    cut_idx=$(binlog_index_of "$cut_file")
    log "retention: keeping the newest $KEEP dump(s) of '$DB'; the line is $cut_file (anchor of $oldest_kept)"

    local aname removed_dumps=0 removed_marks=0 removed_binlogs=0 mfile bare
    for name in "${dumps[@]:0:$((total - KEEP))}"; do
        aname="$(json_str "$OUT_DIR/$name" artefact)"
        [ -z "$aname" ] || rm -f -- "$OUT_DIR/$aname"
        rm -f -- "$OUT_DIR/$name"
        removed_dumps=$((removed_dumps + 1))
        warn "retention: removed dump $name (and its artefact) - every kept dump is newer"
    done
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$(json_str "$OUT_DIR/$name" kind)" = "binlog-mark" ] || continue
        mfile="$(json_str "$OUT_DIR/$name" mark_file)"
        [ -n "$mfile" ] || continue
        [ "$(binlog_prefix_of "$mfile")" = "$cut_prefix" ] || continue
        if [ "$(binlog_index_of "$mfile")" -lt "$cut_idx" ]; then
            rm -f -- "$OUT_DIR/$name"
            removed_marks=$((removed_marks + 1))
            warn "retention: removed mark $name - it points below $cut_file, where no kept dump can reach"
        fi
    done < <(find "$OUT_DIR" -maxdepth 1 -name "${DB}_*_binlogmark.json" -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        bare="${name%.age}"
        [ "$(binlog_prefix_of "$bare")" = "$cut_prefix" ] || continue
        [[ "${bare##*.}" =~ ^[0-9]+$ ]] || continue
        if [ "$(binlog_index_of "$bare")" -lt "$cut_idx" ]; then
            rm -f -- "$ARCHIVE_DIR/$name"
            removed_binlogs=$((removed_binlogs + 1))
        fi
    done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
    ok "retention: kept the newest $KEEP dump(s), line drawn at $cut_file - dropped $removed_dumps dump(s), $removed_marks mark(s), $removed_binlogs archived binlog(s) no kept dump could replay"
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
    local sfx=""
    [ "$(json_str "$mark_local" binlogs_encrypted)" != "yes" ] || sfx="$ENC_SUFFIX"
    local idx name isha fetched=0 already=0 tmpf prefix
    prefix=$(binlog_prefix_of "$mark_file")
    local a_idx m_idx
    a_idx=$(binlog_index_of "$(json_str "$base_local" anchor_file)")
    m_idx=$(binlog_index_of "$mark_file")
    for ((idx = a_idx; idx <= m_idx; idx++)); do
        name="$(binlog_name "$prefix" "$idx")$sfx"
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
    local id_hint=""
    case "$(json_str "$base_local" artefact)" in *"$ENC_SUFFIX") id_hint=" --identity KEYFILE";; esac
    [ -z "$sfx" ] || id_hint=" --identity KEYFILE"
    printf '      ./binlog.sh verify --base %s --mark %s --archive %s --tools TOOLS_DIR%s\n' "$base_local" "$mark_local" "$ARCHIVE_DIR" "$id_hint"
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

        # The mark says what form its chain wears; the audit asks for those
        # exact names. The hashes are of the ciphertext when encrypted, so
        # the remote proves an encrypted chain without any key existing here.
        local rsfx=""
        [ "$(json_str "$tmp/$mark" binlogs_encrypted)" != "yes" ] || rsfx="$ENC_SUFFIX"
        local -a audit=()
        local idx
        if [ "$base_ok" -eq 1 ]; then
            for ((idx = $(binlog_index_of "$bfile"); idx <= $(binlog_index_of "$mark_file"); idx++)); do
                audit+=("$(binlog_name "$(binlog_prefix_of "$mark_file")" "$idx")$rsfx")
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
    # The identity copy the throwaway read - world-readable, so first to go.
    if [ -n "$KEYDIR" ] && [ -d "$KEYDIR" ]; then
        rm -rf -- "$KEYDIR" 2>/dev/null || warn "could not remove the identity copy in $KEYDIR"
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

    # The manifests, not the directory, say what is encrypted - and without
    # the key there is no verification, and no green tick of consolation.
    local base_enc=0 chain_sfx=""
    case "$(json_str "$BASE_MANIFEST" artefact)" in *"$ENC_SUFFIX") base_enc=1;; esac
    [ "$(json_str "$MARK_MANIFEST" binlogs_encrypted)" != "yes" ] || chain_sfx="$ENC_SUFFIX"
    if [ "$base_enc" -eq 1 ] || [ -n "$chain_sfx" ]; then
        [ -n "$IDENTITY" ] \
            || die "this backup is encrypted (base: $([ "$base_enc" -eq 1 ] && echo yes || echo no), binlog archive: $([ -n "$chain_sfx" ] && echo yes || echo no)) - verification without --identity would be a guess, and this tool does not guess"
        encryption_available || die "the pair is encrypted but 'age' is not installed"
    fi

    # GTID mode also comes from the manifests, never from a flag - and the
    # halves must agree: a history that changed mode between the base and
    # the mark is not claimed here. Manifests from before this field are
    # read as plain, which is what they were.
    local base_gtid mark_gtid gtid_mode
    base_gtid=$(json_str "$BASE_MANIFEST" gtid_mode)
    mark_gtid=$(json_str "$MARK_MANIFEST" gtid_mode)
    base_gtid=${base_gtid:-no}
    mark_gtid=${mark_gtid:-no}
    [ "$base_gtid" = "$mark_gtid" ] \
        || die "the base says gtid_mode=$base_gtid but the mark says gtid_mode=$mark_gtid - a pair that disagrees about GTID mode describes two different servers' rules; take a fresh pair"
    gtid_mode="$base_gtid"

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
    local idx name aname fsha problems=0 prefix
    prefix=$(binlog_prefix_of "$anchor_file")
    local -a replay_files=()
    for ((idx = a_idx; idx <= m_idx; idx++)); do
        name=$(binlog_name "$prefix" "$idx")
        aname="$name$chain_sfx"
        replay_files+=("$name")
        if [ ! -e "$ARCHIVE_DIR/$aname" ]; then
            printf '  %sFAIL%s missing %s - a replay would stitch over this hole with rc 0 (measured)\n' "$c_red" "$c_reset" "$aname"
            problems=$((problems + 1))
            continue
        fi
        if [ -z "${inv[$aname]:-}" ]; then
            printf '  %sFAIL%s %s - in the archive, but the mark'\''s inventory never stood on it\n' "$c_red" "$c_reset" "$aname"
            problems=$((problems + 1))
            continue
        fi
        fsha=$(sha256_of "$ARCHIVE_DIR/$aname")
        if [ "$fsha" != "${inv[$aname]%%:*}" ]; then
            printf '  %sFAIL%s %s - these are not the bytes the mark stood on (rot or a partial copy; mysqlbinlog would replay them anyway - measured)\n' "$c_red" "$c_reset" "$aname"
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

    if [ -n "$chain_sfx" ]; then
        # The chain decrypts INSIDE the replay container, so its plaintext
        # only ever exists in a filesystem that dies with the drill - which
        # means the host's age binary rides in, and the static-age lesson
        # applies: prove it runs there BEFORE anything boots (a dynamically
        # linked age was measured failing inside a container in seconds).
        docker run --rm -v "$(command -v age):/usr/local/bin/age:ro" \
                --entrypoint /usr/local/bin/age "$IMAGE" --version >/dev/null 2>&1 \
            || die "the age at $(command -v age) does not run inside $IMAGE (dynamically linked?) - decrypting the chain in the throwaway needs a static age build"
    fi

    PROBE="bv-binlog-$$"
    trap cleanup EXIT
    if [ "$gtid_mode" = yes ]; then
        # The throwaway must speak the pair's language: applying a GTID
        # replay to a gtid_mode=OFF server dies with ERROR 1781 (measured).
        log "booting a throwaway $IMAGE as '$PROBE' (gtid_mode=ON, to match the pair)"
        eng_boot "$PROBE" "$db" "$IMAGE" --gtid-mode=ON --enforce-gtid-consistency=ON
    else
        log "booting a throwaway $IMAGE as '$PROBE'"
        eng_boot "$PROBE" "$db" "$IMAGE"
    fi
    eng_wait_ready "$PROBE"
    [ "$(eng_count_tables "$PROBE" "$db" | tr -d '\n')" = "0" ] \
        || die "the throwaway instance is not empty - refusing an ambiguous restore (measured on the dump side)"

    log "loading the base dump"
    if [ "$base_enc" -eq 1 ]; then
        # Decrypt-and-load in one pipe: the plaintext dump exists only inside
        # it, and PIPESTATUS tells a wrong key apart from a dump that will
        # not load.
        set +e
        age -d -i "$IDENTITY" "$artefact" 2>/dev/null \
            | docker exec -e MYSQL_PWD=verify -i "$PROBE" mysql -uroot > /dev/null 2>&1
        local -a lst=("${PIPESTATUS[@]}")
        set -e
        [ "${lst[0]}" -eq 0 ] \
            || die "the base artefact does not decrypt with the given identity (age rc=${lst[0]}) - wrong key, or ciphertext damage the sha256 gate somehow missed"
        [ "${lst[1]}" -eq 0 ] \
            || die "the base dump did not load cleanly - the replay has nothing sane to stand on"
    else
        docker exec -e MYSQL_PWD=verify -i "$PROBE" mysql -uroot < "$artefact" > /dev/null 2>&1 \
            || die "the base dump did not load cleanly - the replay has nothing sane to stand on"
    fi

    # --verify-binlog-checksum is NOT optional: without it a corrupted event
    # sails into the replay with rc 0 (measured). The inventory above already
    # proved these bytes, so a failure here is mysqlbinlog disagreeing with
    # the mark - worth dying on either way.
    log "replaying ${#replay_files[@]} file(s) to $mark_file:$mark_pos (checksums verified)"
    if [ -n "$chain_sfx" ]; then
        # The replay container decrypts for itself: chain plaintext lands
        # only in ITS filesystem and dies with the docker run, and the
        # decoded history - which is your rows - streams straight into the
        # probe without ever touching the host disk. PIPESTATUS separates
        # the decode side from the apply side, and rc 42 inside the decode
        # side means a file did not decrypt (gate 3 already proved these are
        # the mark's exact bytes, so that is the key disagreeing, not rot).
        KEYDIR=$(mktemp -d)
        cp "$IDENTITY" "$KEYDIR/identity"
        chmod 755 "$KEYDIR"; chmod 644 "$KEYDIR/identity"
        local dec_err apply_err
        dec_err=$(mktemp)
        apply_err=$(mktemp)
        set +e
        docker run --rm -v "$ARCHIVE_DIR:/archive:ro" \
            -v "$TOOLS_DIR/mysqlbinlog:/usr/bin/mysqlbinlog:ro" \
            -v "$(command -v age):/usr/local/bin/age:ro" \
            -v "$KEYDIR:/run/bvkey:ro" \
            --entrypoint sh "$IMAGE" \
            -c "mkdir /dec || exit 1
                for f in $(printf '%s ' "${replay_files[@]}"); do
                    /usr/local/bin/age -d -i /run/bvkey/identity -o /dec/\$f /archive/\$f$chain_sfx || exit 42
                done
                cd /dec && mysqlbinlog --verify-binlog-checksum --start-position=$anchor_pos --stop-position=$mark_pos $(printf '%s ' "${replay_files[@]}")" \
            2> "$dec_err" \
            | docker exec -e MYSQL_PWD=verify -i "$PROBE" mysql -uroot "$db" > /dev/null 2> "$apply_err"
        local -a rst=("${PIPESTATUS[@]}")
        set -e
        if [ "${rst[0]}" -eq 42 ]; then
            sed 's/^/      /' "$dec_err" | head -5
            rm -f "$dec_err" "$apply_err"
            die "a chain file did not decrypt inside the throwaway - the bytes are the mark's own (gate 3), so this is the wrong identity"
        elif [ "${rst[0]}" -ne 0 ]; then
            sed 's/^/      /' "$dec_err" | head -5
            rm -f "$dec_err" "$apply_err"
            die "mysqlbinlog refused the chain - the history cannot even be decoded"
        fi
        if [ "${rst[1]}" -ne 0 ]; then
            sed 's/^/      /' "$apply_err" | head -5
            rm -f "$dec_err" "$apply_err"
            die "the replay did not apply cleanly - an ambiguous half-replayed instance is not a recovery"
        fi
        rm -f "$dec_err" "$apply_err"
    else
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
    fi

    # --- Gate 5 (GTID only): the history, by name ------------------------------
    # A GTID-shaped arrival check in front of the fingerprints: with GTIDs a
    # replay can exit 0 having applied NOTHING AT ALL - auto-skip silently
    # eats every transaction the server believes it has seen (measured: the
    # same replay twice, rc 0 both times, zero effect the second). So the
    # recovered instance must PROVABLY contain every transaction the mark
    # stood on, and GTID_SUBSET asks exactly that.
    local failures=0 gate_fail=0 checked mark_gtids
    if [ "$gtid_mode" = yes ]; then
        mark_gtids=$(json_str "$MARK_MANIFEST" gtid_executed)
        if [ -z "$mark_gtids" ]; then
            warn "this GTID mark records no gtid_executed set, so history containment cannot be checked - the fingerprints below still decide"
        elif [ "$(eng_query "$PROBE" "$db" "SELECT GTID_SUBSET('$mark_gtids', @@global.gtid_executed);" | tr -d '\n')" = "1" ]; then
            ok "the recovered history provably contains every transaction the mark stood on (GTID_SUBSET)"
        else
            printf '  %sFAIL%s the recovered history does not contain the mark'\''s transactions - a GTID replay skips what the server thinks it has seen, silently and with rc 0 (measured)\n' \
                "$c_red" "$c_reset"
            failures=$((failures + 1))
        fi
    fi

    # --- Gate 6: ARRIVAL, proven by content -----------------------------------
    # The measured inversion this script exists for: a --stop-position past
    # the end of history exits 0 with an empty stderr. MySQL will not say
    # whether the replay ARRIVED - so the mark's own fingerprints do.
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

    ok "BINLOG PITR VERIFIED: base dump + archived binlogs reproduce $mark_file:$mark_pos exactly ($checked table(s), byte-for-byte)${chain_sfx:+ - the chain decrypted only inside the throwaway}."
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
        prune)  cmd_prune;;
        pull)   cmd_pull;;
    esac
}

# Guarded so the tests can source this file and exercise parse_args without
# touching Docker (the harness idiom of the whole family).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    parse_args "$@"
    main
fi
