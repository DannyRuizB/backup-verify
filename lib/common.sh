#!/usr/bin/env bash
# =============================================================================
# Shared helpers. Sourced by backup.sh and verify.sh; never run directly.
# =============================================================================

# pipefail is not decoration here, it is the whole point of one of this repo's
# lessons: `pg_dump ... | gzip > out.gz` with a FAILING pg_dump exits 0 and
# leaves a valid, 20-byte, completely empty gzip behind. Measured, not guessed.
set -euo pipefail

c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
c_blue=$'\033[34m'; c_reset=$'\033[0m'

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
