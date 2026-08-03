#!/usr/bin/env bash
# =============================================================================
# Shared helpers. Sourced by backup.sh and verify.sh; never run directly.
# =============================================================================

# pipefail is not decoration here, it is the whole point of one of this repo's
# lessons: `pg_dump ... | gzip > out.gz` with a FAILING pg_dump exits 0 and
# leaves a valid, 20-byte, completely empty gzip behind. Measured, not guessed.
set -euo pipefail

# Colour only when stdout is a terminal. Escape codes in a CI log are noise at
# best, and they broke a test that grepped for "OK   customers" while the real
# bytes were "OK\033[0m   customers" - a check that silently stopped checking.
if [ -t 1 ]; then
    c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
    c_blue=$'\033[34m'; c_reset=$'\033[0m'
else
    c_red=''; c_green=''; c_yellow=''; c_blue=''; c_reset=''
fi

log()  { printf '%s[*]%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

# A backup artefact smaller than this is not a backup. A failed pg_dump leaves
# a 0-byte file; piped through gzip it leaves ~20 bytes of valid-but-empty
# archive. Both measured on a real Postgres. The floor is deliberately low so
# it only ever catches the absurd - real emptiness, not "smaller than usual".
: "${MIN_ARTEFACT_BYTES:=512}"

need() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Fingerprint one table's full contents, order-independent.
#
# Why not `count(*)`: a TRUNCATED dump restores PART of the data and pg_restore
# exits non-zero - but the table is left populated (measured: 500 of 500 rows
# from a dump cut in half). Anyone checking "are there rows?" would call that
# backup good. Only comparing the whole content catches it, which is why this
# function exists and why verify.sh refuses to fall back to counting.
#
# md5 of the sorted concatenation of every column: same rows in a different
# physical order still match, one changed byte does not.
fingerprint_sql() {
    local table="$1"
    cat <<SQL
SELECT coalesce(md5(string_agg(row_text, E'\n' ORDER BY row_text)), 'EMPTY')
FROM (
  SELECT concat_ws('|', t.*)::text AS row_text FROM ${table} t
) s;
SQL
}

# List the base tables of a database's public schema, one per line.
list_tables_sql() {
    cat <<'SQL'
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;
SQL
}

# Run psql inside a container, returning bare tuples. Kept in one place so the
# quoting is right once instead of five times.
#
# NO `-i`, and stdin nailed to /dev/null. This is not cosmetic: `docker exec -i`
# attaches the caller's stdin to the container, so calling this from inside a
# `while IFS= read -r table; do ... done <<EOF` loop makes psql SWALLOW THE REST
# OF THE LOOP'S INPUT - the loop then ends after one iteration. It cost this
# repo a manifest that listed 1 of 2 tables (caught by verify.sh's "restored
# copy has more tables than the manifest describes" guard). Same family as `ssh`
# eating a loop's stdin when you forget `-n`.
psql_in() {
    local container="$1" db="$2" sql="$3"
    docker exec "$container" psql -tA -v ON_ERROR_STOP=1 -U postgres -d "$db" -c "$sql" < /dev/null
}

# --- Schema inventory --------------------------------------------------------
#
# Comparing table CONTENTS is not enough, and this was measured, not assumed:
# `pg_restore -t customers -t orders` (the "I only want the tables" flow) exits
# 0, restores every single row, and silently drops 4 of 4 indexes, 4 of 5
# constraints, the view, the function and the trigger. A verification that only
# looks at rows would call that a good backup and be wrong by omission - the
# restored database cannot enforce a unique key or fire a trigger.
#
# One query per object class, each ORDER BY'd so the output is deterministic.
# The definitions themselves are included (not just names): an index that comes
# back on the wrong column is not the same index.
schema_query() {
    case "$1" in
        indexes)
            printf '%s' "SELECT indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY indexdef;";;
        constraints)
            printf '%s' "SELECT conname||' '||pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='public' ORDER BY 1;";;
        sequences)
            # last_value included on purpose: a sequence restored but left
            # behind the data means the next INSERT collides with the primary
            # key - all the rows are there and the application is broken.
            printf '%s' "SELECT sequencename||'='||coalesce(last_value::text,'unset') FROM pg_sequences WHERE schemaname='public' ORDER BY 1;";;
        views)
            printf '%s' "SELECT table_name||' '||md5(coalesce(view_definition,'')) FROM information_schema.views WHERE table_schema='public' ORDER BY 1;";;
        routines)
            printf '%s' "SELECT p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' ORDER BY 1;";;
        triggers)
            printf '%s' "SELECT t.tgname||' on '||c.relname FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname='public' ORDER BY 1;";;
        *)  die "unknown object class: $1";;
    esac
}

# The object classes the manifest records, in report order. Consumed by
# backup.sh and verify.sh, which source this file - hence the disable: analysing
# this file on its own cannot see those uses.
# shellcheck disable=SC2034
SCHEMA_CLASSES="indexes constraints sequences views routines triggers"

# "<count>:<md5 of the sorted definitions>" for one object class. The count is
# carried alongside the fingerprint so a failure can say "expected 4 indexes,
# found 0" instead of only "the fingerprints differ".
schema_digest() {
    local container="$1" db="$2" class="$3" out count fp
    out=$(psql_in "$container" "$db" "$(schema_query "$class")")
    count=$(printf '%s\n' "$out" | grep -c . || true)
    fp=$(printf '%s' "$out" | md5sum | awk '{print $1}')
    printf '%s:%s' "$count" "$fp"
}

# Wait until Postgres inside a container is *really* ready.
#
# `pg_isready` alone is NOT enough, and this cost a green local run and a red
# CI one: the official Postgres image starts TWO servers. First a temporary one
# on the unix socket to run initdb and any init scripts, then it SHUTS THAT
# DOWN and starts the real one. pg_isready answers "accepting connections"
# during the temporary phase, so a script that trusts it races the shutdown and
# gets `FATAL: the database system is shutting down` - or worse, a
# `database "app" does not exist` from the instant before the init finished.
#
# So: require a real query to succeed on STABLE_HITS consecutive attempts, one
# second apart. The mid-init shutdown breaks the streak and the count restarts.
# No log-message parsing, so it works across image versions.
wait_for_postgres() {
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

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}
