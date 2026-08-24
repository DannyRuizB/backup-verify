#!/usr/bin/env bash
# =============================================================================
# The MySQL binlog PITR fire drill, proven the way everything here is proven:
# by destruction. Seed a real MySQL with its binlog on, take an anchored dump,
# name an instant, commit a disaster AFTER it (and ARCHIVE the disaster too,
# via a second mark), then DESTROY the source. The dump plus the archived
# binlogs alone must reproduce the named instant, fingerprints and all.
#
# Then every measured way binlog PITR lies, each one CAUGHT:
#   * a stop position that is never reached exits 0 with an empty stderr -
#     so a mark doctored to stop EARLY replays clean and must be failed by
#     the ARRIVAL gate (content), not by any exit code;
#   * a missing file in the middle of the chain would be STITCHED OVER
#     silently (measured: 100 of 300 rows gone, rc 0) - refused by name
#     before anything boots;
#   * rot in an archived binlog - mysqlbinlog replays it happily without
#     --verify-binlog-checksum (measured) - named by the mark's inventory
#     TODAY;
#   * a mark that predates the base's anchor can never be reached: refused
#     in milliseconds;
#   * strays and holes in the archive: named by check from the directory
#     alone, and byte-mismatches against the live server named by
#     check --container.
#
# --encrypted runs the same drill with the archive as age ciphertext end to
# end (the mark encrypts as it archives; verify decrypts only inside the
# throwaway), plus the encrypted-only refusals: no key means no drill, and
# the wrong key is named at the first artefact it fails to open.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
. test/seed.sh
load_engine mysql

ENCRYPTED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --encrypted) ENCRYPTED=1; shift;;
        *)           die "unknown option: $1 (usage: binlog.sh [--encrypted])";;
    esac
done

IMAGE="${BV_IMAGE:-mysql:8.4}"
SRC=bv-binlog-drill-src
OUT=$(mktemp -d)
ARCHIVE="$OUT/archive"
TOOLS="$OUT/tools"
FAILURES=0

pass_case() { printf '  %sOK%s   %s\n' "$c_green" "$c_reset" "$1"; }
fail_case() { printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
    docker rm -f "$SRC" >/dev/null 2>&1 || true
    rm -rf "$OUT" 2>/dev/null || true
}
trap cleanup EXIT

# --encrypted runs the SAME drill with the archive as age ciphertext end to
# end: the mark encrypts as it archives, and verify decrypts only inside the
# throwaway. The measured stake: a plain binlog reads your rows back with one
# grep, and a plain binlog truncated at an event boundary decodes CLEAN -
# ciphertext dies loudly at any cut.
SFX=""
EFLAGS=()   # base/mark: --recipient + --identity
VF=()       # verify / check --container: --identity
if [ "$ENCRYPTED" -eq 1 ]; then
    encryption_available || die '--encrypted requires age'
    # The runner's age rides INTO the replay container, so it must be a
    # static binary that actually runs there - proven now, not mid-drill.
    docker run --rm -v "$(command -v age):/usr/local/bin/age:ro" \
            --entrypoint /usr/local/bin/age "$IMAGE" --version >/dev/null 2>&1 \
        || die "the age at $(command -v age) does not run inside $IMAGE (dynamically linked?) - the encrypted drill needs a static age"
    age-keygen -o "$OUT/key.txt" 2>/dev/null
    RECIPIENT=$(grep -o 'age1.*' "$OUT/key.txt")
    SFX=".age"
    EFLAGS=(--recipient "$RECIPIENT" --identity "$OUT/key.txt")
    VF=(--identity "$OUT/key.txt")
fi

# --- the tool the official image does not ship --------------------------------
# mysqlbinlog is NOT in the mysql image (measured) - the drill extracts the
# exact-version binary from the official client RPM, once, and mounts it
# read-only wherever it is needed. No skip path: a missing tool fails the
# suite rather than reporting green on a drill that never ran.
log "extracting mysqlbinlog from the official mysql-community-client RPM"
mkdir -p "$TOOLS" "$ARCHIVE"
docker run --rm -v "$TOOLS:/tools" --entrypoint sh "$IMAGE" -c '
    set -e
    printf "[mysql-full]\nname=MySQL Community\nbaseurl=https://repo.mysql.com/yum/mysql-8.4-community/el/9/x86_64/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-mysql\nmodule_hotfixes=true\n" > /etc/yum.repos.d/full.repo
    nvr=$(microdnf repoquery mysql-community-client 2>/dev/null | grep "el9.x86_64" | sort -V | tail -1)
    [ -n "$nvr" ] || { echo "could not resolve the client RPM"; exit 1; }
    curl -sO "https://repo.mysql.com/yum/mysql-8.4-community/el/9/x86_64/$nvr.rpm"
    rpm -Uvh --replacefiles --nodeps "$nvr.rpm" >/dev/null
    cp /usr/bin/mysqlbinlog /tools/
' >/dev/null 2>&1 || die 'could not extract mysqlbinlog from the official RPM - the drill cannot replay without it'
[ -x "$TOOLS/mysqlbinlog" ] || die 'mysqlbinlog did not land in the tools directory'
ok "mysqlbinlog $(docker run --rm -v "$TOOLS/mysqlbinlog:/usr/bin/mysqlbinlog:ro" --entrypoint mysqlbinlog "$IMAGE" --version 2>/dev/null | grep -oE 'Ver [0-9.]+' | head -1) extracted"

# --- the source, binlog on (the 8.4 default) -----------------------------------
log "booting the source database ($IMAGE) with its binary log on"
docker rm -f "$SRC" >/dev/null 2>&1 || true
docker run -d --name "$SRC" -e MYSQL_ROOT_PASSWORD=verify -e MYSQL_DATABASE=app "$IMAGE" >/dev/null
eng_wait_ready "$SRC"
seed_mysql "$SRC" app
ok "seeded: $(eng_query "$SRC" app 'SELECT COUNT(*) FROM customers;' | tr -d '\n') customers, $(eng_query "$SRC" app 'SELECT COUNT(*) FROM orders;' | tr -d '\n') orders"

printf '\n'
echo '== Case 1: the drill - anchored dump, mark, disaster, destruction, replay to the mark =='
# A mark BEFORE the base exists only to prove case 5 later.
./binlog.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$OUT/early" ${EFLAGS[@]+"${EFLAGS[@]}"} >"$OUT/early.log" 2>&1 \
    || { fail_case 'the pre-base mark itself failed'; sed -n '1,10p' "$OUT/early.log" | sed 's/^/        /'; }
M_EARLY=$(find "$OUT/early" -name '*_binlogmark.json' | head -1)

./binlog.sh base --container "$SRC" --db app --out "$OUT/backups" ${EFLAGS[@]+"${EFLAGS[@]}"} >"$OUT/base.log" 2>&1 \
    || { fail_case 'the anchored dump failed'; sed -n '1,12p' "$OUT/base.log" | sed 's/^/        /'; }
B=$(find "$OUT/backups" -name '*_binlogbase.json' | head -1)
[ -n "$B" ] || die 'no base manifest was written - nothing else can run'

# Traffic across a file boundary, so the anchor..mark chain spans SEVERAL
# files and the hole/rot cases can break a true middle one.
eng_query "$SRC" app "INSERT INTO orders (customer_id, total, note)
    SELECT (n % 500) + 1, n, CONCAT('post-base-', n) FROM (WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<800) SELECT n FROM s) t;" >/dev/null
eng_query "$SRC" mysql 'FLUSH BINARY LOGS;' >/dev/null
eng_query "$SRC" app "INSERT INTO orders (customer_id, total, note)
    SELECT (n % 500) + 1, n, CONCAT('post-flush-', n) FROM (WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<200) SELECT n FROM s) t;" >/dev/null

sleep 1.1   # marks carry second-resolution stamps
./binlog.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$OUT/backups" ${EFLAGS[@]+"${EFLAGS[@]}"} >"$OUT/mark.log" 2>&1 \
    || { fail_case 'the mark failed on a healthy server'; sed -n '1,12p' "$OUT/mark.log" | sed 's/^/        /'; }
M=$(find "$OUT/backups" -name '*_binlogmark.json' | LC_ALL=C sort | tail -1)
[ -n "$M" ] || die 'no mark manifest was written - nothing else can run'
MARK_ROWS=$(eng_query "$SRC" app 'SELECT COUNT(*) FROM orders;' | tr -d '\n')
pass_case "marked the instant to reproduce: $MARK_ROWS orders at $(json_str "$M" mark_file):$(json_num "$M" mark_pos)"

if [ "$ENCRYPTED" -eq 1 ]; then
    # The stake, held: nothing in the archive may be plaintext, and the rows
    # that grep out of a raw binlog in one line (measured) must not grep out
    # of the ciphertext.
    if find "$ARCHIVE" -maxdepth 1 -type f ! -name '*.age' | grep -q .; then
        fail_case 'a plaintext file reached the encrypted archive'
    elif grep -rlq 'example.com' "$ARCHIVE" 2>/dev/null; then
        fail_case 'seeded row data greps out of the archived ciphertext'
    else
        pass_case 'the archive holds only ciphertext, and the seeded rows do not grep out of it'
    fi
fi

# The disaster lands AFTER the mark, and a second mark ARCHIVES it: the
# archive now provably contains the deletion, and the drill to the first
# mark must stop short of it.
eng_query "$SRC" app "DELETE FROM orders WHERE note LIKE 'post-%'; DELETE FROM orders LIMIT 500;" >/dev/null
sleep 1.1
./binlog.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$OUT/backups" ${EFLAGS[@]+"${EFLAGS[@]}"} >"$OUT/mark2.log" 2>&1 \
    || { fail_case 'the post-disaster mark failed'; sed -n '1,12p' "$OUT/mark2.log" | sed 's/^/        /'; }
M2=$(find "$OUT/backups" -name '*_binlogmark.json' | LC_ALL=C sort | tail -1)

if ./binlog.sh check --archive "$ARCHIVE" --container "$SRC" ${VF[@]+"${VF[@]}"} >"$OUT/check1.log" 2>&1; then
    pass_case 'check blesses a continuous archive that matches the live server byte for byte'
else
    fail_case 'check rejected a healthy archive'
    sed -n '1,12p' "$OUT/check1.log" | sed 's/^/        /'
fi

log 'DESTROYING the source database (this is the whole point)'
docker rm -f "$SRC" >/dev/null
ok 'source is gone - the dump and the archived binlogs are now the only copy'
if ./binlog.sh verify --base "$B" --mark "$M" --archive "$ARCHIVE" --tools "$TOOLS" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/verify.log" 2>&1; then
    if grep -q 'BINLOG PITR VERIFIED' "$OUT/verify.log"; then
        pass_case 'the archive reproduced the marked instant, fingerprints and all - the archived disaster excluded'
    else
        fail_case 'verify passed but without the verdict it promises'
        sed -n '1,20p' "$OUT/verify.log" | sed 's/^/        /'
    fi
else
    fail_case 'the fire drill failed: dump + binlogs did not reproduce the mark'
    sed -n '1,25p' "$OUT/verify.log" | sed 's/^/        /'
fi
printf '\n'

echo '== Case 2: a stop that is never reached is SILENT (measured) - arrival is proven by content =='
# The mark's position doctored back to the anchor: the replay applies nothing,
# exits 0, stderr empty - and the fingerprints must be what fails it.
ANCHOR_POS=$(json_num "$B" anchor_pos)
sed "s/\"mark_pos\": [0-9]*/\"mark_pos\": $ANCHOR_POS/" "$M" > "$OUT/early-stop.json"
if ./binlog.sh verify --base "$B" --mark "$OUT/early-stop.json" --archive "$ARCHIVE" --tools "$TOOLS" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/silent.log" 2>&1; then
    fail_case 'verify blessed a replay that provably stopped short of the instant'
else
    if grep -q 'replay ran clean and STILL did not reproduce' "$OUT/silent.log"; then
        pass_case 'the replay exited 0, said nothing, and the fingerprints failed it anyway - exit codes prove nothing here (measured)'
    else
        fail_case 'verify failed, but not through the arrival gate'
        sed -n '1,15p' "$OUT/silent.log" | sed 's/^/        /'
    fi
fi
printf '\n'

# The middle of the chain, computed rather than guessed.
ANCHOR_FILE=$(json_str "$B" anchor_file)
PREFIX=${ANCHOR_FILE%.*}
MIDDLE=$(printf '%s.%06d' "$PREFIX" "$(( $((10#${ANCHOR_FILE##*.})) + 1 ))")

echo "== Case 3: a hole in the chain ($MIDDLE removed) - a replay would stitch over it (measured) =="
mv "$ARCHIVE/$MIDDLE$SFX" "$OUT/hidden"
if ./binlog.sh verify --base "$B" --mark "$M" --archive "$ARCHIVE" --tools "$TOOLS" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/hole.log" 2>&1; then
    fail_case 'verify replayed straight across a hole in the chain'
else
    if grep -q "missing $MIDDLE$SFX" "$OUT/hole.log" && ! grep -q 'booting a throwaway' "$OUT/hole.log"; then
        pass_case 'the hole is named and nothing boots - mysqlbinlog would have stitched over it with rc 0 (measured)'
    else
        fail_case 'verify failed, but without naming the hole before booting'
        sed -n '1,12p' "$OUT/hole.log" | sed 's/^/        /'
    fi
fi
mv "$OUT/hidden" "$ARCHIVE/$MIDDLE$SFX"
printf '\n'

echo '== Case 4: rot in an archived binlog - mysqlbinlog would replay it happily (measured) =='
cp "$ARCHIVE/$MIDDLE$SFX" "$OUT/pristine"
SIZE=$(stat -c%s "$ARCHIVE/$MIDDLE$SFX")
printf 'XXXX' | dd of="$ARCHIVE/$MIDDLE$SFX" bs=1 seek=$((SIZE / 2)) conv=notrunc 2>/dev/null
if ./binlog.sh verify --base "$B" --mark "$M" --archive "$ARCHIVE" --tools "$TOOLS" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/rot.log" 2>&1; then
    fail_case 'verify replayed rotten history'
else
    if grep -q "$MIDDLE$SFX - these are not the bytes the mark stood on" "$OUT/rot.log" \
        && ! grep -q 'booting a throwaway' "$OUT/rot.log"; then
        pass_case 'the inventory names the rotten file TODAY - without it, the default tooling replays rot with rc 0 (measured)'
    else
        fail_case 'verify failed, but not by the inventory path (or it booted first)'
        sed -n '1,15p' "$OUT/rot.log" | sed 's/^/        /'
    fi
fi
cp "$OUT/pristine" "$ARCHIVE/$MIDDLE$SFX"
printf '\n'

echo '== Case 5: a mark that predates the anchor can never be reached =='
if [ -z "$M_EARLY" ]; then
    fail_case 'the pre-base mark was never written, so this case cannot run'
elif ./binlog.sh verify --base "$B" --mark "$M_EARLY" --archive "$ARCHIVE" --tools "$TOOLS" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/early-verify.log" 2>&1; then
    fail_case 'verify accepted a mark from before the base'
else
    if grep -q 'predates the base' "$OUT/early-verify.log" && ! grep -q 'booting a throwaway' "$OUT/early-verify.log"; then
        pass_case 'refused in milliseconds - a replay rolls forward only'
    else
        fail_case 'verify failed, but not with the reachability verdict'
        sed -n '1,12p' "$OUT/early-verify.log" | sed 's/^/        /'
    fi
fi
printf '\n'

echo '== Case 6: strays and holes, named by check from the directory alone =='
printf 'half a copy' > "$ARCHIVE/.${PREFIX}.000099.copying"
mv "$ARCHIVE/$MIDDLE$SFX" "$OUT/hidden"
if ./binlog.sh check --archive "$ARCHIVE" >"$OUT/check-broken.log" 2>&1; then
    fail_case 'check blessed an archive with a stray and a hole'
else
    if grep -q "copying - not an archived binlog" "$OUT/check-broken.log" && grep -q "missing $MIDDLE$SFX" "$OUT/check-broken.log"; then
        pass_case 'the crashed copy and the hole are both named'
    else
        fail_case 'check failed without naming both problems'
        sed -n '1,12p' "$OUT/check-broken.log" | sed 's/^/        /'
    fi
fi
rm -f "$ARCHIVE/.${PREFIX}.000099.copying"
mv "$OUT/hidden" "$ARCHIVE/$MIDDLE$SFX"
printf '\n'

echo '== Case 7: the drill to the SECOND mark - the archived disaster is also an instant =='
if ./binlog.sh verify --base "$B" --mark "$M2" --archive "$ARCHIVE" --tools "$TOOLS" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/verify2.log" 2>&1; then
    pass_case 'the archive reproduces every instant it marked - including the one that contains the disaster'
else
    fail_case 'the second instant did not come back'
    sed -n '1,20p' "$OUT/verify2.log" | sed 's/^/        /'
fi
printf '\n'

if [ "$ENCRYPTED" -eq 1 ]; then
    echo '== Case 8 (encrypted only): no key, no drill - and the wrong key dies fast =='
    # No comforting green tick without the identity: refusing is the feature.
    if ./binlog.sh verify --base "$B" --mark "$M" --archive "$ARCHIVE" --tools "$TOOLS" --image "$IMAGE" >"$OUT/nokey.log" 2>&1; then
        fail_case 'verify ran an encrypted drill without the key'
    else
        if grep -q 'would be a guess' "$OUT/nokey.log" && ! grep -q 'booting a throwaway' "$OUT/nokey.log"; then
            pass_case 'verify refused to guess: an encrypted pair without --identity is not verifiable, and nothing booted'
        else
            fail_case 'verify failed without the refusal it promises'
            sed -n '1,10p' "$OUT/nokey.log" | sed 's/^/        /'
        fi
    fi
    age-keygen -o "$OUT/wrong.txt" 2>/dev/null
    if ./binlog.sh verify --base "$B" --mark "$M" --archive "$ARCHIVE" --tools "$TOOLS" --image "$IMAGE" --identity "$OUT/wrong.txt" >"$OUT/wrongkey.log" 2>&1; then
        fail_case 'verify accepted the WRONG key'
    else
        if grep -q 'does not decrypt with the given identity' "$OUT/wrongkey.log"; then
            pass_case 'the wrong key is named at the base artefact - "no identity matched" is a fact of today, not of the fire'
        else
            fail_case 'verify failed, but without naming the wrong key'
            sed -n '1,15p' "$OUT/wrongkey.log" | sed 's/^/        /'
        fi
    fi
    printf '\n'
fi

if [ "$FAILURES" -gt 0 ]; then
    die "$FAILURES binlog PITR case(s) behaved wrongly"
fi
ok 'the marked instant survived the fire, and every measured binlog lie was caught'
