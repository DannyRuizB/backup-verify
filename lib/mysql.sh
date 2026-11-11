#!/usr/bin/env bash
# =============================================================================
# MySQL / MariaDB engine module (MySQL measured on 8.4 and 9.7, MariaDB on 10.11
# and 11.4 - see my_bin and ENG_FINGERPRINT).
#
# Same eng_* interface as lib/postgres.sh. Two MySQL-specific traps, both
# MEASURED on a real 8.4 server, shape everything below:
#
#  1. `mysqldump` OMITS ROUTINES BY DEFAULT. A dump of a database with one
#     function and one procedure contained zero of each, exit code 0, no
#     warning. Triggers DO come by default; routines and events do not. So the
#     dump here always passes --routines --events --triggers, and verify
#     compares routine counts so a hand-rolled dump missing them cannot pass.
#
#  2. `group_concat_max_len` DEFAULTS TO 1024 BYTES. A content fingerprint built
#     on GROUP_CONCAT would be computed over 1024 of 16175 bytes - SIX PERCENT
#     of the data - and MySQL only whispers a warning (1260 "Row 32 was cut by
#     GROUP_CONCAT()") that a script never sees. A fingerprint that inspects 6%
#     of the rows and reports OK is precisely the lie this repo exists to kill.
#     So: the session limit is raised AND the query proves it was enough by
#     comparing the concatenated length against the length the rows must add up
#     to. If they disagree it returns TRUNCATED, and the caller aborts.
# =============================================================================

ENG_NAME="mysql"
# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
ENG_DEFAULT_IMAGE="mysql:8.4"
# The hash new manifests are fingerprinted with. MySQL 9.7 - the LTS after
# 8.4, and what `mysql:lts` points at - no longer has MD5(), SHA1() or SHA():
# they moved to component_classic_hashing, which is not installed by default
# (measured on 9.7.4: "FUNCTION <db>.MD5 does not exist"; SHA2() is still built
# in, on 8.4 and on MariaDB too). Every manifest written before this says
# nothing and means md5 - see manifest_fingerprint - and keeps verifying
# exactly as it always did.
# shellcheck disable=SC2034  # read by backup.sh/binlog.sh, which source this
ENG_FINGERPRINT="sha256"
# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
ENG_ARTEFACT_EXT=".sql"
# shellcheck disable=SC2034  # used in user-facing messages
ENG_UNIT="table"

# MYSQL_PWD is used throughout instead of -p: a password on the command line is
# visible to every user on the box via the process list.

# Which client binary this container has. MariaDB 11 images ship only
# `mariadb` and `mariadb-dump` (measured on mariadb:11.4: no `mysql`, no
# `mysqldump` - every call failed and the readiness wait ran out after 120 s);
# 10.11 ships both names, MySQL images only the mysql* ones. The mariadb*
# name wins where it exists. Asked once per container and remembered in THIS
# shell; callers inside $(...) are subshells and would forget, so
# eng_preflight and eng_wait_ready - which run in the parent - ask first. A
# container that does not answer yet gets the mysql* name for this one call
# and nothing is remembered.
declare -gA MY_BIN=()
my_bin() {
    local container="$1" name="$2" maria found
    case "$name" in
        mysql)     maria=mariadb;;
        mysqldump) maria=mariadb-dump;;
        *)         die "my_bin: unknown client '$name'";;
    esac
    if [ -z "${MY_BIN[$container:$name]:-}" ]; then
        found=$(docker exec "$container" sh -c "if command -v $maria >/dev/null; then echo $maria; elif command -v $name >/dev/null; then echo $name; fi" \
            < /dev/null 2>/dev/null) || true
        if [ -z "$found" ]; then printf '%s' "$name"; return 0; fi
        MY_BIN[$container:$name]="$found"
    fi
    printf '%s' "${MY_BIN[$container:$name]}"
}

# Backup-side preconditions: the tools exist and the source is reachable.
eng_preflight() {
    need docker
    docker inspect "$1" >/dev/null 2>&1 || die "container '$1' not found"
    my_bin "$1" mysql >/dev/null
    my_bin "$1" mysqldump >/dev/null
}

# Arguments past the image go to the SERVER: a GTID pair must be verified on
# a throwaway that speaks GTID (measured: applying a GTID replay to a
# gtid_mode=OFF server dies with ERROR 1781), so binlog.sh boots the
# throwaway to match the manifests. Existing three-argument callers are
# untouched.
eng_boot() {
    need docker
    local name="$1" db="$2" image="$3"
    shift 3
    docker run -d --name "$name" -e MYSQL_ROOT_PASSWORD=verify -e MYSQL_DATABASE="$db" \
        "$image" "$@" >/dev/null
}

# The server's own version string ("8.4.6", "11.4.13-MariaDB-ubu2404"),
# written into the manifest so verify can boot the same server: a MariaDB
# 11.4 dump restored into the default mysql:8.4 dies on its collation
# ("Unknown collation: 'utf8mb4_uca1400_ai_ci'", measured), and verify then
# blamed the fingerprint ("not usable") instead of the engine.
eng_server_version() {
    eng_query "$1" "$2" 'SELECT VERSION();' | tr -d '\n'
}

# The throwaway image for a recorded server version when --image is not
# given: each server gets its own series back (11.4.13-MariaDB ->
# mariadb:11.4, 9.7.4 -> mysql:9.7, 8.4.6 -> mysql:8.4). MySQL used to keep
# ENG_DEFAULT_IMAGE whatever the manifest said, and a 9.7 backup was then
# "VERIFIED" on 8.4 - proving it restores into an older server than the one
# you would recover onto (measured), and failing a perfectly good backup the
# day it holds something 8.4 does not know, like a VECTOR column. Fails on a
# version it cannot read - never guess an engine.
eng_image_for_server() {
    local series
    series=$(printf '%s' "$1" | grep -oE '^[0-9]+\.[0-9]+') || return 1
    case "$1" in
        *MariaDB*) printf 'mariadb:%s' "$series";;
        *)         printf 'mysql:%s' "$series";;
    esac
}

# Remove the throwaway instance.
eng_teardown() {
    docker rm -f "$1" >/dev/null 2>&1 || true
}

# MySQL's official image also starts twice (init server, then the real one) -
# "ready for connections" appears in the log twice - so the same streak rule as
# Postgres applies: a real query must succeed several times in a row.
eng_wait_ready() {
    local container="$1" tries="${2:-120}" stable_needed="${3:-3}"
    local i streak=0
    for ((i = 1; i <= tries; i++)); do
        my_bin "$container" mysql >/dev/null
        my_bin "$container" mysqldump >/dev/null
        if docker exec -e MYSQL_PWD=verify "$container" "$(my_bin "$container" mysql)" -uroot -N -B -e 'SELECT 1' \
                >/dev/null 2>&1 < /dev/null; then
            streak=$((streak + 1))
            [ "$streak" -ge "$stable_needed" ] && return 0
        else
            streak=0
        fi
        sleep 1
    done
    die "mysql in '$container' never became stably ready after ${tries}s"
}

# -N (no column names) -B (batch/tab-separated) to match the bare-tuple output
# the rest of the code expects. stdin closed for the same reason as Postgres.
eng_query() {
    local container="$1" db="$2" sql="$3"
    docker exec -e MYSQL_PWD=verify "$container" "$(my_bin "$container" mysql)" -uroot -N -B "$db" -e "$sql" < /dev/null 2>/dev/null
}

# --routines --events --triggers are NOT optional: without them the dump
# silently omits every function and procedure (measured). --single-transaction
# gives a consistent snapshot without locking the whole database.
eng_dump() {
    local container="$1" db="$2"
    docker exec -e MYSQL_PWD=verify "$container" "$(my_bin "$container" mysqldump)" -uroot \
        --single-transaction --routines --events --triggers \
        --databases "$db" < /dev/null 2>/dev/null
}

eng_restore() {
    local container="$1" db="$2"
    docker exec -e MYSQL_PWD=verify -i "$container" "$(my_bin "$container" mysql)" -uroot "$db"
}

# A .sql dump is plain text, so "does it parse" is a weaker question than for a
# binary archive: check the structure mysqldump always emits, and that the file
# reached its END. An interrupted dump has no trailing "Dump completed" line -
# which is the cheapest truncation detector MySQL gives us.
eng_archive_parses() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"
    local rc=0
    grep -q 'MySQL dump\|MariaDB dump' "$tmp" || rc=1
    grep -q 'Dump completed' "$tmp" || rc=1
    rm -f "$tmp"
    return "$rc"
}

eng_list_tables() {
    local container="$1" db="$2"
    eng_query "$container" "$db" "SELECT table_name FROM information_schema.tables
WHERE table_schema='$db' AND table_type='BASE TABLE' ORDER BY table_name;"
}

# The fingerprint, with both MySQL traps defused.
#
# MySQL has no `t.*` inside a function - `CONCAT_WS('|', t.*)` is a syntax
# error, unlike Postgres - so the column list is built explicitly from
# information_schema. IFNULL(col,'<NULL>') on purpose: CONCAT_WS SKIPS nulls,
# which would make a row of (1, NULL, 'x') and (1, 'x', NULL) hash the same.
#
# And group_concat_max_len defaults to 1024 BYTES: a fingerprint built on
# GROUP_CONCAT would be computed over 1024 of 16175 bytes - SIX PERCENT of the
# data - while MySQL only whispers warning 1260 that no script ever sees. So the
# limit is raised AND the query proves it was enough, by comparing the joined
# length against the length the rows must add up to. Anything else returns
# TRUNCATED and the caller aborts rather than hashing 6% and reporting OK.
#
# The hash itself is whatever the yardstick was taken with: FP_ALGO is set by
# whoever writes a manifest (ENG_FINGERPRINT) or compares against one (the
# manifest's own "fingerprint"), and both sides run this same query.
my_hash() {
    case "${FP_ALGO:-$ENG_FINGERPRINT}" in
        md5)    printf 'MD5(%s)' "$1";;
        sha256) printf 'SHA2(%s, 256)' "$1";;
        *)      die "unknown fingerprint algorithm '${FP_ALGO}' - refusing to guess how a manifest was hashed";;
    esac
}

# Before comparing anything: can THIS server compute the hash the manifest
# was taken with? Without the check, a manifest hashed with MD5() verified on
# a 9.7 throwaway died with "the fingerprint of customers (restored copy) is
# not usable ('')" (measured) - true, and no help at all on recovery day.
eng_fingerprint_preflight() {
    local container="$1" db="$2" probe
    probe=$(eng_query "$container" "$db" "SELECT $(my_hash "'probe'");" | tr -d '\n') || true
    [ -n "$probe" ] && [ "$probe" != NULL ] && return 0
    die "this server ($(eng_server_version "$container" "$db")) cannot compute the ${FP_ALGO:-$ENG_FINGERPRINT} fingerprints this manifest was taken with - MySQL 9 moved MD5() out of the server (component_classic_hashing). Verify on the series that wrote it (the manifest's server_version)"
}

eng_table_fingerprint() {
    local container="$1" db="$2" table="$3" cols out
    # A VECTOR column (MySQL 9) refuses CAST AS CHAR outright - "Incorrect
    # arguments to cast_as_char", so a table with one could not be backed up -
    # and VECTOR_TO_STRING is no way round it: it prints six digits, and 0.1
    # and 0.1000001 (CDCCCC3D vs DACCCC3D, unequal to the server) both print
    # [1.00000e-01] (measured on 9.7.4). HEX gives its exact float32 bytes.
    # Every other column produces the very expression it always did, so
    # existing fingerprints do not move.
    cols=$(eng_query "$container" "$db" "
SET SESSION group_concat_max_len = 1073741824;
SELECT GROUP_CONCAT(CONCAT('IFNULL(',
                           IF(data_type = 'vector',
                              CONCAT('HEX(\`', column_name, '\`)'),
                              CONCAT('CAST(\`', column_name, '\` AS CHAR)')),
                           ', ''<NULL>'')')
                    ORDER BY ordinal_position)
FROM information_schema.columns
WHERE table_schema='$db' AND table_name='$table';")
    # A table that is not there has no columns, and GROUP_CONCAT over no rows
    # prints the word NULL - which used to pass for a column list: the query
    # then failed, the fingerprint came back empty, and verify died "not
    # usable" instead of reporting the table absent and comparing the rest.
    if [ -z "$cols" ] || [ "$cols" = NULL ]; then
        die "could not read the column list of \`$table\` - refusing to fingerprint nothing"
    fi
    out=$(eng_query "$container" "$db" "
SET SESSION group_concat_max_len = 1073741824;
SELECT CASE
         WHEN cnt = 0 THEN 'EMPTY:0'
         WHEN LENGTH(joined) <> expected_len THEN CONCAT('TRUNCATED:', cnt)
         ELSE CONCAT($(my_hash joined), ':', cnt)
       END
FROM (
  SELECT GROUP_CONCAT(row_text ORDER BY row_text SEPARATOR '\n') AS joined,
         COUNT(*) AS cnt,
         SUM(LENGTH(row_text)) + COUNT(*) - 1 AS expected_len
  FROM (SELECT CONCAT_WS('|', $cols) AS row_text FROM \`$table\`) r
) s;")
    case "$out" in
        TRUNCATED:*) die "the fingerprint of \`$table\` was truncated by GROUP_CONCAT - refusing to compare 6% of the data and call it verified";;
    esac
    printf '%s' "$out"
}

eng_schema_digest() {
    local container="$1" db="$2" class="$3" sql out count fp
    case "$class" in
        indexes)
            # Every index as one line: name, table, and its columns in order.
            sql="SELECT CONCAT(index_name,' on ',table_name,'(',GROUP_CONCAT(column_name ORDER BY seq_in_index),')')
FROM information_schema.statistics WHERE table_schema='$db'
GROUP BY index_name, table_name ORDER BY 1;";;
        constraints)
            sql="SELECT CONCAT(constraint_name,' ',constraint_type,' on ',table_name)
FROM information_schema.table_constraints WHERE table_schema='$db' ORDER BY 1;";;
        sequences)
            # MySQL has no sequences; AUTO_INCREMENT columns are the analogue.
            # Only their EXISTENCE is fingerprinted, never the counter value:
            # MEASURED on 8.4, information_schema reports the counter rounded to
            # an allocation boundary (512 and 1024 while the real maxima were 500
            # and 800), so comparing that number between source and restored copy
            # would raise FALSE ALARMS - the worst failure mode a verifier has.
            # Whether the counter is usable is checked behaviourally instead, by
            # eng_writable_probe_failures, against the real MAX().
            sql="SELECT CONCAT(table_name,'.',column_name,' auto_increment')
FROM information_schema.columns WHERE table_schema='$db'
AND extra LIKE '%auto_increment%' ORDER BY 1;";;
        views)
            sql="SELECT CONCAT(table_name,' ',$(my_hash view_definition))
FROM information_schema.views WHERE table_schema='$db' ORDER BY 1;";;
        routines)
            # The class that a default mysqldump silently drops.
            sql="SELECT CONCAT(routine_type,' ',routine_name)
FROM information_schema.routines WHERE routine_schema='$db' ORDER BY 1;";;
        triggers)
            sql="SELECT CONCAT(trigger_name,' on ',event_object_table)
FROM information_schema.triggers WHERE trigger_schema='$db' ORDER BY 1;";;
        *)  die "unknown object class for $ENG_NAME: $class";;
    esac
    out=$(eng_query "$container" "$db" "$sql")
    count=$(printf '%s\n' "$out" | grep -c . || true)
    fp=$(printf '%s' "$out" | md5sum | awk '{print $1}')
    printf '%s:%s' "$count" "$fp"
}

eng_count_tables() {
    local container="$1" db="$2"
    eng_query "$container" "$db" "SELECT COUNT(*) FROM information_schema.tables
WHERE table_schema='$db' AND table_type='BASE TABLE';"
}

eng_count_relations() {
    local container="$1" db="$2"
    eng_query "$container" "$db" "SELECT COUNT(*) FROM information_schema.tables
WHERE table_schema='$db';"
}

# AUTO_INCREMENT is MySQL's sequence. A counter restored BEHIND the data means
# the next INSERT collides with the primary key: every row present, and the
# application broken on its first write. Two steps, because the counter lives in
# information_schema while the largest value lives in the table itself.
eng_writable_probe_failures() {
    local container="$1" db="$2" tbl col nextval maxid failures=0
    while IFS=$'\t' read -r tbl col nextval; do
        [ -n "$tbl" ] || continue
        [ "$nextval" = "NULL" ] && continue
        maxid=$(eng_query "$container" "$db" "SELECT IFNULL(MAX(\`$col\`), 0) FROM \`$tbl\`;")
        [ -n "$maxid" ] || continue
        if [ "$nextval" -le "$maxid" ]; then
            printf 'AUTO_INCREMENT of %s is %s but %s already reaches %s - the next INSERT collides\n' \
                "$tbl" "$nextval" "$col" "$maxid"
            failures=$((failures + 1))
        fi
    done < <(eng_query "$container" "$db" "
SELECT t.table_name, c.column_name, IFNULL(t.auto_increment,'NULL')
FROM information_schema.tables t
JOIN information_schema.columns c
  ON c.table_schema = t.table_schema AND c.table_name = t.table_name
 AND c.extra LIKE '%auto_increment%'
WHERE t.table_schema='$db' AND t.auto_increment IS NOT NULL
ORDER BY 1;" 2>/dev/null || true)
    return "$failures"
}
