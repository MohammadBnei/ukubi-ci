#!/usr/bin/env bash
# Runs image.yml's own run blocks (extracted with yq, never copied) against
# fixtures. Needs bash, yq v4 and GNU sed (on macOS: gsed is shimmed in).
# Usage: test/check.sh [path/to/image.yml]
set -uo pipefail
WF=${1:-$(dirname "$0")/../.github/workflows/image.yml}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
if ! sed --version >/dev/null 2>&1; then ln -s "$(command -v gsed)" "$T/bin/sed"; fi
export PATH="$T/bin:$PATH"
fails=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fails=$((fails + 1)); }
step() { yq ".jobs.$1.steps[] | select(.name == \"$2\") | .run" "$WF"; }

# 1. The build job runs on the build-runner LXC: sudo is buildah-only there
#    and the box has no yq or node (build-runner-configure.yml:187-195, :327).
step_runs=$(yq '.jobs.build.steps[].run | select(. != null)' "$WF")
if grep -oE 'sudo( +[^ ]+){0,2}' <<<"$step_runs" | grep -vqE '^sudo -n buildah$'; then
  bad "build job: every sudo is 'sudo -n buildah'"
else ok "build job: every sudo is 'sudo -n buildah'"; fi
if grep -qwE 'yq|node|npx|apt-get' <<<"$step_runs"; then
  bad "build job: no yq/node/apt-get on the LXC"
else ok "build job: no yq/node/apt-get on the LXC"; fi

# 2. The pull_request refusal: an allowlist of GitHub-hosted ubuntu-* labels.
step guard "Refuse a non-GitHub-hosted runner on pull_request" > "$T/pr.sh"
[ -s "$T/pr.sh" ] || { echo "FAIL extract guard block"; exit 1; }
pr() { # want_rc event runs-on name
  local rc=0; EVENT=$2 RUNS_ON=$3 bash "$T/pr.sh" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$1" ]; then ok "pr guard: $4"; else bad "pr guard: $4 (rc=$rc)"; fi
}
pr 0 pull_request '["ubuntu-latest"]'             "PR on ubuntu-latest passes"
pr 0 push '["self-hosted","ukubi-build"]'         "push on self-hosted passes"
pr 0 pull_request '["ubuntu-24.04"]'              "PR on ubuntu-24.04 passes"
pr 1 pull_request '["self-hosted","ukubi-build"]' "PR on self-hosted refused"
pr 1 pull_request '["ukubi-build"]'               "PR on a bare self-hosted label refused"
pr 1 pull_request '["Self-Hosted","ukubi-build"]' "PR on mixed-case Self-Hosted refused"
pr 1 pull_request '["ubuntu-latest","ukubi-build"]' "PR mixing ubuntu and a self-hosted label refused"
pr 1 pull_request '[]'                            "PR on an empty list refused"
pr 1 pull_request '"ubuntu-latest"'               "PR on a non-list refused"
pr 0 workflow_dispatch '["ukubi-build"]'          "dispatch on a bare self-hosted label passes"

# 3. The deploy bump. Each case: name, values-key, expected rc, expected
#    error substring (or ""), file content; TAG is always 0123456789ab.
step deploy "Bump the pinned image tag" > "$T/bump.sh"
[ -s "$T/bump.sh" ] || { echo "FAIL extract bump block"; exit 1; }
bump() { # name key want_rc want_msg content
  local d="$T/case" out rc; rm -rf "$d"; mkdir -p "$d"; [ "$5" = - ] || printf '%s' "$5" > "$d/values.yaml"
  out=$(cd "$d" && TAG=0123456789ab VALUES_FILE=values.yaml VALUES_KEY=$2 bash "$T/bump.sh" 2>&1); rc=$?
  if [ "$rc" != "$3" ]; then bad "bump $1: rc=$rc want $3 ($out)"; return; fi
  if [ -n "$4" ] && [[ "$out" != *"$4"* ]]; then bad "bump $1: want '$4', got '$out'"; return; fi
  if [ "$3" = 0 ] && [ "$(yq "$2" "$d/values.yaml")" != 0123456789ab ]; then bad "bump $1: tag not set"; return; fi
  ok "bump $1"
}
bump "head comments, blank lines, trailing comment" .image.tag 0 "" '# Values for the app.
# More head comment.

replicaCount: 1

image:
  repository: registry.bnei.lan:5000/app
  tag: "3e351f7a2867" # CI rewrites this line

service:
  port: 8080
'
bump "already at TAG stays green (re-run)" .image.tag 0 "already 0123456789ab" 'image:
  tag: "0123456789ab"
'
bump "depth-2 key .api.image.tag (indent derived from the key)" .api.image.tag 0 "" 'api:
  image:
    tag: "aaaaaaaaaaaa"
worker:
  tag: "bbbbbbbbbbbb"
'
# Guard: exactly one line changed (a second same-named key at the same depth).
bump "second tag: under another parent refused" .image.tag 1 "must change exactly one line" 'image:
  tag: "aaaaaaaaaaaa"
sidecar:
  tag: "bbbbbbbbbbbb"
'
# Guard: exactly one line changed (unquoted value: the sed matches nothing).
bump "unquoted value refused" .image.tag 1 "must change exactly one line" 'image:
  tag: aaaaaaaaaaaa
'
# Guard: read-back (the sed changes one line, but not the key asked for).
bump "one line changed but not values-key refused" .image.tag 1 "did not land" 'sidecar:
  tag: "bbbbbbbbbbbb"
image:
  tag: aaaaaaaaaaaa
'
bump "missing file refused" .image.tag 1 "not found" -

echo "failures: $fails"
[ "$fails" = 0 ]
