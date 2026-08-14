#!/usr/bin/env bash
# =============================================================================
# The PITR fire drill, proven the way everything here is proven: by
# destruction. Seed a real Postgres with WAL archiving, take a base backup,
# name an instant, commit a disaster AFTER it (rows deleted, a table dropped -
# and ARCHIVED, so the archive itself contains the disaster), then DESTROY the
# source. The base backup plus the archive alone must reproduce the named
# instant, fingerprints and all - with the disaster provably absent.
#
# Then every measured way a WAL archive lies, each one CAUGHT:
#   * a dead archive is silent - commits keep landing, rc 0, while
#     failed_count climbs and the archive freezes. mark refuses to write a
#     manifest for an instant the archive never received, and check reads
#     the only witness there is;
#   * a hole in the chain: verify refuses BEFORE booting anything (a nameless
#     recovery would sail past the hole and call the truncation success);
#   * rot in place with the right size: the chain looks whole, so recovery
#     runs - and must die reaching for the mark, never promote short of it;
#   * a mark that predates its base can never be reached: refused in
#     milliseconds, not discovered by a recovery that replays to FATAL;
#   * squatters and debris in the archive: named by check, by size and by
#     shape, from the directory alone.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
. test/seed.sh
load_engine postgres

ENCRYPTED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --encrypted) ENCRYPTED=1; shift;;
        *)           die "unknown option: $1 (usage: pitr.sh [--encrypted])";;
    esac
done

IMAGE="${BV_IMAGE:-$ENG_DEFAULT_IMAGE}"
SRC=bv-pitr-drill-src
OUT=$(mktemp -d)
ARCHIVE="$OUT/archive"
FAILURES=0

pass_case() { printf '  %sOK%s   %s\n' "$c_green" "$c_reset" "$1"; }
fail_case() { printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$1"; FAILURES=$((FAILURES + 1)); }

# Mutate the archive as root: segments land 0600, owned by the server's user,
# so the host can list and move them but never read or rewrite their bytes.
# Writes go THROUGH the existing inode (cat >, dd conv=notrunc) on purpose, so
# owner and mode survive and the restoring server can still read its segments.
root_sh() { docker run --rm -u root --entrypoint sh -v "$OUT:/work" "$IMAGE" -c "$1"; }

cleanup() {
    docker rm -f "$SRC" >/dev/null 2>&1 || true
    root_sh 'rm -rf /work/archive /work/pristine' >/dev/null 2>&1 || true
    rm -rf "$OUT" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$ARCHIVE"
chmod 777 "$ARCHIVE"   # the container's postgres user writes it
docker rm -f "$SRC" >/dev/null 2>&1 || true
# The archive_command is the documentation's own suggestion, on purpose: the
# lies this suite catches are the ones that ship with the standard recipe.
# --encrypted swaps cp for age (the static binary rides into the container
# read-only), so every segment lands as ciphertext - and the whole suite must
# still hold, key in hand.
SEGSFX=""
VF=()          # extra verify args
BASE_ENC=()    # extra base args
if [ "$ENCRYPTED" -eq 1 ]; then
    encryption_available || die '--encrypted requires age'
    # The runner's age rides INTO containers, so it must be a static binary
    # (the release build is; a distro build might not be). A drill that
    # assumes is not a drill: prove it before booting anything.
    docker run --rm -v "$(command -v age):/usr/local/bin/age:ro" --entrypoint age "$IMAGE" --version >/dev/null 2>&1 \
        || die "the age at $(command -v age) does not run inside $IMAGE (dynamically linked?) - the encrypted drill needs a static age"
    age-keygen -o "$OUT/key.txt" 2>/dev/null
    RECIPIENT=$(grep -o 'age1.*' "$OUT/key.txt")
    SEGSFX=".age"
    VF=(--identity "$OUT/key.txt")
    BASE_ENC=(--recipient "$RECIPIENT" --identity "$OUT/key.txt")
    log "booting the source database ($IMAGE) with ENCRYPTED WAL archiving on"
    docker run -d --name "$SRC" -e POSTGRES_PASSWORD=verify -e POSTGRES_DB=app \
        -v "$ARCHIVE:/archive" -v "$(command -v age):/usr/local/bin/age:ro" "$IMAGE" \
        -c archive_mode=on \
        -c "archive_command=test ! -f /archive/%f.age && age -r $RECIPIENT -o /archive/%f.age %p" >/dev/null
else
    log "booting the source database ($IMAGE) with WAL archiving on"
    docker run -d --name "$SRC" -e POSTGRES_PASSWORD=verify -e POSTGRES_DB=app \
        -v "$ARCHIVE:/archive" "$IMAGE" \
        -c archive_mode=on -c "archive_command=test ! -f /archive/%f && cp %p /archive/%f" >/dev/null
fi
eng_wait_ready "$SRC"
seed_postgres "$SRC" app
ok "seeded: $(eng_query "$SRC" app 'SELECT count(*) FROM customers;' | tr -d '\n') customers, $(eng_query "$SRC" app 'SELECT count(*) FROM orders;' | tr -d '\n') orders"

printf '\n'
echo '== Case 1: the drill - base, mark, disaster, destruction, recovery to the mark =='
# A mark BEFORE the base backup exists only to prove case 5 later: recovery
# rolls forward from the base, so this instant is unreachable by construction.
./pitr.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$OUT/early" >"$OUT/early.log" 2>&1 \
    || { fail_case 'the pre-base mark itself failed'; sed -n '1,10p' "$OUT/early.log" | sed 's/^/        /'; }
M_EARLY=$(find "$OUT/early" -name '*_mark.json' | head -1)

./pitr.sh base --container "$SRC" --db app --archive "$ARCHIVE" --out "$OUT/backups" ${BASE_ENC[@]+"${BASE_ENC[@]}"} >"$OUT/base.log" 2>&1 \
    || { fail_case 'base backup failed'; sed -n '1,12p' "$OUT/base.log" | sed 's/^/        /'; }
B=$(find "$OUT/backups" -name '*_base.json' | head -1)
[ -n "$B" ] || die 'no base manifest was written - nothing else can run'

# Two batches with a segment switch in between, so the base..mark chain spans
# several segments and later cases can break a TRUE middle one. The first
# batch is deliberately fat (>100KB of WAL): case 4 corrupts bytes near the
# START of that segment, and they must land on real records - a switched-out
# segment is zero-padded after its content, and rotting the padding proves
# nothing.
eng_query "$SRC" app "INSERT INTO customers (name, email)
    SELECT 'post-base ' || g, 'pb' || g || '@example.com' FROM generate_series(1,1000) g;" >/dev/null
eng_query "$SRC" app 'SELECT pg_walfile_name(pg_switch_wal());' >/dev/null
eng_query "$SRC" app "INSERT INTO customers (name, email)
    SELECT 'post-switch ' || g, 'ps' || g || '@example.com' FROM generate_series(1,100) g;" >/dev/null

sleep 1.1   # marks carry second-resolution stamps; keep this one distinct
./pitr.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$OUT/backups" >"$OUT/mark.log" 2>&1 \
    || { fail_case 'the mark failed on a healthy archive'; sed -n '1,12p' "$OUT/mark.log" | sed 's/^/        /'; }
M=$(find "$OUT/backups" -name '*_mark.json' | head -1)
[ -n "$M" ] || die 'no mark manifest was written - nothing else can run'
pass_case "marked the instant to reproduce: 1600 customers, $(json_str "$M" mark_name)"

if ./pitr.sh check --archive "$ARCHIVE" --container "$SRC" >"$OUT/check1.log" 2>&1; then
    pass_case 'check blesses a continuous, current archive'
else
    fail_case 'check rejected a healthy archive'
    sed -n '1,12p' "$OUT/check1.log" | sed 's/^/        /'
fi
printf '\n'

echo '== Case 2: the archive dies - and stays SILENT everywhere except here =='
# The measured lie: with the archive unwritable, 600 inserts committed with
# rc 0 each while failed_count climbed and pg_wal piled up. The application
# layer never hears about it; pg_stat_archiver is the only witness.
chmod 555 "$ARCHIVE"
eng_query "$SRC" app "INSERT INTO orders (customer_id, total, note)
    SELECT (g % 500) + 1, 9.99, 'archivo muerto ' || g FROM generate_series(1,100) g;" >/dev/null
if ./pitr.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$OUT/dead" --timeout 8 >"$OUT/dead.log" 2>&1; then
    fail_case 'mark wrote a manifest for an instant the archive never received'
else
    if grep -q 'never reached the archive' "$OUT/dead.log" && grep -q 'pg_stat_archiver says' "$OUT/dead.log"; then
        pass_case 'mark refuses the unarchivable instant AND reads the only witness out loud'
    else
        fail_case 'mark failed, but not for the honest reason'
        sed -n '1,12p' "$OUT/dead.log" | sed 's/^/        /'
    fi
fi
if [ -z "$(find "$OUT/dead" -name '*_mark.json' 2>/dev/null)" ]; then
    pass_case '...and left no plausible manifest behind'
else
    fail_case 'a manifest exists for a mark that admitted failure'
fi
if ./pitr.sh check --archive "$ARCHIVE" --container "$SRC" >"$OUT/check-dead.log" 2>&1; then
    fail_case 'check blessed an archive the archiver cannot write'
else
    if grep -Eq 'behind the server|never archived|choked' "$OUT/check-dead.log"; then
        pass_case 'check names the backlog the application will never mention'
    else
        fail_case 'check failed, but without naming the archiver problem'
        sed -n '1,15p' "$OUT/check-dead.log" | sed 's/^/        /'
    fi
fi
chmod 777 "$ARCHIVE"
# A fresh segment notification nudges the archiver out of its retry backoff;
# it then drains the backlog OLDEST FIRST (measured: the frozen segments
# arrived in order once the cause was fixed).
eng_query "$SRC" app "INSERT INTO orders (customer_id, total) VALUES (1, 1.00);
    SELECT pg_switch_wal();" >/dev/null
tries=0
until ./pitr.sh check --archive "$ARCHIVE" --container "$SRC" >"$OUT/check-heal.log" 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || break
    sleep 3
done
if [ "$tries" -lt 50 ]; then
    if grep -q 'archiver history' "$OUT/check-heal.log"; then
        pass_case 'the archiver healed and check is green - the failed_count tombstone is reported, not punished'
    else
        pass_case 'the archiver healed and check is green again'
    fi
else
    fail_case 'the archiver never caught up after the cause was fixed'
    sed -n '1,15p' "$OUT/check-heal.log" | sed 's/^/        /'
fi
printf '\n'

echo '== Case 1, continued: disaster, destruction, and the recovery that must be exact =='
# The disaster lands AFTER the mark and IS archived: the archive now contains
# the deletion and the dropped table, and recovery must stop short of both.
eng_query "$SRC" app "DELETE FROM orders WHERE note LIKE 'archivo muerto%';
    DROP TABLE customers CASCADE;
    SELECT pg_walfile_name(pg_switch_wal());" >/dev/null 2>&1
sleep 2
log 'DESTROYING the source database (this is the whole point)'
docker rm -f "$SRC" >/dev/null
ok 'source is gone - the base backup and the archive are now the only copy'
if ./pitr.sh verify --base "$B" --mark "$M" --archive "$ARCHIVE" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/verify.log" 2>&1; then
    if grep -q 'PITR VERIFIED' "$OUT/verify.log" \
       && grep -q 'recovery stopping at restore point' "$OUT/verify.log"; then
        pass_case 'the archive reproduced the marked instant, fingerprints and all - the archived disaster excluded'
    else
        fail_case 'verify passed but without the receipt it promises'
        sed -n '1,20p' "$OUT/verify.log" | sed 's/^/        /'
    fi
else
    fail_case 'the fire drill failed: base + archive did not reproduce the mark'
    sed -n '1,25p' "$OUT/verify.log" | sed 's/^/        /'
fi
printf '\n'

# The middle of the chain, computed rather than guessed: the segment right
# after the base backup's first requirement is always strictly inside
# base..mark here (the drill switched segments between them on purpose).
START_FILE=$(json_str "$B" wal_start_file)
SEG_BYTES=$(json_num "$B" wal_segment_bytes)
MIDDLE=$(wal_index_name "$(wal_name_timeline "$START_FILE")" \
    "$(( $(wal_name_index "$START_FILE" "$SEG_BYTES") + 1 ))" "$SEG_BYTES")

echo "== Case 3: a hole in the chain ($MIDDLE removed) - refused before anything boots =="
mv "$ARCHIVE/$MIDDLE$SEGSFX" "$OUT/hidden-$MIDDLE"
if ./pitr.sh verify --base "$B" --mark "$M" --archive "$ARCHIVE" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/hole.log" 2>&1; then
    fail_case 'verify blessed an archive with a hole in the chain'
else
    if grep -q "missing segment $MIDDLE" "$OUT/hole.log" && grep -q 'refusing to boot' "$OUT/hole.log"; then
        pass_case 'the hole is named and the recovery never boots (a nameless recovery would have promoted past it - measured)'
    else
        fail_case 'verify failed, but without naming the hole'
        sed -n '1,12p' "$OUT/hole.log" | sed 's/^/        /'
    fi
    if grep -q 'booting a throwaway' "$OUT/hole.log"; then
        fail_case 'verify booted a container the chain already refuted'
    fi
fi
mv "$OUT/hidden-$MIDDLE" "$ARCHIVE/$MIDDLE$SEGSFX"
printf '\n'

echo '== Case 4: rot in place - right size, rotten bytes, so the chain looks whole =='
# The offsite suite met this shape at the file level. Two eras of defence,
# both asserted: a mark WITH an inventory refuses in milliseconds, before
# anything boots (every complete segment has the same size, so only the hash
# sees rot - measured); an OLD mark without one still cannot promote short,
# because every recovery here has a NAME it must reach - the server boots,
# replay hits garbage and dies. cat > and dd conv=notrunc keep the inode,
# owner and mode.
root_sh "cat /work/archive/$MIDDLE$SEGSFX > /work/pristine
         dd if=/dev/zero of=/work/archive/$MIDDLE$SEGSFX bs=8192 seek=1 count=4 conv=notrunc 2>/dev/null"
if ./pitr.sh verify --base "$B" --mark "$M" --archive "$ARCHIVE" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/rot.log" 2>&1; then
    fail_case 'verify promoted through a segment full of zeros'
else
    if grep -q "$MIDDLE$SEGSFX - these are not the bytes the mark stood on" "$OUT/rot.log" \
        && ! grep -q 'booting a throwaway' "$OUT/rot.log"; then
        pass_case 'the inventory names the rotten segment TODAY - nothing ever boots'
    else
        fail_case 'verify failed, but not by the inventory path (or it booted first)'
        sed -n '1,15p' "$OUT/rot.log" | sed 's/^/        /'
    fi
fi
# The retrocompat era: strip the inventory from a COPY of the mark (an old
# manifest, reconstructed) - the reported-not-skipped warning must fire, and
# the recovery must DIE at the garbage instead of promoting short of the mark.
sed '/^  "wal": {/,/^  },$/d' "$M" > "$OUT/old_mark.json"
if ./pitr.sh verify --base "$B" --mark "$OUT/old_mark.json" --archive "$ARCHIVE" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/rot-old.log" 2>&1; then
    fail_case 'an inventory-less verify promoted through a segment full of zeros'
else
    if grep -q 'records no WAL inventory' "$OUT/rot-old.log" && grep -q 'recovery DIED' "$OUT/rot-old.log"; then
        pass_case 'an old mark is warned about, and its recovery still dies reaching for the mark instead of promoting short'
    else
        fail_case 'the inventory-less path failed differently'
        sed -n '1,20p' "$OUT/rot-old.log" | sed 's/^/        /'
    fi
fi
root_sh "cat /work/pristine > /work/archive/$MIDDLE$SEGSFX && rm /work/pristine"
printf '\n'

echo '== Case 5: a mark that predates its base backup can never be reached =='
if [ -z "$M_EARLY" ]; then
    fail_case 'the pre-base mark was never written, so this case cannot run'
elif ./pitr.sh verify --base "$B" --mark "$M_EARLY" --archive "$ARCHIVE" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/early-verify.log" 2>&1; then
    fail_case 'verify accepted a mark from before the base backup'
else
    if grep -q 'predates the base backup' "$OUT/early-verify.log" \
       && ! grep -q 'booting a throwaway' "$OUT/early-verify.log"; then
        pass_case 'refused in milliseconds what a recovery would refuse in minutes (unreached target = FATAL - measured)'
    else
        fail_case 'verify failed, but not with the reachability verdict'
        sed -n '1,12p' "$OUT/early-verify.log" | sed 's/^/        /'
    fi
fi
printf '\n'

echo '== Case 6: squatters and debris in the archive - named from the directory alone =='
# The measured poison: 26 bytes of garbage on a segment name wedged the
# documented archive_command forever (test ! -f can never pass again), with
# the application none the wiser. Here the source is already gone - but the
# squatter also lies to every FUTURE recovery, and check must name it by size.
# Its name comes from the LAST segment actually present: the archive kept
# growing after the mark (the drill's own switches), and squatting an
# occupied name is just vandalism, not this lie.
LAST_SEG=$(find "$ARCHIVE" -maxdepth 1 -type f -printf '%f\n' | grep -E '^[0-9A-F]{24}(\.age)?$' | grep -oE '^[0-9A-F]{24}' | sort | tail -1)
POISON=$(wal_index_name "$(wal_name_timeline "$LAST_SEG")" \
    "$(( $(wal_name_index "$LAST_SEG" "$SEG_BYTES") + 2 ))" "$SEG_BYTES")
printf 'VENENO: not a WAL segment' > "$ARCHIVE/$POISON$SEGSFX"
printf 'half an archive copy' > "$ARCHIVE/000000010000000000000042.partial"
if ./pitr.sh check --archive "$ARCHIVE" >"$OUT/poison.log" 2>&1; then
    fail_case 'check blessed an archive with a squatter and a .partial in it'
else
    if grep -q "$POISON$SEGSFX is " "$OUT/poison.log" && grep -q 'not a WAL segment' "$OUT/poison.log"; then
        pass_case 'the squatted name is betrayed by its size, the .partial by its shape'
    else
        fail_case 'check failed, but did not name both leftovers'
        sed -n '1,15p' "$OUT/poison.log" | sed 's/^/        /'
    fi
fi
rm -f "$ARCHIVE/$POISON$SEGSFX" "$ARCHIVE/000000010000000000000042.partial"
printf '\n'

if [ "$ENCRYPTED" -eq 1 ]; then
    echo '== Case 8 (encrypted only): no key, no drill - and the wrong key dies fast =='
    # No comforting green tick without the identity: refusing is the feature.
    if ./pitr.sh verify --base "$B" --mark "$M" --archive "$ARCHIVE" --image "$IMAGE" >"$OUT/nokey.log" 2>&1; then
        fail_case 'verify ran an encrypted drill without the key'
    else
        if grep -q 'does not guess' "$OUT/nokey.log" && ! grep -q 'booting a throwaway' "$OUT/nokey.log"; then
            pass_case 'verification without the key is refused outright - a drill that guesses is not a drill'
        else
            fail_case 'verify failed without the key, but not by the refusal path'
            sed -n '1,10p' "$OUT/nokey.log" | sed 's/^/        /'
        fi
    fi
    age-keygen -o "$OUT/wrong.txt" 2>/dev/null
    if ./pitr.sh verify --base "$B" --mark "$M" --archive "$ARCHIVE" --image "$IMAGE" --identity "$OUT/wrong.txt" >"$OUT/wrongkey.log" 2>&1; then
        fail_case 'verify recovered with a key that cannot open the backup'
    else
        if grep -q 'does not decrypt with the given identity' "$OUT/wrongkey.log"; then
            pass_case 'the wrong key dies at the base artefact, named for what it is'
        else
            fail_case 'the wrong key failed some other way'
            sed -n '1,12p' "$OUT/wrongkey.log" | sed 's/^/        /'
        fi
    fi
    printf '\n'
fi

echo '== Case 7: after every mutation was undone, the drill still passes =='
# The suite must leave the archive as it found it - proven the only honest
# way: the same recovery, byte-for-byte, one more time.
if ./pitr.sh verify --base "$B" --mark "$M" --archive "$ARCHIVE" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/verify2.log" 2>&1; then
    pass_case 'the archive still reproduces the mark exactly'
else
    fail_case 'the harness broke the archive it was testing'
    sed -n '1,20p' "$OUT/verify2.log" | sed 's/^/        /'
fi
printf '\n'

if [ "$FAILURES" -gt 0 ]; then
    die "$FAILURES PITR case(s) behaved wrongly"
fi
ok 'the marked instant survived the fire, and every measured WAL archive lie was caught'
