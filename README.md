# backup-verify

[![ci](https://github.com/DannyRuizB/backup-verify/actions/workflows/ci.yml/badge.svg)](https://github.com/DannyRuizB/backup-verify/actions/workflows/ci.yml)

**A backup nobody has restored is not a backup, it is a hope.** This repo takes
PostgreSQL backups and then *proves they restore* — by restoring them into a
throwaway instance and comparing the result against the source, table by table.

CI does the thing everyone talks about and almost nobody automates: it seeds a
real Postgres, backs it up, **destroys the database**, restores from the
artefact, and checks the restored copy is identical. Then it does it again with
five deliberately broken backups to prove the checks actually catch them.

```bash
./backup.sh --container my-postgres --db app --out ./backups --keep 7
./verify.sh --manifest ./backups/app_20260803T120447Z.json
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
order-independent md5 over every column of every row, and compares it to the
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

## How it works

**`backup.sh`** dumps with `pg_dump -Fc` and writes a **manifest** beside the
artefact: size, sha256, server version, and one content fingerprint per table —
the yardstick for later. It refuses to leave a plausible-looking artefact
behind: a dump that fails is deleted, an artefact below a floor size is deleted,
and an archive whose table of contents `pg_restore --list` cannot parse is
deleted. `--keep N` prunes old backups, counting only complete artefact+manifest
pairs.

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
   modifies the restored copy: every sequence must be able to produce a usable
   next value. A sequence restored *behind* its data makes the next `INSERT`
   collide with the primary key — every row present, and the application broken
   on its first write.

## How it's tested

- **`test/e2e.sh`** — seed → back up → **`docker rm -f` the source** → restore
  into a fresh instance → compare. The destruction is the point: it removes the
  possibility of accidentally verifying against the original.
- **`test/negative.sh`** — six cases: truncated archive, un-runnable dump,
  post-backup corruption, matching row count with different content, **every row
  restored with the schema silently gone**, and a good backup that must still
  pass (a suite that only rejects is as useless as one that only accepts). Each
  case takes its **own fresh backup**, because sharing one artefact let case 4
  inherit case 1's edits and quietly test the wrong gate, and a counter-based
  directory name let case 5 read case 4's corrupted file.
- **`test/backup.bats`** — 16 unit tests over argument parsing, manifest
  reading, the schema queries, and two regression guards described below.
- CI runs the e2e against **Postgres 17 and 16**, and on a weekly schedule: a
  backup tool that only works the day you wrote it is not a backup tool.

## Five bugs this harness caught in its own code

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

PostgreSQL, via a Docker container: table contents, schema objects, and whether
the restored copy can be written to. Deliberately not here yet: MySQL/MariaDB,
filesystem archives, encryption at rest (age/gpg), off-site upload, and
point-in-time recovery with WAL archiving — all on the roadmap, none pretended
to work today.

Sibling in spirit of [debian-hardening](https://github.com/DannyRuizB/debian-hardening),
[debian-hardening-ansible](https://github.com/DannyRuizB/debian-hardening-ansible)
and [windows-hardening](https://github.com/DannyRuizB/windows-hardening): a
claim is worth what its test harness proves.

## License

MIT
