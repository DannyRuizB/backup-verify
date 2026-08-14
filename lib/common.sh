#!/usr/bin/env bash
# =============================================================================
# Shared helpers, engine-agnostic. Sourced by backup.sh and verify.sh; never
# run directly. Everything database-specific lives in lib/<engine>.sh behind a
# common eng_* interface, so neither script contains an engine name.
# =============================================================================

# pipefail is not decoration here, it is the whole point of one of this repo's
# lessons: `pg_dump ... | gzip > out.gz` with a FAILING pg_dump exits 0 and
# leaves a valid, 20-byte, completely empty gzip behind. Measured, not guessed.
#
# -E (errtrace) is just as load-bearing: an ERR trap does NOT fire for a
# failure inside a shell function unless errtrace is on. Measured here: moving
# the dump into eng_dump() silently disabled backup.sh's cleanup trap, and a
# failed dump left a plausible 0-byte artefact behind - negative case 2 caught
# it, which is negative case 2's entire job.
set -Eeuo pipefail

# Colour only when stdout is a terminal. Escape codes in a CI log are noise at
# best, and they broke a test that grepped for "OK   customers" while the real
# bytes were "OK\033[0m   customers" - a check that silently stopped checking.
if [ -t 1 ]; then
    c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
    c_blue=$'\033[34m'; c_reset=$'\033[0m'
else
    c_red=''; c_green=''; c_yellow=''; c_blue=''; c_reset=''
fi

log()  { printf '%s[*]%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

# A backup artefact smaller than this is not a backup. A failed dump leaves
# 0 bytes; piped through gzip, ~20 bytes of valid-but-empty archive; piped into
# age, ~200 bytes of valid-but-empty ciphertext. All measured. The floor is
# deliberately low so it only ever catches the absurd - real emptiness, not
# "smaller than usual".
: "${MIN_ARTEFACT_BYTES:=512}"

# The object classes every engine reports, in report order. This is the
# DATABASE default; an engine whose "schema" is something else entirely
# overrides it when loaded (files: modes, symlinks, dirs).
# shellcheck disable=SC2034  # consumed by backup.sh/verify.sh, which source this
SCHEMA_CLASSES="indexes constraints sequences views routines triggers"

SUPPORTED_ENGINES="postgres mysql files"

need() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Load an engine module. Every engine defines the same eng_* functions plus
# ENG_NAME / ENG_DEFAULT_IMAGE / ENG_ARTEFACT_EXT, so the callers stay generic
# and adding an engine never means editing backup.sh or verify.sh.
load_engine() {
    local engine="$1" dir
    case " $SUPPORTED_ENGINES " in
        *" $engine "*) ;;
        *) die "unsupported engine '$engine' (supported: $SUPPORTED_ENGINES)";;
    esac
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=/dev/null
    . "$dir/$engine.sh"
}

# --- Encryption (age) --------------------------------------------------------
#
# age rather than gpg: authenticated encryption, no keyring, no agent, one
# binary. What the probe measured, and why the design looks like it does:
#
#   * a TRUNCATED .age file fails to decrypt at all ("failed to decrypt and
#     authenticate payload chunk", zero bytes written) - so encryption hands
#     us integrity for free, unlike a bare dump, where truncation restores
#     PARTIAL data and lies;
#   * but it does NOT save us from an EMPTY dump: a failed dump piped into age
#     produces a perfectly valid ~200-byte .age that decrypts to 0 bytes with
#     exit code 0. Encryption protects the bytes, not their meaning. Only
#     restoring proves meaning.
# shellcheck disable=SC2034  # used by backup.sh/verify.sh, which source this
ENC_SUFFIX=".age"

# Manifest path for an artefact, encrypted or not, whatever the engine's
# extension. One place so the mapping cannot drift between the two scripts.
manifest_for() {
    local artefact="$1"
    artefact="${artefact%"$ENC_SUFFIX"}"
    artefact="${artefact%.dump}"
    artefact="${artefact%.sql}"
    artefact="${artefact%.tar.gz}"
    printf '%s' "$artefact.json"
}

encryption_available() {
    command -v age >/dev/null 2>&1
}

# --- Manifest reading ---------------------------------------------------------
#
# Minimal JSON reading with grep/sed rather than a jq dependency: the manifest
# is written by this repo, so its shape is known and flat. Shared here because
# verify.sh AND offsite.sh both read manifests, and two copies of a parser is
# how the two scripts end up disagreeing about what a manifest says.
# An absent key is an ANSWER (the empty string), never an error: under
# pipefail a matchless grep fails the whole pipeline, and `var="$(json_str …)"`
# under set -e then kills the caller with no message at all. That landmine sat
# here unarmed until the first manifest was asked for a key it legitimately
# lacks (a dump manifest asked for "kind"); the || true disarms it for every
# caller at once.
json_str() {
    local file="$1" key="$2"
    { grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" || true; } \
        | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

json_num() {
    local file="$1" key="$2"
    { grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]*" "$file" || true; } \
        | head -1 | sed 's/.*:[[:space:]]*//'
}

# Every "key": "value" pair inside one top-level object of the manifest, as
# TAB-separated lines. Scoped to the section's line range because "tables" and
# "objects" both indent their entries by four spaces - a plain four-space match
# would happily mix them.
manifest_section() {
    local file="$1" section="$2"
    sed -n "/^  \"$section\": {/,/^  }/p" "$file" \
        | sed -n 's/^    "\([^"]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1\t\2/p'
}

manifest_tables() { manifest_section "$1" tables; }

# The size+sha256 gate, shared by everyone who is about to TRUST an artefact:
# verify.sh before a restore, offsite.sh before an upload and after a download.
# It answers one question - are these the exact bytes the manifest was written
# about? - and names the caller's context in the failure.
assert_pair_intact() {
    local manifest="$1" artefact="$2" context="$3"
    local expected_bytes expected_sha actual_bytes actual_sha
    expected_bytes="$(json_num "$manifest" bytes)"
    expected_sha="$(json_str "$manifest" sha256)"
    actual_bytes=$(stat -c%s "$artefact")
    actual_sha=$(sha256_of "$artefact")
    [ "$actual_bytes" = "$expected_bytes" ] \
        || die "$context: size drift - manifest says $expected_bytes bytes, file is $actual_bytes"
    [ "$actual_sha" = "$expected_sha" ] \
        || die "$context: checksum drift - these are NOT the bytes the manifest was written about"
}

# A fingerprint must LOOK like one. This guard exists because MySQL's first
# implementation returned an EMPTY STRING (a syntax error swallowed by a
# 2>/dev/null), the manifest recorded `"customers": ""`, and verify would have
# compared "" against "" and reported VERIFIED having checked NOTHING. The most
# dangerous bug this repo could ship, so now an unusable fingerprint is fatal
# wherever it appears.
assert_fingerprint() {
    local what="$1" fp="$2"
    case "$fp" in
        EMPTY:0) return 0;;
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*:[0-9]*) return 0;;
    esac
    die "the fingerprint of $what is not usable ('$fp') - refusing to record or compare a fingerprint that proves nothing"
}

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

# --- Comparing a live instance against a manifest -----------------------------
#
# These four gates are THE verdict of this repo, so there is exactly one copy
# of them: verify.sh measures a restored dump with them, pitr.sh measures a
# recovered instance with them. Two verifiers with two comparison loops is how
# two verifiers end up believing different things. Each prints its findings and
# returns its failure count (call under `|| var=$?`).

# Content, table by table. Sets COMPARED_TABLES so the caller can refuse a
# manifest that lists nothing (a return value only carries the failure count).
compare_tables() {
    local container="$1" db="$2" manifest="$3"
    local failures=0 table expected actual
    COMPARED_TABLES=0
    while IFS=$'\t' read -r table expected; do
        [ -n "$table" ] || continue
        COMPARED_TABLES=$((COMPARED_TABLES + 1))
        if ! actual=$(eng_table_fingerprint "$container" "$db" "$table" 2>/dev/null | tr -d '\n'); then
            printf '  %sFAIL%s %s - %s absent from the restored copy\n' "$c_red" "$c_reset" "$table" "$ENG_UNIT"
            failures=$((failures + 1))
            continue
        fi
        assert_fingerprint "$table (restored copy)" "$actual"
        assert_fingerprint "$table (manifest)" "$expected"
        if [ "$actual" = "$expected" ]; then
            printf '  %sOK%s   %s\n' "$c_green" "$c_reset" "$table"
        else
            printf '  %sFAIL%s %s - fingerprint differs\n' "$c_red" "$c_reset" "$table"
            printf '        expected %s\n        restored %s\n' "$expected" "$actual"
            failures=$((failures + 1))
        fi
    done < <(manifest_tables "$manifest")
    return "$failures"
}

# Schema objects: the half a row-count comparison cannot see. Measured:
# `pg_restore -t a -t b` exits 0 with every row present and silently drops the
# indexes, constraints, view, function and trigger.
compare_objects() {
    local container="$1" db="$2" manifest="$3"
    local failures=0 obj_lines obj_class obj_expected obj_actual exp_count act_count
    obj_lines=$(manifest_section "$manifest" objects)
    if [ -z "$obj_lines" ]; then
        warn 'this manifest predates schema verification (schema 1) - only data was compared'
        return 0
    fi
    printf '\n'
    while IFS=$'\t' read -r obj_class obj_expected; do
        [ -n "$obj_class" ] || continue
        obj_actual=$(eng_schema_digest "$container" "$db" "$obj_class")
        exp_count=${obj_expected%%:*}
        act_count=${obj_actual%%:*}
        if [ "$obj_actual" = "$obj_expected" ]; then
            printf '  %sOK%s   %s (%s)\n' "$c_green" "$c_reset" "$obj_class" "$act_count"
        elif [ "$exp_count" != "$act_count" ]; then
            printf '  %sFAIL%s %s - expected %s, restored copy has %s\n' \
                "$c_red" "$c_reset" "$obj_class" "$exp_count" "$act_count"
            failures=$((failures + 1))
        else
            printf '  %sFAIL%s %s - same count (%s) but the definitions differ\n' \
                "$c_red" "$c_reset" "$obj_class" "$act_count"
            failures=$((failures + 1))
        fi
    done <<EOF
$obj_lines
EOF
    return "$failures"
}

# A restored copy with EXTRA tables is also a mismatch: it means the artefact
# and the manifest describe different moments.
compare_extra_tables() {
    local container="$1" db="$2" expected="$3" restored_count
    restored_count=$(eng_count_tables "$container" "$db" | tr -d '\n')
    if [ "$restored_count" != "$expected" ]; then
        printf '  %sFAIL%s restored copy has %s %ss, the manifest describes %s\n' \
            "$c_red" "$c_reset" "$restored_count" "$ENG_UNIT" "$expected"
        return 1
    fi
    return 0
}

# Can the application actually WRITE to it? Deliberately run LAST by every
# caller, after every comparison, because it may modify the instance.
writable_probe_report() {
    local container="$1" db="$2" wline
    local -a msgs=()
    while IFS= read -r wline; do
        [ -n "$wline" ] || continue
        msgs+=("$wline")
    done < <(eng_writable_probe_failures "$container" "$db" || true)
    [ "${#msgs[@]}" -gt 0 ] || return 0
    printf '\n'
    for wline in "${msgs[@]}"; do
        printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$wline"
    done
    return "${#msgs[@]}"
}

# --- The remote, behind the rem_* interface ------------------------------------
#
# ssh or a directory, decided by the one character that cannot be both: a
# colon. Both backends implement the same rem_* interface, so no caller has
# any idea which transport it is talking through - the engines' eng_* pattern,
# applied to the other end of the wire. Shared here because offsite.sh and
# pitr.sh both ship bytes to a remote, and two copies of the transport
# selection is how two scripts end up disagreeing about what a remote is.
# Callers define REMOTE and SSH_OPTS_STR before calling.
load_remote() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    case "$REMOTE" in
        *:*)
            REM_HOST="${REMOTE%%:*}"
            REM_DIR="${REMOTE#*:}"
            # shellcheck source=lib/remote_ssh.sh
            . "$dir/remote_ssh.sh";;
        *)
            REM_DIR="$REMOTE"
            # shellcheck source=lib/remote_dir.sh
            . "$dir/remote_dir.sh";;
    esac
    [ -n "$REM_DIR" ] || die "the remote spec '$REMOTE' names no directory"
    # --ssh-opts arrives as one string; ssh wants words.
    read -ra REM_SSH_OPTS <<< "$SSH_OPTS_STR"
}

# Upload to a temporary name, make the REMOTE hash what landed, and only then
# rename into place. The hash is not optional and the size is not consulted:
# the disk-full measurement produced a remote file whose SIZE matched the
# manifest exactly while a quarter of its bytes existed.
upload_checked() {
    local local_path="$1" name="$2" expected_sha="$3" landed
    if ! rem_put "$local_path" "$name.part"; then
        rem_delete "$name.part" || true
        die "upload of $name died mid-flight - the partial temporary was removed, nothing at the remote pretends to be this backup"
    fi
    landed=$(rem_sha256 "$name.part" || true)
    if [ "$landed" != "$expected_sha" ]; then
        rem_delete "$name.part" || true
        die "the remote's copy of $name does not hash back to what was sent (got '${landed:-nothing}') - upload rejected and removed"
    fi
    rem_rename "$name.part" "$name"
    ok "  $name - uploaded, hashed AT the remote, renamed into place"
}
