# backup-verify

[![ci](https://github.com/DannyRuizB/backup-verify/actions/workflows/ci.yml/badge.svg)](https://github.com/DannyRuizB/backup-verify/actions/workflows/ci.yml)

**A backup nobody has restored is not a backup, it is a hope.** This repo takes
PostgreSQL and MySQL/MariaDB backups and then *proves they restore* — by
restoring them into a throwaway instance and comparing the result against the
source, table by table.

CI does the thing everyone talks about and almost nobody automates: it seeds a
real server, backs it up, **destroys the database**, restores from the
artefact, and checks the restored copy is identical. Then it does it again with
a suite of deliberately broken backups to prove the checks actually catch them
— on both engines.

```bash
./backup.sh --container my-postgres --db app --out ./backups --keep 7
./verify.sh --manifest ./backups/app_20260803T120447Z.json

# MySQL / MariaDB: same promise, same gates
./backup.sh --engine mysql --container my-mysql --db app --out ./backups
# (verify.sh reads the engine from the manifest - no flag needed)

# encrypted at rest, and proven to decrypt at backup time:
age-keygen -o key.txt
./backup.sh --container my-postgres --db app --recipient age1... --identity key.txt
./verify.sh --manifest ./backups/app_....json --identity key.txt
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

## How it works

**`backup.sh --engine postgres|mysql`** dumps with the engine's own tool
(`pg_dump -Fc`; `mysqldump --single-transaction --routines --events
--triggers`) and writes a **manifest** beside the artefact: size, sha256, the
engine, and one content fingerprint per table — the yardstick for later.
`verify.sh` reads the engine back from the manifest, so a Postgres backup can
never be accidentally "verified" as MySQL. Everything engine-specific lives in
`lib/postgres.sh` and `lib/mysql.sh` behind one `eng_*` interface — neither
script contains an engine name, and a bats test asserts every module implements
the complete interface, so a missing function cannot surface halfway through a
restore.

`backup.sh` refuses to leave a plausible-looking artefact behind: a dump that
fails is deleted, an artefact below a floor size is deleted, and an archive
that does not parse (`pg_restore --list`; for MySQL, the header plus the
trailing `Dump completed` line an interrupted dump never writes) is deleted.
`--keep N` prunes old backups, counting only complete artefact+manifest pairs.

**`verify.sh`** runs four gates, in cost order:

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

## How it's tested

- **`test/e2e.sh [--engine postgres|mysql] [--encrypted]`** — seed → back up →
  **`docker rm -f` the source** → restore into a fresh instance → compare. The
  destruction is the point: it removes the possibility of accidentally
  verifying against the original.
- **`test/negative.sh [--engine postgres|mysql]`** — eleven cases *per engine*:
  truncated archive, un-runnable dump, post-backup corruption, matching row
  count with different content, **every row restored with the schema silently
  gone** (Postgres: a `pg_dump -t` tables-only artefact; MySQL: a dump made
  with mysqldump's own **default** invocation, rejected for exactly
  `routines - expected 2, restored copy has 0`), five encryption cases (real
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
  negative case went green against a different shape and proved nothing. Every
  engine gets the same things to lose: two tables (PK, UNIQUE, CHECK, FK), an
  index, a view, routines and a trigger.
- **`test/backup.bats`** — 29 unit tests over argument parsing, manifest
  reading, the schema queries, the `eng_*` interface, and the regression guards
  described below.
- CI runs the e2e against **Postgres 17, Postgres 16 and MySQL 8.4, plain and
  encrypted** (six combinations) plus the negative suite per engine, and on a
  weekly schedule: a backup tool that only works the day you wrote it is not a
  backup tool. `age` is installed in the negative jobs deliberately **without**
  a skip path — a missing tool fails the suite rather than reporting green on
  tests that never ran.

## Eight bugs this harness caught in its own code

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

## Scope

PostgreSQL and MySQL/MariaDB, via Docker containers: table contents, schema
objects, encryption at rest, and whether the restored copy can be written to.
Deliberately not here yet: filesystem archives, off-site upload, and
point-in-time recovery with WAL archiving — all on the roadmap, none pretended
to work today.

Sibling in spirit of [debian-hardening](https://github.com/DannyRuizB/debian-hardening),
[debian-hardening-ansible](https://github.com/DannyRuizB/debian-hardening-ansible)
and [windows-hardening](https://github.com/DannyRuizB/windows-hardening): a
claim is worth what its test harness proves.

## License

MIT
