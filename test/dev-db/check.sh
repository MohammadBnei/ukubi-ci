#!/usr/bin/env bash
# Assertions for the dev-db self-test, run after an action step has exported
# DATABASE_URL. Usage: check.sh seeded|fresh
set -euo pipefail
q() { psql "$DATABASE_URL" -Atqc "$1"; }
n=$(q 'SELECT count(*) FROM t')
case "$1" in
  seeded) # the seed-command's row is there; dirty the database for the recreate check
    [ "$n" = 1 ] || { echo "FAIL expected 1 seeded row, got $n"; exit 1; }
    q "INSERT INTO t VALUES (2)" ;;
  fresh) # recreated from the template: the dirty row is gone
    [ "$n" = 1 ] || { echo "FAIL expected 1 row after recreate, got $n"; exit 1; } ;;
  *) echo "usage: check.sh seeded|fresh"; exit 2 ;;
esac
# The TTL sweeper's own test: a ttl that parses as timestamptz and lies ahead.
exp=$(q "SELECT (shobj_description(oid,'pg_database')::jsonb->>'ttl')::timestamptz > now() FROM pg_database WHERE datname=current_database()")
[ "$exp" = t ] || { echo "FAIL ttl comment missing or in the past: '$exp'"; exit 1; }
su=$(q "SELECT rolsuper FROM pg_roles WHERE rolname = current_user")
[ "$su" = f ] || { echo "FAIL the test database's role is a superuser"; exit 1; }
echo "ok   $1 (rows=$n, ttl ahead, not superuser)"
