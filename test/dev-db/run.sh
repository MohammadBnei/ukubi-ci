#!/usr/bin/env bash
# Local run of the dev-db self-test: extracts each action's run block with yq
# (never copied), runs it like a runner would and asserts. Needs docker
# compose, yq v4, curl, jq, psql. Usage: test/dev-db/run.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); A=$D/../../actions
T=$(mktemp -d); fails=0
trap 'docker compose -f "$D/compose.yml" down -v >/dev/null 2>&1; rm -rf "$T"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
yq '.runs.steps[0].run' "$A/dev-db/action.yml" > "$T/get.sh"
yq '.runs.steps[0].run' "$A/dev-db-release/action.yml" > "$T/rel.sh"
[ -s "$T/get.sh" ] && [ -s "$T/rel.sh" ] || { echo "FAIL extract run blocks"; exit 1; }
# The deadline checks (4c, 4e) would wait timeout-seconds' 120 s floor; fast.sh
# is get.sh with only that floor lowered. Everything else runs get.sh itself.
sed 's/"\$timeout" -ge 120 ]/"$timeout" -ge 1 ]/' "$T/get.sh" > "$T/fast.sh"
cmp -s "$T/get.sh" "$T/fast.sh" && { echo "FAIL lower the timeout floor in fast.sh"; exit 1; }

docker compose -f "$D/compose.yml" up -d --wait >/dev/null 2>&1 || { echo "FAIL compose up"; exit 1; }
sleep 3
: > "$T/env"
# get hash seed [ttl]: the inputs' defaults, then the overrides. S=script,
# TO=timeout-seconds, KEEP=keep.
get() {
  env GITHUB_ENV="$T/env" IN_URL=http://localhost:15000 IN_TOKEN= IN_HASH="$1" IN_PATHS="migrations seeds" \
    IN_SEED="$2" IN_PORT=15432 IN_SSLMODE=disable IN_TTL="${3:-2}" IN_KEEP="${KEEP:-false}" IN_TIMEOUT="${TO:-120}" bash "${S:-$T/get.sh}"
}
pgsu() { PGPASSWORD=pgpass psql -h localhost -p 15432 -U postgres -Atqc "$1"; }
load() { set -a; # shellcheck disable=SC1090
  . "$T/env"; set +a; }
release() { (load; IN_TOKEN= IN_KEEP="${1:-false}" bash "$T/rel.sh"); }
# The seed also proves the builder's role (IntegreSQL's manager) is no superuser.
seed='[ "$(psql "$DATABASE_URL" -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname = current_user")" = f ] && psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "CREATE TABLE t(id int); INSERT INTO t VALUES (1)"'

# 1. New template: seed runs, database comes back seeded, expiry written, password masked.
out=$(get t1 "$seed" 2>&1) && (load; bash "$D/check.sh" seeded) >/dev/null && ok "build template, seeded database, expiry comment" || bad "build template: $out"
grep -q '^::add-mask::mgrpass$' <<<"$out" && ok "password masked" || bad "password not masked"
grep -q '^DATABASE_URL=postgres://integresql:mgrpass@localhost:15432/.*?sslmode=disable$' "$T/env" && ok "DATABASE_URL: IntegreSQL's role, host from integresql-url" || bad "DATABASE_URL shape"

# 2. Release recreates: the dirty row is gone on the next checkout; seed must not rerun.
release >/dev/null 2>&1 && ok "release recreate" || bad "release"
: > "$T/env"
out=$(get t1 "exit 1" 2>&1) && (load; bash "$D/check.sh" fresh) >/dev/null && ok "reuse template, seed skipped, clean database" || bad "reuse template: $out"

# 3. Waiter: a second job asks while the first is still seeding, and gets the finished template.
: > "$T/env"
( get w1 "sleep 5; $seed" >/dev/null 2>&1 ) & p=$!
sleep 1
w=$(get w1 "exit 1" 2>&1) && grep -q 'waiting for it' <<<"$w" && ok "423 waiter polls until ready" || bad "waiter: $w"
wait $p

# 4. Failed seed discards the template so a retry rebuilds.
get f1 "exit 3" >/dev/null 2>&1 && bad "failed seed should fail the step" || ok "failed seed fails the step"
get f1 "$seed" >/dev/null 2>&1 && ok "retry rebuilds after a failed seed" || bad "retry after failed seed"

# 4b. A cancelled seed (SIGTERM, as a runner cancel or step timeout sends) discards the template.
get c1 "sleep 30" >/dev/null 2>&1 & p=$!
sleep 2; pkill -TERM -f "$T/get.sh"; wait "$p" 2>/dev/null
: > "$T/env"
# Built at once: the trap deleted it, so no waiter is left stuck on it.
out=$(get c1 "$seed" 2>&1) && grep -q 'is new; building it' <<<"$out" && (load; bash "$D/check.sh" seeded) >/dev/null \
  && ok "cancelled seed frees the template" || bad "cancelled seed wedged the template: $out"

# 4c. A builder killed outright (SIGKILL: no trap runs) leaves the template
# unfinished. Two waiters at once: both fail at their deadline with the manual
# DELETE, neither deletes anything (the template database is still there).
# After that DELETE by hand, the next run builds it.
get k1 "sleep 60" >/dev/null 2>&1 & p=$!
sleep 2; pkill -KILL -f "$T/get.sh"; wait "$p" 2>/dev/null
( S=$T/fast.sh TO=6 get k1 "$seed" > "$T/wa.out" 2>&1; echo $? > "$T/wa.rc" ) &
( S=$T/fast.sh TO=6 get k1 "$seed" > "$T/wb.out" 2>&1; echo $? > "$T/wb.rc" ) &
wait
recov=$(sed -n 's/.*delete it and rerun: //p' "$T/wa.out")
kkey=$(sed -n 's/.*template \([0-9a-f]\{32\}\) still not final.*/\1/p' "$T/wa.out")
tpl=$(pgsu "SELECT count(*) FROM pg_database WHERE datname LIKE 'integresql_template_%${kkey:-none}%'")
for w in wa wb; do
  [ "$(cat "$T/$w.rc")" != 0 ] && grep -q 'leaves it unfinished. Only if no job is building it' "$T/$w.out" \
    && grep -q "curl -X DELETE http://localhost:15000/api/v1/templates/$kkey" "$T/$w.out" && ! grep -q 'is new; building it' "$T/$w.out" \
    && ok "killed builder: waiter $w fails with the manual DELETE" || bad "killed builder, waiter $w: $(cat "$T/$w.out")"
done
[ -n "$kkey" ] && [ "$tpl" = 1 ] && ok "two waiters delete nothing: template $kkey still there" || bad "template gone after the waiters (key '$kkey', dbs $tpl)"
[ -n "$recov" ] && eval "$recov -sS -o /dev/null -w '%{http_code}'" | grep -q 204 && : > "$T/env" \
  && out=$(get k1 "$seed" 2>&1) && grep -q 'is new; building it' <<<"$out" && (load; bash "$D/check.sh" seeded) >/dev/null \
  && ok "after the manual DELETE the next run builds" || bad "manual recovery ($recov): $out"

# 4f. A PUT that lands server-side but looks failed here (the reviewer's
# shim: real PUT, then curl exit 28 and 000 after 4 s). The builder must not
# delete the now-final template: the waiter's database survives, the builder
# fails with the recovery hint, and no "discarded" line appears.
mkdir -p "$T/bin"; real_curl=$(command -v curl)
cat > "$T/bin/curl" <<SH
#!/bin/bash
for a in "\$@"; do [ "\$a" = PUT ] && put=1; done
if [ -n "\${put:-}" ]; then "$real_curl" "\$@" >/dev/null; sleep 4; echo -n 000; exit 28; fi
exec "$real_curl" "\$@"
SH
chmod +x "$T/bin/curl"
: > "$T/env"
( PATH="$T/bin:$PATH" get l1 "sleep 3; $seed" > "$T/l1.out" 2>&1; echo $? > "$T/l1.rc" ) &
sleep 1
w=$(get l1 "exit 1" 2>&1); wrc=$?
wait
[ "$wrc" = 0 ] && [ "$(cat "$T/l1.rc")" != 0 ] && grep -q 'finalizing template .* returned 000; it may be final' "$T/l1.out" \
  && ! grep -q discarded "$T/l1.out" && (load; bash "$D/check.sh" seeded) >/dev/null \
  && ok "lost PUT answer: no delete, the waiter's database survives" || bad "lost PUT answer (waiter rc=$wrc): $(cat "$T/l1.out") / $w"

# 4d. Two repos with the same template-hash get different templates.
key_of() { GITHUB_REPOSITORY=$1 get r1 true 2>/dev/null | sed -n 's/.*ready (template \([0-9a-f]*\),.*/\1/p'; }
k_a=$(key_of a/x); k_b=$(key_of b/x)
[ -n "$k_a" ] && [ -n "$k_b" ] && [ "$k_a" != "$k_b" ] && ok "repo is part of the template key" || bad "repo key: '$k_a' '$k_b'"

# 4e. A FINALIZED template whose pool is all handed out answers GET with 500
# "timeout when waiting for ready db", not "unexpected template state"
# (compose.yml: max pool 3, minimal lifetime 10 min, get timeout 3 s). The
# waiter keeps polling, fails at its deadline and never deletes the template,
# which would drop the three databases other jobs hold.
for i in 1 2 3; do : > "$T/env"; get x1 "$seed" >/dev/null 2>&1 || bad "exhaust pool: get $i"; done
xkey=$(sed -n 's/^DEV_DB_TEMPLATE_HASH=//p' "$T/env")
: > "$T/env"
out=$(S=$T/fast.sh TO=8 get x1 "exit 1" 2>&1)
rc=$?
n=$(pgsu "SELECT count(*) FROM pg_database WHERE datname LIKE '%${xkey:-none}%'")
[ "$rc" != 0 ] && grep -q 'returned 500 (timeout when waiting for ready db); still polling' <<<"$out" \
  && grep -q 'no database after 8s; last GET returned 500 (timeout when waiting for ready db)' <<<"$out" \
  && ! grep -q discarding <<<"$out" && [ "$n" = 4 ] \
  && ok "exhausted pool: waiter fails without deleting the template" || bad "exhausted pool (rc=$rc dbs=$n): $out"

# 5. Default hash from files; a changed file changes the template.
mkdir "$T/w" && ( cd "$T/w" && mkdir migrations && echo a > migrations/1.sql
  h1=$(GITHUB_ENV="$T/e1" IN_URL=http://localhost:15000 IN_TOKEN= IN_HASH= IN_PATHS=migrations IN_SEED=true IN_PORT=15432 IN_SSLMODE=disable IN_TTL=0 IN_KEEP=false IN_TIMEOUT=120 bash "$T/get.sh" >/dev/null 2>&1; sed -n 's/^DEV_DB_TEMPLATE_HASH=//p' "$T/e1")
  echo b > migrations/1.sql
  h2=$(GITHUB_ENV="$T/e2" IN_URL=http://localhost:15000 IN_TOKEN= IN_HASH= IN_PATHS=migrations IN_SEED=true IN_PORT=15432 IN_SSLMODE=disable IN_TTL=0 IN_KEEP=false IN_TIMEOUT=120 bash "$T/get.sh" >/dev/null 2>&1; sed -n 's/^DEV_DB_TEMPLATE_HASH=//p' "$T/e2")
  [ -n "$h1" ] && [ -n "$h2" ] && [ "$h1" != "$h2" ] ) && ok "file hash changes with content" || bad "file hash"

# 6. keep=true leaves the database; bad inputs fail early.
: > "$T/env"; get kp true >/dev/null 2>&1
(load; IN_KEEP=true bash "$T/rel.sh" 2>&1 | grep -q 'leaving database') && ok "keep=true skips recreate" || bad "keep"
# refused INPUT EXPECTED-ERROR CMD...: the step fails with that error.
refused() { local name=$1 want=$2 o; shift 2
  o=$("$@" 2>&1) && { bad "$name accepted"; return; }
  grep -q "$want" <<<"$o" && ok "$name refused" || bad "$name: $o"; }
: > "$T/env"
refused "bad template-hash" 'template-hash must match' get 'bad hash!' true
KEEP=true refused "keep=true with ttl=0" 'keep=true needs ttl above 0' get x true 0
KEEP=true refused "keep=true with ttl=00" 'keep=true needs ttl above 0' get x true 00
TO=119 refused "timeout-seconds 119" 'timeout-seconds must be at least 120' get x true

# 7. IntegreSQL not up yet (000, as on a runner whose service still waits for
# its roles): POST is retried until it answers. Last: the restart drops
# IntegreSQL's in-memory templates.
docker compose -f "$D/compose.yml" stop integresql >/dev/null 2>&1
: > "$T/env"
( get p1 "$seed" > "$T/p1.out" 2>&1 ) & p=$!
sleep 4; docker compose -f "$D/compose.yml" start integresql >/dev/null 2>&1
wait "$p" && grep -q 'IntegreSQL is not up yet, retrying' "$T/p1.out" && (load; bash "$D/check.sh" seeded) >/dev/null \
  && ok "POST retried until IntegreSQL is up" || bad "POST retry: $(cat "$T/p1.out")"

echo; [ "$fails" = 0 ] && echo "all dev-db checks passed" || { echo "$fails failed"; exit 1; }
