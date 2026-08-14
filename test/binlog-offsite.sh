#!/usr/bin/env bash
# =============================================================================
# The MySQL binlog PITR fire drill, off-site: mark an instant, PUSH the dump
# and the chain to a remote - then lose the machine (source, local archive,
# every manifest). The remote alone must bring the instant back, exactly.
#
# The binlog-specific twist, measured: at a binlog archive even TRUNCATION
# has no shape. Sizes vary by nature, and a binlog cut at an event boundary
# decodes clean - rc 0, stderr EMPTY, half the history amputated (measured:
# 3 of 6 commits, checksums verified, not one word). At the WAL archive the
# size gate at least caught truncation; here the mark's inventory hash
# carries EVERYTHING. Each measured off-site lie, caught:
#   * an instant never pushed is an instant the remote cannot prove;
#   * rot (or truncation - same shapelessness) at the remote: named by
#     check --remote today, refused and cleaned up by pull, REPAIRED by push;
#   * a crashed upload (.part) named for what it is;
#   * the second push ships only what the remote cannot already prove.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
. test/seed.sh
load_engine mysql

KIND="ssh"
while [ $# -gt 0 ]; do
    case "$1" in
        --remote-kind) KIND="${2:-}"; shift 2;;
        *)             die "unknown option: $1 (usage: binlog-offsite.sh [--remote-kind ssh|dir])";;
    esac
done
case "$KIND" in ssh|dir) ;; *) die "--remote-kind must be ssh or dir, got '$KIND'";; esac

IMAGE="${BV_IMAGE:-mysql:8.4}"
SRC=bv-binlog-off-src
SSHD=bv-binlog-off-sshd
PORT=2302   # 2222 twins, 2299 offsite, 2301 pitr-offsite
OUT=$(mktemp -d)
ARCHIVE="$OUT/archive"
BK="$OUT/backups"
TOOLS="$OUT/tools"
FAILURES=0

pass_case() { printf '  %sOK%s   %s\n' "$c_green" "$c_reset" "$1"; }
fail_case() { printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
    docker rm -f "$SRC" >/dev/null 2>&1 || true
    if [ "$KIND" = ssh ]; then docker rm -f "$SSHD" >/dev/null 2>&1 || true; fi
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
        mkdir -p /root/.ssh /srv/binlog-offsite && chmod 700 /root/.ssh &&
        echo '$(cat "$OUT/key.pub")' > /root/.ssh/authorized_keys &&
        chmod 600 /root/.ssh/authorized_keys &&
        exec /usr/sbin/sshd -D" >/dev/null
    SSH_OPTS="-p $PORT -i $OUT/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
    OS=(--ssh-opts "$SSH_OPTS")
    REMOTE="root@127.0.0.1:/srv/binlog-offsite"
    tries=0
    # shellcheck disable=SC2086  # SSH_OPTS is a word list on purpose
    until ssh $SSH_OPTS -o BatchMode=yes root@127.0.0.1 true 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -lt 60 ] || die 'sshd container never came up'
        sleep 1
    done
    ok "sshd is answering on 127.0.0.1:$PORT"

    # shellcheck disable=SC2086
    remote_sh()      { ssh $SSH_OPTS -o BatchMode=yes root@127.0.0.1 "$1"; }
    remote_rot()     { remote_sh "F=${REMOTE#*:}/$1; touch -r \$F /tmp/mt; printf XXXX | dd of=\$F bs=1 seek=200 conv=notrunc 2>/dev/null; touch -r /tmp/mt \$F"; }
    remote_plant()   { printf '%s' "$1" | remote_sh "cat > ${REMOTE#*:}/$2"; }
    remote_rm()      { remote_sh "rm -f ${REMOTE#*:}/$1"; }
else
    REMOTE="$OUT/nas"
    OS=()
    mkdir -p "$REMOTE"
    remote_rot()     { local f="$REMOTE/$1"; touch -r "$f" "$OUT/mt"; printf XXXX | dd of="$f" bs=1 seek=200 conv=notrunc 2>/dev/null; touch -r "$OUT/mt" "$f"; }
    remote_plant()   { printf '%s' "$1" > "$REMOTE/$2"; }
    remote_rm()      { rm -f "$REMOTE/$1"; }
fi

traffic() {
    eng_query "$SRC" app "INSERT INTO orders (customer_id, total, note)
        SELECT (n % 500) + 1, n, CONCAT('$1-', n) FROM (WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<300) SELECT n FROM s) t;" >/dev/null
}

# --- the tool, extracted once (the image ships none - measured) ---------------
log "extracting mysqlbinlog from the official mysql-community-client RPM"
mkdir -p "$TOOLS" "$ARCHIVE" "$BK"
docker run --rm -v "$TOOLS:/tools" --entrypoint sh "$IMAGE" -c '
    set -e
    printf "[mysql-full]\nname=MySQL Community\nbaseurl=https://repo.mysql.com/yum/mysql-8.4-community/el/9/x86_64/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-mysql\nmodule_hotfixes=true\n" > /etc/yum.repos.d/full.repo
    nvr=$(microdnf repoquery mysql-community-client 2>/dev/null | grep "el9.x86_64" | sort -V | tail -1)
    [ -n "$nvr" ] || { echo "could not resolve the client RPM"; exit 1; }
    curl -sO "https://repo.mysql.com/yum/mysql-8.4-community/el/9/x86_64/$nvr.rpm"
    rpm -Uvh --replacefiles --nodeps "$nvr.rpm" >/dev/null
    cp /usr/bin/mysqlbinlog /tools/
' >/dev/null 2>&1 || die 'could not extract mysqlbinlog from the official RPM'
[ -x "$TOOLS/mysqlbinlog" ] || die 'mysqlbinlog did not land in the tools directory'

# --- the source ---------------------------------------------------------------
log "booting the source database ($IMAGE) with its binary log on"
docker rm -f "$SRC" >/dev/null 2>&1 || true
docker run -d --name "$SRC" -e MYSQL_ROOT_PASSWORD=verify -e MYSQL_DATABASE=app "$IMAGE" >/dev/null
eng_wait_ready "$SRC"
seed_mysql "$SRC" app
ok "seeded: $(eng_query "$SRC" app 'SELECT COUNT(*) FROM customers;' | tr -d '\n') customers, $(eng_query "$SRC" app 'SELECT COUNT(*) FROM orders;' | tr -d '\n') orders"

./binlog.sh base --container "$SRC" --db app --out "$BK" >"$OUT/base.log" 2>&1 \
    || { fail_case 'the anchored dump failed'; sed -n '1,10p' "$OUT/base.log" | sed 's/^/        /'; exit 1; }
B=$(find "$BK" -name '*_binlogbase.json' | head -1)
traffic case1
eng_query "$SRC" mysql 'FLUSH BINARY LOGS;' >/dev/null
traffic case1b
./binlog.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$BK" >"$OUT/mark1.log" 2>&1 \
    || { fail_case 'the first mark failed'; sed -n '1,10p' "$OUT/mark1.log" | sed 's/^/        /'; exit 1; }
M1=$(find "$BK" -name '*_binlogmark.json' | LC_ALL=C sort | tail -1)

printf '\n'
echo '== Case 1: push, and a remote that can PROVE what it holds =='
if ./binlog.sh push --base "$B" --mark "$M1" --archive "$ARCHIVE" --remote "$REMOTE" "${OS[@]}" >"$OUT/push1.log" 2>&1; then
    pass_case "pushed: $(grep -o '[0-9]* file(s) shipped' "$OUT/push1.log" | head -1), dump and manifests behind them"
else
    fail_case 'the first push failed'
    sed -n '1,15p' "$OUT/push1.log" | sed 's/^/        /'
fi
if ./binlog.sh check --remote "$REMOTE" "${OS[@]}" >"$OUT/check1.log" 2>&1; then
    pass_case 'check --remote blesses the freshly pushed instant, hash by hash'
else
    fail_case 'check --remote rejected an instant that was just pushed and hashed'
    sed -n '1,15p' "$OUT/check1.log" | sed 's/^/        /'
fi

printf '\n'
echo '== Case 2: the second push ships only what the remote cannot already prove =='
traffic case2
sleep 1.1
./binlog.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$BK" >"$OUT/mark2.log" 2>&1 \
    || fail_case 'the second mark failed'
M2=$(find "$BK" -name '*_binlogmark.json' | LC_ALL=C sort | tail -1)
if ./binlog.sh push --base "$B" --mark "$M2" --archive "$ARCHIVE" --remote "$REMOTE" "${OS[@]}" >"$OUT/push2.log" 2>&1; then
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
./binlog.sh mark --container "$SRC" --db app --archive "$ARCHIVE" --out "$BK" >"$OUT/mark3.log" 2>&1 \
    || fail_case 'the third mark failed'
M3=$(find "$BK" -name '*_binlogmark.json' | LC_ALL=C sort | tail -1)
if ./binlog.sh pull --db app --remote "$REMOTE" --archive "$OUT/pulled3-archive" --out "$OUT/pulled3" "${OS[@]}" >"$OUT/pull3.log" 2>&1; then
    GOT=$(find "$OUT/pulled3" -name '*_binlogmark.json' -printf '%f\n')
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
echo '== Case 4: rot at the remote - shapeless here even as truncation (measured) - named, refused, repaired =='
VICTIM=$(json_str "$B" anchor_file)
remote_rot "$VICTIM"
if ./binlog.sh check --remote "$REMOTE" "${OS[@]}" >"$OUT/check4.log" 2>&1; then
    fail_case 'check --remote blessed a remote with rotten bytes'
else
    if grep -q "$VICTIM - the remote's bytes do not hash back" "$OUT/check4.log"; then
        pass_case 'check names the rotten file from the inventory alone - size and mtime say nothing at a binlog archive'
    else
        fail_case 'check failed, but without naming the rotten file'
        sed -n '1,15p' "$OUT/check4.log" | sed 's/^/        /'
    fi
fi
if ./binlog.sh pull --db app --remote "$REMOTE" --archive "$OUT/pulled4-archive" --out "$OUT/pulled4" "${OS[@]}" >"$OUT/pull4.log" 2>&1; then
    fail_case 'pull handed over bytes the inventory refutes'
else
    if grep -q "did not survive the transfer" "$OUT/pull4.log" && [ ! -e "$OUT/pulled4-archive/$VICTIM" ]; then
        pass_case 'pull refused the rotten file AND removed what it fetched'
    else
        fail_case 'pull failed, but left the rotten fetch behind (or died elsewhere)'
        sed -n '1,15p' "$OUT/pull4.log" | sed 's/^/        /'
    fi
fi
if ./binlog.sh push --base "$B" --mark "$M2" --archive "$ARCHIVE" --remote "$REMOTE" "${OS[@]}" >"$OUT/push4.log" 2>&1; then
    if grep -q "WRONG bytes" "$OUT/push4.log" && ./binlog.sh check --remote "$REMOTE" "${OS[@]}" >"$OUT/check4b.log" 2>&1; then
        pass_case 'push re-shipped the file its hash refuted - "the file is already there" is a claim about a name, not bytes'
    else
        fail_case 'push did not repair the rotten file (or check still fails)'
        sed -n '1,15p' "$OUT/push4.log" | sed 's/^/        /'
    fi
else
    fail_case 'the repairing push failed'
    sed -n '1,15p' "$OUT/push4.log" | sed 's/^/        /'
fi

printf '\n'
echo '== Case 5: the crashed upload is named for what it is =='
remote_plant 'half an upload' "binlog.000042.part"
if ./binlog.sh check --remote "$REMOTE" "${OS[@]}" >"$OUT/check5.log" 2>&1; then
    fail_case 'check --remote ignored a .part leftover'
else
    if grep -q "binlog.000042.part - a crashed upload" "$OUT/check5.log"; then
        pass_case 'the .part leftover is named - a crashed push leaves debris, never a claim'
    else
        fail_case 'check failed without naming the .part'
        sed -n '1,15p' "$OUT/check5.log" | sed 's/^/        /'
    fi
fi
remote_rm "binlog.000042.part"

printf '\n'
echo '== Case 6: the fire - source, archive and every local manifest destroyed =='
log "DESTROYING the source, the local archive and the local backups (this is the whole point)"
docker rm -f "$SRC" >/dev/null 2>&1
rm -rf "$ARCHIVE" "$BK"
ok "the machine is bare - the remote is the only copy of anything"
if ./binlog.sh pull --db app --remote "$REMOTE" --archive "$OUT/fire-archive" --out "$OUT/fire" "${OS[@]}" >"$OUT/pull6.log" 2>&1; then
    FB=$(find "$OUT/fire" -name '*_binlogbase.json')
    FM=$(find "$OUT/fire" -name '*_binlogmark.json')
    if ./binlog.sh verify --base "$FB" --mark "$FM" --archive "$OUT/fire-archive" --tools "$TOOLS" --image "$IMAGE" >"$OUT/verify6.log" 2>&1; then
        pass_case 'the pulled dump + chain reproduced the pushed instant EXACTLY - arrival proven by content, on a bare machine'
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
ok "the marked instant survived the fire, and every measured off-site binlog lie was caught ($KIND remote)"
