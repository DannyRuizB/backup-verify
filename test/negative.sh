#!/usr/bin/env bash
# =============================================================================
# The cases that justify this repo. Each one is a way a backup looks fine and
# is not, measured on a real Postgres - and each must be CAUGHT.
#
#   1. A truncated archive. pg_restore exits non-zero but LEAVES THE TABLE
#      POPULATED, so a row-count check signs it off. The fingerprint must not.
#   2. An empty artefact (0 bytes, or ~20 bytes of empty gzip). backup.sh must
#      refuse to produce one; verify.sh must refuse to accept one.
#   3. An artefact that rotted on disk after the backup. The checksum catches it.
#   4. Silent data loss: one row deleted from the artefact's source before the
#      manifest is compared - the fingerprint differs even though the counts
#      match. (Simulated by editing the manifest, which is the same comparison.)
#
# A test that only proves the happy path proves the least interesting thing.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
. lib/common.sh

SRC=bv-neg-src
OUT=$(mktemp -d)
IMAGE="${BV_IMAGE:-postgres:17-alpine}"
FAILURES=0

pass_case() { printf '  %sOK%s   %s\n' "$c_green" "$c_reset" "$1"; }
fail_case() { printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
    docker rm -f "$SRC" >/dev/null 2>&1 || true
    docker ps -aq --filter "name=bv-verify-" | xargs -r docker rm -f >/dev/null 2>&1 || true
    rm -rf "$OUT"
}
trap cleanup EXIT

log 'booting a source database with data'
docker rm -f "$SRC" >/dev/null 2>&1 || true
docker run -d --name "$SRC" -e POSTGRES_PASSWORD=neg -e POSTGRES_DB=app "$IMAGE" >/dev/null
wait_for_postgres "$SRC"
# Same shape as the e2e: two tables PLUS a view and a function. Case 6 needs
# schema objects to lose - with a single bare table there is nothing for a
# tables-only dump to drop, and the case silently proves nothing (it did,
# first time round).
docker exec -i "$SRC" psql -q -v ON_ERROR_STOP=1 -U postgres -d app <<'SQL'
CREATE TABLE customers (id serial PRIMARY KEY, name text NOT NULL, email text UNIQUE);
CREATE TABLE orders (id serial PRIMARY KEY, customer_id int REFERENCES customers(id), total numeric(10,2));
CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 1000;
CREATE FUNCTION order_label(o orders) RETURNS text AS
  $$ SELECT 'order #' || o.id $$ LANGUAGE sql;
INSERT INTO customers (name, email)
  SELECT 'cliente ' || g, 'c' || g || '@example.com' FROM generate_series(1,500) g;
INSERT INTO orders (customer_id, total)
  SELECT (g % 500) + 1, (g * 1.37)::numeric(10,2) FROM generate_series(1,800) g;
SQL

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
    ./backup.sh --container "$SRC" --db app --out "$dir" >/dev/null
    # Exactly one backup lives in this directory, so this is unambiguous.
    find "$dir" -name '*.json' | head -1
}

# Re-align a manifest's size+sha with its artefact, so a case that targets a
# LATER gate is not stopped by an earlier one.
realign_manifest() {
    python3 "$SCRIPT_DIR/realign_manifest.py" "$1" "${1%.json}.dump"
}

# Same, for an encrypted artefact (its name carries the .age suffix).
realign_manifest_enc() {
    python3 "$SCRIPT_DIR/realign_manifest.py" "$1" "$2"
}
printf '\n'

echo '== Case 1: truncated archive (restores PARTIAL data, exits non-zero) =='
MANIFEST=$(fresh_backup)
ARTEFACT="${MANIFEST%.json}.dump"
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
    if grep -qE 'fingerprint differs|table absent|restored copy has' "$OUT/c1.log"; then
        pass_case 'truncated archive REJECTED by the content comparison'
        # The evidence for why counting rows is not enough:
        if grep -q 'pg_restore exited' "$OUT/c1.log"; then
            pass_case '...and the log shows pg_restore failed yet data landed anyway'
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
if ./backup.sh --container "$SRC" --db nosuchdb --out "$OUT" >"$OUT/c2.log" 2>&1; then
    fail_case 'backup.sh reported success for a database that does not exist'
else
    pass_case 'backup.sh fails on a dump that cannot run'
    if find "$OUT" -name 'nosuchdb_*' | grep -q .; then
        fail_case 'and it left an artefact behind'
    else
        pass_case '...and leaves no plausible-looking artefact behind'
    fi
fi
printf '\n'

echo '== Case 3: artefact rotted on disk after the backup =='
MANIFEST=$(fresh_backup)
ARTEFACT="${MANIFEST%.json}.dump"
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
MANIFEST=$(fresh_backup)
python3 "$SCRIPT_DIR/break_fingerprint.py" "$MANIFEST"
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
# The most dangerous artefact of all, and entirely realistic: a cron that says
# `pg_dump -t customers -t orders` because someone only cared about the tables.
# MEASURED: it exits 0, restores every row, and drops 4 of 4 indexes, 4 of 5
# constraints, the view, the function and the trigger. Before schema
# verification existed, this repo called that backup VERIFIED.
MANIFEST=$(fresh_backup)
ARTEFACT="${MANIFEST%.json}.dump"
# Both tables (so the data gates all pass) but no independent objects: the
# view and the function are simply not in a `-t`-scoped dump.
docker exec "$SRC" pg_dump -U postgres -d app -Fc -t customers -t orders < /dev/null > "$ARTEFACT"
realign_manifest "$MANIFEST"
if ./verify.sh --manifest "$MANIFEST" --image "$IMAGE" >"$OUT/c6.log" 2>&1; then
    fail_case 'a tables-only artefact passed verification (schema loss went unnoticed)'
    sed -n '1,20p' "$OUT/c6.log" | sed 's/^/        /'
else
    if grep -qE 'indexes - expected|constraints - expected|views - expected|routines - expected' "$OUT/c6.log"; then
        pass_case 'schema loss caught by the object comparison'
        # The point worth shouting about: the DATA was fine.
        if grep -q 'OK   customers' "$OUT/c6.log"; then
            pass_case '...while the table it did restore matched row for row'
        fi
    else
        fail_case 'rejected, but not by the schema comparison'
        sed -n '1,20p' "$OUT/c6.log" | sed 's/^/        /'
    fi
fi
printf '\n'

echo '== Cases 7-11: encryption (a backup you cannot decrypt is not a backup) =='
if ! command -v age >/dev/null 2>&1; then
    fail_case 'age is not installed - the encryption cases could not run (they are not optional)'
else
    KEYDIR=$(mktemp -d "$OUT/keysXXXXXX")
    age-keygen -o "$KEYDIR/good.txt" 2>/dev/null
    age-keygen -o "$KEYDIR/other.txt" 2>/dev/null
    GOOD_RECIP=$(grep 'public key' "$KEYDIR/good.txt" | sed 's/.*: //')
    ENCDIR=$(mktemp -d "$OUT/encXXXXXX")
    ./backup.sh --container "$SRC" --db app --out "$ENCDIR" \
        --recipient "$GOOD_RECIP" --identity "$KEYDIR/good.txt" >/dev/null
    ENCMAN=$(find "$ENCDIR" -name '*.json' | head -1)
    ENCART="${ENCMAN%.json}.dump.age"

    # 7: the artefact must actually BE encrypted, not merely named .age.
    if [ -f "$ENCART" ] && head -c 16 "$ENCART" | grep -q 'age-encryption'; then
        pass_case 'the artefact on disk is real age ciphertext'
    else
        fail_case "no age ciphertext at $ENCART"
    fi
    if head -c 200 "$ENCART" | grep -q 'PGDMP'; then
        fail_case 'the plaintext pg_dump header is visible in the artefact'
    else
        pass_case '...with no pg_dump header in the clear'
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
    ./backup.sh --container "$SRC" --db app --out "$ENCDIR2" \
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
    die "$FAILURES negative case(s) behaved wrongly"
fi
ok 'every failure mode was caught, and the good backup still passes'
