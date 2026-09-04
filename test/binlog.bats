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
    [[ "$output" == *"--keep N"* ]]
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

# --- the encrypted archive (11th round) ----------------------------------------

@test "base and mark refuse --recipient without --identity: the key gets proven today" {
    run bash -c "source '$REPO/binlog.sh'; parse_args base --container c --db app --recipient age1xyz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"base --recipient requires --identity"* ]]
    [[ "$output" == *"anchor lives INSIDE the dump"* ]]
    tmp=$(mktemp -d)
    run bash -c "source '$REPO/binlog.sh'; parse_args mark --container c --db app --archive '$tmp' --recipient age1xyz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mark --recipient requires --identity"* ]]
    rm -rf "$tmp"
}

@test "a key is refused wherever it means nothing: base --identity alone, verify --recipient, push/pull with any key" {
    tmp=$(mktemp -d)
    touch "$tmp/key.txt"
    printf '#!/bin/sh\n' > "$tmp/mysqlbinlog"; chmod +x "$tmp/mysqlbinlog"
    run bash -c "source '$REPO/binlog.sh'; parse_args base --container c --db app --identity '$tmp/key.txt'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--identity only makes sense with --recipient"* ]]
    run bash -c "source '$REPO/binlog.sh'; parse_args verify --archive '$tmp' --base b --mark m --tools '$tmp' --recipient age1xyz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"backup-time option"* ]]
    run bash -c "source '$REPO/binlog.sh'; parse_args push --base b --mark m --archive '$tmp' --remote r --identity '$tmp/key.txt'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"moves opaque ciphertext"* ]]
    run bash -c "source '$REPO/binlog.sh'; parse_args pull --db app --remote r --archive '$tmp' --recipient age1xyz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"moves opaque ciphertext"* ]]
    run bash -c "source '$REPO/binlog.sh'; parse_args base --container c --db app --recipient age1xyz --identity '$tmp/missing'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"identity file not found"* ]]
    rm -rf "$tmp"
}

@test "the archive names its own form: plain, .age, or a mixed coin toss refused" {
    tmp=$(mktemp -d)
    source "$REPO/lib/common.sh"
    source "$REPO/binlog.sh" 2>/dev/null || true
    ARCHIVE_DIR="$tmp"
    [ -z "$(archive_binlog_suffix)" ]                       # empty archive: no form yet
    touch "$tmp/binlog.000001" "$tmp/binlog.000002"
    [ -z "$(archive_binlog_suffix)" ]                       # plain
    rm -f "$tmp"/binlog.00000*
    touch "$tmp/binlog.000001.age"
    [ "$(archive_binlog_suffix)" = ".age" ]                 # encrypted
    touch "$tmp/binlog.000002"
    run archive_binlog_suffix                               # mixed: refuse
    [ "$status" -ne 0 ]
    [[ "$output" == *"BOTH plain and .age"* ]]
    rm -rf "$tmp"
}

@test "verify refuses an encrypted pair without the key, before anything boots" {
    tmp=$(mktemp -d)
    mkdir "$tmp/tools" "$tmp/archive"
    printf '#!/bin/sh\n' > "$tmp/tools/mysqlbinlog"; chmod +x "$tmp/tools/mysqlbinlog"
    printf 'age ciphertext, allegedly' > "$tmp/b_binlogbase.sql.age"
    sha=$(sha256sum "$tmp/b_binlogbase.sql.age" | cut -d' ' -f1)
    bytes=$(stat -c%s "$tmp/b_binlogbase.sql.age")
    printf '{\n  "schema": 3,\n  "kind": "binlog-base",\n  "database": "app",\n  "artefact": "b_binlogbase.sql.age",\n  "bytes": %s,\n  "sha256": "%s",\n  "engine": "mysql",\n  "server_version": "8.4",\n  "anchor_file": "binlog.000003",\n  "anchor_pos": 100\n}\n' \
        "$bytes" "$sha" > "$tmp/b_binlogbase.json"
    printf '{\n  "schema": 3,\n  "kind": "binlog-mark",\n  "database": "app",\n  "mark_file": "binlog.000003",\n  "mark_pos": 500,\n  "binlogs_encrypted": "yes",\n  "binlogs": {\n    "binlog.000003.age": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:158"\n  },\n  "tables": {\n    "t": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1"\n  },\n  "objects": {\n  }\n}\n' \
        > "$tmp/m_binlogmark.json"
    run bash "$REPO/binlog.sh" verify --base "$tmp/b_binlogbase.json" --mark "$tmp/m_binlogmark.json" \
        --archive "$tmp/archive" --tools "$tmp/tools"
    [ "$status" -ne 0 ]
    [[ "$output" == *"would be a guess"* ]]
    [[ "$output" != *"booting"* ]]
    rm -rf "$tmp"
}

@test "check --container over an encrypted archive refuses to guess without the key" {
    tmp=$(mktemp -d)
    mkdir "$tmp/archive"
    printf 'ciphertext' > "$tmp/archive/binlog.000001.age"
    run bash "$REPO/binlog.sh" check --archive "$tmp/archive" --container whatever
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs --identity"* ]]
    rm -rf "$tmp"
}

@test "check --remote audits an encrypted chain by ciphertext hash - no key exists there" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote"
    printf 'not really an encrypted mysqldump' > "$tmp/remote/b.sql.age"
    bsha=$(sha256sum "$tmp/remote/b.sql.age" | cut -d' ' -f1)
    bbytes=$(stat -c%s "$tmp/remote/b.sql.age")
    printf '{\n  "schema": 3,\n  "kind": "binlog-base",\n  "database": "app",\n  "artefact": "b.sql.age",\n  "bytes": %s,\n  "sha256": "%s",\n  "engine": "mysql",\n  "server_version": "8.4",\n  "anchor_file": "binlog.000005",\n  "anchor_pos": 100\n}\n' \
        "$bbytes" "$bsha" > "$tmp/remote/app_20260101T000000Z_binlogbase.json"
    printf 'opaque log ciphertext' > "$tmp/remote/binlog.000005.age"
    ssha=$(sha256sum "$tmp/remote/binlog.000005.age" | cut -d' ' -f1)
    sbytes=$(stat -c%s "$tmp/remote/binlog.000005.age")
    printf '{\n  "schema": 3,\n  "kind": "binlog-mark",\n  "database": "app",\n  "mark_file": "binlog.000005",\n  "mark_pos": 200,\n  "binlogs_encrypted": "yes",\n  "binlogs": {\n    "binlog.000005.age": "%s:%s"\n  },\n  "tables": {\n  },\n  "objects": {\n  }\n}\n' \
        "$ssha" "$sbytes" > "$tmp/remote/app_20260101T000000Z_binlogmark.json"
    run bash "$REPO/binlog.sh" check --remote "$tmp/remote"
    [ "$status" -eq 0 ]
    [[ "$output" == *"can prove every instant it claims"* ]]
    # and rot in the ciphertext is still named, keyless
    printf 'different ciphertext bytes!!' > "$tmp/remote/binlog.000005.age"
    run bash "$REPO/binlog.sh" check --remote "$tmp/remote"
    [ "$status" -ne 0 ]
    [[ "$output" == *"binlog.000005.age - the remote's bytes do not hash back"* ]]
    rm -rf "$tmp"
}

# --- GTID mode (12th round) ------------------------------------------------------

@test "verify refuses a pair that disagrees about GTID mode, before anything boots" {
    tmp=$(mktemp -d)
    mkdir "$tmp/tools" "$tmp/archive"
    printf '#!/bin/sh\n' > "$tmp/tools/mysqlbinlog"; chmod +x "$tmp/tools/mysqlbinlog"
    fabricate_pair "$tmp" binlog.000003 100 binlog.000003 500
    sed -i 's/"kind": "binlog-base",/"kind": "binlog-base",\n  "gtid_mode": "yes",/' "$tmp/b_binlogbase.json"
    sed -i 's/"kind": "binlog-mark",/"kind": "binlog-mark",\n  "gtid_mode": "no",/' "$tmp/m_binlogmark.json"
    run bash "$REPO/binlog.sh" verify --base "$tmp/b_binlogbase.json" --mark "$tmp/m_binlogmark.json" \
        --archive "$tmp/archive" --tools "$tmp/tools"
    [ "$status" -ne 0 ]
    [[ "$output" == *"disagrees about GTID mode"* ]]
    [[ "$output" != *"booting"* ]]
    # a GTID base against a manifest from BEFORE the field is the same refusal:
    # absent reads as plain, which is what it was
    sed -i '/"gtid_mode"/d' "$tmp/m_binlogmark.json"
    run bash "$REPO/binlog.sh" verify --base "$tmp/b_binlogbase.json" --mark "$tmp/m_binlogmark.json" \
        --archive "$tmp/archive" --tools "$tmp/tools"
    [ "$status" -ne 0 ]
    [[ "$output" == *"disagrees about GTID mode"* ]]
    rm -rf "$tmp"
}

@test "a plain pair - or one from before the gtid_mode field - is still read as plain" {
    tmp=$(mktemp -d)
    mkdir "$tmp/tools" "$tmp/archive"
    printf '#!/bin/sh\n' > "$tmp/tools/mysqlbinlog"; chmod +x "$tmp/tools/mysqlbinlog"
    # both halves absent (an old pair): must NOT die on the mode gate - it
    # walks on and dies later, on the chain (the archive is empty)
    fabricate_pair "$tmp" binlog.000003 100 binlog.000003 500
    run bash "$REPO/binlog.sh" verify --base "$tmp/b_binlogbase.json" --mark "$tmp/m_binlogmark.json" \
        --archive "$tmp/archive" --tools "$tmp/tools"
    [ "$status" -ne 0 ]
    [[ "$output" != *"disagrees about GTID mode"* ]]
    [[ "$output" == *"missing binlog.000003"* ]]
    rm -rf "$tmp"
}

@test "binlog.sh --keep must be a non-negative integer" {
    run bash "$REPO/binlog.sh" push --base /nonexistent --mark /nonexistent --archive /tmp --remote /tmp --keep many
    [ "$status" -ne 0 ]
    [[ "$output" == *"--keep must be a non-negative integer"* ]]
}

@test "binlog.sh --keep belongs to push, not to the other subcommands" {
    run bash "$REPO/binlog.sh" check --remote /tmp --keep 3
    [ "$status" -ne 0 ]
    [[ "$output" == *"--keep belongs to push"* ]]
}
