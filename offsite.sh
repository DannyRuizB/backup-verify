#!/usr/bin/env bash
# =============================================================================
# offsite.sh - get a verified backup OFF the machine, and prove the copy that
# landed is the copy you made.
#
# An off-site copy nobody has hashed is a hope with a network in the middle.
# Every lie this script guards against was MEASURED against a real remote
# before a line of it was written:
#
#   * a killed upload leaves a PARTIAL file under its final name (261,120 of
#     10,485,760 bytes, plausible to every "is the file there?" check);
#   * a full remote disk can leave a file with the RIGHT apparent size and
#     the WRONG bytes (stat reported the full 1,048,576 - the manifest would
#     have agreed - du showed 256K of real blocks; only the hash disagreed);
#   * rsync's size+mtime default re-syncs NOTHING over a remote copy that
#     rotted in place: rc 0, "up to date", corrupt forever;
#   * scp resets mtime to UPLOAD time, so after one old backup is re-uploaded,
#     pruning "the oldest by mtime" deletes the newest backup instead.
#
# Hence the protocol: upload under a temporary name, ask the REMOTE to hash
# what actually landed, compare against the manifest, and only then rename -
# artefact first, manifest LAST, so a manifest visible at the remote means its
# artefact arrived whole. Pruning goes by NAME (names carry sortable UTC
# stamps), never by mtime.
#
# Usage:
#   ./offsite.sh push  --manifest FILE --remote REMOTE [--keep N]
#   ./offsite.sh pull  --db NAME --remote REMOTE [--out DIR]
#   ./offsite.sh check --remote REMOTE [--db NAME]
#
# REMOTE is either
#   user@host:/path    over ssh (key-based; the far end needs only a POSIX
#                      shell and sha256sum - busybox qualifies), or
#   /path              a directory: a mounted NAS, a USB disk
#
# Subcommands:
#   push    verify the local pair, upload it, and refuse to leave anything at
#           the remote that the remote cannot hash back correctly
#   pull    download the newest pair of a database and re-verify the bytes -
#           a download is a transfer too, and transfers lie the same ways
#   check   audit every pair at the remote against its manifest WITHOUT
#           downloading artefacts: rot, orphans, crashed uploads. check proves
#           the remote holds the right bytes; only verify.sh proves they
#           restore.
#
# Options:
#   --manifest FILE   manifest of the backup to push (artefact sits beside it)
#   --remote REMOTE   where the off-site copies live (see above)
#   --db NAME         database/dataset name (pull: required; check: filter)
#   --out DIR         where pull writes (default ./restored; never overwrites)
#   --keep N          after a push, keep only the newest N pairs of this
#                     database AT THE REMOTE - decided by name, never mtime
#   --ssh-opts STR    extra ssh options, e.g. '-p 2222 -i ~/.ssh/backup_key'
#   -h, --help        this help
#
# Exit codes: 0 the remote provably holds what the manifests describe,
# non-zero otherwise.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SUBCMD=""
MANIFEST=""
REMOTE=""
DB=""
OUT_DIR="./restored"
KEEP=0
SSH_OPTS_STR=""

usage() { sed -n '2,/^#   -h, --help/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
    case "${1:-}" in
        push|pull|check) SUBCMD="$1"; shift;;
        -h|--help)       usage 0;;
        '')              printf 'a subcommand is required: push, pull or check\n' >&2; usage 1;;
        *)               printf 'unknown subcommand: %s\n' "$1" >&2; usage 1;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --manifest) MANIFEST="${2:-}"; shift 2;;
            --remote)   REMOTE="${2:-}"; shift 2;;
            --db)       DB="${2:-}"; shift 2;;
            --out)      OUT_DIR="${2:-}"; shift 2;;
            --keep)     KEEP="${2:-0}"; shift 2;;
            --ssh-opts) SSH_OPTS_STR="${2:-}"; shift 2;;
            -h|--help)  usage 0;;
            *)          printf 'unknown option: %s\n' "$1" >&2; usage 1;;
        esac
    done
    [ -n "$REMOTE" ] || die "--remote is required"
    case "$KEEP" in
        ''|*[!0-9]*) die "--keep must be a non-negative integer, got '$KEEP'";;
    esac
    case "$SUBCMD" in
        push) [ -n "$MANIFEST" ] || die "push needs --manifest (which backup to send)";;
        pull) [ -n "$DB" ] || die "pull needs --db (which database to bring back)";;
    esac
}

# ssh or a directory, decided by the one character that cannot be both: a
# colon. Both backends implement the same rem_* interface, so everything below
# this line has no idea which transport it is talking through - the engines'
# eng_* pattern, applied to the other end of the wire.
load_remote() {
    case "$REMOTE" in
        *:*)
            REM_HOST="${REMOTE%%:*}"
            REM_DIR="${REMOTE#*:}"
            # shellcheck source=lib/remote_ssh.sh
            . "$SCRIPT_DIR/lib/remote_ssh.sh";;
        *)
            REM_DIR="$REMOTE"
            # shellcheck source=lib/remote_dir.sh
            . "$SCRIPT_DIR/lib/remote_dir.sh";;
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

# Remote retention, decided by NAME. Artefact names carry a sortable UTC
# stamp, so lexical order is chronological no matter when anything was
# uploaded. mtime at the remote is upload time (measured: scp stamps "now"),
# so one re-uploaded old backup would make "delete the oldest by mtime"
# delete the newest backup instead. Only artefact+manifest PAIRS count,
# mirroring backup.sh's local retention.
prune_remote() {
    [ "$KEEP" -gt 0 ] || return 0
    local listing name total to_delete i
    local -a pairs=() sorted=()
    listing=$(rem_list)
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        case "$name" in
            *.json|*.part) continue;;
            "${DB}_"*)     ;;
            *)             continue;;
        esac
        if printf '%s\n' "$listing" | grep -qxF "$(manifest_for "$name")"; then
            pairs+=("$name")
        fi
    done <<< "$listing"
    total=${#pairs[@]}
    [ "$total" -gt "$KEEP" ] || { ok "retention: $total pair(s) at the remote, keeping up to $KEEP"; return 0; }
    while IFS= read -r name; do sorted+=("$name"); done < <(printf '%s\n' "${pairs[@]}" | sort)
    to_delete=$((total - KEEP))
    for ((i = 0; i < to_delete; i++)); do
        rem_delete "${sorted[$i]}"
        rem_delete "$(manifest_for "${sorted[$i]}")"
        warn "retention: removed ${sorted[$i]} (and its manifest) from the remote"
    done
    ok "retention: kept the newest $KEEP of $total at the remote"
}

push_pair() {
    [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
    local dir artefact aname mname
    dir="$(cd "$(dirname "$MANIFEST")" && pwd)"
    artefact="$dir/$(json_str "$MANIFEST" artefact)"
    [ -f "$artefact" ] || die "artefact named by the manifest is missing: $artefact"
    DB="$(json_str "$MANIFEST" database)"

    # Never ship bytes that were not checked THIS run: pushing an artefact
    # that rotted locally would faithfully replicate the rot off-site, with a
    # clean exit code every step of the way.
    assert_pair_intact "$MANIFEST" "$artefact" "pre-push"
    ok "local pair intact ($(stat -c%s "$artefact") bytes, sha256 verified)"

    rem_preflight rw
    aname=$(basename "$artefact")
    mname=$(basename "$MANIFEST")

    log "pushing to $(rem_describe)"
    upload_checked "$artefact" "$aname" "$(json_str "$MANIFEST" sha256)"
    # The manifest goes LAST: its presence at the remote is the commit marker.
    # A push that dies at any earlier point leaves either nothing or an
    # artefact no manifest vouches for - never a manifest whose artefact is
    # missing or partial. check names both leftovers.
    upload_checked "$MANIFEST" "$mname" "$(sha256_of "$MANIFEST")"
    ok "pushed: the remote proved it holds both files"
    prune_remote
}

pull_pair() {
    rem_preflight ro
    local listing name newest="" aname manifest_local artefact_local
    listing=$(rem_list)
    while IFS= read -r name; do
        case "$name" in
            *.part) continue;;
            "${DB}_"*.json)
                if [ -z "$newest" ] || [ "$name" \> "$newest" ]; then newest="$name"; fi;;
        esac
    done <<< "$listing"
    [ -n "$newest" ] || die "the remote holds no manifests for '$DB' - nothing to pull"

    mkdir -p "$OUT_DIR"
    manifest_local="$OUT_DIR/$newest"
    # A pull is for disaster recovery, which is exactly when a local file with
    # this name might be the only other copy of anything. Never overwrite.
    [ ! -e "$manifest_local" ] || die "refusing to overwrite $manifest_local - pull writes fresh copies only"

    log "newest at $(rem_describe): $newest"
    if ! rem_get "$newest" "$manifest_local"; then
        rm -f -- "$manifest_local"
        die "download of $newest died mid-flight - removed the partial local copy"
    fi
    aname="$(json_str "$manifest_local" artefact)"
    [ -n "$aname" ] || { rm -f -- "$manifest_local"; die "the downloaded manifest names no artefact"; }
    artefact_local="$OUT_DIR/$aname"
    [ ! -e "$artefact_local" ] || { rm -f -- "$manifest_local"; die "refusing to overwrite $artefact_local - pull writes fresh copies only"; }
    if ! rem_get "$aname" "$artefact_local"; then
        rm -f -- "$manifest_local" "$artefact_local"
        die "download of $aname died mid-flight - removed the partial local pair"
    fi

    # A download is a transfer too. The same gate that guards an upload guards
    # the way back - without it a pull could hand verify.sh corrupt bytes and
    # let it blame the backup. Run in a subshell so a failure cleans up: a
    # corrupt pair left on disk under --out is a corrupt pair someone will
    # eventually restore from.
    if ! (assert_pair_intact "$manifest_local" "$artefact_local" "post-download"); then
        rm -f -- "$manifest_local" "$artefact_local"
        die "the downloaded pair was removed; the REMOTE copy is suspect - run: $0 check --remote '$REMOTE'"
    fi

    ok "pulled: $aname + manifest, bytes re-verified after the download"
    ok "a copy that arrives is still only a copy - now prove it RESTORES:"
    if [ "$(json_str "$manifest_local" encryption)" = "age" ]; then
        printf '      ./verify.sh --manifest %s --identity YOUR_AGE_KEY\n' "$manifest_local"
    else
        printf '      ./verify.sh --manifest %s\n' "$manifest_local"
    fi
}

check_remote() {
    rem_preflight ro
    local listing name problems=0 pairs_ok=0 tmp expected landed aname
    listing=$(rem_list)
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064  # expand $tmp now: it is readonly-by-intent
    trap "rm -rf '$tmp'" EXIT

    log "checking $(rem_describe)${DB:+ (database $DB)}"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        # --db narrows the audit; everything else at the remote is ignored.
        if [ -n "$DB" ]; then
            case "$name" in "${DB}_"*) ;; *) continue;; esac
        fi
        case "$name" in
            *.part)
                # A temporary that outlived its push is a push that died
                # between "started" and "the remote hashed it back" - some
                # scheduled backup did NOT complete, and nothing else says so.
                printf '  %sFAIL%s %s - a push died mid-flight here\n' "$c_red" "$c_reset" "$name"
                problems=$((problems + 1));;
            *.json)
                # Manifests are small: fetch each one and make the remote hash
                # the artefact it vouches for. No artefact bytes ever travel.
                if ! rem_get "$name" "$tmp/$name"; then
                    printf '  %sFAIL%s %s - cannot be downloaded\n' "$c_red" "$c_reset" "$name"
                    problems=$((problems + 1))
                    continue
                fi
                aname="$(json_str "$tmp/$name" artefact)"
                if ! printf '%s\n' "$listing" | grep -qxF "$aname"; then
                    printf '  %sFAIL%s %s - its artefact (%s) is not at the remote\n' \
                        "$c_red" "$c_reset" "$name" "$aname"
                    problems=$((problems + 1))
                    continue
                fi
                expected="$(json_str "$tmp/$name" sha256)"
                landed=$(rem_sha256 "$aname" || true)
                if [ "$landed" = "$expected" ]; then
                    printf '  %sOK%s   %s - artefact hashes at the remote exactly as promised\n' \
                        "$c_green" "$c_reset" "$name"
                    pairs_ok=$((pairs_ok + 1))
                else
                    printf '  %sFAIL%s %s - the artefact does NOT hash to its manifest (rot, or a transfer lied)\n' \
                        "$c_red" "$c_reset" "$name"
                    problems=$((problems + 1))
                fi;;
            *)
                # An artefact no manifest vouches for: a push that crashed
                # after committing the artefact, or a file someone copied in
                # by hand. Either way nothing can ever verify it.
                if ! printf '%s\n' "$listing" | grep -qxF "$(manifest_for "$name")"; then
                    printf '  %sFAIL%s %s - artefact without a manifest, nothing can ever verify it\n' \
                        "$c_red" "$c_reset" "$name"
                    problems=$((problems + 1))
                fi;;
        esac
    done <<< "$listing"

    printf '\n'
    if [ "$problems" -gt 0 ]; then
        die "OFF-SITE CHECK FAILED: $problems problem(s), $pairs_ok pair(s) clean."
    fi
    [ "$pairs_ok" -gt 0 ] || die "the remote holds nothing${DB:+ for $DB} - nothing checked, nothing proven"
    ok "off-site copies are consistent: $pairs_ok pair(s) hash at the remote exactly as their manifests promise"
    log 'consistent is not restorable - pull one and run verify.sh to prove that'
}

main() {
    need sha256sum
    load_remote
    case "$SUBCMD" in
        push)  push_pair;;
        pull)  pull_pair;;
        check) check_remote;;
    esac
}

# Guarded so the tests can source this file and exercise parse_args/load_remote
# without touching any remote (the harness idiom of the whole family).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    parse_args "$@"
    main
fi
