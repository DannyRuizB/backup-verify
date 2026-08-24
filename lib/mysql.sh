#!/usr/bin/env bash
# =============================================================================
# MySQL / MariaDB engine module.
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
# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
ENG_ARTEFACT_EXT=".sql"
# shellcheck disable=SC2034  # used in user-facing messages
ENG_UNIT="table"

# MYSQL_PWD is used throughout instead of -p: a password on the command line is
# visible to every user on the box via the process list.

# Backup-side preconditions: the tools exist and the source is reachable.
eng_preflight() {
    need docker
    docker inspect "$1" >/dev/null 2>&1 || die "container '$1' not found"
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
        if docker exec -e MYSQL_PWD=verify "$container" mysql -uroot -N -B -e 'SELECT 1' \
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
    docker exec -e MYSQL_PWD=verify "$container" mysql -uroot -N -B "$db" -e "$sql" < /dev/null 2>/dev/null
}

# --routines --events --triggers are NOT optional: without them the dump
# silently omits every function and procedure (measured). --single-transaction
# gives a consistent snapshot without locking the whole database.
eng_dump() {
    local container="$1" db="$2"
    docker exec -e MYSQL_PWD=verify "$container" mysqldump -uroot \
        --single-transaction --routines --events --triggers \
        --databases "$db" < /dev/null 2>/dev/null
}

eng_restore() {
    local container="$1" db="$2"
    docker exec -e MYSQL_PWD=verify -i "$container" mysql -uroot "$db"
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
eng_table_fingerprint() {
    local container="$1" db="$2" table="$3" cols out
    cols=$(eng_query "$container" "$db" "
SET SESSION group_concat_max_len = 1073741824;
SELECT GROUP_CONCAT(CONCAT('IFNULL(CAST(\`', column_name, '\` AS CHAR), ''<NULL>'')')
                    ORDER BY ordinal_position)
FROM information_schema.columns
WHERE table_schema='$db' AND table_name='$table';")
    [ -n "$cols" ] || die "could not read the column list of \`$table\` - refusing to fingerprint nothing"
    out=$(eng_query "$container" "$db" "
SET SESSION group_concat_max_len = 1073741824;
SELECT CASE
         WHEN cnt = 0 THEN 'EMPTY:0'
         WHEN LENGTH(joined) <> expected_len THEN CONCAT('TRUNCATED:', cnt)
         ELSE CONCAT(MD5(joined), ':', cnt)
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
            sql="SELECT CONCAT(table_name,' ',MD5(view_definition))
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
