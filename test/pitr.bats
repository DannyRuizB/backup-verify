#!/usr/bin/env bats
# Unit tests for pitr.sh: argument parsing, the WAL-name arithmetic and the
# cheap refusal gates. No Docker - the fabricated-manifest tests exercise
# exactly the gates that run BEFORE anything boots, which is the point of
# having those gates. The scripts are SOURCED behind their BASH_SOURCE guard.

setup() {
    REPO="${BATS_TEST_DIRNAME}/.."
}

@test "pitr.sh --help lists every subcommand and option" {
    run bash "$REPO/pitr.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"base"* ]]
    [[ "$output" == *"mark"* ]]
    [[ "$output" == *"check"* ]]
    [[ "$output" == *"verify"* ]]
    [[ "$output" == *"--archive"* ]]
    [[ "$output" == *"--timeout"* ]]
    [[ "$output" == *"-h, --help"* ]]
}

@test "pitr.sh refuses to run without a subcommand" {
    run bash "$REPO/pitr.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"a subcommand is required"* ]]
}

@test "pitr.sh rejects an unknown subcommand" {
    run bash "$REPO/pitr.sh" restore --archive /tmp
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown subcommand"* ]]
}

@test "every subcommand requires --archive, and the directory must exist" {
    for sub in base mark check verify; do
        run bash -c "source '$REPO/pitr.sh'; parse_args $sub"
        [ "$status" -ne 0 ]
        [[ "$output" == *"--archive is required"* ]]
    done
    run bash -c "source '$REPO/pitr.sh'; parse_args check --archive /no/such/archive"
    [ "$status" -ne 0 ]
    [[ "$output" == *"archive directory not found"* ]]
}

@test "base and mark require a source, verify requires both manifests" {
    tmp=$(mktemp -d)
    run bash -c "source '$REPO/pitr.sh'; parse_args base --archive '$tmp'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"base needs --container"* ]]
    run bash -c "source '$REPO/pitr.sh'; parse_args mark --archive '$tmp' --container c"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mark needs --db"* ]]
    run bash -c "source '$REPO/pitr.sh'; parse_args verify --archive '$tmp'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"verify needs --base"* ]]
    run bash -c "source '$REPO/pitr.sh'; parse_args verify --archive '$tmp' --base b"
    [ "$status" -ne 0 ]
    [[ "$output" == *"verify needs --mark"* ]]
    rm -rf "$tmp"
}

@test "pitr.sh rejects a non-numeric --timeout" {
    tmp=$(mktemp -d)
    run bash -c "source '$REPO/pitr.sh'; parse_args check --archive '$tmp' --timeout soon"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--timeout must be a non-negative integer"* ]]
    rm -rf "$tmp"
}

@test "WAL name arithmetic survives the log-number carry" {
    # Segment names are two hex counters, not one: for 16MB segments the low
    # counter wraps at 0x100 and CARRIES into the high one. Arithmetic that
    # treats the name as a single number breaks exactly at the wrap, which on
    # a real server arrives after 4GB of WAL - long after every test passed.
    source "$REPO/lib/postgres.sh"
    run wal_index_name 00000001 255 16777216
    [ "$output" = "0000000100000000000000FF" ]
    run wal_index_name 00000001 256 16777216
    [ "$output" = "000000010000000100000000" ]
    run wal_name_index 000000010000000100000000 16777216
    [ "$output" = "256" ]
    run wal_name_index 0000000100000000000000FF 16777216
    [ "$output" = "255" ]
    # A 64MB build wraps at 0x40 instead - the arithmetic must take the
    # segment size, not assume the default.
    run wal_index_name 00000001 64 67108864
    [ "$output" = "000000010000000100000000" ]
    run wal_name_timeline 000000020000000A000000FF
    [ "$output" = "00000002" ]
}

@test "wal_range_problems blesses a complete, full-sized chain" {
    tmp=$(mktemp -d)
    for seg in 0000000100000000000000FE 0000000100000000000000FF 000000010000000100000000; do
        truncate -s 16777216 "$tmp/$seg"   # sparse: 16MB of size, no disk
    done
    source "$REPO/lib/postgres.sh"
    run wal_range_problems "$tmp" 0000000100000000000000FE 000000010000000100000000 16777216
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    rm -rf "$tmp"
}

@test "wal_range_problems names a hole - including one hidden by the carry" {
    tmp=$(mktemp -d)
    truncate -s 16777216 "$tmp/0000000100000000000000FE"
    truncate -s 16777216 "$tmp/000000010000000100000000"
    source "$REPO/lib/postgres.sh"
    run wal_range_problems "$tmp" 0000000100000000000000FE 000000010000000100000000 16777216
    [[ "$output" == *"missing segment 0000000100000000000000FF"* ]]
    rm -rf "$tmp"
}

@test "wal_range_problems names a wrong-size segment with both numbers" {
    # The measured shape: a half-copied segment recovers to a FATAL, but only
    # on the day you recover. This makes it loud today, by size alone - the
    # segments land 0600 owned by the server's user, so size and presence are
    # all the host can honestly inspect.
    tmp=$(mktemp -d)
    truncate -s 16777216 "$tmp/000000010000000000000001"
    truncate -s 8388608  "$tmp/000000010000000000000002"
    source "$REPO/lib/postgres.sh"
    run wal_range_problems "$tmp" 000000010000000000000001 000000010000000000000002 16777216
    [[ "$output" == *"000000010000000000000002 is 8388608 bytes"* ]]
    [[ "$output" == *"exactly 16777216"* ]]
    rm -rf "$tmp"
}

@test "verify refuses a dump manifest where a base manifest belongs" {
    tmp=$(mktemp -d)
    printf '{\n  "schema": 3,\n  "database": "app"\n}\n' > "$tmp/dump.json"
    run bash "$REPO/pitr.sh" verify --base "$tmp/dump.json" --mark "$tmp/dump.json" --archive "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a base-backup manifest"* ]]
    [[ "$output" == *"./verify.sh"* ]]
    rm -rf "$tmp"
}

@test "verify.sh refuses a PITR manifest and points at pitr.sh" {
    tmp=$(mktemp -d)
    printf '{\n  "schema": 3,\n  "kind": "pitr-base",\n  "database": "app"\n}\n' > "$tmp/base.json"
    run bash "$REPO/verify.sh" --manifest "$tmp/base.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pitr.sh"* ]]
    rm -rf "$tmp"
}

# A fabricated base+mark pair whose artefact hashes correctly, so the tests
# reach the reachability gates - the ones that refuse in milliseconds what a
# recovery would refuse in minutes (a named target that is never reached is
# FATAL; measured).
fabricate_pair() {
    local dir="$1" mark_file="$2" start_file="$3"
    printf 'not really a base backup' > "$dir/b_base.tar"
    local sha bytes
    sha=$(sha256sum "$dir/b_base.tar" | cut -d' ' -f1)
    bytes=$(stat -c%s "$dir/b_base.tar")
    printf '{\n  "schema": 3,\n  "kind": "pitr-base",\n  "database": "app",\n  "artefact": "b_base.tar",\n  "bytes": %s,\n  "sha256": "%s",\n  "server_version": "17",\n  "wal_segment_bytes": 16777216,\n  "wal_start_file": "%s"\n}\n' \
        "$bytes" "$sha" "$start_file" > "$dir/b_base.json"
    printf '{\n  "schema": 3,\n  "kind": "pitr-mark",\n  "database": "app",\n  "mark_name": "bv_app_x",\n  "lsn": "0/1",\n  "wal_file": "%s",\n  "tables": {\n    "t": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1"\n  },\n  "objects": {\n  }\n}\n' \
        "$mark_file" > "$dir/m_mark.json"
}

@test "verify refuses a mark that predates its base backup, before booting anything" {
    tmp=$(mktemp -d)
    fabricate_pair "$tmp" 000000010000000000000003 000000010000000000000005
    run bash "$REPO/pitr.sh" verify --base "$tmp/b_base.json" --mark "$tmp/m_mark.json" --archive "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"predates the base backup"* ]]
    [[ "$output" != *"booting"* ]]
    rm -rf "$tmp"
}

@test "verify refuses a mark from another timeline, before booting anything" {
    tmp=$(mktemp -d)
    fabricate_pair "$tmp" 000000020000000000000007 000000010000000000000005
    run bash "$REPO/pitr.sh" verify --base "$tmp/b_base.json" --mark "$tmp/m_mark.json" --archive "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"timeline"* ]]
    [[ "$output" != *"booting"* ]]
    rm -rf "$tmp"
}

@test "verify refuses to boot over a broken chain, and names the hole" {
    tmp=$(mktemp -d)
    fabricate_pair "$tmp" 000000010000000000000007 000000010000000000000005
    truncate -s 16777216 "$tmp/000000010000000000000005"
    truncate -s 16777216 "$tmp/000000010000000000000007"   # 06 missing
    run bash "$REPO/pitr.sh" verify --base "$tmp/b_base.json" --mark "$tmp/m_mark.json" --archive "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing segment 000000010000000000000006"* ]]
    [[ "$output" == *"refusing to boot"* ]]
    [[ "$output" != *"booting"* ]]
    rm -rf "$tmp"
}

@test "check dies on an archive with no segments at all" {
    tmp=$(mktemp -d)
    run bash "$REPO/pitr.sh" check --archive "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no WAL segments at all"* ]]
    rm -rf "$tmp"
}

@test "check names strays: the .partial and the squatted name" {
    tmp=$(mktemp -d)
    truncate -s 16777216 "$tmp/000000010000000000000001"
    printf 'poison' > "$tmp/000000010000000000000002.partial"
    run bash "$REPO/pitr.sh" check --archive "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"000000010000000000000002.partial - not a WAL segment"* ]]
    rm -rf "$tmp"
}

@test "check flags an in-range segment whose size lies" {
    # The squatter with a legal name: 26 bytes of garbage on the next segment's
    # name wedged the measured archiver forever (test ! -f can never pass).
    # From the archive directory alone, its wrong size is what betrays it.
    tmp=$(mktemp -d)
    truncate -s 16777216 "$tmp/000000010000000000000001"
    truncate -s 16777216 "$tmp/000000010000000000000002"
    printf 'this is not a WAL segment' > "$tmp/000000010000000000000003"
    run bash "$REPO/pitr.sh" check --archive "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"000000010000000000000003 is 25 bytes"* ]]
    rm -rf "$tmp"
}

@test "backup history and timeline history files are expected, not strays" {
    tmp=$(mktemp -d)
    truncate -s 16777216 "$tmp/000000010000000000000003"
    printf 'START WAL LOCATION: ...' > "$tmp/000000010000000000000003.00000028.backup"
    printf '1\t0/6008F08\tafter restore point\n' > "$tmp/00000002.history"
    run bash "$REPO/pitr.sh" check --archive "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"archive is continuous: 1 segment(s)"* ]]
    rm -rf "$tmp"
}

# --- the off-site archive: push / pull / check --remote -------------------------

@test "help lists push, pull and the remote options" {
    run bash "$REPO/pitr.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"push"* ]]
    [[ "$output" == *"pull"* ]]
    [[ "$output" == *"--remote"* ]]
    [[ "$output" == *"--ssh-opts"* ]]
}

@test "push and pull name every input they refuse to run without" {
    tmp=$(mktemp -d)
    run bash -c "source '$REPO/pitr.sh'; parse_args push --archive '$tmp'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"push needs --base"* ]]
    run bash -c "source '$REPO/pitr.sh'; parse_args push --archive '$tmp' --base b"
    [ "$status" -ne 0 ]
    [[ "$output" == *"push needs --mark"* ]]
    run bash -c "source '$REPO/pitr.sh'; parse_args push --archive '$tmp' --base b --mark m"
    [ "$status" -ne 0 ]
    [[ "$output" == *"push needs --remote"* ]]
    run bash -c "source '$REPO/pitr.sh'; parse_args pull --archive '$tmp' --remote r"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pull needs --db"* ]]
    run bash -c "source '$REPO/pitr.sh'; parse_args pull --archive '$tmp' --db app"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pull needs --remote"* ]]
    rm -rf "$tmp"
}

@test "check audits the local archive or the remote, never both at once" {
    tmp=$(mktemp -d)
    run bash -c "source '$REPO/pitr.sh'; parse_args check --archive '$tmp' --remote '$tmp'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not both at once"* ]]
    # and a remote check needs no --archive at all
    run bash -c "source '$REPO/pitr.sh'; parse_args check --remote '$tmp' && echo PARSED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PARSED"* ]]
    rm -rf "$tmp"
}

@test "pull creates its archive directory - disaster recovery starts with nothing" {
    tmp=$(mktemp -d)
    run bash -c "source '$REPO/pitr.sh'; parse_args pull --db app --remote r --archive '$tmp/fresh/archive' && echo PARSED"
    [ "$status" -eq 0 ]
    [ -d "$tmp/fresh/archive" ]
    rm -rf "$tmp"
}

@test "push refuses a mark with no WAL inventory - it cannot promise what nothing can audit" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote" "$tmp/archive"
    fabricate_pair "$tmp" 000000010000000000000005 000000010000000000000005
    run bash "$REPO/pitr.sh" push --base "$tmp/b_base.json" --mark "$tmp/m_mark.json" \
        --archive "$tmp/archive" --remote "$tmp/remote"
    [ "$status" -ne 0 ]
    [[ "$output" == *"records no WAL inventory"* ]]
    rm -rf "$tmp"
}

@test "push refuses to replicate a hole off-site" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote" "$tmp/archive"
    fabricate_pair "$tmp" 000000010000000000000007 000000010000000000000005
    sed -i 's/  "tables": {/  "wal": {\n    "000000010000000000000005": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"\n  },\n  "tables": {/' "$tmp/m_mark.json"
    truncate -s 16777216 "$tmp/archive/000000010000000000000005"
    truncate -s 16777216 "$tmp/archive/000000010000000000000007"   # 06 missing
    run bash "$REPO/pitr.sh" push --base "$tmp/b_base.json" --mark "$tmp/m_mark.json" \
        --archive "$tmp/archive" --remote "$tmp/remote"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing segment 000000010000000000000006"* ]]
    [[ "$output" == *"replicate the hole off-site"* ]]
    rm -rf "$tmp"
}

@test "pull refuses a remote that cannot prove any instant of the database" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote"
    run bash "$REPO/pitr.sh" pull --db app --remote "$tmp/remote" \
        --archive "$tmp/archive" --out "$tmp/out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no mark manifest for 'app'"* ]]
    rm -rf "$tmp"
}

@test "pull removes a fetched mark that records no inventory, instead of trusting it" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote"
    printf '{\n  "schema": 3,\n  "kind": "pitr-mark",\n  "database": "app",\n  "mark_name": "bv_app_x",\n  "wal_file": "000000010000000000000005",\n  "tables": {\n  },\n  "objects": {\n  }\n}\n' \
        > "$tmp/remote/app_20260101T000000Z_mark.json"
    run bash "$REPO/pitr.sh" pull --db app --remote "$tmp/remote" \
        --archive "$tmp/archive" --out "$tmp/out"
    [ "$status" -ne 0 ]
    [[ "$output" == *"records no WAL inventory"* ]]
    [ ! -e "$tmp/out/app_20260101T000000Z_mark.json" ]
    rm -rf "$tmp"
}

@test "check --remote names the crashed upload, the missing segment and the missing base" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote"
    printf 'crashed' > "$tmp/remote/000000010000000000000009.part"
    printf '{\n  "schema": 3,\n  "kind": "pitr-mark",\n  "database": "app",\n  "mark_name": "bv_app_x",\n  "wal_file": "000000010000000000000005",\n  "wal": {\n    "000000010000000000000005": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"\n  },\n  "tables": {\n  },\n  "objects": {\n  }\n}\n' \
        > "$tmp/remote/app_20260101T000000Z_mark.json"
    run bash "$REPO/pitr.sh" check --remote "$tmp/remote"
    [ "$status" -ne 0 ]
    [[ "$output" == *"000000010000000000000009.part - a crashed upload"* ]]
    [[ "$output" == *"the remote does not hold it"* ]]
    [[ "$output" == *"no intact base backup at the remote"* ]]
    [[ "$output" == *"REMOTE ARCHIVE CHECK FAILED"* ]]
    rm -rf "$tmp"
}

@test "check --remote blesses a remote whose newest mark provably stands on what it holds" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote"
    printf 'not really a base backup' > "$tmp/remote/b_base.tar"
    local_sha=$(sha256sum "$tmp/remote/b_base.tar" | cut -d' ' -f1)
    local_bytes=$(stat -c%s "$tmp/remote/b_base.tar")
    printf '{\n  "schema": 3,\n  "kind": "pitr-base",\n  "database": "app",\n  "artefact": "b_base.tar",\n  "bytes": %s,\n  "sha256": "%s",\n  "server_version": "17",\n  "wal_segment_bytes": 16777216,\n  "wal_start_file": "000000010000000000000005"\n}\n' \
        "$local_bytes" "$local_sha" > "$tmp/remote/app_20260101T000000Z_base.json"
    printf 'segment bytes' > "$tmp/remote/000000010000000000000005"
    seg_sha=$(sha256sum "$tmp/remote/000000010000000000000005" | cut -d' ' -f1)
    printf '{\n  "schema": 3,\n  "kind": "pitr-mark",\n  "database": "app",\n  "mark_name": "bv_app_x",\n  "wal_file": "000000010000000000000005",\n  "wal": {\n    "000000010000000000000005": "%s"\n  },\n  "tables": {\n  },\n  "objects": {\n  }\n}\n' \
        "$seg_sha" > "$tmp/remote/app_20260101T000000Z_mark.json"
    run bash "$REPO/pitr.sh" check --remote "$tmp/remote"
    [ "$status" -eq 0 ]
    [[ "$output" == *"can prove every instant it claims"* ]]
    rm -rf "$tmp"
}

@test "an old mark without an inventory is reported by verify, never silently skipped" {
    # The retrocompat contract, testable without Docker: the warning text must
    # exist in the script verbatim, tied to the empty-inventory branch.
    grep -q 'records no WAL inventory (an older mark)' "$REPO/pitr.sh"
    grep -q 'invisible until a recovery trips over it' "$REPO/pitr.sh"
}

# --- the encrypted archive -------------------------------------------------------

@test "base --recipient without --identity is refused, with the backup_label reason" {
    tmp=$(mktemp -d)
    run bash -c "source '$REPO/pitr.sh'; parse_args base --archive '$tmp' --container c --db app --recipient age1xyz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires --identity"* ]]
    [[ "$output" == *"backup_label"* ]]
    rm -rf "$tmp"
}

@test "verify refuses an encrypted base without the key, before anything boots" {
    tmp=$(mktemp -d)
    printf 'not really ciphertext' > "$tmp/b_base.tar.age"
    sha=$(sha256sum "$tmp/b_base.tar.age" | cut -d' ' -f1)
    bytes=$(stat -c%s "$tmp/b_base.tar.age")
    printf '{\n  "schema": 3,\n  "kind": "pitr-base",\n  "database": "app",\n  "artefact": "b_base.tar.age",\n  "bytes": %s,\n  "sha256": "%s",\n  "server_version": "17",\n  "wal_segment_bytes": 16777216,\n  "wal_start_file": "000000010000000000000003"\n}\n' \
        "$bytes" "$sha" > "$tmp/b_base.json"
    printf '{\n  "schema": 3,\n  "kind": "pitr-mark",\n  "database": "app",\n  "mark_name": "bv_app_x",\n  "lsn": "0/1",\n  "wal_file": "000000010000000000000005",\n  "tables": {\n  },\n  "objects": {\n  }\n}\n' \
        > "$tmp/m_mark.json"
    run bash "$REPO/pitr.sh" verify --base "$tmp/b_base.json" --mark "$tmp/m_mark.json" --archive "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not guess"* ]]
    [[ "$output" != *"booting"* ]]
    rm -rf "$tmp"
}

@test "wal_range_problems audits suffixed ciphertext names against the ciphertext size" {
    tmp=$(mktemp -d)
    truncate -s 16781496 "$tmp/000000010000000000000001.age"
    truncate -s 16781496 "$tmp/000000010000000000000002.age"
    source "$REPO/lib/postgres.sh"
    run wal_range_problems "$tmp" 000000010000000000000001 000000010000000000000002 16777216 .age 16781496
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    truncate -s 8000000 "$tmp/000000010000000000000002.age"
    run wal_range_problems "$tmp" 000000010000000000000001 000000010000000000000002 16777216 .age 16781496
    [[ "$output" == *"000000010000000000000002.age is 8000000 bytes"* ]]
    [[ "$output" == *"exactly 16781496"* ]]
    rm -rf "$tmp"
}

@test "push refuses an encrypted mark that records no ciphertext size" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote" "$tmp/archive"
    fabricate_pair "$tmp" 000000010000000000000005 000000010000000000000005
    sed -i 's/  "tables": {/  "wal_files_encrypted": "yes",\n  "wal": {\n    "000000010000000000000005.age": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"\n  },\n  "tables": {/' "$tmp/m_mark.json"
    run bash "$REPO/pitr.sh" push --base "$tmp/b_base.json" --mark "$tmp/m_mark.json" \
        --archive "$tmp/archive" --remote "$tmp/remote"
    [ "$status" -ne 0 ]
    [[ "$output" == *"records no ciphertext size"* ]]
    rm -rf "$tmp"
}
