#!/usr/bin/env bats
# Unit tests for binlog.sh: argument parsing, the binlog name arithmetic and
# the cheap refusal gates - the ones that run BEFORE anything boots. No
# containers are started: the fabricated-manifest tests exercise exactly the
# gates whose point is refusing early. The script is SOURCED behind its
# BASH_SOURCE guard.

setup() {
    REPO="${BATS_TEST_DIRNAME}/.."
}

@test "binlog.sh --help lists every subcommand and option" {
    run bash "$REPO/binlog.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"base"* ]]
    [[ "$output" == *"mark"* ]]
    [[ "$output" == *"check"* ]]
    [[ "$output" == *"verify"* ]]
    [[ "$output" == *"--tools"* ]]
    [[ "$output" == *"--archive"* ]]
    [[ "$output" == *"-h, --help"* ]]
}

@test "binlog.sh refuses to run without a subcommand, and names unknown ones" {
    run bash "$REPO/binlog.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"a subcommand is required"* ]]
    run bash "$REPO/binlog.sh" replay
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown subcommand"* ]]
}

@test "every subcommand names the inputs it refuses to run without" {
    tmp=$(mktemp -d)
    run bash -c "source '$REPO/binlog.sh'; parse_args base"
    [ "$status" -ne 0 ]
    [[ "$output" == *"base needs --container"* ]]
    run bash -c "source '$REPO/binlog.sh'; parse_args mark --container c --db app"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--archive is required"* ]]
    run bash -c "source '$REPO/binlog.sh'; parse_args verify --archive '$tmp'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"verify needs --base"* ]]
    run bash -c "source '$REPO/binlog.sh'; parse_args verify --archive '$tmp' --base b --mark m"
    [ "$status" -ne 0 ]
    [[ "$output" == *"verify needs --tools"* ]]
    run bash -c "source '$REPO/binlog.sh'; parse_args verify --archive '$tmp' --base b --mark m --tools '$tmp'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no executable mysqlbinlog"* ]]
    rm -rf "$tmp"
}

@test "binlog name arithmetic: one decimal counter, any prefix, no carry games" {
    source "$REPO/lib/mysql.sh"
    source "$REPO/binlog.sh" 2>/dev/null || true
    [ "$(binlog_prefix_of binlog.000004)" = "binlog" ]
    [ "$(binlog_prefix_of mysql-bin.000123)" = "mysql-bin" ]
    [ "$(binlog_index_of binlog.000255)" = "255" ]
    [ "$(binlog_index_of binlog.000009)" = "9" ]   # 10# defuses octal
    [ "$(binlog_name binlog 256)" = "binlog.000256" ]
    [ "$(binlog_name mysql-bin 7)" = "mysql-bin.000007" ]
}

@test "binlog.sh verify refuses pitr and dump manifests, pointing at their tools" {
    tmp=$(mktemp -d)
    mkdir "$tmp/tools" "$tmp/archive"
    printf '#!/bin/sh\n' > "$tmp/tools/mysqlbinlog"; chmod +x "$tmp/tools/mysqlbinlog"
    printf '{\n  "schema": 3,\n  "kind": "pitr-base",\n  "database": "app"\n}\n' > "$tmp/pitr.json"
    run bash "$REPO/binlog.sh" verify --base "$tmp/pitr.json" --mark "$tmp/pitr.json" --archive "$tmp/archive" --tools "$tmp/tools"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a binlog-base manifest"* ]]
    [[ "$output" == *"./pitr.sh"* ]]
    rm -rf "$tmp"
}

@test "verify.sh refuses a binlog manifest and points at binlog.sh" {
    tmp=$(mktemp -d)
    printf '{\n  "schema": 3,\n  "kind": "binlog-mark",\n  "database": "app"\n}\n' > "$tmp/m.json"
    run bash "$REPO/verify.sh" --manifest "$tmp/m.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"./binlog.sh verify"* ]]
    rm -rf "$tmp"
}

# A fabricated base+mark pair whose artefact hashes correctly, so the tests
# reach the reachability and continuity gates - the ones that refuse in
# milliseconds what a replay would silently get wrong (measured: holes are
# stitched over with rc 0).
fabricate_pair() {
    local dir="$1" anchor_file="$2" anchor_pos="$3" mark_file="$4" mark_pos="$5"
    printf 'not really a mysqldump' > "$dir/b_binlogbase.sql"
    local sha bytes
    sha=$(sha256sum "$dir/b_binlogbase.sql" | cut -d' ' -f1)
    bytes=$(stat -c%s "$dir/b_binlogbase.sql")
    printf '{\n  "schema": 3,\n  "kind": "binlog-base",\n  "database": "app",\n  "artefact": "b_binlogbase.sql",\n  "bytes": %s,\n  "sha256": "%s",\n  "engine": "mysql",\n  "server_version": "8.4",\n  "anchor_file": "%s",\n  "anchor_pos": %s\n}\n' \
        "$bytes" "$sha" "$anchor_file" "$anchor_pos" > "$dir/b_binlogbase.json"
    printf '{\n  "schema": 3,\n  "kind": "binlog-mark",\n  "database": "app",\n  "mark_file": "%s",\n  "mark_pos": %s,\n  "binlogs": {\n    "%s": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:158"\n  },\n  "tables": {\n    "t": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1"\n  },\n  "objects": {\n  }\n}\n' \
        "$mark_file" "$mark_pos" "$mark_file" > "$dir/m_binlogmark.json"
}

@test "verify refuses a mark that predates the anchor, before anything boots" {
    tmp=$(mktemp -d)
    mkdir "$tmp/tools" "$tmp/archive"
    printf '#!/bin/sh\n' > "$tmp/tools/mysqlbinlog"; chmod +x "$tmp/tools/mysqlbinlog"
    fabricate_pair "$tmp" binlog.000005 500 binlog.000003 100
    run bash "$REPO/binlog.sh" verify --base "$tmp/b_binlogbase.json" --mark "$tmp/m_binlogmark.json" \
        --archive "$tmp/archive" --tools "$tmp/tools"
    [ "$status" -ne 0 ]
    [[ "$output" == *"predates the base"* ]]
    [[ "$output" != *"booting"* ]]
    rm -rf "$tmp"
}

@test "verify refuses a mark whose prefix names a different server's history" {
    tmp=$(mktemp -d)
    mkdir "$tmp/tools" "$tmp/archive"
    printf '#!/bin/sh\n' > "$tmp/tools/mysqlbinlog"; chmod +x "$tmp/tools/mysqlbinlog"
    fabricate_pair "$tmp" binlog.000002 158 mysql-bin.000005 200
    run bash "$REPO/binlog.sh" verify --base "$tmp/b_binlogbase.json" --mark "$tmp/m_binlogmark.json" \
        --archive "$tmp/archive" --tools "$tmp/tools"
    [ "$status" -ne 0 ]
    [[ "$output" == *"two different servers"* ]]
    rm -rf "$tmp"
}

@test "verify refuses a hole in the chain, naming the measured stitch-over" {
    tmp=$(mktemp -d)
    mkdir "$tmp/tools" "$tmp/archive"
    printf '#!/bin/sh\n' > "$tmp/tools/mysqlbinlog"; chmod +x "$tmp/tools/mysqlbinlog"
    fabricate_pair "$tmp" binlog.000003 158 binlog.000005 200
    printf 'log bytes' > "$tmp/archive/binlog.000003"
    printf 'log bytes' > "$tmp/archive/binlog.000005"   # 000004 missing
    run bash "$REPO/binlog.sh" verify --base "$tmp/b_binlogbase.json" --mark "$tmp/m_binlogmark.json" \
        --archive "$tmp/archive" --tools "$tmp/tools"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing binlog.000004"* ]]
    [[ "$output" == *"stitch over"* ]]
    [[ "$output" != *"booting"* ]]
    rm -rf "$tmp"
}

@test "verify refuses bytes the mark's inventory never stood on" {
    tmp=$(mktemp -d)
    mkdir "$tmp/tools" "$tmp/archive"
    printf '#!/bin/sh\n' > "$tmp/tools/mysqlbinlog"; chmod +x "$tmp/tools/mysqlbinlog"
    fabricate_pair "$tmp" binlog.000003 158 binlog.000003 200
    printf 'the wrong bytes entirely' > "$tmp/archive/binlog.000003"
    run bash "$REPO/binlog.sh" verify --base "$tmp/b_binlogbase.json" --mark "$tmp/m_binlogmark.json" \
        --archive "$tmp/archive" --tools "$tmp/tools"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not the bytes the mark stood on"* ]]
    [[ "$output" == *"replay them anyway"* ]]
    rm -rf "$tmp"
}

@test "check names strays and numbering holes from the directory alone" {
    tmp=$(mktemp -d)
    printf 'x' > "$tmp/binlog.000002"
    printf 'x' > "$tmp/binlog.000004"   # 000003 missing
    printf 'x' > "$tmp/.binlog.000009.copying"
    run bash "$REPO/binlog.sh" check --archive "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing binlog.000003"* ]]
    [[ "$output" == *".binlog.000009.copying - not an archived binlog"* ]]
    rm -rf "$tmp"
}

@test "check refuses an archive written by two different servers" {
    tmp=$(mktemp -d)
    printf 'x' > "$tmp/binlog.000002"
    printf 'x' > "$tmp/mysql-bin.000002"
    run bash "$REPO/binlog.sh" check --archive "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"TWO prefixes"* ]]
    rm -rf "$tmp"
}
