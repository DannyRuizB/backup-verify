#!/usr/bin/env bash
# =============================================================================
# The honest cycle: seed a real Postgres, back it up, DESTROY it, restore into
# a fresh instance and compare. If this passes, the backup restores - not
# "looks fine", restores.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/common.sh

SRC=bv-e2e-src
OUT=$(mktemp -d)
IMAGE="${BV_IMAGE:-postgres:17-alpine}"
# --encrypted runs the SAME cycle through age: the point is that encryption
# changes nothing about the promise. A backup you cannot decrypt is not a
# backup, so the encrypted path has to survive the same destruction test.
ENCRYPTED=0
[ "${1:-}" = "--encrypted" ] && ENCRYPTED=1

cleanup() { docker rm -f "$SRC" >/dev/null 2>&1 || true; rm -rf "$OUT"; }
trap cleanup EXIT

log "booting the source database"
docker rm -f "$SRC" >/dev/null 2>&1 || true
docker run -d --name "$SRC" -e POSTGRES_PASSWORD=e2e -e POSTGRES_DB=app "$IMAGE" >/dev/null
wait_for_postgres "$SRC"

log "seeding deterministic data"
docker exec -i "$SRC" psql -q -v ON_ERROR_STOP=1 -U postgres -d app <<'SQL'
CREATE TABLE customers (
  id serial PRIMARY KEY,
  name text NOT NULL,
  email text UNIQUE,
  created_at timestamptz DEFAULT '2026-01-01T00:00:00Z'
);
CREATE TABLE orders (
  id serial PRIMARY KEY,
  customer_id int REFERENCES customers(id),
  total numeric(10,2) CHECK (total >= 0),
  note text
);
-- Schema objects on purpose: a restore can bring back every row and drop all
-- of these (measured with `pg_restore -t`), so the e2e must have some to lose.
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 1000;
CREATE FUNCTION order_label(o orders) RETURNS text AS
  $$ SELECT 'order #' || o.id $$ LANGUAGE sql;
INSERT INTO customers (name, email)
  SELECT 'cliente ' || g, 'c' || g || '@example.com' FROM generate_series(1,500) g;
INSERT INTO orders (customer_id, total, note)
  SELECT (g % 500) + 1, (g * 1.37)::numeric(10,2), 'pedido ' || g FROM generate_series(1,2000) g;
SQL
ok "seeded: $(psql_in "$SRC" app 'SELECT count(*) FROM customers;' | tr -d '\n') customers, $(psql_in "$SRC" app 'SELECT count(*) FROM orders;' | tr -d '\n') orders"

KEYFILE=""
if [ "$ENCRYPTED" -eq 1 ]; then
    command -v age >/dev/null 2>&1 || die 'age is not installed - cannot run the encrypted cycle'
    KEYFILE="$OUT/key.txt"
    age-keygen -o "$KEYFILE" 2>/dev/null
    RECIPIENT=$(grep 'public key' "$KEYFILE" | sed 's/.*: //')
    log "BACKUP (encrypted to $RECIPIENT)"
    ./backup.sh --container "$SRC" --db app --out "$OUT" \
        --recipient "$RECIPIENT" --identity "$KEYFILE"
else
    log "BACKUP"
    ./backup.sh --container "$SRC" --db app --out "$OUT"
fi
MANIFEST=$(find "$OUT" -name '*.json' | head -1)
[ -n "$MANIFEST" ] || die 'backup.sh produced no manifest'

# The destruction is the point. A backup nobody has restored is a hope, and the
# only way to stop hoping is to throw the original away first.
log "DESTROYING the source database (this is the whole point)"
docker rm -f "$SRC" >/dev/null
SRC=""
ok 'source is gone - the artefact on disk is now the only copy'

log "VERIFY (restores into a fresh instance and compares)"
if [ "$ENCRYPTED" -eq 1 ]; then
    ./verify.sh --manifest "$MANIFEST" --identity "$KEYFILE" --image "$IMAGE"
else
    ./verify.sh --manifest "$MANIFEST" --image "$IMAGE"
fi

if [ "$ENCRYPTED" -eq 1 ]; then
    ok 'e2e passed: the ENCRYPTED backup decrypted and restored identically after the source was destroyed'
else
    ok 'e2e passed: the backup restored identically after the source was destroyed'
fi
