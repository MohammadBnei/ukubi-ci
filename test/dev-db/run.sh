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

docker compose -f "$D/compose.yml" up -d --wait >/dev/null 2>&1 || { echo "FAIL compose up"; exit 1; }
sleep 3
: > "$T/env"
# get hash seed [ttl] [files]: the inputs' defaults, then the overrides.
get() {
  env GITHUB_ENV="$T/env" IN_URL=http://localhost:15000 IN_TOKEN= IN_HASH="$1" IN_PATHS="migrations seeds" \
    IN_SEED="$2" IN_PORT=15432 IN_SSLMODE=disable IN_TTL="${3:-2}" IN_KEEP=false IN_TIMEOUT=30 bash "$T/get.sh"
}
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
# Built at once, not reclaimed after timeout-seconds: the trap deleted it.
out=$(get c1 "$seed" 2>&1) && grep -q 'is new; building it' <<<"$out" && (load; bash "$D/check.sh" seeded) >/dev/null \
  && ok "cancelled seed frees the template" || bad "cancelled seed wedged the template: $out"

# 4c. A builder killed outright (no trap runs) is reclaimed by the next job after timeout-seconds.
get k1 "sleep 60" >/dev/null 2>&1 & p=$!
sleep 2; pkill -KILL -f "$T/get.sh"; wait "$p" 2>/dev/null
: > "$T/env"
out=$(env GITHUB_ENV="$T/env" IN_URL=http://localhost:15000 IN_TOKEN= IN_HASH=k1 IN_PATHS=x IN_SEED="$seed" IN_PORT=15432 IN_SSLMODE=disable IN_TTL=2 IN_KEEP=false IN_TIMEOUT=5 bash "$T/get.sh" 2>&1) \
  && grep -q 'discarding it and building it here' <<<"$out" && ok "killed builder reclaimed after timeout" || bad "killed builder: $out"

# 4d. Two repos with the same template-hash get different templates.
key_of() { GITHUB_REPOSITORY=$1 get r1 true 2>/dev/null | sed -n 's/.*ready (template \([0-9a-f]*\),.*/\1/p'; }
k_a=$(key_of a/x); k_b=$(key_of b/x)
[ -n "$k_a" ] && [ -n "$k_b" ] && [ "$k_a" != "$k_b" ] && ok "repo is part of the template key" || bad "repo key: '$k_a' '$k_b'"

# 5. Default hash from files; a changed file changes the template.
mkdir "$T/w" && ( cd "$T/w" && mkdir migrations && echo a > migrations/1.sql
  h1=$(GITHUB_ENV="$T/e1" IN_URL=http://localhost:15000 IN_TOKEN= IN_HASH= IN_PATHS=migrations IN_SEED=true IN_PORT=15432 IN_SSLMODE=disable IN_TTL=0 IN_KEEP=false IN_TIMEOUT=30 bash "$T/get.sh" >/dev/null 2>&1; sed -n 's/^DEV_DB_TEMPLATE_HASH=//p' "$T/e1")
  echo b > migrations/1.sql
  h2=$(GITHUB_ENV="$T/e2" IN_URL=http://localhost:15000 IN_TOKEN= IN_HASH= IN_PATHS=migrations IN_SEED=true IN_PORT=15432 IN_SSLMODE=disable IN_TTL=0 IN_KEEP=false IN_TIMEOUT=30 bash "$T/get.sh" >/dev/null 2>&1; sed -n 's/^DEV_DB_TEMPLATE_HASH=//p' "$T/e2")
  [ -n "$h1" ] && [ -n "$h2" ] && [ "$h1" != "$h2" ] ) && ok "file hash changes with content" || bad "file hash"

# 6. keep=true leaves the database; bad inputs fail early.
(load; IN_KEEP=true bash "$T/rel.sh" 2>&1 | grep -q 'leaving database') && ok "keep=true skips recreate" || bad "keep"
get 'bad hash!' true >/dev/null 2>&1 && bad "bad hash accepted" || ok "bad template-hash refused"
env GITHUB_ENV="$T/e3" IN_URL=http://localhost:15000 IN_TOKEN= IN_HASH=x IN_PATHS=x IN_SEED=true IN_PORT=15432 IN_SSLMODE=disable IN_TTL=0 IN_KEEP=true IN_TIMEOUT=5 bash "$T/get.sh" >/dev/null 2>&1 && bad "keep=true with ttl=0 accepted" || ok "keep=true with ttl=0 refused"

echo; [ "$fails" = 0 ] && echo "all dev-db checks passed" || { echo "$fails failed"; exit 1; }
