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

@test "the fingerprint SQL sorts rows so physical order cannot matter" {
    run bash -c "source '$REPO/lib/common.sh'; fingerprint_sql customers"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ORDER BY row_text"* ]]
    [[ "$output" == *"md5"* ]]
}

@test "psql_in never attaches stdin (it would eat a caller's read loop)" {
    # Regression guard for a real bug: with `docker exec -i`, calling psql_in
    # from inside a `while read` loop made psql swallow the loop's remaining
    # input, and the manifest listed 1 of 2 tables.
    run grep -n 'docker exec' "$REPO/lib/common.sh"
    [[ "$output" != *"docker exec -i \"\$container\" psql"* ]]
    run bash -c "grep -A3 '^psql_in()' '$REPO/lib/common.sh'"
    [[ "$output" == *"/dev/null"* ]]
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

@test "every schema class has a deterministic, ORDER BY'd query" {
    for class in indexes constraints sequences views routines triggers; do
        run bash -c "source '$REPO/lib/common.sh'; schema_query $class"
        [ "$status" -eq 0 ]
        [[ "$output" == *"ORDER BY"* ]]
        [[ "$output" == *"public"* ]]
    done
}

@test "an unknown schema class is a loud error, not an empty digest" {
    run bash -c "source '$REPO/lib/common.sh'; schema_query nonsense"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown object class"* ]]
}

@test "sequences are compared with their last_value, not just their names" {
    # A sequence restored behind its data means the next INSERT collides.
    run bash -c "source '$REPO/lib/common.sh'; schema_query sequences"
    [[ "$output" == *"last_value"* ]]
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
