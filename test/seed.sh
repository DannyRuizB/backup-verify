#!/usr/bin/env bash
# =============================================================================
# Seed functions shared by e2e.sh and negative.sh - ONE definition per engine,
# on purpose. The two suites once seeded different shapes, and the difference
# made negative case 6 pass while proving NOTHING (a tables-only dump of a
# database with one bare table has no view or function to lose). Sharing the
# seed makes "the negative suite exercises the same shape as the e2e"
# structural instead of a promise.
#
# Every engine gets the same things to lose: two tables (PK, UNIQUE, CHECK,
# FK), an extra index, a view, TWO routines and a trigger - because the
# measured failure modes (`pg_dump -t`, `mysqldump` without --routines) drop
# exactly the objects a row count never sees.
# =============================================================================

seed_postgres() {
    local container="$1" db="$2"
    docker exec -i "$container" psql -q -v ON_ERROR_STOP=1 -U postgres -d "$db" <<'SQL'
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
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 1000;
CREATE FUNCTION order_label(o orders) RETURNS text AS
  $$ SELECT 'order #' || o.id $$ LANGUAGE sql;
CREATE FUNCTION order_count() RETURNS bigint AS
  $$ SELECT count(*) FROM orders $$ LANGUAGE sql;
INSERT INTO customers (name, email)
  SELECT 'cliente ' || g, 'c' || g || '@example.com' FROM generate_series(1,500) g;
INSERT INTO orders (customer_id, total, note)
  SELECT (g % 500) + 1, (g * 1.37)::numeric(10,2), 'pedido ' || g FROM generate_series(1,2000) g;
CREATE FUNCTION touch_note() RETURNS trigger AS
  $$ BEGIN NEW.note := coalesce(NEW.note, 'pedido sin nota'); RETURN NEW; END $$ LANGUAGE plpgsql;
CREATE TRIGGER orders_note BEFORE INSERT ON orders
  FOR EACH ROW EXECUTE FUNCTION touch_note();
SQL
}

seed_mysql() {
    local container="$1" db="$2"
    # The mysql client aborts on the first error in batch mode, so no
    # ON_ERROR_STOP analogue is needed. Single-statement routine bodies on
    # purpose: they need no DELIMITER games inside a heredoc.
    docker exec -i -e MYSQL_PWD=verify "$container" mysql -uroot "$db" <<'SQL'
CREATE TABLE customers (
  id int AUTO_INCREMENT PRIMARY KEY,
  name varchar(100) NOT NULL,
  email varchar(100) UNIQUE,
  created_at datetime DEFAULT '2026-01-01 00:00:00'
);
CREATE TABLE orders (
  id int AUTO_INCREMENT PRIMARY KEY,
  customer_id int,
  total decimal(10,2) CHECK (total >= 0),
  note varchar(100),
  -- Table-level on purpose: MySQL PARSES an inline `REFERENCES` on a column
  -- and silently IGNORES it - no constraint is created, no warning is given.
  FOREIGN KEY (customer_id) REFERENCES customers(id)
);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 1000;
-- TWO routines, because this is exactly what a default mysqldump silently
-- drops (measured: one function and one procedure in, zero out, exit code 0).
CREATE FUNCTION order_label(oid int) RETURNS varchar(20) DETERMINISTIC
  RETURN CONCAT('order #', oid);
CREATE PROCEDURE count_orders() SELECT COUNT(*) FROM orders;
CREATE TRIGGER orders_note BEFORE INSERT ON orders
  FOR EACH ROW SET NEW.note = IFNULL(NEW.note, 'pedido sin nota');
SET SESSION cte_max_recursion_depth = 5000;
INSERT INTO customers (name, email)
  WITH RECURSIVE g(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM g WHERE n < 500)
  SELECT CONCAT('cliente ', n), CONCAT('c', n, '@example.com') FROM g;
INSERT INTO orders (customer_id, total, note)
  WITH RECURSIVE g(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM g WHERE n < 2000)
  SELECT (n % 500) + 1, ROUND(n * 1.37, 2), CONCAT('pedido ', n) FROM g;
SQL
}

# SQLite gets the same shape to lose, in one file: two tables (PK, UNIQUE,
# CHECK, FK), an extra index, a view and a trigger. SQLite has no stored
# routines, so the "routines" slot is filled by a second view - the point of
# case 6 is a table-scoped dump dropping every VIEW, and two of them prove it
# drops all, not just the first. AUTOINCREMENT on the PKs so the writable gate
# has a counter to check. The argument is the TARGET .db file (created here),
# not a container - the containerless shape the files engine established.
seed_sqlite() {
    local dbfile="$1"
    sqlite3 "$dbfile" <<'SQL'
PRAGMA foreign_keys=ON;
CREATE TABLE customers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  email TEXT UNIQUE,
  created_at TEXT DEFAULT '2026-01-01T00:00:00Z'
);
CREATE TABLE orders (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_id INTEGER REFERENCES customers(id),
  total NUMERIC CHECK (total >= 0),
  note TEXT
);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 1000;
CREATE VIEW order_totals AS SELECT customer_id, sum(total) AS spent FROM orders GROUP BY customer_id;
CREATE TRIGGER orders_note AFTER INSERT ON orders
  WHEN NEW.note IS NULL
  BEGIN UPDATE orders SET note = 'pedido sin nota' WHERE id = NEW.id; END;
WITH RECURSIVE g(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM g WHERE n < 500)
  INSERT INTO customers (name, email) SELECT 'cliente '||n, 'c'||n||'@example.com' FROM g;
WITH RECURSIVE g(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM g WHERE n < 2000)
  INSERT INTO orders (customer_id, total, note) SELECT (n % 500) + 1, round(n * 1.37, 2), 'pedido '||n FROM g;
SQL
}

# The files tree gets the same treatment: everything a naive file backup is
# MEASURED to lose. A dotfile (the glob invocation drops it), a 100KB blob
# (a truncated archive leaves a partial copy with a plausible size), a
# group-writable file and a setgid shared directory (extraction without -p
# strips both), a symlink (a copy-based tool turns it into a second file) and
# an empty directory (glob backups skip it).
seed_files() {
    local dir="$1"
    mkdir -p "$dir/config" "$dir/data" "$dir/shared" "$dir/empty-dir"
    printf 'DB_PASS=hunter2\nAPI_KEY=sk-not-really\n' > "$dir/.env"
    chmod 600 "$dir/.env"
    printf 'server {\n  listen 80;\n  root /var/www;\n}\n' > "$dir/config/nginx.conf"
    # Deterministic bulk content: big enough that a half archive cuts through
    # it, and not from /dev/urandom so reruns are comparable.
    seq 1 20000 > "$dir/data/blob.bin"
    printf '#!/bin/sh\necho running\n' > "$dir/run.sh"
    chmod 755 "$dir/run.sh"
    printf 'shared notes\n' > "$dir/shared/group-file"
    chmod 664 "$dir/shared/group-file"
    chmod 2775 "$dir/shared"
    ln -s config/nginx.conf "$dir/current.conf"
}
