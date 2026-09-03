#!/usr/bin/env bash
# =============================================================================
# The off-site cycle, proven the way everything here is proven: by destruction.
# Back up a real tree, push it, then DELETE the source AND every local backup -
# the building burned down - and the pulled copy alone must restore.
#
# Then every measured way an off-site copy lies, each one CAUGHT:
#   * a crashed upload (the .part leftover, and the artefact no manifest ever
#     committed) is named by check and invisible to pull;
#   * in-place rot at the remote - the rsync -a lie: same size, same mtime,
#     rc 0, "up to date", corrupt forever - fails check, and pull refuses to
#     hand the bytes over;
#   * a full remote disk (measured: a file with the RIGHT apparent size and
#     the wrong bytes) fails the push and leaves NOTHING plausible behind;
#   * retention decides by NAME: after an old backup is re-uploaded, its
#     remote mtime says "newest" (measured: upload time is all a remote mtime
#     holds) and pruning by mtime would delete the wrong file;
#   * the encrypted chain survives the same fire end to end.
#
# --remote-kind ssh boots a real sshd in Docker; --remote-kind dir runs the
# same protocol against a local directory (the mounted-NAS case), minus the
# disk-full case, which needs the container's small tmpfs.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh
. test/seed.sh

KIND="ssh"
while [ $# -gt 0 ]; do
    case "$1" in
        --remote-kind) KIND="${2:-}"; shift 2;;
        *)             die "unknown option: $1 (usage: offsite.sh [--remote-kind ssh|dir])";;
    esac
done
case "$KIND" in ssh|dir) ;; *) die "--remote-kind must be ssh or dir, got '$KIND'";; esac

OUT=$(mktemp -d)
SSHD=bv-offsite-sshd
PORT=2299
FAILURES=0

pass_case() { printf '  %sOK%s   %s\n' "$c_green" "$c_reset" "$1"; }
fail_case() { printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
    if [ "$KIND" = ssh ]; then docker rm -f "$SSHD" >/dev/null 2>&1 || true; fi
    rm -rf "$OUT"
    rm -rf "${TMPDIR:-/tmp}"/bv-files-bv-verify-* 2>/dev/null || true
}
trap cleanup EXIT

# --- the remote, and kind-specific helpers the cases lean on ----------------
if [ "$KIND" = ssh ]; then
    log "booting a real sshd in Docker (with a 256K tmpfs for the disk-full case)"
    ssh-keygen -t ed25519 -N '' -f "$OUT/key" -q
    docker rm -f "$SSHD" >/dev/null 2>&1 || true
    docker run -d --name "$SSHD" -p "127.0.0.1:$PORT:22" \
        --tmpfs /srv/full:rw,size=256k alpine:3.20 sh -c "
        apk add --no-cache openssh >/dev/null 2>&1 &&
        ssh-keygen -A >/dev/null 2>&1 &&
        mkdir -p /root/.ssh /srv/backups && chmod 700 /root/.ssh &&
        echo '$(cat "$OUT/key.pub")' > /root/.ssh/authorized_keys &&
        chmod 600 /root/.ssh/authorized_keys &&
        exec /usr/sbin/sshd -D" >/dev/null
    SSH_OPTS="-p $PORT -i $OUT/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
    OS=(--ssh-opts "$SSH_OPTS")
    BASE="root@127.0.0.1:/srv/backups"
    # foreground wait, no fixed sleep: apk needs a moment on a cold cache
    tries=0
    # shellcheck disable=SC2086  # SSH_OPTS is a word list on purpose
    until ssh $SSH_OPTS -o BatchMode=yes root@127.0.0.1 true 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -lt 60 ] || die 'sshd container never came up'
        sleep 1
    done
    ok "sshd is answering on 127.0.0.1:$PORT"

    # shellcheck disable=SC2086
    remote_sh()   { ssh $SSH_OPTS -o BatchMode=yes root@127.0.0.1 "$1"; }
    remote_ls()   { remote_sh "find ${1#*:} -maxdepth 1 -type f" | sed 's|.*/||' | sort; }
    remote_head() { remote_sh "head -c ${2} ${1#*:}/${3}"; }
    # Corrupt one byte IN PLACE: size unchanged, and the mtime is restored so
    # the shape matches the measured rsync blind spot exactly.
    remote_rot()  { remote_sh "F=${1#*:}/${2}; touch -r \$F /tmp/mt; printf X | dd of=\$F bs=1 seek=100 conv=notrunc 2>/dev/null; touch -r /tmp/mt \$F"; }
    remote_plant() { printf '%s' "$2" | remote_sh "cat > ${1#*:}/${3}"; }
else
    BASE="$OUT/nas"
    OS=()
    remote_sh()   { :; }
    remote_ls()   { find "$1" -maxdepth 1 -type f 2>/dev/null | sed 's|.*/||' | sort; }
    remote_head() { head -c "$2" "$1/$3"; }
    remote_rot()  { local f="$1/$2"; touch -r "$f" "$OUT/mt"; printf X | dd of="$f" bs=1 seek=100 conv=notrunc 2>/dev/null; touch -r "$OUT/mt" "$f"; }
    remote_plant() { printf '%s' "$2" > "$1/$3"; }
fi

# A fresh seeded tree + local backup, so no case inherits another's state.
# Returns the manifest path. sleep 1.1 where a case needs DISTINCT stamps:
# artefact names carry second-resolution UTC stamps.
mk_backup() {
    local dest="$1" src
    src=$(mktemp -d "$OUT/srcXXXXXX")
    seed_files "$src"
    ./backup.sh --engine files --path "$src" --db app --out "$dest" >/dev/null
    rm -rf "$src"
    find "$dest" -name '*.json' | sort | tail -1
}

printf '\n'
echo '== Case 1: the fire - source and local backups destroyed, the off-site copy alone restores =='
BK1=$(mktemp -d "$OUT/bk1XXXXXX")
M1=$(mk_backup "$BK1")
R1="$BASE/case1"
./offsite.sh push --manifest "$M1" --remote "$R1" "${OS[@]}" >"$OUT/c1-push.log" 2>&1 \
    || { fail_case 'push of a good pair failed'; sed -n '1,10p' "$OUT/c1-push.log" | sed 's/^/        /'; }
if ./offsite.sh check --remote "$R1" "${OS[@]}" >"$OUT/c1-check.log" 2>&1; then
    pass_case 'check blesses the freshly pushed pair'
else
    fail_case 'check rejected a pair that was just pushed and hashed'
    sed -n '1,10p' "$OUT/c1-check.log" | sed 's/^/        /'
fi
rm -rf "$BK1"   # the building burns down: no source (mk_backup already ate it), no local backups
if ./offsite.sh pull --db app --remote "$R1" --out "$OUT/restored1" "${OS[@]}" >"$OUT/c1-pull.log" 2>&1; then
    PM=$(find "$OUT/restored1" -name '*.json' | head -1)
    if ./verify.sh --manifest "$PM" >"$OUT/c1-verify.log" 2>&1; then
        pass_case 'the pulled copy RESTORED - the off-site copy was a backup, not a hope'
    else
        fail_case 'the pulled copy did not verify'
        sed -n '1,15p' "$OUT/c1-verify.log" | sed 's/^/        /'
    fi
else
    fail_case 'pull failed with nothing local left'
    sed -n '1,10p' "$OUT/c1-pull.log" | sed 's/^/        /'
fi
if ./offsite.sh pull --db app --remote "$R1" --out "$OUT/restored1" "${OS[@]}" >"$OUT/c1-repull.log" 2>&1; then
    fail_case 'a second pull silently overwrote the recovered copy'
else
    if grep -q 'refusing to overwrite' "$OUT/c1-repull.log"; then
        pass_case 'a repeated pull refuses to overwrite what it recovered'
    else
        fail_case 'the second pull failed, but not for the overwrite reason'
    fi
fi
printf '\n'

echo '== Case 2: crashed uploads - the .part leftover and the uncommitted artefact =='
BK2=$(mktemp -d "$OUT/bk2XXXXXX")
M2=$(mk_backup "$BK2")
R2="$BASE/case2"
./offsite.sh push --manifest "$M2" --remote "$R2" "${OS[@]}" >/dev/null 2>&1
# The killed-upload measurement: 261,120 bytes of a 10 MB artefact under a
# temporary name, and an artefact whose push died before the manifest went up.
remote_plant "$R2" 'half an upload' "app_20200101T000000Z.tar.gz.part"
remote_plant "$R2" 'committed artefact, manifest never arrived' "app_20200102T000000Z.tar.gz"
if ./offsite.sh check --remote "$R2" "${OS[@]}" >"$OUT/c2-check.log" 2>&1; then
    fail_case 'check blessed a remote with a dead .part and an orphan artefact'
else
    if grep -q 'died mid-flight' "$OUT/c2-check.log" && grep -q 'without a manifest' "$OUT/c2-check.log"; then
        pass_case 'check names the crashed upload AND the artefact nothing vouches for'
    else
        fail_case 'check failed, but did not name both leftovers'
        sed -n '1,12p' "$OUT/c2-check.log" | sed 's/^/        /'
    fi
fi
if ./offsite.sh pull --db app --remote "$R2" --out "$OUT/restored2" "${OS[@]}" >"$OUT/c2-pull.log" 2>&1; then
    if [ -f "$OUT/restored2/$(basename "${M2%.json}").tar.gz" ]; then
        pass_case 'pull is not fooled: it hands over the committed pair, never the leftovers'
    else
        fail_case 'pull returned something other than the committed pair'
    fi
else
    fail_case 'pull failed on a remote that still holds one good pair'
    sed -n '1,10p' "$OUT/c2-pull.log" | sed 's/^/        /'
fi
printf '\n'

echo '== Case 3: the remote copy rots in place (the rsync -a blind spot) =='
BK3=$(mktemp -d "$OUT/bk3XXXXXX")
M3=$(mk_backup "$BK3")
R3="$BASE/case3"
./offsite.sh push --manifest "$M3" --remote "$R3" "${OS[@]}" >/dev/null 2>&1
remote_rot "$R3" "$(basename "${M3%.json}").tar.gz"
# Same size, same mtime, different bytes: rsync -a re-syncs NOTHING over this
# (measured: rc 0, no transfer). check must see it without downloading it.
if ./offsite.sh check --remote "$R3" "${OS[@]}" >"$OUT/c3-check.log" 2>&1; then
    fail_case 'check blessed a remote artefact that no longer hashes to its manifest'
else
    if grep -q 'does NOT hash to its manifest' "$OUT/c3-check.log"; then
        pass_case 'check catches in-place rot from the manifest alone (no artefact downloaded)'
    else
        fail_case 'check failed, but not on the rotten artefact'
        sed -n '1,10p' "$OUT/c3-check.log" | sed 's/^/        /'
    fi
fi
if ./offsite.sh pull --db app --remote "$R3" --out "$OUT/restored3" "${OS[@]}" >"$OUT/c3-pull.log" 2>&1; then
    fail_case 'pull handed over corrupt bytes with a clean exit code'
else
    if grep -q 'post-download' "$OUT/c3-pull.log" && [ -z "$(ls -A "$OUT/restored3" 2>/dev/null)" ]; then
        pass_case 'pull refuses corrupt bytes AND removes the partial local pair'
    else
        fail_case 'pull failed, but left something behind or blamed the wrong gate'
        sed -n '1,10p' "$OUT/c3-pull.log" | sed 's/^/        /'
        find "$OUT/restored3" -maxdepth 1 -type f 2>/dev/null | sed 's/^/        /'
    fi
fi
printf '\n'

if [ "$KIND" = ssh ]; then
    echo '== Case 4: the remote disk is full (a file with the right size and the wrong bytes) =='
    # Measured: stat at the remote reported the FULL size - the manifest would
    # have agreed with it - while du showed a quarter of the blocks. Only the
    # remote-side hash catches it, and a failed push must leave NOTHING.
    BK4=$(mktemp -d "$OUT/bk4XXXXXX")
    SRC4=$(mktemp -d "$OUT/src4XXXXXX")
    seed_files "$SRC4"
    dd if=/dev/urandom of="$SRC4/data/huge.bin" bs=1M count=1 2>/dev/null   # incompressible > 256K
    ./backup.sh --engine files --path "$SRC4" --db app --out "$BK4" >/dev/null
    rm -rf "$SRC4"
    M4=$(find "$BK4" -name '*.json' | head -1)
    R4="root@127.0.0.1:/srv/full"
    if ./offsite.sh push --manifest "$M4" --remote "$R4" "${OS[@]}" >"$OUT/c4-push.log" 2>&1; then
        fail_case 'a push onto a full disk reported success'
    else
        pass_case 'the push fails loudly instead of trusting what the disk kept'
    fi
    LEFT=$(remote_ls "$R4")
    if [ -z "$LEFT" ]; then
        pass_case '...and leaves nothing at the remote pretending to be a backup'
    else
        fail_case "a failed push left plausible files behind: $LEFT"
    fi
    printf '\n'
fi

echo '== Case 5: retention prunes by NAME - remote mtime points at the wrong victim =='
BK5=$(mktemp -d "$OUT/bk5XXXXXX")
R5="$BASE/case5"
MA=$(mk_backup "$BK5"); sleep 1.1
MB=$(mk_backup "$BK5"); sleep 1.1
MC=$(mk_backup "$BK5")
./offsite.sh push --manifest "$MA" --remote "$R5" "${OS[@]}" >/dev/null 2>&1
./offsite.sh push --manifest "$MB" --remote "$R5" "${OS[@]}" >/dev/null 2>&1
./offsite.sh push --manifest "$MC" --remote "$R5" --keep 2 "${OS[@]}" >"$OUT/c5-push.log" 2>&1
LISTING=$(remote_ls "$R5")
if ! printf '%s\n' "$LISTING" | grep -q "$(basename "$MA")" \
   && printf '%s\n' "$LISTING" | grep -q "$(basename "$MC")"; then
    pass_case 'keep 2 of 3: the oldest pair is gone, the newest two remain'
else
    fail_case 'retention kept the wrong pairs'
    printf '%s\n' "$LISTING" | sed 's/^/        /'
fi
# The measured trap: re-upload the OLD backup. Its remote mtime now says
# "newest of all" - pruning by mtime would delete the genuinely newest backup
# and keep this one. Pruning by name must delete IT.
./offsite.sh push --manifest "$MA" --remote "$R5" --keep 2 "${OS[@]}" >"$OUT/c5-repush.log" 2>&1
LISTING=$(remote_ls "$R5")
if ! printf '%s\n' "$LISTING" | grep -q "$(basename "$MA")" \
   && printf '%s\n' "$LISTING" | grep -q "$(basename "$MB")" \
   && printf '%s\n' "$LISTING" | grep -q "$(basename "$MC")"; then
    pass_case 'the re-uploaded old backup is pruned despite its "newest" mtime'
else
    fail_case 'retention was fooled by the re-uploaded old backup'
    printf '%s\n' "$LISTING" | sed 's/^/        /'
fi
printf '\n'

echo '== Case 6: the encrypted chain survives the same fire =='
if ! command -v age >/dev/null 2>&1; then
    fail_case 'age is not installed - the encrypted chain could not run (it is not optional)'
else
    BK6=$(mktemp -d "$OUT/bk6XXXXXX")
    SRC6=$(mktemp -d "$OUT/src6XXXXXX")
    seed_files "$SRC6"
    age-keygen -o "$OUT/age.txt" 2>/dev/null
    RECIP=$(grep 'public key' "$OUT/age.txt" | sed 's/.*: //')
    ./backup.sh --engine files --path "$SRC6" --db app --out "$BK6" \
        --recipient "$RECIP" --identity "$OUT/age.txt" >/dev/null
    rm -rf "$SRC6"
    M6=$(find "$BK6" -name '*.json' | head -1)
    R6="$BASE/case6"
    ./offsite.sh push --manifest "$M6" --remote "$R6" "${OS[@]}" >/dev/null 2>&1 \
        || fail_case 'push of the encrypted pair failed'
    if remote_head "$R6" 16 "$(basename "${M6%.json}").tar.gz.age" | grep -q 'age-encryption'; then
        pass_case 'what sits at the remote is real ciphertext'
    else
        fail_case 'the remote copy is not age ciphertext'
    fi
    rm -rf "$BK6"
    if ./offsite.sh pull --db app --remote "$R6" --out "$OUT/restored6" "${OS[@]}" >"$OUT/c6-pull.log" 2>&1; then
        PM6=$(find "$OUT/restored6" -name '*.json' | head -1)
        if grep -q 'identity' "$OUT/c6-pull.log" \
           && ./verify.sh --manifest "$PM6" --identity "$OUT/age.txt" >"$OUT/c6-verify.log" 2>&1; then
            pass_case 'pulled, reminded about the key, decrypted and RESTORED'
        else
            fail_case 'the encrypted chain broke after the pull'
            sed -n '1,12p' "$OUT/c6-verify.log" 2>/dev/null | sed 's/^/        /'
        fi
    else
        fail_case 'pull of the encrypted pair failed'
        sed -n '1,10p' "$OUT/c6-pull.log" | sed 's/^/        /'
    fi
fi
echo '== Case 7: the fire, SQLite edition - the fourth engine through the same off-site cycle =='
# The off-site protocol is engine-agnostic by construction (a manifest and
# its artefact, hashed at both ends), so the drill so far ran the files
# engine only. The fourth engine gets the same fire, for two reasons the
# manifest cannot promise on its own: its artefact is a text .dump whose
# closing COMMIT is the restore's parse gate (a truncated upload must never
# verify), and it carries no container - the pull lands on a box with nothing
# but sqlite3, the containerless shape the files engine established.
if command -v sqlite3 >/dev/null 2>&1; then
    BK7=$(mktemp -d "$OUT/bk7XXXXXX")
    SRC7="$OUT/src7.db"
    seed_sqlite "$SRC7"
    ./backup.sh --engine sqlite --path "$SRC7" --db app --out "$BK7" >/dev/null
    M7=$(find "$BK7" -name '*.json' | sort | tail -1)
    R7="$BASE/case7"
    ./offsite.sh push --manifest "$M7" --remote "$R7" "${OS[@]}" >"$OUT/c7-push.log" 2>&1 \
        || { fail_case 'push of the sqlite pair failed'; sed -n '1,10p' "$OUT/c7-push.log" | sed 's/^/        /'; }
    rm -f "$SRC7" "$SRC7-wal" "$SRC7-shm"; rm -rf "$BK7"   # the building burns: source db and local backups gone
    if ./offsite.sh pull --db app --remote "$R7" --out "$OUT/restored7" "${OS[@]}" >"$OUT/c7-pull.log" 2>&1; then
        PM7=$(find "$OUT/restored7" -name '*.json' | head -1)
        if ./verify.sh --manifest "$PM7" >"$OUT/c7-verify.log" 2>&1; then
            pass_case 'the pulled SQLite dump RESTORED into a scratch database - the fourth engine survives the fire too'
        else
            fail_case 'the pulled sqlite pair did not verify'
            sed -n '1,15p' "$OUT/c7-verify.log" | sed 's/^/        /'
        fi
        # The engine-specific lie: a dump amputated by a dying upload has no
        # closing COMMIT. Truncate the pulled artefact like a crash would and
        # verify must REFUSE it - not restore half a database and call it done.
        A7=$(find "$OUT/restored7" -type f ! -name '*.json' | head -1)
        if [ -n "$A7" ]; then
            size7=$(stat -c %s "$A7")
            truncate -s $((size7 * 2 / 3)) "$A7"
            if ./verify.sh --manifest "$PM7" >"$OUT/c7-trunc.log" 2>&1; then
                fail_case 'a truncated sqlite dump verified - half a database passed as a backup'
            else
                pass_case 'a truncated sqlite dump is REFUSED by verify (the closing COMMIT is the gate, and the hash disagrees first)'
            fi
        fi
    else
        fail_case 'pull of the sqlite pair failed with nothing local left'
        sed -n '1,10p' "$OUT/c7-pull.log" | sed 's/^/        /'
    fi
else
    fail_case 'sqlite3 is not installed - case 7 cannot run (the CI installs it; do the same locally)'
fi
printf '\n'

if [ "$FAILURES" -gt 0 ]; then
    die "$FAILURES off-site case(s) behaved wrongly ($KIND remote)"
fi
ok "the off-site copy survived the fire, and every measured lie was caught ($KIND remote)"
