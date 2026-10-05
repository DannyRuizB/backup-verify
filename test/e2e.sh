#!/usr/bin/env bash
# =============================================================================
# The honest cycle: seed a real database, back it up, DESTROY it, restore into
# a fresh instance and compare. If this passes, the backup restores - not
# "looks fine", restores.
#
# The cycle is engine-agnostic; only the seeding knows SQL dialects. Every
# engine gets the SAME shape to lose: two tables, an index, a view, routines
# and a trigger - because the measured failure modes (pg_dump -t, mysqldump
# without --routines) drop exactly the things a row count never sees.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
. test/seed.sh

ENGINE="postgres"
# --encrypted runs the SAME cycle through age: the point is that encryption
# changes nothing about the promise. A backup you cannot decrypt is not a
# backup, so the encrypted path has to survive the same destruction test.
ENCRYPTED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --engine)    ENGINE="${2:-}"; shift 2;;
        --encrypted) ENCRYPTED=1; shift;;
        *)           die "unknown option: $1 (usage: e2e.sh [--engine postgres|mysql|files|sqlite] [--encrypted])";;
    esac
done
load_engine "$ENGINE"

SRC=bv-e2e-src
SRC_DIR=""
OUT=$(mktemp -d)
IMAGE="${BV_IMAGE:-$ENG_DEFAULT_IMAGE}"

SRC_DB=""
cleanup() {
    if [ "$ENG_NAME" = files ]; then
        if [ -n "$SRC_DIR" ]; then rm -rf "$SRC_DIR"; fi
    elif [ "$ENG_NAME" = sqlite ]; then
        [ -n "$SRC_DB" ] && rm -f "$SRC_DB" "$SRC_DB-wal" "$SRC_DB-shm"
    else
        docker rm -f "$SRC" >/dev/null 2>&1 || true
    fi
    rm -rf "$OUT"
}
trap cleanup EXIT

# The source: a database container for the DB engines, a directory tree for
# the files engine. Same cycle either way - seed, back up, DESTROY, verify.
if [ "$ENG_NAME" = files ]; then
    SRC_DIR=$(mktemp -d)
    log "seeding a deterministic file tree ($SRC_DIR)"
    seed_files "$SRC_DIR"
    ok "seeded: $(find "$SRC_DIR" -type f | wc -l) files, $(find "$SRC_DIR" -type l | wc -l) symlink, $(find "$SRC_DIR" -mindepth 1 -type d | wc -l) dirs (one empty, one setgid)"
elif [ "$ENG_NAME" = sqlite ]; then
    SRC_DB="$OUT/source.db"
    log "seeding a deterministic SQLite database ($SRC_DB)"
    seed_sqlite "$SRC_DB"
    ok "seeded: $(eng_query "$SRC_DB" app 'SELECT count(*) FROM customers;' | tr -d '\n') customers, $(eng_query "$SRC_DB" app 'SELECT count(*) FROM orders;' | tr -d '\n') orders"
else
    log "booting the source database ($ENG_NAME, $IMAGE)"
    docker rm -f "$SRC" >/dev/null 2>&1 || true
    eng_boot "$SRC" app "$IMAGE"
    eng_wait_ready "$SRC"

    log "seeding deterministic data"
    "seed_$ENG_NAME" "$SRC" app
    ok "seeded: $(eng_query "$SRC" app 'SELECT count(*) FROM customers;' | tr -d '\n') customers, $(eng_query "$SRC" app 'SELECT count(*) FROM orders;' | tr -d '\n') orders"
fi

# One invocation shape for every engine: the source arguments differ, the
# promise does not.
if [ "$ENG_NAME" = files ]; then
    SRC_ARGS=(--path "$SRC_DIR")
elif [ "$ENG_NAME" = sqlite ]; then
    SRC_ARGS=(--path "$SRC_DB" --db app)
else
    SRC_ARGS=(--container "$SRC" --db app)
fi

KEYFILE=""
if [ "$ENCRYPTED" -eq 1 ]; then
    command -v age >/dev/null 2>&1 || die 'age is not installed - cannot run the encrypted cycle'
    KEYFILE="$OUT/key.txt"
    age-keygen -o "$KEYFILE" 2>/dev/null
    RECIPIENT=$(grep 'public key' "$KEYFILE" | sed 's/.*: //')
    log "BACKUP (encrypted to $RECIPIENT)"
    ./backup.sh --engine "$ENGINE" "${SRC_ARGS[@]}" --out "$OUT" \
        --recipient "$RECIPIENT" --identity "$KEYFILE"
else
    log "BACKUP"
    ./backup.sh --engine "$ENGINE" "${SRC_ARGS[@]}" --out "$OUT"
fi
MANIFEST=$(find "$OUT" -name '*.json' | head -1)
[ -n "$MANIFEST" ] || die 'backup.sh produced no manifest'

# The destruction is the point. A backup nobody has restored is a hope, and the
# only way to stop hoping is to throw the original away first.
if [ "$ENG_NAME" = files ]; then
    log "DESTROYING the source tree (this is the whole point)"
    rm -rf "$SRC_DIR"
    SRC_DIR=""
elif [ "$ENG_NAME" = sqlite ]; then
    log "DESTROYING the source database file (this is the whole point)"
    rm -f "$SRC_DB" "$SRC_DB-wal" "$SRC_DB-shm"
    SRC_DB=""
else
    log "DESTROYING the source database (this is the whole point)"
    docker rm -f "$SRC" >/dev/null
    SRC=""
fi
ok 'source is gone - the artefact on disk is now the only copy'

# No --engine here on purpose: verify.sh reads the engine from the manifest.
log "VERIFY (restores into a fresh instance and compares)"
if [ "$ENCRYPTED" -eq 1 ]; then
    ./verify.sh --manifest "$MANIFEST" --identity "$KEYFILE" --image "$IMAGE"
else
    ./verify.sh --manifest "$MANIFEST" --image "$IMAGE"
fi

# --max-age: the same backup proved "a month later" (BV_NOW stands in for the
# clock) is a schedule that stopped. It must still restore - VERIFIED stays in
# the log, the positive anchor - and the run must fail anyway.
log "VERIFY again with --max-age 7 and the clock 30 days ahead (must restore AND fail)"
VERIFY_ARGS=(--manifest "$MANIFEST" --image "$IMAGE" --max-age 7)
[ "$ENCRYPTED" -eq 1 ] && VERIFY_ARGS+=(--identity "$KEYFILE")
STALE_LOG=$(mktemp)
STALE_RC=0
BV_NOW=$(( $(date -u +%s) + 30 * 86400 )) ./verify.sh "${VERIFY_ARGS[@]}" >"$STALE_LOG" 2>&1 || STALE_RC=$?
if [ "$STALE_RC" -eq 0 ] || ! grep -q 'VERIFIED:' "$STALE_LOG" \
    || ! grep -q 'STALE: this backup restores, but it was taken 30 days ago' "$STALE_LOG"; then
    sed 's/^/      /' "$STALE_LOG"
    rm -f "$STALE_LOG"
    die "--max-age did not fail a 30-day-old backup that restores (rc $STALE_RC)"
fi
rm -f "$STALE_LOG"
ok '--max-age 7 a month later: VERIFIED, and failed as STALE'

if [ "$ENCRYPTED" -eq 1 ]; then
    ok "e2e passed: the ENCRYPTED $ENG_NAME backup decrypted and restored identically after the source was destroyed"
else
    ok "e2e passed: the $ENG_NAME backup restored identically after the source was destroyed"
fi
