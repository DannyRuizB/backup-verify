#!/usr/bin/env bash
# =============================================================================
# Files engine module: back up a DIRECTORY TREE and prove it restores.
#
# Same eng_* interface as the database engines, because a file tree lies in
# all the same ways a database does - every one of these was MEASURED on this
# machine before the module was written:
#
#   * a TRUNCATED .tar.gz extracts a PARTIAL tree with rc=2: files on disk,
#     plausible sizes (a 100000-byte blob came back as 49664 bytes). "The
#     directory exists and has files" signs it off; only content hashes don't.
#   * `tar czf backup.tgz *` misses every dotfile - .env was simply not in the
#     archive, exit code 0. The default invocation loses the secrets first.
#   * a failing tar piped into gzip leaves a 45-byte archive that PASSES
#     `gzip -t`, and the pipeline exits 0 without pipefail.
#   * without -p, the umask strips modes on extraction: 664 became 644 and a
#     setgid 2775 directory came back 755 - a shared directory that silently
#     stopped being shared. (600 and 755 survive, which HIDES the problem in
#     simple tests.) Restores here always use -p.
#   * same size, same mtime, different content: only a content hash sees it -
#     an rsync-style size+mtime comparison calls the two files identical.
#
# The mapping: files are the tables (sha256:bytes fingerprints), the metadata
# classes are the schema (modes, symlinks, dirs), and the throwaway instance
# is a scratch directory instead of a container. No Docker involved.
# =============================================================================

# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
ENG_NAME="files"
# No container is ever booted: the "instance" is a scratch directory. The
# variable exists because the interface promises it and verify.sh logs it.
# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
ENG_DEFAULT_IMAGE="scratch-dir"
# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
ENG_ARTEFACT_EXT=".tar.gz"
# shellcheck disable=SC2034  # used in user-facing messages
ENG_UNIT="file"
# The generic 512-byte floor would REFUSE a real backup here: a legitimate
# two-small-files tree gzips to 176 bytes (measured). An empty source gives
# 110, so the floor still catches the absurd - and the "manifest lists no
# files" gate is the real guard against backing up nothing.
# shellcheck disable=SC2034  # read by backup.sh
ENG_MIN_ARTEFACT_BYTES=128

# The metadata classes verify.sh compares - the half a file-count never sees.
# modes catches the umask strip (2775 -> 755), symlinks catches links turned
# into copies or lost, dirs catches empty directories that a naive tool drops.
# shellcheck disable=SC2034  # read by backup.sh/verify.sh, which source this
SCHEMA_CLASSES="modes symlinks dirs"

# Where an instance name lives on disk. The first argument of every eng_*
# function is either the SOURCE directory (absolute, from --path) or a probe
# NAME like bv-verify-1234; a name maps to a namespaced scratch directory.
files_root() {
    case "$1" in
        /*) printf '%s' "$1";;
        *)  printf '%s' "${TMPDIR:-/tmp}/bv-files-$1";;
    esac
}

# Backup-side preconditions: the source must be a directory we can read.
eng_preflight() {
    need tar
    [ -d "$1" ] || die "source directory '$1' not found"
    [ -r "$1" ] || die "source directory '$1' is not readable"
    [ -x "$1" ] || die "source directory '$1' is not traversable"
}

# "Boot a throwaway instance" = make an empty scratch directory.
eng_boot() {
    local name="$1"
    mkdir -p "$(files_root "$name")"
}

# A directory has no boot sequence; it is ready by existing.
eng_wait_ready() {
    return 0
}

# Deliberately fatal: nothing in backup.sh or verify.sh queries an engine
# directly (only engine internals do, and this engine has none). Failing loudly
# beats pretending a directory speaks SQL.
eng_query() {
    die "the files engine has no query interface"
}

# Dump the tree to stdout. `.` and not `*`: the glob invocation is the
# measured disaster (it silently drops every dotfile), and negative case 6
# exists to prove this engine does not repeat it.
eng_dump() {
    local root
    root=$(files_root "$1")
    tar -C "$root" -czf - .
}

# Restore from stdin. -p is load-bearing: without it the umask strips
# group-write and setgid on extraction (664 -> 644, 2775 -> 755, measured),
# and the modes class would blame the archive for what the extraction did.
eng_restore() {
    local root
    root=$(files_root "$1")
    tar -xzpf - -C "$root"
}

# Cheap parse gate: list the archive without extracting. Measured to catch
# truncation (`tar -tzf` on a half archive exits 2), and it reads the whole
# stream, unlike extraction of an early file.
eng_archive_parses() {
    tar -tzf - >/dev/null
}

# Every regular file, as a sorted relative path - these are the "tables".
# Symlinks are metadata (their class below), not content. Names that cannot
# survive the manifest's line-oriented format are refused outright: a backup
# whose manifest cannot name a file cannot verify that file.
eng_list_tables() {
    local root
    root=$(files_root "$1")
    if find "$root" -name "$(printf '*\n*')" -o -name "$(printf '*\t*')" -o -name '*"*' 2>/dev/null | grep -q .; then
        die "the source contains file names with newlines, tabs or double quotes - the manifest cannot represent them"
    fi
    (cd "$root" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
}

# sha256:bytes of one file. The hash is the whole point: same size plus same
# mtime with different content fools every metadata comparison (measured), and
# a partial file from a truncated archive has a plausible size.
eng_table_fingerprint() {
    local root f
    root=$(files_root "$1")
    f="$root/$3"
    [ -f "$f" ] || return 1
    printf '%s:%s' "$(sha256sum < "$f" | awk '{print $1}')" "$(stat -c%s "$f")"
}

# count:md5 over the sorted definition lines of one metadata class, exactly
# like the database engines digest their schema classes.
eng_schema_digest() {
    local root lines count
    root=$(files_root "$1")
    case "$3" in
        modes)    lines=$(cd "$root" && find . -mindepth 1 -printf '%P\t%y\t%m\n' | LC_ALL=C sort);;
        symlinks) lines=$(cd "$root" && find . -type l -printf '%P -> %l\n' | LC_ALL=C sort);;
        dirs)     lines=$(cd "$root" && find . -mindepth 1 -type d -printf '%P\n' | LC_ALL=C sort);;
        *)        die "unknown object class for files engine: $3";;
    esac
    count=$(printf '%s' "$lines" | grep -c . || true)
    printf '%s:%s' "$count" "$(printf '%s' "$lines" | md5sum | awk '{print $1}')"
}

# Regular files in the restored copy - compared against how many the manifest
# describes, so an EXTRA file is a mismatch too.
eng_count_tables() {
    local root
    root=$(files_root "$1")
    find "$root" -type f | wc -l
}

# Everything, files and directories and links: the "is the instance clean"
# gate. A restore into a non-empty directory proves nothing.
eng_count_relations() {
    local root
    root=$(files_root "$1")
    find "$root" -mindepth 1 | wc -l
}

# The behavioural gate: a restored file the application cannot READ is the
# files version of "every row present and the first INSERT collides". A file
# restored 000 or 200 is faithful to its manifest and still useless.
eng_writable_probe_failures() {
    local root
    root=$(files_root "$1")
    (cd "$root" && find . -type f ! -readable -printf 'file %P is not readable by its owner\n')
    (cd "$root" && find . -type d \( ! -readable -o ! -executable \) \
        -printf 'directory %P cannot be entered by its owner\n')
}

# Tear the throwaway instance down. ONLY derived scratch roots are ever
# removed: an absolute path is user-supplied source, and deleting it would
# make this tool the disaster it exists to prevent.
eng_teardown() {
    case "$1" in
        /*) : ;;
        *)  rm -rf "$(files_root "$1")";;
    esac
}
