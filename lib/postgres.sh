#!/usr/bin/env bash
# =============================================================================
# PostgreSQL engine module.
#
# Every engine implements the same eng_* interface, so backup.sh and verify.sh
# never contain an engine name. Sourced by lib/common.sh via load_engine.
# =============================================================================

ENG_NAME="postgres"
# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
ENG_DEFAULT_IMAGE="postgres:17-alpine"
# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
ENG_ARTEFACT_EXT=".dump"
# shellcheck disable=SC2034  # used in user-facing messages
ENG_UNIT="table"

# Backup-side preconditions: the tools exist and the source is reachable.
eng_preflight() {
    need docker
    docker inspect "$1" >/dev/null 2>&1 || die "container '$1' not found"
}

# Boot a throwaway instance of this engine.
eng_boot() {
    need docker
    local name="$1" db="$2" image="$3"
    docker run -d --name "$name" -e POSTGRES_PASSWORD=verify -e POSTGRES_DB="$db" \
        "$image" >/dev/null
}

# Remove the throwaway instance.
eng_teardown() {
    docker rm -f "$1" >/dev/null 2>&1 || true
}

# Wait until the server is *really* ready.
#
# `pg_isready` alone is NOT enough, and this cost a green local run and a red CI
# one: the official image starts TWO servers - a temporary one on the unix
# socket to run initdb, which it then SHUTS DOWN before starting the real one.
# pg_isready answers "accepting connections" during the temporary phase, so a
# script that trusts it races the shutdown and gets `FATAL: the database system
# is shutting down`, or a `database "app" does not exist` from the instant
# before init finished. MySQL does the same thing, so the streak rule lives in
# both engines.
eng_wait_ready() {
    local container="$1" tries="${2:-90}" stable_needed="${3:-3}"
    local i streak=0
    for ((i = 1; i <= tries; i++)); do
        if docker exec "$container" psql -U postgres -d postgres -tAc 'SELECT 1' \
                >/dev/null 2>&1 < /dev/null; then
            streak=$((streak + 1))
            [ "$streak" -ge "$stable_needed" ] && return 0
        else
            streak=0
        fi
        sleep 1
    done
    die "postgres in '$container' never became stably ready after ${tries}s"
}

# Run a query, returning bare tuples.
#
# NO `-i`, and stdin nailed to /dev/null: `docker exec -i` attaches the caller's
# stdin to the container, so calling this from inside a `while read` loop makes
# psql SWALLOW THE REST OF THE LOOP'S INPUT. It cost this repo a manifest that
# listed 1 of 2 tables. Same family as `ssh` eating a loop's stdin without -n.
eng_query() {
    local container="$1" db="$2" sql="$3"
    docker exec "$container" psql -tA -v ON_ERROR_STOP=1 -U postgres -d "$db" -c "$sql" < /dev/null
}

# Dump to stdout. Custom format: compressed, and pg_restore reads it
# selectively. No pipe into gzip on purpose (see the pipefail note in
# lib/common.sh).
eng_dump() {
    local container="$1" db="$2"
    docker exec "$container" pg_dump -U postgres -d "$db" -Fc < /dev/null
}

# Restore from stdin. Exit code is returned; the caller decides what it means.
eng_restore() {
    local container="$1" db="$2"
    docker exec -i "$container" pg_restore -U postgres -d "$db" --no-owner
}

# Does stdin parse as this engine's archive format? Catches a truncated or
# corrupt artefact at backup time rather than in six months.
eng_archive_parses() {
    local container="$1"
    docker exec -i "$container" pg_restore --list > /dev/null 2>&1
}

eng_list_tables() {
    local container="$1" db="$2"
    eng_query "$container" "$db" "SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name;"
}

# Order-independent md5 over every column of every row, with the row count
# appended. Not a row count: a TRUNCATED dump restores PART of the data and
# leaves the table populated (measured), so counting proves nothing on its own -
# but carrying the count makes a failure message say how many rows are missing.
eng_table_fingerprint() {
    local container="$1" db="$2" table="$3"
    eng_query "$container" "$db" "SELECT coalesce(md5(string_agg(row_text, E'\n' ORDER BY row_text)), 'EMPTY') || ':' || count(*)
FROM (SELECT concat_ws('|', t.*)::text AS row_text FROM \"$table\" t) s;"
}

# "<count>:<md5 of the sorted definitions>" for one class of schema object.
# Definitions, not just names: an index that comes back on the wrong column is
# not the same index.
eng_schema_digest() {
    local container="$1" db="$2" class="$3" sql out count fp
    case "$class" in
        indexes)     sql="SELECT indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY indexdef;";;
        constraints) sql="SELECT conname||' '||pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='public' ORDER BY 1;";;
        # last_value included on purpose: a sequence restored behind its data
        # means the next INSERT collides with the primary key.
        sequences)   sql="SELECT sequencename||'='||coalesce(last_value::text,'unset') FROM pg_sequences WHERE schemaname='public' ORDER BY 1;";;
        # PITR's sequences class: names only, no last_value. Measured: a
        # recovered instance brings sequences back up to 32 AHEAD of the
        # marked instant, because nextval pre-logs 32 values at a time so a
        # crash can never repeat one. Demanding last_value equality would fail
        # every exact recovery; the writable probe proves usability instead -
        # the same reasoning that keeps MySQL's rounded auto_increment out of
        # its digest.
        sequence_names) sql="SELECT sequencename FROM pg_sequences WHERE schemaname='public' ORDER BY 1;";;
        views)       sql="SELECT table_name||' '||md5(coalesce(view_definition,'')) FROM information_schema.views WHERE table_schema='public' ORDER BY 1;";;
        routines)    sql="SELECT p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' ORDER BY 1;";;
        triggers)    sql="SELECT t.tgname||' on '||c.relname FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname='public' ORDER BY 1;";;
        *)           die "unknown object class for $ENG_NAME: $class";;
    esac
    out=$(eng_query "$container" "$db" "$sql")
    count=$(printf '%s\n' "$out" | grep -c . || true)
    fp=$(printf '%s' "$out" | md5sum | awk '{print $1}')
    printf '%s:%s' "$count" "$fp"
}

# How many tables the public schema holds - used to prove the verification
# target starts empty, and that the restored copy has no EXTRA tables.
eng_count_tables() {
    local container="$1" db="$2"
    eng_query "$container" "$db" "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';"
}

eng_count_relations() {
    local container="$1" db="$2"
    eng_query "$container" "$db" "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
}

# --- WAL archive arithmetic (PITR) -------------------------------------------
#
# A WAL segment name is TTTTTTTTLLLLLLLLSSSSSSSS: timeline, "log" number and
# segment-within-log, zero-padded uppercase hex. How many segments share one
# log number depends on the segment size (4GB worth: 256 for the default 16MB),
# so the arithmetic takes the size instead of assuming it. Pure functions on
# purpose: the unit tests exercise the log-boundary carry without Docker.

wal_name_timeline() { printf '%s' "${1:0:8}"; }

# Absolute segment position of a name, timeline ignored.
wal_name_index() {
    local name="$1" seg_bytes="$2" per_log
    per_log=$((4294967296 / seg_bytes))
    printf '%s' $((16#${name:8:8} * per_log + 16#${name:16:8}))
}

# The name a segment position carries on a timeline - the inverse of the above.
wal_index_name() {
    local timeline="$1" index="$2" seg_bytes="$3" per_log
    per_log=$((4294967296 / seg_bytes))
    printf '%s%08X%08X' "$timeline" $((index / per_log)) $((index % per_log))
}

# Every problem in the archive between two segments (inclusive), one line per
# problem on stdout; the CALLER counts lines. Two checks only, both cheap and
# both measured: a segment that is absent breaks the chain (recovery without a
# target sails past the hole and calls the truncation success), and a segment
# whose size is not exactly the segment size is not a segment (a half-copied
# file recovers to a FATAL - but only on the day you recover; this makes it
# loud today). No content is read: the segments land 0600, owned by the
# server's user - size and presence are what the archive's landlord can see.
# Optional 5th/6th args: a filename suffix (an encrypted archive holds
# NAME.age) and the expected on-disk size of a completed file when it differs
# from seg_bytes - a full segment's age ciphertext is plaintext plus a
# CONSTANT overhead (measured: 16781496 for every 16777216-byte segment, one
# recipient), so the exact-size gate survives encryption unchanged.
wal_range_problems() {
    local dir="$1" first="$2" last="$3" seg_bytes="$4" suffix="${5:-}" expect_bytes="${6:-$4}"
    local timeline i i0 i1 name size
    timeline=$(wal_name_timeline "$first")
    i0=$(wal_name_index "$first" "$seg_bytes")
    i1=$(wal_name_index "$last" "$seg_bytes")
    for ((i = i0; i <= i1; i++)); do
        name=$(wal_index_name "$timeline" "$i" "$seg_bytes")$suffix
        if [ ! -f "$dir/$name" ]; then
            printf 'missing segment %s - the chain is broken here\n' "$name"
        else
            size=$(stat -c%s "$dir/$name")
            if [ "$size" -ne "$expect_bytes" ]; then
                printf 'segment %s is %s bytes - a completed segment is exactly %s\n' \
                    "$name" "$size" "$expect_bytes"
            fi
        fi
    done
}

# Can the application WRITE after the restore? A sequence left behind its data
# makes the next INSERT collide with the primary key: every row present, and
# the app broken on its first write.
eng_writable_probe_failures() {
    local container="$1" db="$2" line seq_name failures=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        seq_name=${line%%|*}
        if ! eng_query "$container" "$db" "SELECT nextval('\"$seq_name\"');" >/dev/null 2>&1; then
            printf 'sequence %s cannot produce a usable next value\n' "$seq_name"
            failures=$((failures + 1))
        fi
    done < <(eng_query "$container" "$db" "SELECT sequencename||'|' FROM pg_sequences WHERE schemaname='public' ORDER BY 1;" 2>/dev/null || true)
    return "$failures"
}
