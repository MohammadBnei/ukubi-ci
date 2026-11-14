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
#    error substring (or ""), file content; the pin is 0123456789ab@$D unless
#    the optional 6th arg overrides it.
D=sha256:$(printf 'a%.0s' {1..64})
PIN="0123456789ab@$D"
# The commit every pin below was built from (the bump checks the tag is its prefix).
export BUILT=0123456789ab0123456789ab0123456789abcdef
step deploy "Bump the pinned image tag" > "$T/bump.sh"
[ -s "$T/bump.sh" ] || { echo "FAIL extract bump block"; exit 1; }
bump() { # name key want_rc want_msg content [pin]
  local want=${6-$PIN}
  local d="$T/case" out rc; rm -rf "$d"; mkdir -p "$d"; [ "$5" = - ] || printf '%s' "$5" > "$d/values.yaml"
  out=$(cd "$d" && PINS="values.yaml $want" VALUES_KEY=$2 bash "$T/bump.sh" 2>&1); rc=$?
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
bump "already at the pin stays green (re-run)" .image.tag 0 "already $PIN" "image:
  tag: \"$PIN\"
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
for p in "" "0123456789ab" "0123456789ab@" "0123456789ab@sha256:$(printf 'A%.0s' {1..64})" \
         "0123456789ab@sha256:$(printf 'a%.0s' {1..63})" "0123456789ab@sha512:$(printf 'a%.0s' {1..64})" \
         "0123456789a@$D" "0123456789AB@$D" "0123456789ab@$D extra" "x/y@$D" "ffffffffffff@$D"; do
  bump "malformed pin '${p:0:24}...' refused" .image.tag 1 "pin" 'image:
  tag: "x"
' "$p"
done

# 3a. image.yml's prep step: tag and digest become PINS, one line per values file.
step deploy "Pin the pushed digest" > "$T/prep.sh"
[ -s "$T/prep.sh" ] || { echo "FAIL extract prep block"; exit 1; }
pins_of() { sed -n '/^PINS<<PINS_EOF$/,/^PINS_EOF$/{//!p;}' "$1"; }
prep() { # name want_rc want_msg values-files [digest] [tag]
  local out rc; : > "$T/penv"
  out=$(TAG=${6-0123456789ab} DIGEST=${5-$D} VALUES_FILES=$4 GITHUB_ENV=$T/penv bash "$T/prep.sh" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && { [ -z "$3" ] || [[ "$out" == *"$3"* ]]; }; then ok "prep $1"; else bad "prep $1: rc=$rc ($out)"; fi
}
prep "two files, newline separated" 0 "" $'a.yaml\n b.yaml'
if [ "$(pins_of "$T/penv")" = "a.yaml $PIN"$'\n'"b.yaml $PIN" ]; then ok "prep: PINS holds one line per file"; else bad "prep: PINS '$(cat "$T/penv")'"; fi
prep "empty digest fails" 1 "digest missing or malformed" a.yaml ""
prep "uppercase digest refused" 1 "digest missing or malformed" a.yaml "sha256:$(printf 'A%.0s' {1..64})"
prep "63-hex digest refused" 1 "digest missing or malformed" a.yaml "sha256:$(printf 'a%.0s' {1..63})"
prep "sha512 digest refused" 1 "digest missing or malformed" a.yaml "sha512:$(printf 'a%.0s' {1..64})"
prep "bad tag refused" 1 "bad image tag" a.yaml "$D" "v1.2.3"
prep "blank values-files refused" 1 "values-files is blank" " "

# 3b. Several values files: one commit, a no-op only when every file holds its pin.
step deploy "Commit and push" > "$T/commit.sh"
[ -s "$T/commit.sh" ] || { echo "FAIL extract commit block"; exit 1; }
# repo <dir> <a-tag> <b-tag>: a work tree with a.yaml and b.yaml, pushed to a bare remote.
repo() {
  local d=$1 r="$1-remote.git"; rm -rf "$d" "$r"; mkdir -p "$d"; git init -q --bare -b main "$r"
  printf 'image:\n  tag: "%s"\n' "$2" > "$d/a.yaml"; printf 'image:\n  tag: "%s"\n' "$3" > "$d/b.yaml"
  git -C "$d" init -q -b main; git -C "$d" remote add origin "$r"; git -C "$d" add .
  git -C "$d" -c user.name=t -c user.email=t@t commit -qm init; git -C "$d" push -q origin main
}
multi() { # name want_commits files-of-commit(0|1|2) a-tag b-tag
  local d="$T/multi" pins; repo "$d" "$4" "$5"; pins="a.yaml $PIN"$'\n'"b.yaml $PIN"
  local out rc; out=$(cd "$d" && PINS=$pins VALUES_KEY=.image.tag bash "$T/bump.sh" 2>&1); rc=$?
  [ "$rc" = 0 ] || { bad "multi $1: bump rc=$rc ($out)"; return; }
  [ "$(yq .image.tag "$d/a.yaml")" = "$PIN" ] && [ "$(yq .image.tag "$d/b.yaml")" = "$PIN" ] || { bad "multi $1: a file not pinned"; return; }
  (cd "$d" && AUTHOR=app-ci MESSAGE="chore(deploy): bump app image to $PIN" PINS=$pins BRANCH=main bash "$T/commit.sh" >/dev/null 2>&1) || { bad "multi $1: commit step failed"; return; }
  local n f; n=$(git -C "$d" rev-list --count HEAD); f=$(git -C "$d" show --format= --name-only HEAD | grep -c yaml)
  if [ "$n" != "$2" ] || { [ "$2" = 2 ] && [ "$f" != "$3" ]; }; then bad "multi $1: $n commits, last touches $f files; want $2, $3"; return; fi
  if [ "$2" = 2 ] && [ "$(git -C "$d" log -1 --format=%an%n%s)" != "app-ci"$'\n'"chore(deploy): bump app image to $PIN" ]; then bad "multi $1: author or subject"; return; fi
  ok "multi $1"
}
multi "both stale: one commit touching both files" 2 2 aaaaaaaaaaaa bbbbbbbbbbbb
multi "one file already pinned: bump still lands, one commit" 2 1 "$PIN" bbbbbbbbbbbb
multi "first file pinned, second stale (order does not matter)" 2 1 aaaaaaaaaaaa "$PIN"
multi "every file already pinned: no commit" 1 0 "$PIN" "$PIN"
# vbump: image.yml's values-files through the prep step, then the bump.
vbump() { # name want_rc want_msg files
  local d="$T/vb"; rm -rf "$d"; mkdir -p "$d"; printf 'image:\n  tag: "x"\n' > "$d/a.yaml"; printf 'image:\n  tag: "x"\n' > "$d/b.yaml"
  : > "$T/venv"; local out rc
  out=$(TAG=0123456789ab DIGEST=$D VALUES_FILES=$4 GITHUB_ENV=$T/venv bash "$T/prep.sh" 2>&1 \
    && cd "$d" && PINS=$(pins_of "$T/venv") VALUES_KEY=.image.tag bash "$T/bump.sh" 2>&1); rc=$?
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
vbump "same file twice refused" 1 "listed twice" "a.yaml a.yaml"
vbump_link() { local d="$T/vb"; mkdir -p "$d"; printf 'image:\n  tag: "x"\n' > "$d/real.yaml"; ln -sf real.yaml "$d/l.yaml"
  local out rc; out=$(cd "$d" && PINS="l.yaml $PIN" VALUES_KEY=.image.tag bash "$T/bump.sh" 2>&1); rc=$?
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
  (cd "$w" && BUILT=$bt GITHUB_RUN_ATTEMPT=${5:-2} BRANCH=main PINS="values.yaml ${bt:0:12}@$D" VALUES_KEY=.image.tag GITHUB_OUTPUT="$T/out" bash "$T/fresh.sh" >/dev/null 2>&1)
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
if (cd "$g/w" && BUILT=abc BRANCH=main PINS="values.yaml $PIN" VALUES_KEY=.image.tag GITHUB_OUTPUT="$T/out" bash "$T/fresh.sh" >"$T/m" 2>&1); then bad "guard malformed BUILT must fail"
elif grep -q "built commit missing or malformed" "$T/m"; then ok "guard malformed BUILT fails closed"; else bad "guard malformed BUILT: $(cat "$T/m")"; fi

# The guard skips when ANY file's pin descends from BUILT, in either order.
printf 'image:\n  tag: "ffffffffffff@%s"\n' "$D" > "$g/w/other.yaml"; cp "$g/w/other.yaml" "$g/w/third.yaml"; pin "${B:0:12}@$D"
lines() { local f; for f in $1; do echo "$f ${2:0:12}@$D"; done; } # files built
gm() { # name want files [built] [guard script]
  : > "$T/out"
  (cd "$g/w" && BUILT=${4:-$A} GITHUB_RUN_ATTEMPT=2 BRANCH=main PINS=$(lines "$3" "${4:-$A}") VALUES_KEY=.image.tag GITHUB_OUTPUT="$T/out" bash "${5:-$T/fresh.sh}" >"$T/gm" 2>&1)
  if grep -qx "ok=$2" "$T/out"; then ok "guard $1"; else bad "guard $1: $(cat "$T/out" "$T/gm")"; fi
}
gm "several files: a stale one first skips" false "values.yaml other.yaml"
gm "several files: a stale one second skips" false "other.yaml values.yaml"
gm "several files: no pin descends, deploys" true "other.yaml third.yaml"
gm_fail() { # name pins substring
  (cd "$g/w" && BUILT=$A BRANCH=main PINS=$2 VALUES_KEY=.image.tag GITHUB_OUTPUT="$T/out" bash "$T/fresh.sh" >"$T/gm" 2>&1) \
    && { bad "guard $1 must fail"; return; }
  if grep -q "$3" "$T/gm"; then ok "guard $1"; else bad "guard $1: $(cat "$T/gm")"; fi
}
gm_fail "blank pins fails early" " " "no pins"
AP="${A:0:12}@$D"
gm_fail "path with .. refused before reading" "../x.yaml $AP" "bad values file"
gm_fail "leading dash refused" "-x.yaml $AP" "bad values file"
gm_fail "malformed pin refused" "values.yaml ${A:0:12}" "bad pin"
gm_fail "pin of another commit refused" "values.yaml ${B:0:12}@$D" "not of the built commit"
gm_fail "same file twice refused" "$(lines "values.yaml values.yaml" "$A")" "listed twice"
gm_fail "same file as ./ spelling refused" "values.yaml $AP"$'\n'"./values.yaml $AP" "bad values file"
ln -sf values.yaml "$g/w/link.yaml"; gm_fail "symlink refused" "link.yaml $AP" "symlink"; unlink "$g/w/link.yaml"

# 4a. deploy.yml: several images, one commit. Its shared steps are image.yml's
#     byte for byte (test/reusable.sh); these run deploy.yml's own copy.
DWF=$(dirname "$WF")/deploy.yml
dstep() { yq ".jobs.deploy.steps[] | select(.name == \"$1\") | .run" "$DWF"; }
dstep "Skip a stale run" > "$T/dfresh.sh"; dstep "Bump the pinned image tag" > "$T/dbump.sh"; dstep "Commit and push" > "$T/dcommit.sh"
dstep "Check inputs" > "$T/dcheck.sh"
for f in dfresh dbump dcommit dcheck; do [ -s "$T/$f.sh" ] || { echo "FAIL extract deploy.yml $f"; exit 1; }; done
GAME="0123456789ab@$D"; REALM="0123456789ab@sha256:$(printf 'b%.0s' {1..64})"
atomic() { # name want_commits a-tag b-tag [files in the bump commit]
  local d="$T/atomic" pins out rc; repo "$d" "$3" "$4"; pins="a.yaml $GAME"$'\n'"b.yaml $REALM"
  out=$(cd "$d" && PINS=$pins VALUES_KEY=.image.tag bash "$T/dbump.sh" 2>&1 \
    && AUTHOR=game-ci MESSAGE="chore(deploy): bump game images" PINS=$pins BRANCH=main bash "$T/dcommit.sh" 2>&1); rc=$?
  [ "$rc" = 0 ] || { bad "deploy.yml $1: rc=$rc ($out)"; return; }
  [ "$(yq .image.tag "$d/a.yaml")" = "$GAME" ] && [ "$(yq .image.tag "$d/b.yaml")" = "$REALM" ] || { bad "deploy.yml $1: a file not at its own pin"; return; }
  local n; n=$(git -C "$d-remote.git" rev-list --count main)
  [ "$n" = "$2" ] || { bad "deploy.yml $1: $n commits on the remote, want $2"; return; }
  if [ "$2" = 2 ]; then
    [ "$(git -C "$d" show --format= --name-only HEAD | sort | tr '\n' ' ')" = "${5:-a.yaml b.yaml} " ] || { bad "deploy.yml $1: bump commit files"; return; }
    [ "$(git -C "$d" log -1 --format=%b | grep -c '@sha256:')" = 2 ] || { bad "deploy.yml $1: body does not list both pins"; return; }
  fi
  ok "deploy.yml $1"
}
atomic "two files, different pins: one commit holding both" 2 aaaaaaaaaaaa bbbbbbbbbbbb
atomic "one file already at its pin: still one commit" 2 "$GAME" bbbbbbbbbbbb b.yaml
atomic "every file already at its pin: no-op, no commit" 1 "$GAME" "$REALM"
dfail() { # name pins substring
  local d="$T/atomic" out rc; repo "$d" x x
  out=$(cd "$d" && PINS=$2 VALUES_KEY=.image.tag bash "$T/dbump.sh" 2>&1); rc=$?
  if [ "$rc" != 0 ] && [[ "$out" == *"$3"* ]] && [ "$(yq .image.tag "$d/a.yaml")" = x ]; then ok "deploy.yml $1"; else bad "deploy.yml $1: rc=$rc ($out)"; fi
}
dfail "pin without a digest refused" "a.yaml 0123456789ab" "bad pin"
dfail "line without a pin refused" "a.yaml" "bad pin"
dfail "third field refused" "a.yaml $GAME b.yaml" "bad pin"
dfail "a malformed second line refuses before any edit" "a.yaml $GAME"$'\n'"b.yaml $GAME junk" "bad pin"
dfail "parent-dir path refused" "../a.yaml $GAME" "bad values file"
dfail "absolute path refused" "/etc/passwd $GAME" "bad values file"
dfail "blank pins refused" $'\n  \n' "no pins"
dfail "second image from another commit refused (not one rollout)" "a.yaml $GAME"$'\n'"b.yaml ffffffffffff@$D" "not of the built commit"
dfail "./ segment refused (a.yaml and ./a.yaml are one file)" "a.yaml $GAME"$'\n'"./a.yaml $REALM" "bad values file"
dfail "inner . segment refused" "x/./a.yaml $GAME" "bad values file"
dfail "// refused" "x//a.yaml $GAME" "bad values file"
dfail "trailing slash refused" "a.yaml/ $GAME" "bad values file"
ln -sf a.yaml "$T/atomic/l.yaml"; out=$(cd "$T/atomic" && PINS="l.yaml $GAME" VALUES_KEY=.image.tag bash "$T/dbump.sh" 2>&1)
if [[ "$out" == *symlink* ]]; then ok "deploy.yml symlink refused"; else bad "deploy.yml symlink: $out"; fi
gm "deploy.yml: stale re-run (any pin descends from built) skips" false "other.yaml values.yaml" "$A" "$T/dfresh.sh"
gm "deploy.yml: no pin descends, deploys" true "other.yaml third.yaml" "$A" "$T/dfresh.sh"
if VALUES_KEY='.image.tag; x' bash "$T/dcheck.sh" >/dev/null 2>&1; then bad "deploy.yml bad values-key must fail"; else ok "deploy.yml bad values-key refused"; fi
if VALUES_KEY=.image.tag bash "$T/dcheck.sh" >/dev/null 2>&1; then ok "deploy.yml values-key .image.tag passes"; else bad "deploy.yml .image.tag refused"; fi

# 4c. image.yml deploy: false skips the deploy job and keeps the build outputs.
if [ "$(yq '.on.workflow_call.inputs.deploy.default' "$WF")" = true ]; then ok "image.yml deploy defaults to true"; else bad "image.yml deploy default"; fi
if yq '.jobs.deploy.if' "$WF" | grep -qF '&& inputs.deploy'; then ok "image.yml deploy job gated on inputs.deploy"; else bad "image.yml deploy job not gated on inputs.deploy"; fi
for o in tag commit digest; do
  if [ "$(yq ".on.workflow_call.outputs.$o.value" "$WF")" = "\${{ jobs.build.outputs.$o }}" ]; then ok "image.yml output $o comes from the build job"; else bad "image.yml output $o"; fi
done
ev="(github.event_name == 'push' || github.event_name == 'workflow_dispatch')"
br="github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"
if [ "$(yq '.jobs.deploy.if' "$DWF")" = "$ev && $br" ] && [[ "$(yq '.jobs.deploy.if' "$WF")" == *"$ev"*"$br"* ]]; then
  ok "deploy.yml deploys on the same events and branch as image.yml"
else bad "deploy.yml event/branch gate differs from image.yml"; fi

# 4b. Version inputs sanity in the build job's Check inputs step.
step build "Check inputs" > "$T/ci.sh"
[ -s "$T/ci.sh" ] || { echo "FAIL extract Check inputs"; exit 1; }
cin() { # name want_rc want_msg version-arg version build-args
  local out rc; out=$(IMAGE=app VALUES_KEY=.image.tag VERSION_ARG_ON=$4 VERSION_IN=$5 BUILD_ARGS_IN=$6 EXTRA_TAGS_IN=${7-} bash "$T/ci.sh" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && { [ -z "$3" ] || [[ "$out" == *"$3"* ]]; }; then ok "check inputs: $1"; else bad "check inputs: $1: rc=$rc ($out)"; fi
}
cin "version without version-arg warns" 0 "::warning::version is set" false 1.2.3 ""
cin "no version, no arg: silent" 0 "" false "" "A=b"
cin "version-arg with a VERSION= build-arg fails" 1 "already sets VERSION" true 1.2.3 $'A=b\nVERSION=9'
cin "version-arg with an unrelated build-arg passes" 0 "" true 1.2.3 "MYVERSION=9"
cin "extra-tags: latest and a second tag pass" 0 "" false "" "" $'latest\nstable-1.2'
cin "extra-tags: a bad line refused" 1 "bad extra-tags line" false "" "" $'latest\n-x'
cin "extra-tags: a flag-like line refused" 1 "bad extra-tags line" false "" "" 'a --force'
cin "extra-tags: a colon (image ref) refused" 1 "bad extra-tags line" false "" "" 'img:latest'

# 5a. extra-tags and push-default-branch-only: the Push step tags and pushes each
#     extra tag after the sha tag; the build-only gate sits on every registry step.
step build "Push" > "$T/push.sh"
[ -s "$T/push.sh" ] || { echo "FAIL extract Push block"; exit 1; }
mkdir -p "$T/fake"
cat > "$T/fake/sudo" <<'FAKE'
#!/bin/bash
shift; echo "$*" >> "$FAKE_OUT"
last=${*: -1}
[ -z "${FAKE_FAIL:-}" ] || [ "$last" != "$FAKE_FAIL" ] || exit 1
d=$FAKE_DIGEST; case $last in *:0123456789ab) ;; *) d=${FAKE_EXTRA_DIGEST:-$FAKE_DIGEST} ;; esac
while [ $# -gt 0 ]; do if [ "$1" = --digestfile ]; then printf '%s' "$d" > "$2"; fi; shift; done
FAKE
chmod +x "$T/fake/sudo"
pushes() { # extra-tags [digest-for-extras]
  local out="$T/pargs" rt="$T/rt" go="$T/pgo"; rm -rf "$rt"; mkdir "$rt"; : > "$out"; : > "$go"
  PATH="$T/fake:$PATH" FAKE_OUT="$out" FAKE_DIGEST=$D RUNNER_TEMP=$rt GITHUB_OUTPUT=$go \
    GITHUB_REF=${PREF:-refs/heads/main} DEFAULT_BRANCH=main \
    TAG=0123456789ab EXTRA_TAGS=$1 REGISTRY=r IMAGE=i bash "$T/push.sh" > "$T/pmsg" 2>&1
  cat "$out"
}
a=$(pushes "")
if [ "$(grep -c . <<<"$a")" = 1 ] && [[ "$a" == "buildah push "*" r/i:0123456789ab" ]] && grep -qx "digest=$D" "$T/pgo"; then ok "push: no extra-tags pushes the sha tag only"; else bad "push without extra-tags: '$a'"; fi
a=$(pushes $'latest\nstable')
want=$'buildah push --authfile '"$T"$'/rt/registry-auth.json --tls-verify=false --digestfile '"$T"$'/rt/digest r/i:0123456789ab\nbuildah tag r/i:0123456789ab r/i:latest'
if [[ "$a" == "$want"$'\n'*"r/i:latest"$'\n'*"buildah tag r/i:0123456789ab r/i:stable"$'\n'*" r/i:stable" ]] && [ "$(grep -c '^buildah push' <<<"$a")" = 3 ]; then ok "push: extra tags tagged and pushed after the sha tag"; else bad "push with extra-tags: '$a'"; fi
if [ "$(grep -c digest= "$T/pgo")" = 1 ] && grep -qx "digest=$D" "$T/pgo"; then ok "push: digest output is the sha tag's, one line"; else bad "push digest output: $(cat "$T/pgo")"; fi
a=$(FAKE_EXTRA_DIGEST=sha256:$(printf 'b%.0s' {1..64}) pushes latest)
if grep -q '::warning::latest pushed a different digest' "$T/pmsg" && grep -qx "digest=$D" "$T/pgo"; then ok "push: extra-tag digest mismatch only warns"; else bad "push mismatch: $(cat "$T/pmsg")"; fi
if FAKE_FAIL=r/i:latest pushes latest >/dev/null && grep -q '::warning::extra tag latest was not pushed' "$T/pmsg" && grep -qx "digest=$D" "$T/pgo"; then ok "push: a failing extra-tag push only warns, sha digest kept"; else bad "push extra failure: $(cat "$T/pmsg")"; fi
a=$(PREF=refs/heads/feat pushes latest)
if [ "$(grep -c . <<<"$a")" = 1 ] && [[ "$a" == "buildah push "*" r/i:0123456789ab" ]]; then ok "push: extra tags skipped off the default branch"; else bad "push extras off default branch: '$a'"; fi
step build "Remove the local image" > "$T/rmi.sh"
[ -s "$T/rmi.sh" ] || { echo "FAIL extract rmi block"; exit 1; }
: > "$T/pargs"; PATH="$T/fake:$PATH" FAKE_OUT="$T/pargs" TAG=0123456789ab EXTRA_TAGS=$'latest' REGISTRY=r IMAGE=i bash "$T/rmi.sh" >/dev/null 2>&1
if [ "$(cat "$T/pargs")" = $'buildah rmi r/i:latest\nbuildah rmi r/i:0123456789ab' ]; then ok "rmi: extra tags removed before the sha tag"; else bad "rmi: '$(cat "$T/pargs")'"; fi
for in in push-default-branch-only extra-tags; do
  case $in in push-default-branch-only) want=false ;; *) want='""' ;; esac
  if [ "$(yq ".on.workflow_call.inputs.\"$in\".default" "$WF")" = "${want//\"/}" ]; then ok "image.yml $in is off by default"; else bad "image.yml $in default"; fi
done
gate="!inputs.push-default-branch-only || github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"
for sn in "Read the registry password from Infisical" "Keep only the registry password" "Registry login" "Push" "Registry logout"; do
  if [[ "$(yq ".jobs.build.steps[] | select(.name == \"$sn\") | .if" "$WF")" == *"$gate"* ]]; then ok "gate on '$sn'"; else bad "no push-default-branch-only gate on '$sn'"; fi
done

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
