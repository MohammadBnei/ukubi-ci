#!/usr/bin/env bash
# Runs image.yml's own run blocks (extracted with yq, never copied) against
# fixtures. Needs bash, yq v4 and GNU sed (on macOS: gsed is shimmed in).
# Usage: test/check.sh [path/to/image.yml]
set -uo pipefail
WF=${1:-$(dirname "$0")/../.github/workflows/image.yml}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
if ! sed --version >/dev/null 2>&1; then
  g=$(command -v gsed) || { echo "FAIL need GNU sed (gsed)"; exit 1; }
  ln -s "$g" "$T/bin/sed"
fi
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
pr 1 pull_request_target '["self-hosted","ukubi-build"]' "pull_request_target on self-hosted refused"
pr 0 pull_request_target '["ubuntu-latest"]'      "pull_request_target on ubuntu-latest passes"
pr 0 workflow_dispatch '["ukubi-build"]'          "dispatch on a bare self-hosted label passes"

# 3. The deploy bump. Each case: name, values-key, expected rc, expected
#    error substring (or ""), file content; TAG is 0123456789ab and DIGEST $D
#    unless the optional 6th arg overrides the digest.
D=sha256:$(printf 'a%.0s' {1..64})
step deploy "Bump the pinned image tag" > "$T/bump.sh"
[ -s "$T/bump.sh" ] || { echo "FAIL extract bump block"; exit 1; }
bump() { # name key want_rc want_msg content [digest]
  local dg=${6-$D} want="0123456789ab@${6-$D}"
  local d="$T/case" out rc; rm -rf "$d"; mkdir -p "$d"; [ "$5" = - ] || printf '%s' "$5" > "$d/values.yaml"
  out=$(cd "$d" && TAG=0123456789ab DIGEST=$dg VALUES_FILES=values.yaml VALUES_KEY=$2 bash "$T/bump.sh" 2>&1); rc=$?
  if [ "$rc" != "$3" ]; then bad "bump $1: rc=$rc want $3 ($out)"; return; fi
  if [ -n "$4" ] && [[ "$out" != *"$4"* ]]; then bad "bump $1: want '$4', got '$out'"; return; fi
  if [ "$3" = 0 ] && [ "$(yq "$2" "$d/values.yaml")" != "$want" ]; then bad "bump $1: tag not set"; return; fi
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
bump "already at TAG stays green (re-run)" .image.tag 0 "already 0123456789ab@$D" "image:
  tag: \"0123456789ab@$D\"
"
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
bump "same sha, new digest bumps" .image.tag 0 "" "image:
  tag: \"0123456789ab@sha256:$(printf 'b%.0s' {1..64})\"
"
bump "old bare-sha value bumps to sha@digest" .image.tag 0 "" 'image:
  tag: "0123456789ab"
'
bump "empty digest fails" .image.tag 1 "digest missing or malformed" 'image:
  tag: "x"
' ""
bump "uppercase digest refused" .image.tag 1 "digest missing or malformed" 'image:
  tag: "x"
' "sha256:$(printf 'A%.0s' {1..64})"
bump "63-hex digest refused" .image.tag 1 "digest missing or malformed" 'image:
  tag: "x"
' "sha256:$(printf 'a%.0s' {1..63})"
bump "sha512 digest refused" .image.tag 1 "digest missing or malformed" 'image:
  tag: "x"
' "sha512:$(printf 'a%.0s' {1..64})"

# 3b. Several values files: one commit, a no-op only when every file holds the pin.
step deploy "Commit and push" > "$T/commit.sh"
[ -s "$T/commit.sh" ] || { echo "FAIL extract commit block"; exit 1; }
PIN="0123456789ab@$D"
multi() { # name want_commits files-of-commit(0|1|2) a-tag b-tag
  local d="$T/multi" r="$T/multi-remote.git"; rm -rf "$d" "$r"; mkdir -p "$d"; git init -q --bare -b main "$r"
  printf 'image:\n  tag: "%s"\n' "$4" > "$d/a.yaml"; printf 'image:\n  tag: "%s"\n' "$5" > "$d/b.yaml"
  git -C "$d" init -q -b main; git -C "$d" remote add origin "$r"; git -C "$d" add .
  git -C "$d" -c user.name=t -c user.email=t@t commit -qm init; git -C "$d" push -q origin main
  local out rc; out=$(cd "$d" && TAG=0123456789ab DIGEST=$D VALUES_FILES=$'a.yaml\n b.yaml' VALUES_KEY=.image.tag bash "$T/bump.sh" 2>&1); rc=$?
  [ "$rc" = 0 ] || { bad "multi $1: bump rc=$rc ($out)"; return; }
  [ "$(yq .image.tag "$d/a.yaml")" = "$PIN" ] && [ "$(yq .image.tag "$d/b.yaml")" = "$PIN" ] || { bad "multi $1: a file not pinned"; return; }
  (cd "$d" && IMAGE=app PINNED=$PIN BRANCH=main VALUES_FILES=$'a.yaml\n b.yaml' bash "$T/commit.sh" >/dev/null 2>&1) || { bad "multi $1: commit step failed"; return; }
  local n f; n=$(git -C "$d" rev-list --count HEAD); f=$(git -C "$d" show --format= --name-only HEAD | grep -c yaml)
  if [ "$n" != "$2" ] || { [ "$2" = 2 ] && [ "$f" != "$3" ]; }; then bad "multi $1: $n commits, last touches $f files; want $2, $3"; return; fi
  ok "multi $1"
}
multi "both stale: one commit touching both files" 2 2 aaaaaaaaaaaa bbbbbbbbbbbb
multi "one file already pinned: bump still lands, one commit" 2 1 "$PIN" bbbbbbbbbbbb
multi "first file pinned, second stale (order does not matter)" 2 1 aaaaaaaaaaaa "$PIN"
multi "every file already pinned: no commit" 1 0 "$PIN" "$PIN"
vbump() { # name want_rc want_msg files
  local d="$T/vb"; rm -rf "$d"; mkdir -p "$d"; printf 'image:\n  tag: "x"\n' > "$d/a.yaml"; printf 'image:\n  tag: "x"\n' > "$d/b.yaml"
  local out rc; out=$(cd "$d" && TAG=0123456789ab DIGEST=$D VALUES_FILES=$4 VALUES_KEY=.image.tag bash "$T/bump.sh" 2>&1); rc=$?
  if [ "$rc" != "$2" ] || { [ -n "$3" ] && [[ "$out" != *"$3"* ]]; }; then bad "multi $1: rc=$rc ($out)"; else ok "multi $1"; fi
}
vbump "single file in VALUES_FILES works (values-file alias)" 0 "" a.yaml
vbump "space separated files work" 0 "" "a.yaml b.yaml"
vbump "second file missing refused" 1 "nope.yaml not found" "a.yaml nope.yaml"
vbump "parent-dir path refused" 1 "bad values file" "a.yaml ../x.yaml"
vbump "absolute path refused" 1 "bad values file" "/etc/passwd"
vbump "glob refused, not expanded" 1 "bad values file" "*.yaml"
vbump "empty list refused" 1 "no values file" ""
vbump "blank list refused" 1 "no values file" " "
vbump "leading dash refused" 1 "bad values file" "-a.yaml"
vbump_link() { local d="$T/vb"; mkdir -p "$d"; printf 'image:\n  tag: "x"\n' > "$d/real.yaml"; ln -sf real.yaml "$d/l.yaml"
  local out rc; out=$(cd "$d" && TAG=0123456789ab DIGEST=$D VALUES_FILES=l.yaml VALUES_KEY=.image.tag bash "$T/bump.sh" 2>&1); rc=$?
  if [ "$rc" = 1 ] && [[ "$out" == *symlink* ]]; then ok "multi symlink refused"; else bad "multi symlink: rc=$rc ($out)"; fi; }
vbump_link

# 4. The stale-run guard, against a throwaway remote. History: A, B (built
#    commits), a docs commit, then the bot's bump commit pinning B.
step deploy "Skip a stale run" > "$T/fresh.sh"
[ -s "$T/fresh.sh" ] || { echo "FAIL extract guard block"; exit 1; }
g="$T/g"; git init -q --bare "$g/remote.git" -b main; git clone -q "$g/remote.git" "$g/w" 2>/dev/null
c() { git -C "$g/w" commit -q --allow-empty -m "$1"; git -C "$g/w" rev-parse HEAD; }
git -C "$g/w" config user.name t; git -C "$g/w" config user.email t@t; git -C "$g/w" checkout -q -b main
A=$(c "feat: a"); B=$(c "feat: b"); DOC=$(c "docs: x")
pin() { printf 'image:\n  tag: "%s"\n' "$1" > "$g/w/values.yaml"; }
pin "${B:0:12}@$D"; c "chore(deploy): bump app image" >/dev/null; git -C "$g/w" push -q origin main
guard() { # name built-sha pinned-value want [attempt] [clone]
  local w="${6:-$g/w}" bt=$2; : > "$T/out"; pin "$3"; [ "$w" = "$g/w" ] || cp "$g/w/values.yaml" "$w/"
  (cd "$w" && BUILT=$bt GITHUB_RUN_ATTEMPT=${5:-2} BRANCH=main VALUES_FILES=values.yaml VALUES_KEY=.image.tag GITHUB_OUTPUT="$T/out" bash "$T/fresh.sh" >/dev/null 2>&1)
  if grep -qx "ok=$4" "$T/out"; then ok "guard $1"; else bad "guard $1: $(cat "$T/out")"; fi
}
git clone -q --depth 1 "file://$g/remote.git" "$g/shallow" 2>/dev/null
for w in "$g/w" "$g/shallow"; do
  n=$([ "$w" = "$g/w" ] && echo full || echo shallow)
  guard "[$n] dispatch with HEAD on a bump commit deploys (same commit, new digest)" "$B" "${B:0:12}@sha256:$(printf 'c%.0s' {1..64})" true 2 "$w"
  guard "[$n] docs commit after the built sha deploys" "$DOC" "${B:0:12}@$D" true 2 "$w"
  guard "[$n] old run re-run (attempt 2, pinned is a descendant) skips" "$A" "${B:0:12}@$D" false 2 "$w"
  guard "[$n] fresh dispatch of an old sha (attempt 1) deploys" "$A" "${B:0:12}@$D" true 1 "$w"
  guard "[$n] unknown pin deploys" "$B" "ffffffffffff@$D" true 2 "$w"
done
: > "$T/out"; pin "${B:0:12}@$D"
if (cd "$g/w" && BUILT=abc BRANCH=main VALUES_FILES=values.yaml VALUES_KEY=.image.tag GITHUB_OUTPUT="$T/out" bash "$T/fresh.sh" >"$T/m" 2>&1); then bad "guard malformed BUILT must fail"
elif grep -q "built commit missing or malformed" "$T/m"; then ok "guard malformed BUILT fails closed"; else bad "guard malformed BUILT: $(cat "$T/m")"; fi

# The guard skips when ANY file's pin descends from BUILT, in either order.
printf 'image:\n  tag: "ffffffffffff@%s"\n' "$D" > "$g/w/other.yaml"; pin "${B:0:12}@$D"
gm() { # name want files [built]
  : > "$T/out"
  (cd "$g/w" && BUILT=${4:-$A} GITHUB_RUN_ATTEMPT=2 BRANCH=main VALUES_FILES=$3 VALUES_KEY=.image.tag GITHUB_OUTPUT="$T/out" bash "$T/fresh.sh" >"$T/gm" 2>&1)
  if grep -qx "ok=$2" "$T/out"; then ok "guard $1"; else bad "guard $1: $(cat "$T/out" "$T/gm")"; fi
}
gm "several files: a stale one first skips" false "values.yaml other.yaml"
gm "several files: a stale one second skips" false "other.yaml values.yaml"
gm "several files: no pin descends, deploys" true "other.yaml other.yaml"
gm_fail() { # name files substring
  (cd "$g/w" && BUILT=$A BRANCH=main VALUES_FILES=$2 VALUES_KEY=.image.tag GITHUB_OUTPUT="$T/out" bash "$T/fresh.sh" >"$T/gm" 2>&1) \
    && { bad "guard $1 must fail"; return; }
  if grep -q "$3" "$T/gm"; then ok "guard $1"; else bad "guard $1: $(cat "$T/gm")"; fi
}
gm_fail "blank values-files fails early" " " "values-files is blank"
gm_fail "path with .. refused before reading" "../x.yaml" "bad values file"
gm_fail "leading dash refused" "-x.yaml" "bad values file"
ln -sf values.yaml "$g/w/link.yaml"; gm_fail "symlink refused" "link.yaml" "symlink"; unlink "$g/w/link.yaml"

# 4b. Version inputs sanity in the build job's Check inputs step.
step build "Check inputs" > "$T/ci.sh"
[ -s "$T/ci.sh" ] || { echo "FAIL extract Check inputs"; exit 1; }
cin() { # name want_rc want_msg version-arg version build-args
  local out rc; out=$(IMAGE=app VALUES_KEY=.image.tag VERSION_ARG_ON=$4 VERSION_IN=$5 BUILD_ARGS_IN=$6 bash "$T/ci.sh" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && { [ -z "$3" ] || [[ "$out" == *"$3"* ]]; }; then ok "check inputs: $1"; else bad "check inputs: $1: rc=$rc ($out)"; fi
}
cin "version without version-arg warns" 0 "::warning::version is set" false 1.2.3 ""
cin "no version, no arg: silent" 0 "" false "" "A=b"
cin "version-arg with a VERSION= build-arg fails" 1 "already sets VERSION" true 1.2.3 $'A=b\nVERSION=9'
cin "version-arg with an unrelated build-arg passes" 0 "" true 1.2.3 "MYVERSION=9"

# 5. The version build arg: the version step computes it, the Build step passes it
#    (a fake sudo records buildah's args; no buildah needed).
step build "Compute the build version" > "$T/ver.sh"
[ -s "$T/ver.sh" ] || { echo "FAIL extract version block"; exit 1; }
step build "Build" > "$T/build.sh"
[ -s "$T/build.sh" ] || { echo "FAIL extract Build block"; exit 1; }
mkdir -p "$T/fake"
# shellcheck disable=SC2016 # a literal $@, the fake's own script
printf '#!/bin/sh\nshift; shift; echo "$@" > "$FAKE_OUT"\n' > "$T/fake/sudo"; chmod +x "$T/fake/sudo"
ver() { # name want_rc want-VERSION_ARG-or-substring version ref github_ref
  local out rc genv="$T/genv"; : > "$genv"
  out=$(TAG=0123456789ab VERSION=$4 RELEASE_TAG=$5 GITHUB_REF=$6 DEFAULT_BRANCH=main GITHUB_ENV=$genv bash "$T/ver.sh" 2>&1); rc=$?
  if [ "$rc" != "$2" ]; then bad "version $1: rc=$rc ($out)"; return; fi
  if [ "$2" = 0 ]; then
    if [ "$(cat "$genv")" = "VERSION_ARG=VERSION=$3" ]; then ok "version $1"; else bad "version $1: got '$(cat "$genv")'"; fi
  elif [[ "$out" == *"$3"* ]]; then ok "version $1"; else bad "version $1: want '$3' in '$out'"; fi
}
ver "release ref: the bare X.Y.Z" 0 1.2.3 1.2.3 v1.2.3 refs/heads/main
ver "default branch, no ref: X.Y.Z+sha" 0 1.2.3+0123456789ab 1.2.3 '' refs/heads/main
ver "default branch, nothing released yet: 0.0.0+sha" 0 0.0.0+0123456789ab '' '' refs/heads/main
ver "other branch, no ref: X.Y.Z-dev+sha" 0 1.2.3-dev+0123456789ab 1.2.3 '' refs/heads/feat
ver "other branch, nothing released: 0.0.0-dev+sha" 0 0.0.0-dev+0123456789ab '' '' refs/heads/feat
ver "empty version with a release ref refused" 1 "bad version" '' v1.2.3 refs/heads/main
ver "misnamed version refused" 1 "bad version" v1.2.3 '' refs/heads/main
ver "version with a flag refused" 1 "bad version" '1.2.3 --x' '' refs/heads/main
build_args() { # VERSION_ARG value; empty means unset
  local out="$T/bargs"; : > "$out"
  env -u VERSION_ARG ${1:+VERSION_ARG="$1"} PATH="$T/fake:$PATH" FAKE_OUT="$out" TAG=t CONTEXT=. DOCKERFILE=Dockerfile TARGET='' \
    BUILD_ARGS=A=b LAYERS=true PULL_NEWER=true BUILD_SECRETS='' REGISTRY=r IMAGE=i bash "$T/build.sh" >/dev/null 2>&1
  cat "$out"
}
a=$(build_args VERSION=1.2.3+0123456789ab)
if [[ "$a" == *"--build-arg VERSION=1.2.3+0123456789ab"* && "$a" == *"--build-arg A=b"* ]]; then ok "Build passes --build-arg VERSION next to build-args"; else bad "Build with VERSION_ARG: '$a'"; fi
a=$(build_args '')
if [[ "$a" == *"--build-arg A=b"* && "$a" != *VERSION* ]]; then ok "Build without VERSION_ARG adds no VERSION arg"; else bad "Build without VERSION_ARG: '$a'"; fi

# 9. Every job has a timeout; only REGISTRY_PASSWORD leaves the Infisical file.
for f in "$WF" "$(dirname "$WF")/image-build.yml"; do
  for j in $(yq '.jobs | keys | .[]' "$f"); do
    if [ "$(yq ".jobs.$j.timeout-minutes // \"\"" "$f")" != "" ]; then ok "$(basename "$f") job $j has timeout-minutes"; else bad "$(basename "$f") job $j has no timeout-minutes"; fi
  done
done
if [ "$(yq '.jobs.build.steps[] | select(.name == "Remove the Infisical secrets file") | .if' "$WF")" = "always()" ]; then ok "cleanup step runs always()"; else bad "cleanup step missing or not always()"; fi
step build "Keep only the registry password" > "$T/keep.sh"
[ -s "$T/keep.sh" ] || { echo "FAIL extract keep block"; exit 1; }
keep() { # name want_rc content
  local w="$T/ws"; rm -rf "$w"; mkdir "$w"; [ "$3" = - ] || printf '%s' "$3" > "$w/.infisical-secrets"
  : > "$T/genv"; local rc=0
  GITHUB_WORKSPACE=$w GITHUB_ENV=$T/genv bash "$T/keep.sh" >/dev/null 2>&1 || rc=$?
  if [ "$rc" != "$2" ]; then bad "keep $1: rc=$rc want $2"; return; fi
  if [ -e "$w/.infisical-secrets" ]; then bad "keep $1: file left behind"; return; fi
  ok "keep $1"
}
keep "extracts the password" 0 "REDIS_URL='redis://x'
REGISTRY_PASSWORD='pw 1'
OTHER='y'"
if [ "$(cat "$T/genv")" = "REGISTRY_PASSWORD=pw 1" ]; then ok "keep: GITHUB_ENV holds only REGISTRY_PASSWORD"; else bad "keep: GITHUB_ENV '$(cat "$T/genv")'"; fi
keep "no password fails" 1 "REDIS_URL='redis://x'"
keep "missing file fails" 1 -
keep "empty value fails" 1 "REGISTRY_PASSWORD=''"
keep "multi-line value fails" 1 "REGISTRY_PASSWORD='line1
line2'"

echo "failures: $fails"
[ "$fails" = 0 ]
