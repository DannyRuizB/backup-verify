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

# --- the off-site binlog archive ---------------------------------------------------

@test "binlog help lists push, pull and the remote options" {
    run bash "$REPO/binlog.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"push"* ]]
    [[ "$output" == *"pull"* ]]
    [[ "$output" == *"--remote"* ]]
    [[ "$output" == *"--ssh-opts"* ]]
}

@test "binlog push and pull name every input they refuse to run without" {
    tmp=$(mktemp -d)
    run bash -c "source '$REPO/binlog.sh'; parse_args push --archive '$tmp'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"push needs --base"* ]]
    run bash -c "source '$REPO/binlog.sh'; parse_args push --archive '$tmp' --base b --mark m"
    [ "$status" -ne 0 ]
    [[ "$output" == *"push needs --remote"* ]]
    run bash -c "source '$REPO/binlog.sh'; parse_args pull --archive '$tmp' --remote r"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pull needs --db"* ]]
    rm -rf "$tmp"
}

@test "binlog check audits the local archive or the remote, never both at once" {
    tmp=$(mktemp -d)
    run bash -c "source '$REPO/binlog.sh'; parse_args check --archive '$tmp' --remote '$tmp'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not both at once"* ]]
    run bash -c "source '$REPO/binlog.sh'; parse_args check --remote '$tmp' && echo PARSED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PARSED"* ]]
    rm -rf "$tmp"
}

@test "binlog pull creates its archive directory - disaster recovery starts with nothing" {
    tmp=$(mktemp -d)
    run bash -c "source '$REPO/binlog.sh'; parse_args pull --db app --remote r --archive '$tmp/fresh/archive' && echo PARSED"
    [ "$status" -eq 0 ]
    [ -d "$tmp/fresh/archive" ]
    rm -rf "$tmp"
}

@test "binlog push refuses to replicate a local hole off-site" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote" "$tmp/archive"
    fabricate_pair "$tmp" binlog.000003 158 binlog.000005 200
    printf 'log bytes' > "$tmp/archive/binlog.000003"
    printf 'log bytes' > "$tmp/archive/binlog.000005"   # 000004 missing locally
    run bash "$REPO/binlog.sh" push --base "$tmp/b_binlogbase.json" --mark "$tmp/m_binlogmark.json" \
        --archive "$tmp/archive" --remote "$tmp/remote"
    [ "$status" -ne 0 ]
    [[ "$output" == *"binlog.000003"* || "$output" == *"binlog.000004"* ]]
    [[ "$output" == *"replicate"* || "$output" == *"inventory"* ]]
    rm -rf "$tmp"
}

@test "binlog pull refuses a remote that cannot prove any instant of the database" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote"
    run bash "$REPO/binlog.sh" pull --db app --remote "$tmp/remote" \
        --archive "$tmp/archive" --out "$tmp/out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no binlog mark manifest for 'app'"* ]]
    rm -rf "$tmp"
}

@test "binlog check --remote names the crashed upload, the missing file and the missing base" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote"
    printf 'crashed' > "$tmp/remote/binlog.000009.part"
    printf '{\n  "schema": 3,\n  "kind": "binlog-mark",\n  "database": "app",\n  "mark_file": "binlog.000005",\n  "mark_pos": 200,\n  "binlogs": {\n    "binlog.000005": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:158"\n  },\n  "tables": {\n  },\n  "objects": {\n  }\n}\n' \
        > "$tmp/remote/app_20260101T000000Z_binlogmark.json"
    run bash "$REPO/binlog.sh" check --remote "$tmp/remote"
    [ "$status" -ne 0 ]
    [[ "$output" == *"binlog.000009.part - a crashed upload"* ]]
    [[ "$output" == *"does not hold it"* ]]
    [[ "$output" == *"no intact base dump at the remote"* ]]
    rm -rf "$tmp"
}

@test "binlog check --remote blesses a remote whose newest mark provably replays" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote"
    printf 'not really a mysqldump' > "$tmp/remote/b.sql"
    bsha=$(sha256sum "$tmp/remote/b.sql" | cut -d' ' -f1)
    bbytes=$(stat -c%s "$tmp/remote/b.sql")
    printf '{\n  "schema": 3,\n  "kind": "binlog-base",\n  "database": "app",\n  "artefact": "b.sql",\n  "bytes": %s,\n  "sha256": "%s",\n  "engine": "mysql",\n  "server_version": "8.4",\n  "anchor_file": "binlog.000005",\n  "anchor_pos": 100\n}\n' \
        "$bbytes" "$bsha" > "$tmp/remote/app_20260101T000000Z_binlogbase.json"
    printf 'log bytes' > "$tmp/remote/binlog.000005"
    ssha=$(sha256sum "$tmp/remote/binlog.000005" | cut -d' ' -f1)
    printf '{\n  "schema": 3,\n  "kind": "binlog-mark",\n  "database": "app",\n  "mark_file": "binlog.000005",\n  "mark_pos": 200,\n  "binlogs": {\n    "binlog.000005": "%s:9"\n  },\n  "tables": {\n  },\n  "objects": {\n  }\n}\n' \
        "$ssha" > "$tmp/remote/app_20260101T000000Z_binlogmark.json"
    run bash "$REPO/binlog.sh" check --remote "$tmp/remote"
    [ "$status" -eq 0 ]
    [[ "$output" == *"can prove every instant it claims"* ]]
    rm -rf "$tmp"
}
