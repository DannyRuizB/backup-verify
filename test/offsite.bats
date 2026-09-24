#!/usr/bin/env bats
# Unit tests for offsite.sh: argument parsing, remote selection and the pure
# parts of both remote backends. No Docker, no network - the dir backend is
# exercised for real against temporary directories, the ssh backend only for
# its interface shape. The scripts are SOURCED behind their BASH_SOURCE guard.

setup() {
    REPO="${BATS_TEST_DIRNAME}/.."
}

@test "offsite.sh --help lists every subcommand and option" {
    run bash "$REPO/offsite.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"push"* ]]
    [[ "$output" == *"pull"* ]]
    [[ "$output" == *"check"* ]]
    [[ "$output" == *"--remote"* ]]
    [[ "$output" == *"--keep"* ]]
    [[ "$output" == *"--ssh-opts"* ]]
    [[ "$output" == *"-h, --help"* ]]
}

@test "offsite.sh refuses to run without a subcommand" {
    run bash "$REPO/offsite.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"a subcommand is required"* ]]
}

@test "offsite.sh rejects an unknown subcommand" {
    run bash "$REPO/offsite.sh" sync --remote /tmp
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown subcommand"* ]]
}

@test "every subcommand requires --remote" {
    for sub in push pull check; do
        run bash -c "source '$REPO/offsite.sh'; parse_args $sub"
        [ "$status" -ne 0 ]
        [[ "$output" == *"--remote is required"* ]]
    done
}

@test "push requires --manifest, pull requires --db" {
    run bash -c "source '$REPO/offsite.sh'; parse_args push --remote /tmp/r"
    [ "$status" -ne 0 ]
    [[ "$output" == *"push needs --manifest"* ]]
    run bash -c "source '$REPO/offsite.sh'; parse_args pull --remote /tmp/r"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pull needs --db"* ]]
}

@test "offsite.sh rejects a non-numeric --keep" {
    run bash -c "source '$REPO/offsite.sh'; parse_args push --manifest m --remote /tmp/r --keep two"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--keep must be a non-negative integer"* ]]
}

@test "a colon selects the ssh backend and splits host from directory" {
    run bash -c "source '$REPO/offsite.sh'; REMOTE='bk@nas.local:/srv/backups'; load_remote; echo \"\$REM_KIND \$REM_HOST \$REM_DIR\""
    [ "$status" -eq 0 ]
    [ "$output" = "ssh bk@nas.local /srv/backups" ]
}

@test "a plain path selects the directory backend" {
    run bash -c "source '$REPO/offsite.sh'; REMOTE='/mnt/nas/backups'; load_remote; echo \"\$REM_KIND \$REM_DIR\""
    [ "$status" -eq 0 ]
    [ "$output" = "dir /mnt/nas/backups" ]
}

@test "--ssh-opts is split into words for ssh, not passed as one blob" {
    run bash -c "source '$REPO/offsite.sh'; REMOTE='a@b:/c'; SSH_OPTS_STR='-p 2222 -i /k'; load_remote; echo \"\${#REM_SSH_OPTS[@]}\""
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "both remote backends implement the whole rem_* interface" {
    # Adding a backend must not mean discovering a missing function at runtime,
    # halfway through someone's disaster recovery - the eng_* rule, applied to
    # the other end of the wire.
    for backend in remote_ssh remote_dir; do
        for fn in rem_describe rem_preflight rem_put rem_get rem_rename \
                  rem_delete rem_sha256 rem_list; do
            run grep -c "^$fn()" "$REPO/lib/$backend.sh"
            [ "$output" = "1" ]
        done
        run grep -c '^REM_KIND=' "$REPO/lib/$backend.sh"
        [ "$output" = "1" ]
    done
}

@test "assert_pair_intact passes bytes the manifest was written about" {
    tmp=$(mktemp -d)
    printf 'not really a dump' > "$tmp/a.dump"
    sha=$(sha256sum "$tmp/a.dump" | cut -d' ' -f1)
    printf '{\n  "bytes": 17,\n  "sha256": "%s"\n}\n' "$sha" > "$tmp/a.json"
    run bash -c "source '$REPO/lib/common.sh'; assert_pair_intact '$tmp/a.json' '$tmp/a.dump' test"
    [ "$status" -eq 0 ]
    rm -rf "$tmp"
}

@test "assert_pair_intact names size drift and checksum drift apart" {
    tmp=$(mktemp -d)
    printf 'not really a dump' > "$tmp/a.dump"
    sha=$(sha256sum "$tmp/a.dump" | cut -d' ' -f1)
    # Right sha recorded, wrong byte count: the size gate speaks first.
    printf '{\n  "bytes": 99,\n  "sha256": "%s"\n}\n' "$sha" > "$tmp/a.json"
    run bash -c "source '$REPO/lib/common.sh'; assert_pair_intact '$tmp/a.json' '$tmp/a.dump' test"
    [ "$status" -ne 0 ]
    [[ "$output" == *"size drift"* ]]
    # Right byte count, wrong sha - the disk-full shape, where size LIES:
    # measured remotely as stat saying 1,048,576 over 256K of real blocks.
    printf '{\n  "bytes": 17,\n  "sha256": "%s"\n}\n' "${sha%??}00" > "$tmp/a.json"
    run bash -c "source '$REPO/lib/common.sh'; assert_pair_intact '$tmp/a.json' '$tmp/a.dump' test"
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum drift"* ]]
    rm -rf "$tmp"
}

@test "dir backend: put, hash, rename, list, get, delete round-trip" {
    tmp=$(mktemp -d)
    mkdir "$tmp/remote"
    printf 'payload\n' > "$tmp/src"
    run bash -c "
        source '$REPO/lib/common.sh'; REM_DIR='$tmp/remote'; source '$REPO/lib/remote_dir.sh'
        rem_preflight rw
        rem_put '$tmp/src' x.part
        [ \"\$(rem_sha256 x.part)\" = \"\$(sha256_of '$tmp/src')\" ] || exit 1
        rem_rename x.part x
        rem_list
        rem_get x '$tmp/back'
        cmp -s '$tmp/src' '$tmp/back' || exit 1
        rem_delete x
        [ -z \"\$(rem_list)\" ] || exit 1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"x"* ]]
    [[ "$output" != *"x.part"* ]]
    rm -rf "$tmp"
}

@test "dir backend: a read-only preflight refuses a remote that is not there" {
    # A typo'd --remote must look like what it is (no such remote), never like
    # an empty-but-healthy one.
    run bash -c "source '$REPO/lib/common.sh'; REM_DIR=/no/such/remote; source '$REPO/lib/remote_dir.sh'; rem_preflight ro"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "ssh helpers starve stdin; only rem_put may read it" {
    # Regression guard for this repo's bug #1, relearned: ssh without -n
    # slurps the caller's stdin, and check's while-read loop feeds the ssh
    # helpers from the listing it iterates - the first rem_get ate every
    # remaining line and check blessed a remote full of planted leftovers.
    # Green locally on a lucky find order; CI's order exposed it.
    run bash -c "grep '^rem_ssh()' '$REPO/lib/remote_ssh.sh'"
    [[ "$output" == *"ssh -n "* ]]
    run bash -c "grep '^rem_ssh_stdin()' '$REPO/lib/remote_ssh.sh'"
    [[ "$output" != *"ssh -n "* ]]
    run bash -c "grep '^rem_put()' '$REPO/lib/remote_ssh.sh'"
    [[ "$output" == *"rem_ssh_stdin"* ]]
}

@test "the ssh backend never prompts (BatchMode) and never uses scp" {
    # scp reads -p as "preserve times" and swallows the port number as a
    # filename (hit by this feature's probe); everything must ride ssh. The
    # comments may TALK about scp and rsync; the code must not call them.
    # Both wrappers - rem_ssh and rem_ssh_stdin - must refuse to prompt.
    run grep -c 'BatchMode=yes' "$REPO/lib/remote_ssh.sh"
    [ "$output" = "2" ]
    run bash -c "grep -v '^ *#' '$REPO/lib/remote_ssh.sh' | grep -c 'scp \|rsync ' || true"
    [ "$output" = "0" ]
}

# ---- retention by age (--keep-days): the pure decision ------------------------
# Four pairs on days 1, 5, 9 and 10 of September; "now" is pinned with
# BV_NOW so the tests never depend on the clock.
retention_names() {
    printf '%s\n' app_20260910T000000Z.tar.gz app_20260901T000000Z.tar.gz \
                  app_20260909T000000Z.tar.gz app_20260905T000000Z.tar.gz
}
NOW_SEP10_NOON=1789041600   # 2026-09-10T12:00:00Z

@test "offsite.sh rejects a non-numeric --keep-days" {
    run bash -c "source '$REPO/offsite.sh'; parse_args push --manifest m --remote /tmp/r --keep-days week"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--keep-days must be a non-negative integer"* ]]
}

@test "--help documents --keep-days and the newest-pair guarantee" {
    run bash "$REPO/offsite.sh" --help
    [[ "$output" == *"--keep-days D"* ]]
    [[ "$output" == *"never removed"* ]]
}

@test "the pinned now really is 2026-09-10 12:00 UTC" {
    run date -u -d "@$NOW_SEP10_NOON" +%Y%m%dT%H%M%SZ
    [ "$output" = "20260910T120000Z" ]
}

@test "--keep N alone: everything outside the newest N goes, oldest first" {
    run bash -c "source '$REPO/offsite.sh'; DB=app KEEP=2 KEEP_DAYS=0; $(declare -f retention_names); retention_names | retention_victims"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' app_20260901T000000Z.tar.gz app_20260905T000000Z.tar.gz)" ]
}

@test "--keep-days alone: pairs older than the window go, by NAME stamp" {
    # window 3 days back from Sep 10 12:00 = Sep 7 12:00: days 1 and 5 go
    run bash -c "source '$REPO/offsite.sh'; DB=app KEEP=0 KEEP_DAYS=3 BV_NOW=$NOW_SEP10_NOON; $(declare -f retention_names); retention_names | retention_victims"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' app_20260901T000000Z.tar.gz app_20260905T000000Z.tar.gz)" ]
}

@test "backups that stopped: age never removes the newest pair" {
    # a month later, every pair is out of a 7-day window - the newest stays
    run bash -c "source '$REPO/offsite.sh'; DB=app KEEP=0 KEEP_DAYS=7 BV_NOW=$((NOW_SEP10_NOON + 30 * 86400)); $(declare -f retention_names); retention_names | retention_victims"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' app_20260901T000000Z.tar.gz app_20260905T000000Z.tar.gz app_20260909T000000Z.tar.gz)" ]
}

@test "--keep and --keep-days together: a pair survives if EITHER keeps it" {
    # newest 3 (5, 9, 10) or under 1 day old (10): only day 1 goes
    run bash -c "source '$REPO/offsite.sh'; DB=app KEEP=3 KEEP_DAYS=1 BV_NOW=$NOW_SEP10_NOON; $(declare -f retention_names); retention_names | retention_victims"
    [ "$output" = "app_20260901T000000Z.tar.gz" ]
    # newest 1 or under 3 days old (9, 10): days 1 and 5 go
    run bash -c "source '$REPO/offsite.sh'; DB=app KEEP=1 KEEP_DAYS=3 BV_NOW=$NOW_SEP10_NOON; $(declare -f retention_names); retention_names | retention_victims"
    [ "$output" = "$(printf '%s\n' app_20260901T000000Z.tar.gz app_20260905T000000Z.tar.gz)" ]
}

@test "a sibling database sharing the prefix is neither counted nor touched" {
    # app_prod_* matches "app_" and sorts after every app_2026*: counted, it
    # took the newest slot and --keep 1 deleted every copy of app (pre-fix)
    run bash -c "source '$REPO/offsite.sh'; DB=app KEEP=1 KEEP_DAYS=0; printf '%s\n' app_20260901T000000Z.tar.gz app_20260905T000000Z.tar.gz app_prod_20260920T000000Z.tar.gz | retention_victims"
    [ "$status" -eq 0 ]
    [ "$output" = "app_20260901T000000Z.tar.gz" ]
}

@test "a pair whose name carries no stamp is never aged out" {
    run bash -c "source '$REPO/offsite.sh'; DB=app KEEP=0 KEEP_DAYS=1 BV_NOW=$NOW_SEP10_NOON; printf '%s\n' app_manual-copy.tar.gz app_20260901T000000Z.tar.gz app_20260910T000000Z.tar.gz | retention_victims"
    [ "$output" = "app_20260901T000000Z.tar.gz" ]
}

@test "a single pair is never a victim, whatever the rules" {
    run bash -c "source '$REPO/offsite.sh'; DB=app KEEP=0 KEEP_DAYS=1 BV_NOW=$((NOW_SEP10_NOON + 400 * 86400)); printf '%s\n' app_20260901T000000Z.tar.gz | retention_victims"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
