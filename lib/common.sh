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
json_str() {
    local file="$1" key="$2"
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" \
        | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}

json_num() {
    local file="$1" key="$2"
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]*" "$file" \
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
