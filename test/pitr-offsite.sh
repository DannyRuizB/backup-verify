#!/usr/bin/env bash
# =============================================================================
# The PITR fire drill, off-site: the strongest disaster this repo simulates.
# Seed a real Postgres with WAL archiving, mark an instant, PUSH the pair and
# its chain to a remote - then lose the machine: source destroyed, local
# archive wiped, every local manifest gone. The remote alone must bring the
# named instant back, exactly.
#
# Then every measured way an off-site WAL archive lies, each one CAUGHT:
#   * every complete segment measures EXACTLY the same, so a size audit is
#     blind BY CONSTRUCTION - only hashes see anything at all;
#   * rot in place at the remote: stat identical, bytes different - named by
#     check TODAY from the mark's inventory, refused (and cleaned up) by
#     pull, and REPAIRED by push, which trusts hashes and never names;
#   * a crashed upload (.part) named for what it is;
#   * an instant never pushed is an instant the remote cannot prove: pull
#     returns the newest mark the remote HOLDS, not the newest that exists -
#     the mark manifest travels LAST, so its presence is the receipt.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
. test/seed.sh
load_engine postgres

KIND="ssh"
ENCRYPTED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --remote-kind) KIND="${2:-}"; shift 2;;
        --encrypted)   ENCRYPTED=1; shift;;
        *)             die "unknown option: $1 (usage: pitr-offsite.sh [--remote-kind ssh|dir] [--encrypted])";;
    esac
done
case "$KIND" in ssh|dir) ;; *) die "--remote-kind must be ssh or dir, got '$KIND'";; esac

IMAGE="${BV_IMAGE:-$ENG_DEFAULT_IMAGE}"
SRC=bv-pitr-off-src
SSHD=bv-pitr-off-sshd
PORT=2301   # 2222 belongs to the hardening twins, 2299 to the offsite suite
OUT=$(mktemp -d)
ARCHIVE="$OUT/archive"
BK="$OUT/backups"
FAILURES=0

pass_case() { printf '  %sOK%s   %s\n' "$c_green" "$c_reset" "$1"; }
fail_case() { printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$1"; FAILURES=$((FAILURES + 1)); }

# Mutate host-side state as root (segments land 0600, the server's uid).
root_sh() { docker run --rm -u root --entrypoint sh -v "$OUT:/work" "$IMAGE" -c "$1"; }

cleanup() {
    docker rm -f "$SRC" >/dev/null 2>&1 || true
    if [ "$KIND" = ssh ]; then docker rm -f "$SSHD" >/dev/null 2>&1 || true; fi
    root_sh "rm -rf /work/archive /work/pulled* && chown -R $(id -u):$(id -g) /work" >/dev/null 2>&1 || true
    rm -rf "$OUT" 2>/dev/null || true
}
trap cleanup EXIT

# --- the remote, and kind-specific mutation helpers --------------------------
if [ "$KIND" = ssh ]; then
    log "booting a real sshd in Docker"
    ssh-keygen -t ed25519 -N '' -f "$OUT/key" -q
    docker rm -f "$SSHD" >/dev/null 2>&1 || true
    docker run -d --name "$SSHD" -p "127.0.0.1:$PORT:22" alpine:3.20 sh -c "
        apk add --no-cache openssh >/dev/null 2>&1 &&
        ssh-keygen -A >/dev/null 2>&1 &&
        mkdir -p /root/.ssh /srv/wal-offsite && chmod 700 /root/.ssh &&
        echo '$(cat "$OUT/key.pub")' > /root/.ssh/authorized_keys &&
        chmod 600 /root/.ssh/authorized_keys &&
        exec /usr/sbin/sshd -D" >/dev/null
    SSH_OPTS="-p $PORT -i $OUT/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
    OS=(--ssh-opts "$SSH_OPTS")
    REMOTE="root@127.0.0.1:/srv/wal-offsite"
    tries=0
    # shellcheck disable=SC2086  # SSH_OPTS is a word list on purpose
    until ssh $SSH_OPTS -o BatchMode=yes root@127.0.0.1 true 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -lt 60 ] || die 'sshd container never came up'
        sleep 1
    done
    ok "sshd is answering on 127.0.0.1:$PORT"

    # shellcheck disable=SC2086
    remote_sh()    { ssh $SSH_OPTS -o BatchMode=yes root@127.0.0.1 "$1"; }
    # Corrupt IN PLACE at a real-content offset: size unchanged, mtime
    # restored - the exact shape a size or metadata audit is blind to.
    remote_rot()   { remote_sh "F=${REMOTE#*:}/$1; touch -r \$F /tmp/mt; printf XXXX | dd of=\$F bs=1 seek=8192 conv=notrunc 2>/dev/null; touch -r /tmp/mt \$F"; }
    remote_plant() { printf '%s' "$1" | remote_sh "cat > ${REMOTE#*:}/$2"; }
    remote_rm()    { remote_sh "rm -f ${REMOTE#*:}/$1"; }
else
    REMOTE="$OUT/nas"
    OS=()
    mkdir -p "$REMOTE"
    remote_rot()   { local f="$REMOTE/$1"; touch -r "$f" "$OUT/mt"; printf XXXX | dd of="$f" bs=1 seek=8192 conv=notrunc 2>/dev/null; touch -r "$OUT/mt" "$f"; }
    remote_plant() { printf '%s' "$1" > "$REMOTE/$2"; }
    remote_rm()    { rm -f "$REMOTE/$1"; }
fi

traffic() {
    eng_query "$SRC" app "INSERT INTO orders(customer_id, total, note)
        SELECT (i % 500) + 1, i, '$1' FROM generate_series(1, 2000) i;" >/dev/null
}

# --- the source, archiving for real -------------------------------------------
# --encrypted: every segment leaves the server as age ciphertext, and the
# whole off-site protocol must compose untouched - the inventory hashes
# ciphertext, so push, pull and check move opaque names and never need a key.
# Only verify does, at the very end.
mkdir -p "$ARCHIVE" "$BK"
chmod 777 "$ARCHIVE"   # the container's postgres user writes it
docker rm -f "$SRC" >/dev/null 2>&1 || true
SEGSFX=""
VF=()
BASE_ENC=()
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
seed_postgres "$SRC" app >/dev/null
ok "seeded: $(eng_query "$SRC" app 'SELECT count(*) FROM customers;' | tr -d '\n') customers, $(eng_query "$SRC" app 'SELECT count(*) FROM orders;' | tr -d '\n') orders"

./pitr.sh base --container "$SRC" --db app --archive "$ARCHIVE" --out "$BK" ${BASE_ENC[@]+"${BASE_ENC[@]}"} >"$OUT/base.log" 2>&1 \
    || { fail_case 'taking the base backup failed'; sed -n '1,10p' "$OUT/base.log" | sed 's/^/        /'; exit 1; }
B=$(ls "$BK"/*_base.json)
traffic case1
./pitr.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$BK" >"$OUT/mark1.log" 2>&1 \
    || { fail_case 'the first mark failed'; sed -n '1,10p' "$OUT/mark1.log" | sed 's/^/        /'; exit 1; }
M1=$(find "$BK" -name "*_mark.json" | LC_ALL=C sort | tail -1)

printf '\n'
echo '== Case 1: push, and a remote that can PROVE what it holds =='
if ./pitr.sh push --base "$B" --mark "$M1" --archive "$ARCHIVE" --remote "$REMOTE" "${OS[@]}" >"$OUT/push1.log" 2>&1; then
    pass_case "pushed: $(grep -o '[0-9]* file(s) shipped' "$OUT/push1.log" | head -1), base and manifests behind them"
else
    fail_case 'the first push failed'
    sed -n '1,15p' "$OUT/push1.log" | sed 's/^/        /'
fi
if ./pitr.sh check --remote "$REMOTE" "${OS[@]}" >"$OUT/check1.log" 2>&1; then
    pass_case 'check --remote blesses the freshly pushed instant, hash by hash'
else
    fail_case 'check --remote rejected an instant that was just pushed and hashed'
    sed -n '1,15p' "$OUT/check1.log" | sed 's/^/        /'
fi

printf '\n'
echo '== Case 2: the second push ships only what the remote cannot already prove =='
traffic case2
sleep 1.1   # manifest names carry second-resolution stamps
./pitr.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$BK" >"$OUT/mark2.log" 2>&1 \
    || fail_case 'the second mark failed'
M2=$(find "$BK" -name "*_mark.json" | LC_ALL=C sort | tail -1)
if ./pitr.sh push --base "$B" --mark "$M2" --archive "$ARCHIVE" --remote "$REMOTE" "${OS[@]}" >"$OUT/push2.log" 2>&1; then
    SHIPPED=$(grep -o '[0-9]* file(s) shipped' "$OUT/push2.log" | grep -o '^[0-9]*')
    PROVEN=$(grep -o '[0-9]* already proven' "$OUT/push2.log" | grep -o '^[0-9]*')
    if [ "${PROVEN:-0}" -gt 0 ] && [ "${SHIPPED:-0}" -gt 0 ]; then
        pass_case "incremental by hash: $SHIPPED new file(s) shipped, $PROVEN re-hashed at the remote and skipped"
    else
        fail_case "expected a mixed push, got shipped=$SHIPPED proven=$PROVEN"
        sed -n '1,15p' "$OUT/push2.log" | sed 's/^/        /'
    fi
else
    fail_case 'the second push failed'
    sed -n '1,15p' "$OUT/push2.log" | sed 's/^/        /'
fi

printf '\n'
echo '== Case 3: an instant never pushed is an instant the remote cannot prove =='
traffic case3
sleep 1.1
./pitr.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$BK" >"$OUT/mark3.log" 2>&1 \
    || fail_case 'the third mark failed'
M3=$(find "$BK" -name "*_mark.json" | LC_ALL=C sort | tail -1)
if ./pitr.sh pull --db app --remote "$REMOTE" --archive "$OUT/pulled3-archive" --out "$OUT/pulled3" "${OS[@]}" >"$OUT/pull3.log" 2>&1; then
    GOT=$(find "$OUT/pulled3" -name '*_mark.json' -printf '%f\n')
    if [ "$GOT" = "$(basename "$M2")" ]; then
        pass_case "pull returned $(basename "$M2") - the newest instant the remote can PROVE, not the newest that exists ($(basename "$M3") never travelled)"
    else
        fail_case "pull returned '$GOT', expected $(basename "$M2")"
    fi
else
    fail_case 'pull failed against a healthy remote'
    sed -n '1,15p' "$OUT/pull3.log" | sed 's/^/        /'
fi

printf '\n'
echo '== Case 4: rot in place at the remote - named today, refused by pull, repaired by push =='
VICTIM=$(json_str "$B" wal_start_file)$SEGSFX
remote_rot "$VICTIM"
if ./pitr.sh check --remote "$REMOTE" "${OS[@]}" >"$OUT/check4.log" 2>&1; then
    fail_case 'check --remote blessed a remote with rotten bytes'
else
    if grep -q "$VICTIM - the remote's bytes do not hash back" "$OUT/check4.log"; then
        pass_case 'check names the rotten segment from the inventory alone (size and mtime are untouched - only the hash sees it)'
    else
        fail_case 'check failed, but without naming the rotten segment'
        sed -n '1,15p' "$OUT/check4.log" | sed 's/^/        /'
    fi
fi
if ./pitr.sh pull --db app --remote "$REMOTE" --archive "$OUT/pulled4-archive" --out "$OUT/pulled4" "${OS[@]}" >"$OUT/pull4.log" 2>&1; then
    fail_case 'pull handed over bytes the inventory refutes'
else
    if grep -q "did not survive the transfer" "$OUT/pull4.log" && [ ! -e "$OUT/pulled4-archive/$VICTIM" ]; then
        pass_case 'pull refused the rotten segment AND removed what it fetched'
    else
        fail_case 'pull failed, but left the rotten fetch behind (or died elsewhere)'
        sed -n '1,15p' "$OUT/pull4.log" | sed 's/^/        /'
    fi
fi
if ./pitr.sh push --base "$B" --mark "$M2" --archive "$ARCHIVE" --remote "$REMOTE" "${OS[@]}" >"$OUT/push4.log" 2>&1; then
    if grep -q "WRONG bytes" "$OUT/push4.log" && ./pitr.sh check --remote "$REMOTE" "${OS[@]}" >"$OUT/check4b.log" 2>&1; then
        pass_case 'push re-shipped the segment its hash refuted - "the file is already there" signs off rot, hashes do not'
    else
        fail_case 'push did not repair the rotten segment (or check still fails)'
        sed -n '1,15p' "$OUT/push4.log" | sed 's/^/        /'
    fi
else
    fail_case 'the repairing push failed'
    sed -n '1,15p' "$OUT/push4.log" | sed 's/^/        /'
fi

printf '\n'
echo '== Case 5: the crashed upload is named for what it is =='
remote_plant 'half an upload' "000000010000000000000042.part"
if ./pitr.sh check --remote "$REMOTE" "${OS[@]}" >"$OUT/check5.log" 2>&1; then
    fail_case 'check --remote ignored a .part leftover'
else
    if grep -q "000000010000000000000042.part - a crashed upload" "$OUT/check5.log"; then
        pass_case 'the .part leftover is named - a crashed push leaves debris, never a claim'
    else
        fail_case 'check failed without naming the .part'
        sed -n '1,15p' "$OUT/check5.log" | sed 's/^/        /'
    fi
fi
remote_rm "000000010000000000000042.part"

printf '\n'
echo '== Case 6: the fire - source, archive and every local manifest destroyed =='
log "DESTROYING the source, the local archive and the local backups (this is the whole point)"
docker rm -f "$SRC" >/dev/null 2>&1
root_sh "rm -rf /work/archive && chown -R $(id -u):$(id -g) /work" >/dev/null 2>&1 || true
rm -rf "$ARCHIVE" "$BK"
ok "the machine is bare - the remote is the only copy of anything"
if ./pitr.sh pull --db app --remote "$REMOTE" --archive "$OUT/fire-archive" --out "$OUT/fire" "${OS[@]}" >"$OUT/pull6.log" 2>&1; then
    FB=$(find "$OUT/fire" -name '*_base.json')
    FM=$(find "$OUT/fire" -name '*_mark.json')
    if ./pitr.sh verify --base "$FB" --mark "$FM" --archive "$OUT/fire-archive" --image "$IMAGE" ${VF[@]+"${VF[@]}"} >"$OUT/verify6.log" 2>&1; then
        pass_case 'the pulled base + chain reproduced the pushed instant EXACTLY - the off-site copy was a recovery, not a hope'
    else
        fail_case 'the pulled pair did not verify'
        sed -n '1,25p' "$OUT/verify6.log" | sed 's/^/        /'
    fi
else
    fail_case 'pull failed on the day it exists for'
    sed -n '1,15p' "$OUT/pull6.log" | sed 's/^/        /'
fi

printf '\n'
if [ "$FAILURES" -gt 0 ]; then
    die "$FAILURES case(s) failed ($KIND remote)"
fi
ok "the marked instant survived the fire, and every measured off-site archive lie was caught ($KIND remote)"
