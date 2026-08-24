# backup-verify

[![ci](https://github.com/DannyRuizB/backup-verify/actions/workflows/ci.yml/badge.svg)](https://github.com/DannyRuizB/backup-verify/actions/workflows/ci.yml)

**A backup nobody has restored is not a backup, it is a hope.** This repo takes
PostgreSQL, MySQL/MariaDB and plain file-tree backups and then *proves they
restore* — by restoring them into a throwaway instance and comparing the
result against the source, table by table (or file by file). And because a
copy that never left the building is a hope of a different kind, `offsite.sh`
gets the proven pair off the machine — and makes the far end prove, hash in
hand, that what landed is what was sent. And `pitr.sh` proves the strongest
promise a backup can make: that a base backup plus a WAL archive reproduce a
**named instant**, exactly — with `binlog.sh` proving the same for MySQL,
through the binary log, against reflexes measured to be the exact opposite.

CI does the thing everyone talks about and almost nobody automates: it seeds a
real source, backs it up, **destroys it**, restores from the artefact, and
checks the restored copy is identical. Then it does it again with a suite of
deliberately broken backups to prove the checks actually catch them — on every
engine.

```bash
./backup.sh --container my-postgres --db app --out ./backups --keep 7
./verify.sh --manifest ./backups/app_20260803T120447Z.json

# MySQL / MariaDB: same promise, same gates
./backup.sh --engine mysql --container my-mysql --db app --out ./backups
# (verify.sh reads the engine from the manifest - no flag needed)

# a directory tree: same promise, same gates, no Docker involved
./backup.sh --engine files --path /srv/app --out ./backups

# encrypted at rest, and proven to decrypt at backup time:
age-keygen -o key.txt
./backup.sh --container my-postgres --db app --recipient age1... --identity key.txt
./verify.sh --manifest ./backups/app_....json --identity key.txt

# off-site, with the REMOTE hashing what actually landed:
./offsite.sh push  --manifest ./backups/app_....json --remote bk@nas:/srv/backups --keep 14
./offsite.sh check --remote bk@nas:/srv/backups
./offsite.sh pull  --db app --remote bk@nas:/srv/backups --out ./restored

# point-in-time: prove that base backup + WAL archive reproduce a NAMED instant
./pitr.sh base   --container my-postgres --db app --archive /srv/wal-archive
./pitr.sh mark   --container my-postgres --db app --archive /srv/wal-archive
./pitr.sh check  --archive /srv/wal-archive --container my-postgres
./pitr.sh verify --base ./backups/app_..._base.json \
                 --mark ./backups/app_..._mark.json --archive /srv/wal-archive

# ...and get the instant off the machine, chain and all:
./pitr.sh push  --base ./backups/app_..._base.json --mark ./backups/app_..._mark.json \
                --archive /srv/wal-archive --remote bk@nas:/srv/pitr
./pitr.sh check --remote bk@nas:/srv/pitr
./pitr.sh pull  --db app --remote bk@nas:/srv/pitr --archive ./recovered-wal --out ./recovered

# encrypted end to end: segments leave the server as ciphertext...
#   archive_command = 'test ! -f /srv/wal-archive/%f.age &&
#                      age -r age1... -o /srv/wal-archive/%f.age %p'
# ...the base travels encrypted too, and verify decrypts inside the drill:
./pitr.sh base   --container my-postgres --db app --archive /srv/wal-archive \
                 --recipient age1... --identity key.txt
./pitr.sh verify --base ... --mark ... --archive /srv/wal-archive --identity key.txt

# MySQL point-in-time, through the binary log (a different animal, measured):
./binlog.sh base   --container my-mysql --db app
./binlog.sh mark   --container my-mysql --db app --archive /srv/binlog-archive
./binlog.sh verify --base ./backups/app_..._binlogbase.json \
                   --mark ./backups/app_..._binlogmark.json \
                   --archive /srv/binlog-archive --tools ./tools

# ...and off the machine too, same remotes, same receipts:
./binlog.sh push  --base ./backups/app_..._binlogbase.json \
                  --mark ./backups/app_..._binlogmark.json \
                  --archive /srv/binlog-archive --remote bk@nas:/srv/binlogs
./binlog.sh check --remote bk@nas:/srv/binlogs
./binlog.sh pull  --db app --remote bk@nas:/srv/binlogs --archive ./recovered-binlogs

# encrypted end to end: the mark encrypts as it archives (and proves the
# round trip against the server's bytes), the chain travels as ciphertext,
# and only verify ever holds the key:
./binlog.sh base   --container my-mysql --db app --recipient age1... --identity key.txt
./binlog.sh mark   --container my-mysql --db app --archive /srv/binlog-archive \
                   --recipient age1... --identity key.txt
./binlog.sh verify --base ... --mark ... --archive ... --tools ./tools --identity key.txt
```

```
[+] artefact matches its manifest (28421 bytes, sha256 verified)
[*] booting a throwaway postgres:17-alpine as 'bv-verify-757818'
[+] throwaway instance is empty (0 tables)
[*] restoring...
  OK   customers
  OK   orders
[+] VERIFIED: 2 table(s) restored byte-for-byte identical to the source.
```

## Why row counts are not verification

This is the finding the whole repo is built on, measured on a real Postgres:

> A **truncated** dump makes `pg_restore` exit non-zero **and still leaves the
> table populated** — 500 of 500 rows restored from an archive cut in half.

So the two obvious checks both sign that backup off: the table exists, and it
has rows. Only comparing the **whole content** catches it. `verify.sh` therefore
never answers the question by counting: for each table it computes an
order-independent md5 over every column of every row (the row count rides along
only so a failure can say how many rows are missing), and compares it to the
fingerprint recorded at backup time.

### ...and rows are only half the database

Measured the same way, on the "I only want the tables" flow every sysadmin has
typed at some point:

> `pg_restore -t customers -t orders` exits **0**, restores **every single row**
> — and silently drops **4 of 4 indexes, 4 of 5 constraints, the view, the
> function and the trigger**.

A restored copy that cannot enforce a unique key, or whose trigger no longer
fires, is not a restored copy. So the manifest also records **schema objects** —
indexes, constraints, sequences (with their `last_value`), views, routines,
triggers — as a count plus a fingerprint of their definitions, and `verify.sh`
compares each class. A missing index is a failure, and so is an index that came
back on the wrong column.

Three more ways a backup lies, all measured, all covered by the negative suite:

| What looks fine | What is actually happening |
|---|---|
| `backup.sh` finished, file exists | A failed `pg_dump` leaves **0 bytes**; piped through `gzip`, **~20 bytes** of perfectly valid *empty* archive |
| The nightly cron reported success | `pg_dump ... \| gzip > out.gz` exits **0 even when pg_dump fails** — without `set -o pipefail` the pipeline's status is gzip's |
| The archive verified last month | Bit rot, a half-finished copy, a truncated upload: the sha256 in the manifest catches it *before* wasting a restore |

## Encryption, and why it needs the same suspicion

A backup you have never decrypted is **two** hopes stacked: that it restores,
and that the key still opens it. So `--recipient` encrypts with
[age](https://github.com/FiloSottile/age), and:

- The **plaintext dump never touches disk** — `pg_dump` is piped straight into
  `age`, so a crash cannot leave an unencrypted copy behind. This is the one
  pipe this repo allows, and `PIPESTATUS` names *which* side failed instead of
  guessing.
- `--identity` at **backup** time decrypts the artefact immediately and parses
  it. That turns "the key works" from an assumption into a fact you learn today
  rather than during a restore. Without it the artefact is still written, and
  the script **says out loud** that it was not decryption-checked.
- `verify.sh` decrypts into `pg_restore` and **refuses to run without the key**:
  no key, no verification, no comforting green tick.

Two measured facts shaped this, and they pull in opposite directions:

| Measured | Consequence |
|---|---|
| A **truncated** `.age` fails to decrypt at all — *"failed to decrypt and authenticate payload chunk"*, zero bytes written | Authenticated encryption hands you integrity for free. Contrast case 1: a truncated **plain** dump restores partial data and lies. |
| A failed `pg_dump` piped into age yields a **valid ~200-byte `.age` that decrypts to 0 bytes with exit code 0** | Encryption protects the bytes, **not their meaning**. Only restoring proves meaning — which is the whole repo. |

## MySQL has its own ways of lying

Adding the second engine was not a port, it was a new measurement campaign —
every one of these was observed on a real MySQL 8.4 before a line of the module
was written:

| What looks fine | What is actually happening |
|---|---|
| `mysqldump` exited 0, the file has your tables | **Routines are omitted by default.** A database with one function and one procedure dumps with zero of each — no error, no warning. Triggers do come along; functions, procedures and events do not. The engine module forces `--routines --events --triggers`, and negative case 6 proves a default dump is rejected for exactly this. |
| A `GROUP_CONCAT`-based fingerprint returns a hash | **`group_concat_max_len` defaults to 1024 bytes.** The hash would be computed over 1024 of 16 175 bytes — six percent of the data — and MySQL only whispers warning 1260, which no script ever sees. The fingerprint query raises the limit *and proves it sufficed*, by checking the joined length against what the rows must add up to; anything else aborts. |
| `information_schema` says the `AUTO_INCREMENT` counter matches | **It reports the counter rounded to an allocation boundary** — measured: 512 and 1024 where the real maxima were 500 and 800. Comparing that number between source and copy would raise *false alarms*, the worst failure mode a verifier can have. So only the counter's existence is fingerprinted, and usability is tested behaviourally against the real `MAX()`. |
| The column has `REFERENCES customers(id)` | MySQL **parses an inline column-level foreign key and silently ignores it** — no constraint exists. The test seed declares its FK at table level, where it is real. |

And the official MySQL image boots **two** servers just like the Postgres one
(init, shutdown, the real one), so the same wait rule applies to both: a real
query must succeed three times in a row before anyone trusts the server.

## File trees have their own ways of lying

The third engine needed no database at all to earn its measurement table —
every row below was observed on this machine before the module was written:

| What looks fine | What is actually happening |
|---|---|
| The restore directory exists and has files in it | **A truncated `.tar.gz` extracts a partial tree.** tar exits 2, but the files it got to are on disk — and the one it was cut off inside has a plausible size (a 100 000-byte blob came back as 49 664). "It restored something" signs it off; only a per-file content hash does not. |
| `tar czf backup.tgz *` exited 0 | **The glob never matched the dotfiles.** `.env` — the credentials — was simply not in the archive. No error, no warning. The engine dumps `.` instead, and negative case 6 proves a glob-built artefact is rejected with `.env - file absent`. |
| The `.tgz` passes `gzip -t` | **A failing tar piped into gzip leaves a valid archive of nothing** — 45 bytes that decompress happily. Without `pipefail` the pipeline exits 0. Same family as the empty `pg_dump`; and an EMPTY source tree gives a valid 110-byte archive the same way, so backing up zero files is refused outright. |
| The files came back, same names, same sizes | **Extraction without `-p` lets the umask strip modes**: 664 became 644 and a setgid 2775 shared directory came back 755 — silently no longer shared. (600 and 755 survive, which hides the problem in simple tests.) Restores here always use `-p`, and the `modes` class fingerprints every entry's mode so drift is named. |
| Size and mtime match the manifest | **Same size + same mtime with different content fools every metadata comparison** — an rsync-style check calls the files identical. Fingerprints are `sha256:bytes`, so content is what decides. |

The "schema objects" of a tree are its metadata, digested in three classes the
way the database engines digest theirs: **modes** (every entry's permission
bits — the umask lie), **symlinks** (a link turned into a copy is a different
tree), and **dirs** (an empty directory a naive tool drops is still a loss).

## Off-site copies have their own ways of lying

An off-site copy nobody has hashed is a hope with a network in the middle.
Every row below was measured against a real remote (sshd, busybox at the far
end) before `offsite.sh` was written:

| What looks fine | What is actually happening |
|---|---|
| The nightly `rsync -a` exits 0: "up to date" | **rsync's default comparison is size + mtime.** A remote copy corrupted *in place* (same size, mtime preserved — bit rot's exact shape) is re-synced **never**: rc 0 every night, `--itemize-changes` shows nothing transferred, and the off-site copy stays corrupt forever. Only `--checksum` notices. |
| The file is there, the size looks right | **A killed upload leaves a partial file under its final name** — measured: 261 120 bytes of a 10 485 760-byte artefact, sitting at the destination as if it were the backup. Every "is the file there?" check signs it off. |
| `stat` at the remote agrees with the manifest | **A full remote disk produced a file with the RIGHT apparent size and the wrong bytes** — `stat` reported the full 1 048 576 (exactly what the manifest promises), `du` showed 256K of real blocks. Even a size comparison lies here; only hashing *at the remote* disagreed. |
| Prune "the oldest" at the remote by mtime | **A remote mtime is the upload time, not the backup time** (measured: scp stamps "now"). Re-upload one old backup — after a restore drill, say — and it becomes the "newest" file on the remote: an mtime-based prune then deletes the genuinely newest backup and keeps January's. |
| `pg_dump \| ssh nas 'cat > backup.sql'` exits 0 | The straight-to-NAS pipe from every tutorial: with the dump **failing**, the pipeline's status is the remote `cat`'s — a 20-byte file with a final-looking name lands at the remote and the cron reports success. The gzip lie, with a network in the middle. |

Hence `offsite.sh`'s protocol, suspicious in both directions:

- **`push`** verifies the local pair *first* (shipping bytes that rotted locally
  would replicate the rot off-site with a clean exit code), uploads under a
  temporary name, asks **the remote** to sha256 what actually landed, and only
  then renames into place. The artefact commits first and the manifest **last**,
  so a manifest visible at the remote is a receipt: its artefact arrived whole.
  A push that dies at any point leaves nothing that looks like a backup.
- **`pull`** re-verifies the bytes after the download — a download is a transfer
  too — and never overwrites anything: disaster recovery is exactly when a local
  file with that name might be the only other copy of anything. A pull that
  catches corruption removes what it fetched instead of leaving a plausible
  pair for someone to restore from.
- **`check`** audits every pair at the remote **without downloading artefacts**:
  each manifest is fetched (they are small) and the remote hashes the artefact
  it vouches for. In-place rot, artefacts no manifest vouches for, and crashed
  uploads (`.part` leftovers) are all named. `check` proves the remote holds the
  right bytes; only `verify.sh` proves those bytes restore.
- Retention at the remote (`--keep N`) counts complete pairs and decides **by
  name** — names carry sortable UTC stamps — never by mtime, for the measured
  reason above.

A remote is `user@host:/path` (ssh, key-based — the far end needs only a POSIX
shell and `sha256sum`, busybox qualifies) or a plain `/path` (a mounted NAS or
USB disk — same protocol, because a mount fails in the same shapes). Both live
behind one `rem_*` interface in `lib/remote_ssh.sh` and `lib/remote_dir.sh`:
the engines' `eng_*` pattern, applied to the other end of the wire. Everything
rides plain `ssh` — the probe for this feature was bitten by `scp` reading
`-p 2299` as "preserve times, then a filename", which is the kind of footgun a
backup tool should not keep loaded. Encryption composes untouched: the
manifest's sha256 is the ciphertext's, so the remote hashes ciphertext and the
whole cycle runs encrypted end to end.

## Point-in-time recovery has its own ways of lying

A dump is one instant; PITR promises *any* instant — a base backup plus an
archive of WAL segments, replayed to the moment you name. Every promise in
that sentence was measured breaking silently, on a real Postgres, before a
line of `pitr.sh` was written:

| What looks fine | What is actually happening |
|---|---|
| Recovery "to the latest" boots, rc 0, the app comes up | **The tail of history since the last archived segment simply does not exist.** Measured: 500 of 600 rows after a recovery that reported success — the missing 100 sat ~175 KB into a 16 MB segment that had never been archived. With the default `archive_timeout=0`, that unarchived tail can be **days** old. Hence `mark`: an instant only counts once its WAL provably sits in the archive. |
| Commits succeed, the application is happy | **A dead archive is silent everywhere except `pg_stat_archiver`.** Measured: 600 commits, rc 0 each, while `failed_count` climbed 0→9 and segments piled up in `pg_wal`. Nothing user-facing says a word. `check --container` reads the only witness there is — knowing that a *cured* archiver can still take ~60 s (its retry cycle) before the backlog moves. |
| The recovery log looks like every other recovery log | **A hole in the WAL chain with no recovery target is a silent truncation** — rc 0, and the `cp: can't stat` noise it makes is identical to the noise a *healthy* recovery makes probing for `.history` files. The SAME hole with a **named** target is FATAL: `recovery ended before configured recovery target was reached`. That measured asymmetry is the spine of `pitr.sh`: every recovery here has a name it must reach or die trying. |
| Every segment file is present, names contiguous | **A truncated segment only fails on the day you recover** — `invalid segment file size`, FATAL — which is the worst possible day to learn it. Every *complete* segment measures exactly `wal_segment_size`, so `check` makes that lie loud **today**, by size, from the directory alone (`.backup` and `.history` files are legitimately small and exempt). |
| The archive directory accepts files | **One planted file bearing the name of the *next* segment jams the documented `archive_command` forever**: `test ! -f ... && cp ...` refuses to overwrite, so the real segment can never land (measured: `failed_count` +6 per 70 s, indefinitely — the poison pill). And a `pg_basebackup -X none` artefact alone does not even boot (`could not locate required checkpoint record`): it is **half** a backup whose other half *is* the archive — which is why `base` waits for that WAL to be archived, and a hung `base` is the honest symptom of a dead archiver. |

Hence the subcommands, suspicious at every step:

- **`base`** — `pg_basebackup` (tar, `-X none` on purpose: bundling WAL into
  the artefact would let the drill pass with a dead archive) plus a manifest
  binding artefact and archive together: the WAL start file from the backup
  label, the segment size, the server major version.
- **`mark`** — fingerprint every table, drop a named restore point, switch the
  segment out, and **wait until the mark's segment is whole in the archive**.
  If it never lands, no manifest is written: a mark you cannot recover to is
  not a mark, and pretending otherwise is the "to the latest" lie again. The
  mark also records **one sha256 per archived file it stands on** — the
  inventory every later audit hashes against, for the measured reason below.
- **`check`** — audit the archive *today*: holes in the chain, wrong-size
  segments, strays and squatters, all from the directory alone — and, with
  `--container`, whether the archiver is behind or failing right now.
- **`verify`** — the drill: boot a throwaway instance from the base backup,
  recover **through** the archive to the mark **by name**, demand the log's
  receipt (`recovery stopping at restore point`), then compare every
  fingerprint the mark recorded. The cheap refusals come first: a mark from
  another timeline or predating its base, and any hole in the WAL range, are
  rejected before anything boots.

PostgreSQL only, on purpose: WAL archiving is a PostgreSQL mechanism, and
MySQL's binlogs are a different animal. Once that animal was measured it got
its own script — `binlog.sh`, below — rather than a flag on this one, because
the measurements disagree at the spine: Postgres dies loudly when a named
target is unreachable, MySQL says nothing at all.

### The archive has to leave the building too

A WAL archive that never left the machine dies in the same fire as the
database. But an off-site WAL archive lies in shapes even the off-site
artefact copies above don't — each one measured before `push`, `pull` and
`check --remote` were written:

| What looks fine | What is actually happening |
|---|---|
| Every segment is at the remote, every size matches | **Every complete segment measures exactly `wal_segment_size`, so a size audit of a WAL archive is blind to rot BY CONSTRUCTION.** Measured: a segment corrupted in place kept identical `stat` output — same 16 777 216 bytes, same mtime. At the artefact copies above, size at least catches truncation; here even that discriminates nothing between complete segments. Only a hash says anything at all. |
| The fire drill passed | **Rot past the mark leaves that mark's drill green.** Measured: with a segment rotted *after* mark 1's stop point, verify to mark 1 exits 0 with every fingerprint true — and verify to mark 2, straight through the rot, dies FATAL (`invalid magic number`). A passing recovery proves the chain it replayed, not the archive. Hence the mark's **inventory**: one sha256 per file, so `check --remote` can hash the remote's bytes against a recorded claim *today*, and `verify` refuses rot in its range in milliseconds instead of discovering it mid-replay. |
| The archive was synced an hour ago | **An archive pushed at 12:00 cannot prove a 12:05 mark** — the mark's segment never travelled. Measured: recovery against the stale copy, newer mark named = refused, `missing segment ... the chain is broken here`. So the mark manifest travels **last**, behind everything it stands on: a mark at the remote is a receipt, and `pull` returns the newest instant the remote can *prove*, never the newest that merely exists. |
| The segment is there, the "skip existing" sync is fast | **A killed upload leaves a partial under the segment's final name, and an exists-check never repairs it** — measured: 262 144 of 16 777 216 bytes squatting as the segment, invisible to `test -f`-style syncs forever. `push` uploads under a temporary name, has the **remote** hash it, renames only on a match — and re-ships anything whose remote hash disagrees with the inventory, because "the file is already there" is a claim about a name, not about bytes. |

The protocol is offsite.sh's, applied per file: the same `rem_*` transports
(ssh, or a mounted directory), upload to `.part`, hash at the remote, rename;
base artefact and segments first, manifests after, the mark at the very end.
`pull` re-hashes everything after the download, never overwrites, and removes
what it fetched if the bytes disagree — and `push`, `pull` and `check
--remote` all operate on the same set, **the range the pair actually
replays**: from the base's first segment to the mark, plus timeline history
files. What the drill proves end to end: mark, push, lose the *machine* —
source, local archive, every manifest — pull, and recover the named instant
exactly, on nothing but the remote's contents.

### And the archive is your data, in cleartext

Encrypting the dump and shipping the WAL archive plain is a locked front door
with the back door open — measured, like everything here:

| What looks fine | What is actually happening |
|---|---|
| The base backup travels encrypted, so the data is safe | **WAL segments carry row data in cleartext.** Measured: a seeded email address greps straight out of a raw archived segment. An off-site WAL archive is an off-site copy of your rows, whatever the base artefact does. |
| Encrypt each segment when it is uploaded | **age is non-deterministic: the same segment encrypted twice yields different bytes** (same size, different sha — measured). Re-encrypting can never reproduce an archived file, so a segment's identity is its ciphertext **as archived**: encrypt once, in `archive_command`, and let the mark's inventory hash exactly that. Push, pull and `check --remote` then compose **untouched** — they move opaque names and hashes and never need a key. |
| The `.age` file exists, so the segment is archived | **This probe was caught by its own measurement**: a stat milliseconds after the file appeared found 7.8 MB of a 16.8 MB ciphertext — age writes progressively, and "the file exists" blesses a half-written one. The encrypted `mark` wait demands a size past the plaintext AND stable across two polls. |
| Corruption in an encrypted archive needs the inventory to catch | The inventory still catches it **today** — but authenticated encryption adds a second, free line of defence: a truncated *or* bit-flipped `.age` refuses to decrypt at all (*"failed to decrypt and authenticate payload chunk"* — measured both ways), so even an old mark without an inventory dies loudly instead of replaying garbage. And every complete ciphertext measures the same (plaintext + constant overhead; 16 781 496 bytes for every 16 MiB segment), so the exact-size gate survives encryption unchanged. |
| The key question waits until recovery day | **`verify` refuses to run without `--identity`** — no key, no drill, no comforting green tick — and a wrong key dies at the base artefact, named for what it is. Inside the drill the throwaway decrypts each segment itself (`restore_command` pipes through a static `age` that rides into the container read-only); the wrong key there is FATAL and immediate: *"no identity matched any of the recipients"* (measured). `base --recipient` requires `--identity` for the same reason `backup.sh` offers it: the key gets proven **today**. |

## MySQL point-in-time has its own ways of lying

`pitr.sh` declared MySQL out of its reach until the animal was measured — and
the measurements say it deserved its own script. `binlog.sh` is `pitr.sh`'s
sibling for the binary log, with the same four subcommands (`base`, `mark`,
`check`, `verify`) built on findings that are not just different from WAL
archiving but in places its exact opposite:

| What looks fine | What is actually happening |
|---|---|
| The replay to an exact position exited 0 | **A `--stop-position` past the end of history exits 0 with an EMPTY stderr** (measured). Postgres dies FATAL when a named target is not reached; MySQL says *nothing* — the position is a hint, not a promise. So `verify` proves **arrival by content**: the mark's fingerprints, the same yardstick every other verifier here uses, because here no exit code can be trusted to mean "we got there". |
| Replay the files you still have | **A missing file in the middle of the list is stitched over silently**: rc 0, empty stderr, and the missing file's transactions gone (measured: 100 of 300 rows vanished while everything reported success). Postgres at least stops at a hole; MySQL replays straight across it. Continuity is proven by name before anything boots. |
| `mysqlbinlog` read the whole file without complaint | **It does not verify event checksums unless asked**: a corrupted binlog decodes with rc 0 without `--verify-binlog-checksum` and dies loudly with it (measured, same file both ways). The flag is hardwired here — and the mark's inventory names the rot **today**, without waiting for a replay to trip. |
| The nightly `mysqldump`, plus "we keep the binlogs" | **The tutorial dump records no anchor** — nothing says WHERE the replay starts. Starting from the beginning re-runs history the dump already contains (measured: it died on the first DDL collision, leaving an ambiguous half-replay). `base` dumps with `--source-data` and refuses to write a manifest if the anchor is missing. |
| Copy the binlogs somewhere safe | **The active binlog grows under the copy, and MySQL has no `archive_command`** — nothing ships closed files anywhere, ever. So `mark` IS the archiver: it flushes the active file closed, copies every file the instant stands on, and hash-verifies each copy against the server's own bytes *before* the manifest exists. The mark's inventory carries one sha256 per file — sizes vary by nature here, so the hash carries all the weight the WAL size gate used to. |
| The database image can read its own history | **The official `mysql` image does not ship `mysqlbinlog`** (and `SHOW MASTER STATUS` is gone in 8.4 — both measured the hard way). The drill extracts the exact-version binary from the official client RPM and mounts it read-only into throwaways — the static-age lesson again — and `verify` refuses a version-skewed tool: a replay through the wrong decoder is a guess. |

Measured with `gtid_mode=OFF`, the 8.4 default; GTID-mode PITR changes the
replay rules and is not claimed here.

### The binlog archive has to leave the building too

`push`, `pull` and `check --remote` work exactly as `pitr.sh`'s do — same
`rem_*` transports, upload to `.part` with the remote hashing before the
rename, the mark manifest travelling last as the receipt, everything
incremental by hash and re-hashed after every transfer, and all three
operating on the same set: the range the pair replays. One measured fact
makes the binlog remote *more* treacherous than the WAL one:

> At a WAL archive, truncation at least had a shape — every complete segment
> measures exactly `wal_segment_size`, so a short file is loud. **A binlog
> truncated exactly at an event boundary decodes clean: rc 0, stderr EMPTY,
> half the history amputated** — measured: 3 of 6 commits survived a cut
> after a commit event, checksums verified, not one word of complaint. And
> sizes vary by nature, so the size says nothing either. At a binlog archive
> the mark's inventory hash is not the best defence — it is the *only* one.

The fire drill is the same as the WAL's: mark, push, lose the machine —
source, local archive, every manifest — pull, and the instant comes back
exactly, arrival proven by content on a bare machine.

### And the binlog is your rows too

The WAL measurement repeats here almost verbatim — a seeded email address
greps straight out of a raw archived binlog (ROW format writes the row
itself, and 8.4 neither compresses nor encrypts it by default) — with one
trap the probe itself fell into: the grep first came back *empty*, because
`binlog.000001` of a fresh official-image server belongs to the **init**, not
to you — ~3 MB of timezone rows written by the entrypoint's temporary server.
Your rows live from `binlog.000002` on, in clear either way. So the binlog
archive earned its own encryption campaign, and the animal disagrees with the
WAL's in both directions:

| What looks fine | What is actually happening |
|---|---|
| Encrypt each file when it is uploaded | Same non-determinism as the WAL — **the same binlog encrypted twice gives different bytes** (measured, same size) — so the ciphertext **as archived** is the file's identity and the inventory hashes exactly that. But MySQL has no `archive_command` to hang the encryption on: the mark IS the archiver, so **the mark encrypts** — `docker exec` streams each closed file straight into `age`, and the plaintext never touches the host's disk. |
| The `.age` landed, so the file is archived | The mark can do something the WAL's `archive_command` never could: **decrypt what it just archived and hold the plaintext against the server's own bytes, right now**. Every archived ciphertext is round-trip-proven before the manifest exists — the copy check and the key check are the same act, which is why `mark --recipient` requires `--identity`. |
| Truncation needs the inventory to catch, like everything else here | The measured lie that anchors the plain binlog remote — **truncation at an event boundary decodes clean, rc 0, stderr empty** — is exactly what authenticated encryption kills: a `.age` cut *anywhere* (25%, 50%, 90%, and exactly at a chunk boundary — all measured) dies loudly at decrypt. **Encryption hands the binlog archive the noisy truncation it never had.** The WAL kept its exact-size gate through encryption; binlog sizes vary by nature, so here the loudness is pure gain. |
| Encrypted means safe to trust | **A failed stream piped into age is still a valid ~200-byte `.age` that decrypts to nothing, rc 0** (measured) — encryption protects the bytes, not their meaning. `PIPESTATUS` names which side of the pipe broke, and the round trip against the server's bytes catches what no ciphertext self-check can. |
| Ship the key with the backup, or verify can't run | `push` and `pull` **refuse** a key — they move opaque names and opaque hashes, and the remote audits the chain by ciphertext hash without ever holding a key. Only `verify` takes `--identity` (and refuses to run without it — no key, no drill, no comforting green tick); the wrong key is named at the first artefact it fails to open, and the chain decrypts only **inside** the throwaway, in a filesystem that dies with the drill. |

## How it works

**`backup.sh --engine postgres|mysql|files`** dumps with the engine's own tool
(`pg_dump -Fc`; `mysqldump --single-transaction --routines --events
--triggers`; `tar -cz .` — the dot, never the dotfile-dropping glob) and writes
a **manifest** beside the artefact: size, sha256, the
engine, and one content fingerprint per table (or file) — the yardstick for later.
`verify.sh` reads the engine back from the manifest, so a Postgres backup can
never be accidentally "verified" as MySQL. Everything engine-specific lives in
a `lib/<engine>.sh` module behind one `eng_*` interface — neither script
contains an engine name, and a bats test asserts every module implements the
complete interface, so a missing function cannot surface halfway through a
restore. (`offsite.sh` gets the same treatment on its axis: every
transport-specific line lives in a `lib/remote_*.sh` module behind the `rem_*`
interface.)

`backup.sh` refuses to leave a plausible-looking artefact behind: a dump that
fails is deleted, an artefact below a floor size is deleted, and an archive
that does not parse (`pg_restore --list`; for MySQL, the header plus the
trailing `Dump completed` line an interrupted dump never writes) is deleted.
`--keep N` prunes old backups, counting only complete artefact+manifest pairs.

**`verify.sh`** runs six gates, in cost order:

1. **Size and checksum** against the manifest — separates "born broken" from
   "rotted on disk", two different problems with different fixes.
2. **A genuinely clean target.** Restoring over existing data makes `pg_restore`
   report *already exists* and leaves an ambiguous mixture (measured), so
   verification always uses a fresh container and aborts if it is not empty.
3. **The restore**, whose exit code is *recorded but not trusted* — see the
   truncated-dump finding above.
4. **Content, table by table**, plus a guard that the restored copy has no
   **extra** tables (that guard earned its keep on day one: it caught a bug in
   this repo's own manifest writer).
5. **Schema objects**, per class, by count and definition — the half of the
   database a row comparison cannot see.
6. **Can the application actually write to it?** Last on purpose, because it
   modifies the restored copy: every Postgres sequence must produce a usable
   next value, and every MySQL `AUTO_INCREMENT` counter must sit above the
   largest value its column actually holds. A counter restored *behind* its
   data makes the next `INSERT` collide with the primary key — every row
   present, and the application broken on its first write.

Gates 4–6 live in `lib/common.sh` and are shared with `pitr.sh verify`, so a
point-in-time recovery is measured with the same yardstick as a restored dump
— and `verify.sh` refuses a `pitr-*` manifest outright, pointing at `pitr.sh`,
for the same reason it refuses to verify a Postgres backup as MySQL.

## How it's tested

- **`test/e2e.sh [--engine postgres|mysql|files] [--encrypted]`** — seed →
  back up → **destroy the source** (`docker rm -f`, or `rm -rf` of the tree) →
  restore into a fresh instance → compare. The
  destruction is the point: it removes the possibility of accidentally
  verifying against the original.
- **`test/negative.sh [--engine postgres|mysql|files]`** — eleven cases *per
  engine*:
  truncated archive, un-runnable dump, post-backup corruption, matching row
  count with different content, **everything restored with the silent loss
  intact** (Postgres: a `pg_dump -t` tables-only artefact; MySQL: a dump made
  with mysqldump's own **default** invocation, rejected for exactly
  `routines - expected 2, restored copy has 0`; files: a `tar czf backup.tgz *`
  artefact, rejected for exactly `.env - file absent`), five encryption cases (real
  ciphertext on disk with no plaintext header in the clear, verification
  refusing without a key, the **wrong** key failing at decryption and told
  apart from a bad archive, a truncated ciphertext that cannot decrypt at all,
  and a good encrypted backup that restores end to end), and a good plain
  backup that must still pass (a suite that only rejects is as useless as one
  that only accepts). Each case takes its **own fresh backup**, because sharing
  one artefact let case 4 inherit case 1's edits and quietly test the wrong
  gate, and a counter-based directory name let case 5 read case 4's corrupted
  file.
- **`test/seed.sh`** — ONE seed shared by both suites, per engine, after a
  negative case went green against a different shape and proved nothing. The
  database engines get the same things to lose: two tables (PK, UNIQUE, CHECK,
  FK), an index, a view, routines and a trigger. The files tree gets what a
  naive file backup is measured to lose: a dotfile, a 100 KB blob, a setgid
  shared directory, a group-writable file, a symlink and an empty directory.
- **`test/offsite.sh [--remote-kind ssh|dir]`** — the fire drill: back up,
  push, **delete the source AND every local backup**, pull, verify — the
  pulled copy alone must restore. Then each measured off-site lie, caught:
  crashed uploads named by `check` and invisible to `pull`; in-place rot
  failing `check` from the manifest alone, with `pull` refusing to hand the
  corrupt bytes over (and cleaning up what it fetched); a full remote disk
  failing the push with nothing plausible left behind; retention pruning by
  name while the re-uploaded old backup's mtime says "newest"; and the
  encrypted chain through the same fire. The ssh run boots a real sshd in
  Docker (with a 256K tmpfs for the disk-full case); the dir run drives the
  same protocol against a local directory, the mounted-NAS case.
- **`test/pitr.sh [--encrypted]`** — the point-in-time fire drill: seed, base
  backup, mark —
  then commit a **disaster after the mark**, destroy the source, and recover.
  The recovered instant must contain everything the mark saw and **nothing**
  the disaster wrote (recovering "everything" here would be a *failure*: the
  point of PITR is stopping in time). Then each measured archive lie, caught:
  the archiver killed mid-run and named by `check` alone while commits stay
  green; a hole in the chain refused before anything boots; in-place rot in a
  segment caught today by size; a mark predating its base refused in
  milliseconds; squatters and debris named from the directory alone; and,
  after every mutation is undone, the full drill again — a suite that only
  rejects is as useless as one that only accepts.
- **`test/pitr-offsite.sh [--remote-kind ssh|dir] [--encrypted]`** — the
  strongest disaster
  simulated here: mark, push, then lose the **machine** — source container,
  local WAL archive, every local manifest — pull, and the named instant must
  come back exactly. Around it, each measured off-site archive lie as a
  caught case: the second push shipping only what the remote cannot already
  prove; an unpushed mark being unclaimable (pull returns the newest instant
  the remote can *prove*); in-place rot named by `check --remote` from the
  inventory alone, refused and cleaned up by `pull`, and *repaired* by the
  next `push`; and the crashed `.part` upload named for what it is.
- **`test/binlog.sh [--encrypted]`** — the MySQL fire drill: seed, anchored
  dump, mark —
  then a disaster after the mark (archived too, by a second mark), the source
  destroyed, and the replay must reproduce the first instant exactly. Around
  it, each measured binlog lie as a caught case: a mark doctored to stop
  early replays **clean** and is failed by the arrival gate alone; the hole
  and the rot are named before anything boots; the pre-anchor mark is
  refused in milliseconds; and the drill to the second mark proves the
  archived disaster is also a recoverable instant. `--encrypted` runs the
  same drill through age ciphertext end to end — asserting the archive holds
  no plaintext and the seeded rows no longer grep out of it — plus the
  encrypted-only refusals: no key means no drill, and the wrong key is named.
- **`test/binlog-offsite.sh [--remote-kind ssh|dir] [--encrypted]`** — the
  binlog archive's
  own fire drill: push, lose the machine, pull, and verify on nothing but
  the remote's contents — plus the incremental push, the unpushed mark being
  unclaimable, rot at the remote (shapeless here even as truncation —
  measured) named by `check --remote`, refused by `pull` and repaired by the
  next `push`, and the `.part` debris named. `--encrypted` sends the same
  instant as ciphertext the remote never gets a key for.
- **`test/backup.bats`**, **`test/offsite.bats`**, **`test/pitr.bats`** and
  **`test/binlog.bats`** —
  unit tests over argument
  parsing, manifest reading, the schema queries, the `eng_*` and `rem_*`
  interfaces, the WAL-name arithmetic (including the log-number carry a naive
  hex increment gets wrong), the binlog name arithmetic, and the regression
  guards described below.
- CI runs the e2e against **Postgres 17, Postgres 16, MySQL 8.4 and a file
  tree, plain and encrypted** (eight combinations), the negative suite per
  engine, the off-site fire drill over **both remote kinds**, the PITR fire
  drill on **both Postgres majors** (a base backup is bytes from one major
  version, so a recovery is a compatibility promise too), the PITR off-site
  fire drill over **both remote kinds again** — the PITR drills each run
  **plain and encrypted**, because encryption must not change the promise —
  the MySQL binlog fire drill (**plain and encrypted**, for the same reason)
  and its off-site drill over **both remote kinds, plain and encrypted
  again**, and everything
  again on a
  weekly schedule: a backup tool that only works the day you wrote it is not a
  backup tool. `age` is installed in the negative jobs deliberately **without**
  a skip path — a missing tool fails the suite rather than reporting green on
  tests that never ran.

## Thirteen bugs this harness caught in its own code

**The most dangerous one: a fingerprint of nothing.** MySQL has no `t.*` inside
functions, so the Postgres fingerprint query was a syntax error there — an
error swallowed by a `2>/dev/null`, so `eng_table_fingerprint` returned an
**empty string**, and the manifest recorded `"customers": ""`. verify.sh would
have compared `""` against `""` and reported **VERIFIED having checked
nothing**. Caught before the first commit because the fingerprint was printed
and eyeballed; fixed by building the column list from `information_schema`
(with `IFNULL(col,'<NULL>')`, because `CONCAT_WS` *skips* NULLs and
`(1,NULL,'x')` must not hash like `(1,'x',NULL)`) — and by a new guard,
`assert_fingerprint`, that makes a fingerprint that doesn't look like one
**fatal** wherever it appears, at write time and at compare time.

**An ERR trap does not fire inside a function.** backup.sh cleans up a failed
dump with `trap 'rm -f -- "$artefact"' ERR` — and the engine refactor moved the
dump into `eng_dump()`, where, without `set -o errtrace`, the trap silently
never fires. A failed dump left a plausible 0-byte artefact behind again, which
is precisely the promise backup.sh makes it can never happen. Negative case 2
caught it on the first run after the refactor — that case *is* the promise,
mechanised. (`set -E` now lives next to `set -o pipefail` in `lib/common.sh`,
with a comment explaining why removing it is a bug.) The same run also caught a
test helper pinned to a fingerprint format the manifest had outgrown — both now
held down by bats regression tests.

**A shell function cannot return a list.** The recipient flags came from a
helper doing `printf '%s\n%s' -r "$key"` — with no trailing newline, so `read`
**dropped the last line** and `age` was invoked with a bare `-r`. It failed on
the very first encrypted run. Lists belong in arrays; the helper is gone and a
bats guard keeps it gone.

**A negative case that proved nothing.** The schema-loss case was added, went
green, and was worthless: the negative suite's database had a single bare table,
so a tables-only dump had no view, function or trigger to drop and the
comparison trivially matched. A test that cannot fail is not a test. The suite
now seeds the same shape as the e2e, and the case is surgical — data perfect,
schema incomplete. (Its sibling symptom: an assertion grepping for
`OK   customers` never matched, because the real bytes carried colour escapes
between the two. Colour is now suppressed when stdout is not a terminal.)

**A function called as `$(fn)` runs in a subshell.** The negative suite gave
each case its own backup directory using an incrementing counter — except
`M=$(fresh_backup)` runs the function in a subshell, so the counter never
advanced in the parent. Every case shared one directory and `find | head -1`
handed case 5 the *corrupted* manifest from case 4. It passed locally purely
because `find` happened to return the newer file first; CI ordered them the
other way. Non-determinism in the test suite of a tool about non-determinism.
Fixed with `mktemp -d`, which needs no shared state.

**The Postgres image starts two servers.** The first CI run failed with
`FATAL: the database system is shutting down` and `database "app" does not
exist`, having passed locally minutes earlier. The official image boots a
*temporary* server on the unix socket to run `initdb`, **shuts it down**, and
then starts the real one — and `pg_isready` happily answers "accepting
connections" during that temporary phase. Anything that trusts it races the
shutdown. `wait_for_postgres` now requires a **real query to succeed three
times in a row**, one second apart: the mid-init shutdown breaks the streak and
the count restarts. Reproduced locally by deleting the cached image first, which
is the only reason the local run had been green — timing, not correctness.

**`docker exec -i` eats a `while read` loop.** `psql_in` originally used
`docker exec -i`, which attaches the caller's stdin to the container — so
calling it inside `while IFS= read -r table; do ... done <<EOF` made psql
swallow the loop's remaining input. The loop ended after one iteration and the
manifest described **1 of 2 tables**. Same family as `ssh` eating a loop's stdin
when you forget `-n`. Caught by the extra-tables guard, now pinned by a bats
regression test.

**A glob in an assignment is literal.** `local pattern="$dir/${db}_"*.dump`
stores the asterisk verbatim; the retention loop only worked by accident through
word splitting. ShellCheck's SC2125 was right, and the glob now goes straight
into the `for` with `nullglob`.

**The same stdin bug, one layer up.** The `docker exec -i` paragraph above ends
by noting it is the same family as ssh eating a loop's stdin when you forget
`-n` — and `offsite.sh` then shipped exactly that: `check` iterates the remote
listing in a `while read` loop and calls the ssh helpers *inside* it, so the
first `rem_get` swallowed every listing line after the first manifest. check
counted one clean pair and exited **0 over a remote full of planted leftovers**
— a verifier blessing what it never looked at, the exact failure this repo
exists to kill. It passed locally because `find` happened to list the planted
files first; CI's order exposed it (non-determinism again — third time this
harness has been caught by it). The fix is the contract the engines already
obey: helpers that do not need stdin must starve it (`ssh -n`; only `rem_put`
reads stdin), pinned by the same kind of bats guard. Writing a lesson down is
not the same as having learned it.

**An absent JSON key killed the whole script, with no message.** `json_str`
ended in a bare `grep`, so a key that was not in the manifest meant rc 1 — and
under `set -e -o pipefail`, `var=$(json_str ...)` **terminates the caller
silently**. The mine was latent in verify.sh all along: its engine fallback
for old schema-1/2 manifests was unreachable code, because reading the absent
`engine` key would have killed the verifier before the fallback could run.
PITR's optional keys stepped on it first. The absence of a key is an *answer*,
not an error — `{ grep ... || true; }`, pinned by bats.

**The cleanup that could not delete its own scratch directory.** The Postgres
image's entrypoint chowns the extracted cluster — *including the mount point
itself* — to its own user, and /tmp's sticky bit forbids unlinking an entry
you no longer own. So the host wiped nothing, and every verify attempt after
the first inherited a dirty scratch. The fix asks the same image to remove
what it created **and hand the directory back** (`chown` to the host user).
Relatedly, measured while building the mutation cases: files the container
archives land `0600` owned by uid 70, so the host can `stat` and `mv` them but
never touch their bytes — every corruption in the harness is committed via
`docker run -u root`, which also preserves inode, owner and mode.

**Sequences come back from recovery up to 32 ahead — by design.** The first
full drill failed its own comparison: every table identical, every sequence's
`last_value` a little *larger* than the mark recorded. `nextval` pre-logs 32
values into WAL per fetch for crash-safety, so an exactly-recovered instant
legitimately shows its counters ahead of the instant. Demanding equality would
fail every correct recovery — the false-alarm failure mode again, MySQL's
rounded-`AUTO_INCREMENT` lesson wearing Postgres clothes. The mark therefore
records sequence *names* only, and usability is what the writable probe
proves.

**The same bytes recovered on one transport and died on the other.** The
PITR off-site fire drill passed over ssh and failed over a directory remote —
`could not locate required checkpoint record`, a recovery that never got to
read its first segment. A dir remote's `cp` carries the source's `0600` mode
through push and pull, and the throwaway instance's postgres user cannot read
a `0600` file owned by the host; ssh's `cat >` redirect mints fresh `0644`
files and sails through. Same bytes, same hashes, different mode bits — the
fourth time a transport- or order-dependent difference has been caught by
running everything on more than one of them. `pull` now sets the mode
explicitly, so both transports tell the same story.

## Scope

PostgreSQL and MySQL/MariaDB via Docker containers, plain directory trees via
`--engine files`, off-site copies over ssh or onto a mounted disk, and
point-in-time recovery for both database engines — Postgres over a WAL
archive and MySQL over archived binlogs, both archives optionally encrypted
end to end, both pushed off-site, audited at the remote, and pulled back
onto a bare machine: contents, schema objects (or file metadata), encryption
at rest, whether the restored copy is actually usable, whether the remote
provably holds what was sent, and whether a named instant provably comes back.
Deliberately not here yet: binlog PITR under GTID mode (measured with the
8.4 default, `gtid_mode=OFF`) — it changes the replay rules, so it will be
measured first, like everything else here. On the roadmap, not pretended to
work today.

Sibling in spirit of [debian-hardening](https://github.com/DannyRuizB/debian-hardening),
[debian-hardening-ansible](https://github.com/DannyRuizB/debian-hardening-ansible)
and [windows-hardening](https://github.com/DannyRuizB/windows-hardening): a
claim is worth what its test harness proves.

## License

MIT
