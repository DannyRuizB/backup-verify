#!/usr/bin/env bash
# =============================================================================
# The cases that justify this repo. Each one is a way a backup looks fine and
# is not, measured on a real server - and each must be CAUGHT. The suite runs
# per engine (--engine postgres|mysql); the cases are the same, except case 6,
# where each engine contributes its own measured disaster:
#
#   1. A truncated archive. The restore exits non-zero but LEAVES TABLES
#      POPULATED, so a row-count check signs it off. The fingerprint must not.
#   2. An empty artefact (0 bytes, or ~20 bytes of empty gzip). backup.sh must
#      refuse to produce one; verify.sh must refuse to accept one.
#   3. An artefact that rotted on disk after the backup. The checksum catches it.
#   4. Silent data loss: one row deleted from the artefact's source before the
#      manifest is compared - the fingerprint differs even though the counts
#      match. (Simulated by editing the manifest, which is the same comparison.)
#   5. The good backup still verifies - no false alarms.
#   6. Every row restored, schema silently gone. Postgres: `pg_dump -t` (exit 0,
#      all rows, no view/function/trigger). MySQL: `mysqldump` WITHOUT
#      --routines - which is mysqldump's DEFAULT - so every function and
#      procedure vanishes with exit code 0 and no warning (measured on 8.4).
#   7-11. Encryption: real ciphertext on disk, refusal without the key, the
#      wrong key told apart from a bad archive, truncated ciphertext, and the
#      good encrypted backup passing end to end.
#
# A test that only proves the happy path proves the least interesting thing.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
. lib/common.sh
. test/seed.sh

ENGINE="postgres"
while [ $# -gt 0 ]; do
    case "$1" in
        --engine) ENGINE="${2:-}"; shift 2;;
        *)        die "unknown option: $1 (usage: negative.sh [--engine postgres|mysql|files|sqlite])";;
    esac
done
load_engine "$ENGINE"

SRC=bv-neg-src
SRC_DIR=""
OUT=$(mktemp -d)
IMAGE="${BV_IMAGE:-$ENG_DEFAULT_IMAGE}"
EXT="$ENG_ARTEFACT_EXT"
FAILURES=0

pass_case() { printf '  %sOK%s   %s\n' "$c_green" "$c_reset" "$1"; }
fail_case() { printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$1"; FAILURES=$((FAILURES + 1)); }

SRC_DB=""
cleanup() {
    if [ "$ENG_NAME" = files ]; then
        if [ -n "$SRC_DIR" ]; then rm -rf "$SRC_DIR"; fi
        rm -rf "${TMPDIR:-/tmp}"/bv-files-bv-verify-* 2>/dev/null || true
    elif [ "$ENG_NAME" = sqlite ]; then
        [ -n "$SRC_DB" ] && rm -f "$SRC_DB" "$SRC_DB-wal" "$SRC_DB-shm"
        rm -f "${TMPDIR:-/tmp}"/bv-sqlite-bv-verify-*.db 2>/dev/null || true
    else
        docker rm -f "$SRC" >/dev/null 2>&1 || true
        docker ps -aq --filter "name=bv-verify-" | xargs -r docker rm -f >/dev/null 2>&1 || true
    fi
    rm -rf "$OUT"
}
trap cleanup EXIT

# The seed is SHARED with the e2e (test/seed.sh) since the day case 6 passed
# while proving nothing: this suite had seeded one bare table, so a tables-only
# dump had no view or function to lose. Same shape, structurally.
if [ "$ENG_NAME" = files ]; then
    SRC_DIR=$(mktemp -d)
    log "seeding a source file tree ($SRC_DIR)"
    seed_files "$SRC_DIR"
elif [ "$ENG_NAME" = sqlite ]; then
    SRC_DB="$OUT/source.db"
    log "seeding a source SQLite database ($SRC_DB)"
    seed_sqlite "$SRC_DB"
else
    log "booting a source database with data ($ENG_NAME, $IMAGE)"
    docker rm -f "$SRC" >/dev/null 2>&1 || true
    eng_boot "$SRC" app "$IMAGE"
    eng_wait_ready "$SRC"
    "seed_$ENG_NAME" "$SRC" app
fi

# Each case gets its OWN fresh backup. Sharing one artefact across cases meant
# case 4 inherited the size/sha that the case-1 edit had aligned to a TRUNCATED
# file, so it tripped the size gate instead of the fingerprint comparison it
# exists to test - a bug in the TEST, and exactly the kind of state carry-over
# that makes a suite lie about what it covers.
# mktemp, NOT a counter. This function is called as `M=$(fresh_backup)`, which
# runs it in a SUBSHELL - so an incrementing CASE_N never persisted in the
# parent, every case landed in the same directory, and `find | head -1` handed
# case 5 the CORRUPTED manifest from case 4. It passed locally purely because
# find happened to return the newer file first; CI ordered them the other way.
# Non-determinism in the test suite of a tool about non-determinism.
fresh_backup() {
    local dir
    dir=$(mktemp -d "$OUT/caseXXXXXX")
    if [ "$ENG_NAME" = files ]; then
        ./backup.sh --engine "$ENGINE" --path "$SRC_DIR" --db app --out "$dir" >/dev/null
    elif [ "$ENG_NAME" = sqlite ]; then
        ./backup.sh --engine "$ENGINE" --path "$SRC_DB" --db app --out "$dir" >/dev/null
    else
        ./backup.sh --engine "$ENGINE" --container "$SRC" --db app --out "$dir" >/dev/null
    fi
    # Exactly one backup lives in this directory, so this is unambiguous.
    find "$dir" -name '*.json' | head -1
}

# Re-align a manifest's size+sha with its artefact, so a case that targets a
# LATER gate is not stopped by an earlier one.
realign_manifest() {
    python3 "$SCRIPT_DIR/realign_manifest.py" "$1" "${1%.json}$EXT"
}

# Same, for an encrypted artefact (its name carries the .age suffix).
realign_manifest_enc() {
    python3 "$SCRIPT_DIR/realign_manifest.py" "$1" "$2"
}
printf '\n'

echo '== Case 1: truncated archive (restores PARTIAL data, exits non-zero) =='
MANIFEST=$(fresh_backup)
ARTEFACT="${MANIFEST%.json}$EXT"
# Cut the archive in half. The size is read into a variable first: reading and
# truncating the same path in one command only works because bash expands
# before it redirects (SC2094).
HALF=$(( $(stat -c%s "$ARTEFACT") / 2 ))
cp "$ARTEFACT" "$ARTEFACT.full"
head -c "$HALF" "$ARTEFACT.full" > "$ARTEFACT"
rm -f "$ARTEFACT.full"
# Align size+sha with the truncated file, or the checksum gate fires first and
# this would only re-test case 3.
realign_manifest "$MANIFEST"
if ./verify.sh --manifest "$MANIFEST" --image "$IMAGE" >"$OUT/c1.log" 2>&1; then
    fail_case 'a truncated archive was accepted as a good backup'
    sed -n '1,12p' "$OUT/c1.log" | sed 's/^/        /'
else
    if grep -qE 'fingerprint differs|absent from the restored|restored copy has' "$OUT/c1.log"; then
        pass_case 'truncated archive REJECTED by the content comparison'
        # The evidence for why counting rows is not enough:
        if grep -q 'the restore exited' "$OUT/c1.log"; then
            pass_case '...and the log shows the restore failed yet data landed anyway'
        fi
    else
        fail_case 'truncated archive was rejected, but not for the right reason'
        sed -n '1,12p' "$OUT/c1.log" | sed 's/^/        /'
    fi
fi
printf '\n'

echo '== Case 2: empty artefact (the failed-dump signature) =='
# backup.sh must never create one: a dump of a database that does not exist
# leaves 0 bytes, and piped through gzip, ~20 bytes of valid empty archive.
# The files version of the same lie, both measured: a missing source, and an
# EMPTY source - tar of an empty directory exits 0 with a valid 110-byte
# archive that guards exactly nothing.
if [ "$ENG_NAME" = files ]; then
    if ./backup.sh --engine "$ENGINE" --path "$OUT/does-not-exist" --out "$OUT" >"$OUT/c2.log" 2>&1; then
        fail_case 'backup.sh reported success for a source directory that does not exist'
    else
        pass_case 'backup.sh fails on a source that is not there'
    fi
    EMPTY_SRC=$(mktemp -d "$OUT/emptyXXXXXX")
    if ./backup.sh --engine "$ENGINE" --path "$EMPTY_SRC" --db emptyset --out "$OUT" >"$OUT/c2b.log" 2>&1; then
        fail_case 'backup.sh called a valid archive of an EMPTY directory a backup'
    else
        pass_case 'backup.sh refuses to back up an empty tree (a backup of nothing is nothing)'
        if find "$OUT" -maxdepth 1 -name 'emptyset_*' | grep -q .; then
            fail_case 'and it left an artefact behind'
        else
            pass_case '...and leaves no plausible-looking artefact behind'
        fi
    fi
elif [ "$ENG_NAME" = sqlite ]; then
    # The missing source: a .db file that is not there must fail at preflight.
    if ./backup.sh --engine "$ENGINE" --path "$OUT/does-not-exist.db" --out "$OUT" >"$OUT/c2.log" 2>&1; then
        fail_case 'backup.sh reported success for a source database that does not exist'
    else
        pass_case 'backup.sh fails on a source database that is not there'
    fi
    # The EMPTY database: a valid SQLite file with zero tables. It dumps
    # cleanly (BEGIN; COMMIT;), so the parse gate passes - only the "manifest
    # lists no tables" guard stands between it and a backup of nothing.
    EMPTY_DB="$OUT/emptyset.db"
    sqlite3 "$EMPTY_DB" 'PRAGMA user_version;' >/dev/null
    if ./backup.sh --engine "$ENGINE" --path "$EMPTY_DB" --db emptyset --out "$OUT" >"$OUT/c2b.log" 2>&1; then
        fail_case 'backup.sh called a dump of an EMPTY database a backup'
    else
        pass_case 'backup.sh refuses to back up a database with no tables (a backup of nothing is nothing)'
        if find "$OUT" -maxdepth 1 -name 'emptyset_*' | grep -q .; then
            fail_case 'and it left an artefact behind'
        else
            pass_case '...and leaves no plausible-looking artefact behind'
        fi
    fi
else
    if ./backup.sh --engine "$ENGINE" --container "$SRC" --db nosuchdb --out "$OUT" >"$OUT/c2.log" 2>&1; then
        fail_case 'backup.sh reported success for a database that does not exist'
    else
        pass_case 'backup.sh fails on a dump that cannot run'
        if find "$OUT" -name 'nosuchdb_*' | grep -q .; then
            fail_case 'and it left an artefact behind'
        else
            pass_case '...and leaves no plausible-looking artefact behind'
        fi
    fi
fi
printf '\n'

echo '== Case 3: artefact rotted on disk after the backup =='
MANIFEST=$(fresh_backup)
ARTEFACT="${MANIFEST%.json}$EXT"
printf 'corruption' >> "$ARTEFACT"
if ./verify.sh --manifest "$MANIFEST" --image "$IMAGE" >"$OUT/c3.log" 2>&1; then
    fail_case 'a modified artefact passed verification'
else
    if grep -qE 'size drift|checksum drift' "$OUT/c3.log"; then
        pass_case 'post-backup corruption caught by size/checksum before wasting a restore'
    else
        fail_case 'rejected, but not by the checksum gate'
        sed -n '1,8p' "$OUT/c3.log" | sed 's/^/        /'
    fi
fi
printf '\n'

echo '== Case 4: same row count, different content =='
# Rewriting one fingerprint is the same comparison that happens when a restore
# silently drops a value while keeping the row: counts match, content does not.
# For files this is the measured same-size-same-mtime edit: every metadata
# comparison calls the two files identical, only the hash disagrees.
MANIFEST=$(fresh_backup)
if [ "$ENG_NAME" = files ]; then
    python3 "$SCRIPT_DIR/break_fingerprint.py" "$MANIFEST" "config/nginx.conf"
else
    python3 "$SCRIPT_DIR/break_fingerprint.py" "$MANIFEST"
fi
if ./verify.sh --manifest "$MANIFEST" --image "$IMAGE" >"$OUT/c4.log" 2>&1; then
    fail_case 'a content mismatch passed verification'
else
    if grep -q 'fingerprint differs' "$OUT/c4.log"; then
        pass_case 'content mismatch caught even with the row count intact'
    else
        fail_case 'rejected, but not by the fingerprint comparison'
        sed -n '1,10p' "$OUT/c4.log" | sed 's/^/        /'
    fi
fi
printf '\n'

echo '== Case 5: the good backup still verifies (no false alarms) =='
GOOD=$(fresh_backup)
if ./verify.sh --manifest "$GOOD" --image "$IMAGE" >"$OUT/c5.log" 2>&1; then
    pass_case 'an untouched backup verifies cleanly'
else
    fail_case 'a good backup was rejected - the checks are too strict'
    sed -n '1,15p' "$OUT/c5.log" | sed 's/^/        /'
fi

echo '== Case 6: every row restored, schema silently gone =='
# The most dangerous artefact of all, and entirely realistic - each engine has
# its own version, all measured:
#   Postgres: a cron that says `pg_dump -t customers -t orders` because someone
#   only cared about the tables. Exit 0, every row, and it drops the indexes,
#   constraints, view, functions and trigger.
#   MySQL: `mysqldump` run WITHOUT --routines - the DEFAULT invocation - which
#   silently omits every function and procedure. Exit 0, no warning. Before
#   schema verification existed, this repo called both of these VERIFIED.
#   Files: `tar czf backup.tgz *` - the invocation in half the tutorials on
#   the internet - which silently drops every dotfile. The .env with the
#   credentials is the first thing the backup loses, exit code 0.
MANIFEST=$(fresh_backup)
ARTEFACT="${MANIFEST%.json}$EXT"
case "$ENG_NAME" in
    postgres)
        # Both tables (so the data gates all pass) but no independent objects:
        # the view and the functions are simply not in a `-t`-scoped dump.
        docker exec "$SRC" pg_dump -U postgres -d app -Fc -t customers -t orders \
            < /dev/null > "$ARTEFACT";;
    mysql)
        # Everything eng_dump forces on, deliberately left at the default:
        # tables, view and trigger survive; the function and procedure vanish.
        docker exec -e MYSQL_PWD=verify "$SRC" mysqldump -uroot \
            --single-transaction --databases app < /dev/null > "$ARTEFACT";;
    files)
        # The glob expands to everything EXCEPT the dotfiles - measured: .env
        # was simply not in the archive, and tar exited 0.
        (cd "$SRC_DIR" && tar -czf - -- *) > "$ARTEFACT";;
    sqlite)
        # A TABLE-SCOPED dump: `.dump customers orders` returns every row of
        # both tables (exit 0, no warning) and drops the index, both views and
        # the trigger - the SQLite `pg_dump -t` (measured: 2500 rows kept, all
        # other objects gone).
        sqlite3 "$SRC_DB" '.dump customers orders' > "$ARTEFACT";;
esac
realign_manifest "$MANIFEST"
# What the rejection must SAY, per engine. MySQL is pinned to the exact numbers
# because only the routines differ there (triggers and the view survive a
# default mysqldump): a looser pattern could pass on the wrong signal.
case "$ENG_NAME" in
    postgres) C6_PAT='indexes - expected|constraints - expected|views - expected|routines - expected'
              C6_OK='OK   customers';;
    mysql)    C6_PAT='routines - expected 2, restored copy has 0'
              C6_OK='OK   customers';;
    files)    C6_PAT='\.env - file absent'
              C6_OK='OK   config/nginx.conf';;
    sqlite)   C6_PAT='indexes - expected|views - expected|triggers - expected'
              C6_OK='OK   customers';;
esac
if ./verify.sh --manifest "$MANIFEST" --image "$IMAGE" >"$OUT/c6.log" 2>&1; then
    fail_case 'a stripped artefact passed verification (the loss went unnoticed)'
    sed -n '1,20p' "$OUT/c6.log" | sed 's/^/        /'
else
    if grep -qE "$C6_PAT" "$OUT/c6.log"; then
        pass_case 'the silent loss was caught and NAMED'
        # The point worth shouting about: what the artefact did carry was fine.
        if grep -q "$C6_OK" "$OUT/c6.log"; then
            pass_case '...while the content it did restore matched byte for byte'
        fi
    else
        fail_case 'rejected, but not for the right reason'
        sed -n '1,20p' "$OUT/c6.log" | sed 's/^/        /'
    fi
fi
printf '\n'

echo '== Cases 7-11: encryption (a backup you cannot decrypt is not a backup) =='
if ! command -v age >/dev/null 2>&1; then
    fail_case 'age is not installed - the encryption cases could not run (they are not optional)'
else
    # What a LEAKED plaintext of this engine starts with - the signature that
    # must never appear in the artefact on disk. The files plaintext is a
    # gzip stream, so its signature is the two magic bytes, checked as hex.
    case "$ENG_NAME" in
        postgres) PLAIN_SIG='PGDMP';;
        mysql)    PLAIN_SIG='MySQL dump';;
        files)    PLAIN_SIG='';;
        sqlite)   PLAIN_SIG='PRAGMA foreign_keys';;
    esac
    KEYDIR=$(mktemp -d "$OUT/keysXXXXXX")
    age-keygen -o "$KEYDIR/good.txt" 2>/dev/null
    age-keygen -o "$KEYDIR/other.txt" 2>/dev/null
    GOOD_RECIP=$(grep 'public key' "$KEYDIR/good.txt" | sed 's/.*: //')
    # The same source arguments fresh_backup uses - built once, so the
    # encrypted invocations cannot drift from the plain ones.
    if [ "$ENG_NAME" = files ]; then
        SRC_ARGS=(--path "$SRC_DIR" --db app)
    elif [ "$ENG_NAME" = sqlite ]; then
        SRC_ARGS=(--path "$SRC_DB" --db app)
    else
        SRC_ARGS=(--container "$SRC" --db app)
    fi
    ENCDIR=$(mktemp -d "$OUT/encXXXXXX")
    ./backup.sh --engine "$ENGINE" "${SRC_ARGS[@]}" --out "$ENCDIR" \
        --recipient "$GOOD_RECIP" --identity "$KEYDIR/good.txt" >/dev/null
    ENCMAN=$(find "$ENCDIR" -name '*.json' | head -1)
    ENCART="${ENCMAN%.json}$EXT.age"

    # 7: the artefact must actually BE encrypted, not merely named .age.
    if [ -f "$ENCART" ] && head -c 16 "$ENCART" | grep -q 'age-encryption'; then
        pass_case 'the artefact on disk is real age ciphertext'
    else
        fail_case "no age ciphertext at $ENCART"
    fi
    if [ "$ENG_NAME" = files ]; then
        if [ "$(head -c 2 "$ENCART" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
            fail_case 'the artefact begins with the gzip magic - the payload is plaintext'
        else
            pass_case '...with no gzip magic in the clear (the payload is real ciphertext)'
        fi
    elif head -c 200 "$ENCART" | grep -q "$PLAIN_SIG"; then
        fail_case 'the plaintext dump header is visible in the artefact'
    else
        pass_case '...with no plaintext dump header in the clear'
    fi

    # 8: without the key, verification must REFUSE rather than pretend.
    if ./verify.sh --manifest "$ENCMAN" --image "$IMAGE" >"$OUT/c7.log" 2>&1; then
        fail_case 'an encrypted backup was "verified" with no identity at all'
    elif grep -q 'pass --identity' "$OUT/c7.log"; then
        pass_case 'without the key, verification refuses instead of pretending'
    else
        fail_case 'refused, but not because the identity was missing'
        sed -n '1,6p' "$OUT/c7.log" | sed 's/^/        /'
    fi

    # 9: the WRONG key must fail loudly, and be told apart from a bad archive.
    if ./verify.sh --manifest "$ENCMAN" --identity "$KEYDIR/other.txt" --image "$IMAGE" >"$OUT/c8.log" 2>&1; then
        fail_case 'the wrong identity decrypted the backup'
    elif grep -q 'decryption FAILED' "$OUT/c8.log"; then
        pass_case 'the wrong identity fails at DECRYPTION, told apart from a bad archive'
    else
        fail_case 'rejected, but not distinguished as a decryption failure'
        sed -n '1,6p' "$OUT/c8.log" | sed 's/^/        /'
    fi

    # 10: a truncated ciphertext - the contrast with case 1 is the lesson.
    cp "$ENCART" "$ENCART.full"
    HALF_E=$(( $(stat -c%s "$ENCART.full") / 2 ))
    head -c "$HALF_E" "$ENCART.full" > "$ENCART"
    rm -f "$ENCART.full"
    realign_manifest_enc "$ENCMAN" "$ENCART"
    if ./verify.sh --manifest "$ENCMAN" --identity "$KEYDIR/good.txt" --image "$IMAGE" >"$OUT/c9.log" 2>&1; then
        fail_case 'a truncated ciphertext passed verification'
    elif grep -q 'decryption FAILED' "$OUT/c9.log"; then
        pass_case 'a truncated ciphertext cannot decrypt at all (authenticated encryption, unlike case 1)'
    else
        fail_case 'rejected, but not at the decryption stage'
        sed -n '1,6p' "$OUT/c9.log" | sed 's/^/        /'
    fi

    # 11: and the good encrypted backup still verifies end to end.
    ENCDIR2=$(mktemp -d "$OUT/enc2XXXXXX")
    ./backup.sh --engine "$ENGINE" "${SRC_ARGS[@]}" --out "$ENCDIR2" \
        --recipient "$GOOD_RECIP" --identity "$KEYDIR/good.txt" >/dev/null
    ENCMAN2=$(find "$ENCDIR2" -name '*.json' | head -1)
    if ./verify.sh --manifest "$ENCMAN2" --identity "$KEYDIR/good.txt" --image "$IMAGE" >"$OUT/c10.log" 2>&1; then
        pass_case 'an untouched ENCRYPTED backup decrypts, restores and verifies'
    else
        fail_case 'a good encrypted backup was rejected'
        sed -n '1,15p' "$OUT/c10.log" | sed 's/^/        /'
    fi
fi
printf '\n'

if [ "$FAILURES" -gt 0 ]; then
    die "$FAILURES negative case(s) behaved wrongly ($ENG_NAME)"
fi
ok "every failure mode was caught on $ENG_NAME, and the good backup still passes"
