#!/usr/bin/env bash
# =============================================================================
# SQLite engine module: back up a single-file database and prove it restores.
#
# Same eng_* interface as the other engines, with no container in sight - the
# "instance" is a scratch .db file, exactly as the files engine's is a scratch
# directory. SQLite has its own famous ways of lying, every one MEASURED on
# this machine (sqlite3 3.46.1) before the module was written:
#
#   * `cp app.db backup.db` while a writer holds the database is the obvious
#     backup and the wrong one: the copy can be TORN (a page written, its
#     index page not yet) - it still OPENS, and a naive "does it open?" check
#     signs it off, but `PRAGMA integrity_check` reports the damage. Worse in
#     WAL mode: copying only the .db file (not the -wal) loses every commit
#     still in the write-ahead log. So the backup here is a `.dump` - a
#     consistent logical snapshot inside a read transaction - never a file copy.
#   * a `.dump` is wrapped in `BEGIN TRANSACTION; ... COMMIT;`. An interrupted
#     dump (writer killed, disk full) has no closing `COMMIT;` - measured, a
#     dump truncated before it rolls back CLEANLY on restore (the table never
#     exists) rather than committing half the rows. The parse gate checks for
#     that trailer, the exact analogue of MySQL's `Dump completed`.
#   * a TABLE-SCOPED dump (`sqlite3 db .dump customers orders`) returns every
#     ROW of the named tables, exit 0, no warning - and silently drops every
#     VIEW, and every index and trigger not attached to those tables. This is
#     the SQLite `pg_dump -t`: the objects a row count never sees, gone.
#   * `INTEGER PRIMARY KEY AUTOINCREMENT` tracks its high-water mark in the
#     `sqlite_sequence` table. A dump that restored that counter BEHIND the
#     data would make the next INSERT reuse an id - every row present, the
#     application broken on its first write (the writable gate below).
#
# The mapping: tables are the tables (quote()-per-column content fingerprints),
# indexes/views/triggers are the schema classes, and the throwaway instance is
# a scratch .db file instead of a container. No Docker involved.
# =============================================================================

# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
ENG_NAME="sqlite"
# No container is ever booted: the "instance" is a scratch .db file. The
# variable exists because the interface promises it and verify.sh logs it.
# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
ENG_DEFAULT_IMAGE="scratch-db"
# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
ENG_ARTEFACT_EXT=".sql"
# shellcheck disable=SC2034  # used in user-facing messages
ENG_UNIT="table"
# A `.dump` of an empty database is 50-ish bytes (the PRAGMA + BEGIN + COMMIT).
# The generic 512-byte floor would refuse a legitimately small database, so
# lower it; the "manifest lists no tables" guard is the real defence against
# backing up nothing.
# shellcheck disable=SC2034  # read by backup.sh
ENG_MIN_ARTEFACT_BYTES=48

# The schema classes verify.sh compares - the half a row count never sees.
# Tables themselves are compared by content (the "tables"); their CREATE
# statements ride along in the indexes/views/triggers digests' cousins here:
# indexes catches a dropped UNIQUE/lookup index, views catches a dropped view
# (what a table-scoped dump loses), triggers catches a dropped trigger.
# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
SCHEMA_CLASSES="indexes views triggers"

# Where an instance lives on disk. The first argument of every eng_* function
# is either the SOURCE database (an absolute path to a .db file, from --path)
# or a probe NAME like bv-verify-1234; a name maps to a namespaced scratch
# file. The same guard the files engine uses: an absolute path is user data
# and is never created or removed here.
sqlite_file() {
    case "$1" in
        /*) printf '%s' "$1";;
        *)  printf '%s' "${TMPDIR:-/tmp}/bv-sqlite-$1.db";;
    esac
}

# Backup-side preconditions: the tool exists and the source is a readable
# SQLite database file (a directory here is the files engine's job).
eng_preflight() {
    need sqlite3
    local f="$1"
    [ -f "$f" ] || die "source database '$f' not found (a SQLite source is a .db FILE, not a directory)"
    [ -r "$f" ] || die "source database '$f' is not readable"
    # A valid database answers its own header pragma; a truncated or non-SQLite
    # file fails here instead of halfway through a dump.
    sqlite3 "$f" 'PRAGMA schema_version;' >/dev/null 2>&1 \
        || die "source '$f' is not a valid SQLite database"
}

# "Boot a throwaway instance" = guarantee an empty scratch database. Remove any
# stale file (and its WAL/SHM sidecars) so the clean-target gate starts from
# genuinely nothing. Never touches an absolute source path.
eng_boot() {
    local name="$1" f
    case "$name" in
        /*) return 0;;
    esac
    f=$(sqlite_file "$name")
    rm -f "$f" "$f-wal" "$f-shm"
    # Create the file so it exists and is empty (no tables).
    sqlite3 "$f" 'PRAGMA user_version;' >/dev/null
}

# A file database is ready by existing.
eng_wait_ready() {
    return 0
}

# One query against the database file. The db argument is unused - a SQLite
# file IS the database - but the interface passes it, so it is accepted and
# ignored. -noheader -batch gives the bare tuples the rest of the code expects.
eng_query() {
    local f
    f=$(sqlite_file "$1")
    sqlite3 -noheader -batch "$f" "$3" < /dev/null 2>/dev/null
}

# Dump the database as SQL to stdout. `.dump` runs inside a read transaction,
# so the snapshot is consistent even under concurrent writers - the whole
# reason it beats `cp`. It emits every table, index, view and trigger, plus
# sqlite_sequence, wrapped in BEGIN/COMMIT.
eng_dump() {
    local f
    f=$(sqlite_file "$1")
    sqlite3 "$f" '.dump'
}

# Restore from stdin into the (fresh, empty) instance. -bail so a parse error
# stops rather than limping on; the BEGIN/COMMIT wrapper already makes the
# whole apply atomic, which is why a truncated dump leaves NO table rather than
# half of one (measured).
eng_restore() {
    local f
    f=$(sqlite_file "$1")
    sqlite3 -bail "$f"
}

# Cheap parse gate: a `.dump` always ends with `COMMIT;`, the line an
# interrupted dump never reaches. Also require the BEGIN header, so a random
# text file cannot pass. Reads the whole stream (the truncation is at the END).
eng_archive_parses() {
    local tmp rc=0
    tmp=$(mktemp)
    cat > "$tmp"
    grep -q 'BEGIN TRANSACTION;' "$tmp" || rc=1
    # The trailer, on its own line: `.dump` closes with exactly `COMMIT;`.
    tail -n 5 "$tmp" | grep -qx 'COMMIT;' || rc=1
    rm -f "$tmp"
    return "$rc"
}

# The base tables, sorted - these are the "tables". SQLite's own bookkeeping
# tables (sqlite_sequence, sqlite_stat*) are internal and never compared.
eng_list_tables() {
    local f
    f=$(sqlite_file "$1")
    sqlite3 -noheader -batch "$f" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
}

# A content fingerprint of one table: HASH:COUNT, deterministic and immune to
# both NULL/'NULL' confusion and embedded newlines.
#
# quote() per column (built from PRAGMA table_info) makes NULL distinct from
# the string 'NULL' - quote(NULL) is the bareword NULL, quote('NULL') is a
# quoted string - and char(31) between columns keeps a value ending in the
# separator from colliding with the next column. The per-row texts are ordered
# and joined INSIDE SQLite (group_concat over an ORDER BY subquery) into ONE
# value, then hashed once: a newline inside a value is just bytes in that
# single value, never a row boundary, so it cannot fool a line-oriented sort
# (measured with a value literally containing a newline).
eng_table_fingerprint() {
    local f table expr count
    f=$(sqlite_file "$1")
    table="$3"
    expr=$(sqlite3 -noheader -batch "$f" \
        "SELECT group_concat('quote(\"'||name||'\")', '||char(31)||') FROM pragma_table_info('$table');")
    [ -n "$expr" ] || die "could not read the column list of '$table' - refusing to fingerprint nothing"
    count=$(sqlite3 -noheader -batch "$f" "SELECT count(*) FROM \"$table\";")
    if [ "${count:-0}" -eq 0 ]; then
        printf 'EMPTY:0'
        return 0
    fi
    printf '%s:%s' \
        "$(sqlite3 -noheader -batch "$f" \
            "SELECT group_concat(r, char(30)) FROM (SELECT $expr AS r FROM \"$table\" ORDER BY r);" \
            | sha256sum | awk '{print $1}')" \
        "$count"
}

# count:md5 over the sorted definition lines of one schema class, exactly like
# the database engines digest theirs. Auto-created objects (the sqlite_autoindex
# a UNIQUE/PK makes) carry a NULL sql and are excluded: they are implied by the
# table definition, not independent objects, and would count differently across
# equivalent restores.
#
# Each object's stored `sql` is normalized to ONE line (newlines -> spaces): a
# multi-line CREATE TRIGGER is a single object, and counting lines instead of
# objects would report "3 triggers" for one three-line definition (measured),
# and could let one N-line object masquerade as N one-line ones. `grep -c .`
# then counts objects, not lines.
eng_schema_digest() {
    local f class lines count
    f=$(sqlite_file "$1")
    class="$3"
    local flat="replace(replace(sql,char(10),' '),char(13),' ')"
    case "$class" in
        indexes)  lines=$(sqlite3 -noheader -batch "$f" "SELECT name||' '||$flat FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY name;");;
        views)    lines=$(sqlite3 -noheader -batch "$f" "SELECT name||' '||$flat FROM sqlite_master WHERE type='view' ORDER BY name;");;
        triggers) lines=$(sqlite3 -noheader -batch "$f" "SELECT name||' '||$flat FROM sqlite_master WHERE type='trigger' ORDER BY name;");;
        *)        die "unknown object class for $ENG_NAME: $class";;
    esac
    count=$(printf '%s\n' "$lines" | grep -c . || true)
    printf '%s:%s' "$count" "$(printf '%s' "$lines" | md5sum | awk '{print $1}')"
}

# How many base tables the database holds - proves the target starts empty and
# that the restored copy has no EXTRA tables.
eng_count_tables() {
    local f
    f=$(sqlite_file "$1")
    sqlite3 -noheader -batch "$f" \
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
}

# Everything a restore might land - tables, views, indexes, triggers - so a
# non-empty target is caught before it can pretend to be a clean restore.
eng_count_relations() {
    local f
    f=$(sqlite_file "$1")
    sqlite3 -noheader -batch "$f" \
        "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';"
}

# Can the application WRITE after the restore? An AUTOINCREMENT counter
# (sqlite_sequence.seq) restored BEHIND the largest id its table holds makes
# the next INSERT reuse that id and collide with the primary key: every row
# present, the app broken on its first write - the SQLite twin of a Postgres
# sequence behind its data or a MySQL AUTO_INCREMENT below its max.
eng_writable_probe_failures() {
    local f line name seq maxid failures=0
    f=$(sqlite_file "$1")
    # Only AUTOINCREMENT tables have a sqlite_sequence row; plain rowid tables
    # compute the next id live and cannot fall behind.
    if ! sqlite3 -noheader -batch "$f" \
            "SELECT name FROM sqlite_master WHERE type='table' AND name='sqlite_sequence';" \
            | grep -q .; then
        return 0
    fi
    while IFS='|' read -r name seq; do
        [ -n "$name" ] || continue
        maxid=$(sqlite3 -noheader -batch "$f" "SELECT coalesce(max(rowid),0) FROM \"$name\";")
        if [ "${seq:-0}" -lt "${maxid:-0}" ]; then
            printf 'AUTOINCREMENT counter for %s (%s) sits below its data (max id %s) - the next INSERT reuses an id\n' \
                "$name" "$seq" "$maxid"
            failures=$((failures + 1))
        fi
    done < <(sqlite3 -noheader -batch -separator '|' "$f" \
                "SELECT name, seq FROM sqlite_sequence ORDER BY name;" 2>/dev/null || true)
    return "$failures"
}

# Tear the throwaway instance down. ONLY derived scratch files are ever
# removed - an absolute path is user-supplied source, and deleting it would
# make this tool the disaster it exists to prevent. The WAL/SHM sidecars go too.
eng_teardown() {
    local f
    case "$1" in
        /*) return 0;;
    esac
    f=$(sqlite_file "$1")
    rm -f "$f" "$f-wal" "$f-shm"
}
