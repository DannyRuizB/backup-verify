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
