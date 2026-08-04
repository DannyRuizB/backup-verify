#!/usr/bin/env bats
# Unit tests over argument parsing and the pure helpers. No Docker, no host
# touched: the scripts are SOURCED, and their `main` is guarded by a
# BASH_SOURCE check (the idiom borrowed from the debian-hardening siblings).

setup() {
    REPO="${BATS_TEST_DIRNAME}/.."
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
    [[ "$output" == *"--container is required"* ]]
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
    for engine in postgres mysql; do
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
    for engine in postgres mysql; do
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
    for engine in postgres mysql; do
        for fn in eng_boot eng_wait_ready eng_query eng_dump eng_restore \
                  eng_archive_parses eng_list_tables eng_table_fingerprint \
                  eng_schema_digest eng_count_tables eng_count_relations \
                  eng_writable_probe_failures; do
            run grep -c "^$fn()" "$REPO/lib/$engine.sh"
            [ "$output" = "1" ]
        done
        run bash -c "grep -c '^ENG_NAME=\|^ENG_DEFAULT_IMAGE=\|^ENG_ARTEFACT_EXT=' '$REPO/lib/$engine.sh'"
        [ "$output" = "3" ]
    done
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
