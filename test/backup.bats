#!/usr/bin/env bats
# Unit tests over argument parsing and the pure helpers. No Docker, no host
# touched: the scripts are SOURCED, and their `main` is guarded by a
# BASH_SOURCE check (the idiom borrowed from the debian-hardening siblings).

setup() {
    REPO="${BATS_TEST_DIRNAME}/.."
    # The sqlite engine's unit tests need the CLI; skip them cleanly if it is
    # not installed rather than failing the whole suite (CI has it).
    SQLITE="$(command -v sqlite3 || true)"
    if [[ "$BATS_TEST_DESCRIPTION" == sqlite\ engine:* && -z "$SQLITE" ]]; then
        skip "sqlite3 CLI not installed"
    fi
}

@test "backup.sh --help lists every option" {
    run bash "$REPO/backup.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--container"* ]]
    [[ "$output" == *"--db"* ]]
    [[ "$output" == *"--keep"* ]]
    [[ "$output" == *"-h, --help"* ]]
}

@test "backup.sh refuses to run without --container" {
    run bash -c "source '$REPO/backup.sh'; parse_args --db app"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--container (or --path) is required"* ]]
}

@test "backup.sh --path sets the source and derives the dataset name" {
    dir=$(mktemp -d)
    mkdir "$dir/webroot"
    run bash -c "source '$REPO/backup.sh'; parse_args --engine files --path '$dir/webroot'; echo \"\$CONTAINER \$DB\""
    [ "$status" -eq 0 ]
    [ "$output" = "$dir/webroot webroot" ]
    rm -rf "$dir"
}

@test "backup.sh refuses --path and --container together" {
    dir=$(mktemp -d)
    run bash -c "source '$REPO/backup.sh'; parse_args --container c --path '$dir'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"two different sources"* ]]
    rm -rf "$dir"
}

@test "backup.sh refuses a --path that does not exist" {
    run bash -c "source '$REPO/backup.sh'; parse_args --engine files --path /no/such/dir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "backup.sh refuses to run without --db" {
    run bash -c "source '$REPO/backup.sh'; parse_args --container c"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--db is required"* ]]
}

@test "backup.sh rejects a non-numeric --keep" {
    run bash -c "source '$REPO/backup.sh'; parse_args --container c --db app --keep two"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--keep must be a non-negative integer"* ]]
}

@test "backup.sh accepts a full valid invocation" {
    run bash -c "source '$REPO/backup.sh'; parse_args --container c --db app --out /tmp/x --keep 3 --label nightly; echo \"\$CONTAINER \$DB \$OUT_DIR \$KEEP \$LABEL\""
    [ "$status" -eq 0 ]
    [ "$output" = "c app /tmp/x 3 nightly" ]
}

@test "backup.sh rejects an unknown option" {
    run bash "$REPO/backup.sh" --nonsense
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown option"* ]]
}

@test "verify.sh requires a manifest" {
    run bash -c "source '$REPO/verify.sh'; parse_args"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--manifest is required"* ]]
}

@test "verify.sh reads flat keys out of a manifest" {
    tmp="$BATS_TEST_TMPDIR/m.json"
    cat > "$tmp" <<'JSON'
{
  "schema": 1,
  "database": "shop",
  "artefact": "shop_20260101T000000Z.dump",
  "bytes": 12345,
  "sha256": "abc123",
  "tables": {
    "customers": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "orders": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
}
JSON
    run bash -c "source '$REPO/verify.sh'; json_str '$tmp' database; json_num '$tmp' bytes; json_str '$tmp' sha256"
    [ "$status" -eq 0 ]
    [[ "$output" == *"shop"* ]]
    [[ "$output" == *"12345"* ]]
    [[ "$output" == *"abc123"* ]]
}

@test "verify.sh extracts every table fingerprint, and only those" {
    tmp="$BATS_TEST_TMPDIR/m.json"
    cat > "$tmp" <<'JSON'
{
  "database": "shop",
  "sha256": "notatable",
  "tables": {
    "customers": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "orders": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
}
JSON
    run bash -c "source '$REPO/verify.sh'; manifest_tables '$tmp' | wc -l"
    [ "$output" = "2" ]
    # The top-level keys sit at two spaces, table entries at four - so a key
    # like "sha256" must never be mistaken for a table.
    run bash -c "source '$REPO/verify.sh'; manifest_tables '$tmp'"
    [[ "$output" != *"sha256"* ]]
    [[ "$output" == *"customers"* ]]
    [[ "$output" == *"orders"* ]]
}

@test "every engine's fingerprint sorts rows so physical order cannot matter" {
    # Both engines must sort before hashing, or two identical databases would
    # disagree because their rows sit in a different physical order.
    run bash -c "grep -A4 '^eng_table_fingerprint' '$REPO/lib/postgres.sh'"
    [[ "$output" == *"ORDER BY row_text"* ]]
    run bash -c "grep -A18 '^eng_table_fingerprint' '$REPO/lib/mysql.sh'"
    [[ "$output" == *"ORDER BY row_text"* ]]
}

@test "no engine's query helper attaches stdin (it would eat a caller's read loop)" {
    # Regression guard for a real bug: with `docker exec -i`, calling the query
    # helper from inside a `while read` loop made the client swallow the loop's
    # remaining input, and the manifest listed 1 of 2 tables.
    for engine in postgres mysql sqlite; do
        run bash -c "grep -A3 '^eng_query' '$REPO/lib/$engine.sh'"
        [[ "$output" == *"/dev/null"* ]]
        [[ "$output" != *"docker exec -i \"\$container\""* ]]
    done
}

# --- schema verification (v0.2) ---------------------------------------------

@test "manifest_section keeps 'tables' and 'objects' apart" {
    tmp="$BATS_TEST_TMPDIR/m.json"
    cat > "$tmp" <<'JSON'
{
  "schema": 2,
  "database": "shop",
  "tables": {
    "customers": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "orders": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  },
  "objects": {
    "indexes": "4:cccccccccccccccccccccccccccccccc",
    "views": "1:dddddddddddddddddddddddddddddddd"
  }
}
JSON
    # Both sections indent by four spaces, so a naive match would mix them.
    run bash -c "source '$REPO/verify.sh'; manifest_section '$tmp' tables | wc -l"
    [ "$output" = "2" ]
    run bash -c "source '$REPO/verify.sh'; manifest_section '$tmp' objects | wc -l"
    [ "$output" = "2" ]
    run bash -c "source '$REPO/verify.sh'; manifest_section '$tmp' tables"
    [[ "$output" != *"indexes"* ]]
    run bash -c "source '$REPO/verify.sh'; manifest_section '$tmp' objects"
    [[ "$output" != *"customers"* ]]
    [[ "$output" == *"4:cccc"* ]]
}

@test "every engine covers every schema class, with ORDER BY" {
    # A class an engine forgets would silently never be compared.
    for engine in postgres mysql; do
        for class in indexes constraints sequences views routines triggers; do
            run bash -c "sed -n '/^eng_schema_digest/,/^}/p' '$REPO/lib/$engine.sh' | grep -c '^ *$class)'"
            [ "$output" = "1" ]
        done
        run bash -c "sed -n '/^eng_schema_digest/,/^}/p' '$REPO/lib/$engine.sh' | grep -c 'ORDER BY'"
        [ "$output" -ge 6 ]
    done
}

@test "an unknown schema class is a loud error in every engine" {
    for engine in postgres mysql sqlite files; do
        run bash -c "sed -n '/^eng_schema_digest/,/^}/p' '$REPO/lib/$engine.sh'"
        [[ "$output" == *"unknown object class"* ]]
    done
}

@test "an unsupported engine is refused by name" {
    run bash -c "source '$REPO/lib/common.sh'; load_engine oracle"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported engine"* ]]
}

@test "each engine module defines the whole eng_* interface" {
    # Adding an engine must not mean discovering a missing function at runtime,
    # halfway through someone's restore.
    for engine in postgres mysql files sqlite; do
        for fn in eng_preflight eng_boot eng_wait_ready eng_query eng_dump \
                  eng_restore eng_archive_parses eng_list_tables \
                  eng_table_fingerprint eng_schema_digest eng_count_tables \
                  eng_count_relations eng_writable_probe_failures eng_teardown; do
            run grep -c "^$fn()" "$REPO/lib/$engine.sh"
            [ "$output" = "1" ]
        done
        run bash -c "grep -c '^ENG_NAME=\|^ENG_DEFAULT_IMAGE=\|^ENG_ARTEFACT_EXT=\|^ENG_UNIT=' '$REPO/lib/$engine.sh'"
        [ "$output" = "4" ]
    done
}

@test "files engine: a probe name maps under /tmp, an absolute path stays itself" {
    # eng_teardown does rm -rf on what files_root returns - this mapping is
    # the one thing standing between cleanup and deleting a user's source.
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/files.sh'; files_root bv-verify-123; echo; files_root /srv/app"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "${TMPDIR:-/tmp}/bv-files-bv-verify-123" ]
    [ "${lines[1]}" = "/srv/app" ]
}

@test "files engine: teardown never removes an absolute (user-supplied) path" {
    dir=$(mktemp -d)
    touch "$dir/precious"
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/files.sh'; eng_teardown '$dir'"
    [ "$status" -eq 0 ]
    [ -f "$dir/precious" ]
    rm -rf "$dir"
    # ...while a derived scratch root IS removed
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/files.sh';
        eng_boot probe-bats-$$; [ -d \"\$(files_root probe-bats-$$)\" ] || exit 1;
        eng_teardown probe-bats-$$; [ ! -d \"\$(files_root probe-bats-$$)\" ]"
    [ "$status" -eq 0 ]
}

@test "files engine: fingerprints are sha256:bytes and pass the fingerprint guard" {
    dir=$(mktemp -d)
    printf 'hello\n' > "$dir/f.txt"
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/files.sh';
        fp=\$(eng_table_fingerprint '$dir' ignored f.txt); assert_fingerprint f.txt \"\$fp\"; printf '%s' \"\$fp\""
    [ "$status" -eq 0 ]
    [ "$output" = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03:6" ]
    # an absent file is a non-zero return, which verify reads as "absent"
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/files.sh'; eng_table_fingerprint '$dir' ignored missing.txt"
    [ "$status" -ne 0 ]
    rm -rf "$dir"
}

@test "files engine: file names the manifest cannot represent are refused" {
    dir=$(mktemp -d)
    touch "$dir/ok.txt" "$dir/"'bad"name.txt'
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/files.sh'; eng_list_tables '$dir' ignored"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot represent"* ]]
    rm -rf "$dir"
}

@test "manifest_for maps every artefact form, files engine included" {
    run bash -c "source '$REPO/lib/common.sh'; manifest_for backups/app_1.tar.gz; echo; manifest_for backups/app_1.tar.gz.age"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "backups/app_1.json" ]
    [ "${lines[1]}" = "backups/app_1.json" ]
}

@test "sqlite engine: a probe name maps under /tmp, an absolute path stays itself" {
    # eng_teardown does rm -f on what sqlite_file returns - the same guard the
    # files engine has between cleanup and deleting a user's database.
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/sqlite.sh'; sqlite_file bv-verify-123; echo; sqlite_file /srv/app.db"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "${TMPDIR:-/tmp}/bv-sqlite-bv-verify-123.db" ]
    [ "${lines[1]}" = "/srv/app.db" ]
}

@test "sqlite engine: teardown never removes an absolute (user-supplied) database" {
    dir=$(mktemp -d)
    "$SQLITE" "$dir/precious.db" 'CREATE TABLE t(x);' >/dev/null
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/sqlite.sh'; eng_teardown '$dir/precious.db'"
    [ "$status" -eq 0 ]
    [ -f "$dir/precious.db" ]
    rm -rf "$dir"
    # ...while a derived scratch database IS removed
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/sqlite.sh';
        eng_boot probe-bats-$$; [ -f \"\$(sqlite_file probe-bats-$$)\" ] || exit 1;
        eng_teardown probe-bats-$$; [ ! -f \"\$(sqlite_file probe-bats-$$)\" ]"
    [ "$status" -eq 0 ]
}

@test "sqlite engine: fingerprints are HASH:COUNT, deterministic and NULL-safe" {
    dir=$(mktemp -d)
    "$SQLITE" "$dir/f.db" "CREATE TABLE t(id INTEGER, v TEXT); INSERT INTO t VALUES (1,'a'),(2,NULL),(3,'NULL');" >/dev/null
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/sqlite.sh'; eng_table_fingerprint '$dir/f.db' ignored t"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{64}:3$ ]]
    fp1="$output"
    # Deterministic: same data, same fingerprint.
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/sqlite.sh'; eng_table_fingerprint '$dir/f.db' ignored t"
    [ "$output" = "$fp1" ]
    # NULL and the string 'NULL' must NOT hash the same: flip row 2 to 'NULL'.
    "$SQLITE" "$dir/f.db" "UPDATE t SET v='NULL' WHERE id=2;" >/dev/null
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/sqlite.sh'; eng_table_fingerprint '$dir/f.db' ignored t"
    [ "$output" != "$fp1" ]
    # An empty table is EMPTY:0, never a hash of nothing.
    "$SQLITE" "$dir/f.db" "CREATE TABLE e(x);" >/dev/null
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/sqlite.sh'; eng_table_fingerprint '$dir/f.db' ignored e"
    [ "$output" = "EMPTY:0" ]
    rm -rf "$dir"
}

@test "sqlite engine: the parse gate demands the COMMIT trailer a truncated dump lacks" {
    # A .dump ends with COMMIT; an interrupted one does not - the SQLite twin
    # of MySQL's 'Dump completed' truncation detector.
    good="BEGIN TRANSACTION;
CREATE TABLE t(x);
COMMIT;"
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/sqlite.sh'; printf '%s\n' '$good' | eng_archive_parses"
    [ "$status" -eq 0 ]
    trunc="BEGIN TRANSACTION;
CREATE TABLE t(x);
INSERT INTO t VALUES(1"
    run bash -c "source '$REPO/lib/common.sh'; source '$REPO/lib/sqlite.sh'; printf '%s\n' '$trunc' | eng_archive_parses"
    [ "$status" -ne 0 ]
}

@test "sqlite engine: schema classes are indexes/views/triggers, each with ORDER BY" {
    for class in indexes views triggers; do
        run bash -c "sed -n '/^eng_schema_digest/,/^}/p' '$REPO/lib/sqlite.sh' | grep -c '^ *$class)'"
        [ "$output" = "1" ]
    done
    run bash -c "sed -n '/^eng_schema_digest/,/^}/p' '$REPO/lib/sqlite.sh' | grep -c 'ORDER BY'"
    [ "$output" -ge 3 ]
}

@test "Postgres compares sequences with their last_value" {
    # A sequence restored behind its data means the next INSERT collides.
    run bash -c "sed -n '/^eng_schema_digest/,/^}/p' '$REPO/lib/postgres.sh'"
    [[ "$output" == *"last_value"* ]]
}

@test "MySQL fingerprints auto_increment EXISTENCE, never the counter value" {
    # Measured on 8.4: information_schema rounds the counter (512/1024 while the
    # real maxima were 500/800), so comparing it would raise false alarms.
    run bash -c "sed -n '/^eng_schema_digest/,/^}/p' '$REPO/lib/mysql.sh' | sed -n '/sequences)/,/;;/p'"
    [[ "$output" == *"auto_increment"* ]]
    [[ "$output" != *"IFNULL(auto_increment"* ]]
}

@test "MySQL defuses the group_concat_max_len trap twice over" {
    # Default 1024 bytes: a fingerprint would cover 6% of the data and report OK.
    run bash -c "sed -n '/^eng_table_fingerprint/,/^}/p' '$REPO/lib/mysql.sh'"
    [[ "$output" == *"group_concat_max_len"* ]]   # raise the limit...
    [[ "$output" == *"expected_len"* ]]           # ...and prove it was enough
    [[ "$output" == *"TRUNCATED"* ]]
}

@test "MySQL always dumps routines (mysqldump omits them by default)" {
    run bash -c "sed -n '/^eng_dump/,/^}/p' '$REPO/lib/mysql.sh'"
    [[ "$output" == *"--routines"* ]]
    [[ "$output" == *"--triggers"* ]]
    [[ "$output" == *"--single-transaction"* ]]
}

@test "manifest_for handles both engines' extensions, plain and encrypted" {
    run bash -c "source '$REPO/lib/common.sh'; manifest_for /b/a.sql; echo; manifest_for /b/a.sql.age"
    [[ "$output" == *"/b/a.json"* ]]
    run bash -c "source '$REPO/lib/common.sh'; a=\$(manifest_for /b/x.sql); b=\$(manifest_for /b/x.sql.age); [ \"\$a\" = \"\$b\" ]"
    [ "$status" -eq 0 ]
}

@test "colour is suppressed when stdout is not a terminal" {
    # Escape codes broke a grep-based assertion once; a redirected run must be
    # plain bytes.
    run bash -c "source '$REPO/lib/common.sh'; ok 'plain' | cat"
    [[ "$output" != *$'\033'* ]]
}

# --- encryption (v0.3) ------------------------------------------------------

@test "backup.sh rejects --identity without --recipient" {
    run bash -c "source '$REPO/backup.sh'; parse_args --container c --db app --identity /tmp/k"
    [ "$status" -ne 0 ]
    [[ "$output" == *"only makes sense with --recipient"* ]]
}

@test "backup.sh --help documents the encryption options" {
    run bash "$REPO/backup.sh" --help
    [[ "$output" == *"--recipient"* ]]
    [[ "$output" == *"--identity"* ]]
    [[ "$output" == *"NEVER touches disk"* ]]
}

@test "verify.sh --help documents --identity" {
    run bash "$REPO/verify.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--identity"* ]]
}

@test "manifest_for maps both plain and encrypted artefacts to one manifest" {
    run bash -c "source '$REPO/lib/common.sh'; manifest_for /b/app_2026.dump; echo; manifest_for /b/app_2026.dump.age"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/b/app_2026.json"* ]]
    # Both lines must be the same path: the mapping lives in one place so it
    # cannot drift between backup.sh and verify.sh.
    run bash -c "source '$REPO/lib/common.sh'; a=\$(manifest_for /b/x.dump); b=\$(manifest_for /b/x.dump.age); [ \"\$a\" = \"\$b\" ]"
    [ "$status" -eq 0 ]
}

@test "the recipient flags are built as an array, not returned as text" {
    # Regression guard: a helper returning "-r\nage1..." through printf without
    # a trailing newline made `read` drop the value, and age got a bare -r.
    run grep -c 'age_recipient_args' "$REPO/lib/common.sh" "$REPO/backup.sh"
    [[ "$output" != *":1"* ]]
    run bash -c "grep -A6 'recip_args=()' '$REPO/backup.sh'"
    [[ "$output" == *"recip_args=(-R"* ]]
    [[ "$output" == *"recip_args=(-r"* ]]
}

@test "common.sh turns errtrace on, so ERR traps fire inside eng_* functions" {
    # Regression guard for bug 8: without `set -E`, backup.sh's cleanup trap
    # never fired when the dump failed INSIDE eng_dump(), and a failed dump left
    # a plausible 0-byte artefact behind. Negative case 2 caught it.
    run bash -c "source '$REPO/lib/common.sh'; set -o | grep errtrace"
    [ "$status" -eq 0 ]
    [[ "$output" == *on* ]]
}

@test "break_fingerprint corrupts the md5 and keeps the row count intact" {
    # The helper must track the manifest's fingerprint format. When the format
    # grew a ':<rowcount>' suffix, the old 32-hex-only regex matched NOTHING,
    # exited non-zero, and set -e killed the negative suite at case 4.
    tmp=$(mktemp)
    printf '{\n  "tables": {\n    "customers": "0123456789abcdef0123456789abcdef:500"\n  }\n}\n' > "$tmp"
    run python3 "$REPO/test/break_fingerprint.py" "$tmp"
    [ "$status" -eq 0 ]
    run grep -c 'deadbeefdeadbeefdeadbeefdeadbeef:500' "$tmp"
    [ "$output" = "1" ]
    rm -f "$tmp"
}
