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

# 2. The publish decision: only push and workflow_dispatch may log in, push or
#    bump; every other event (pull_request, pull_request_target, new ones) builds only.
step guard "Decide whether this run may publish" > "$T/pr.sh"
[ -s "$T/pr.sh" ] || { echo "FAIL extract guard block"; exit 1; }
pr() { # want_publish want_deploy name EVENT REF [PDBO] [DEPLOY] [VALUES]
  local rc=0 got gotd; : > "$T/gout"
  EVENT=$4 REF=$5 DEFAULT_BRANCH=main PDBO=${6:-false} DEPLOY=${7:-true} VALUES=${8-helm/values.yaml} \
    GITHUB_OUTPUT="$T/gout" bash "$T/pr.sh" >/dev/null 2>&1 || rc=$?
  got=$(sed -n 's/^value=//p' "$T/gout"); gotd=$(sed -n 's/^deploy=//p' "$T/gout")
  if [ "$rc" = 0 ] && [ "$got" = "$1" ] && [ "$gotd" = "$2" ]; then ok "publish guard: $3"; else bad "publish guard: $3 (rc=$rc, publish=$got, deploy=$gotd)"; fi
}
M=refs/heads/main B=refs/heads/feat
pr true  true  "push on main publishes and deploys"      push              $M
pr true  true  "dispatch on main publishes and deploys"  workflow_dispatch $M
pr true  false "push on a branch publishes, no deploy"   push              $B
pr false false "push-default-branch-only off main: nothing" push           $B true
pr true  true  "push-default-branch-only on main"        push              $M true
pr true  false "deploy: false publishes, no deploy"      push              $M false false
pr true  false "no values file: no deploy"               push              $M false true ""
pr false false "tag push with push-default-branch-only"  push              refs/tags/v1.0.0 true
pr false false "pull_request builds only"                pull_request      refs/pull/1/merge
pr false false "pull_request_target builds only"         pull_request_target $M
pr false false "workflow_run builds only"                workflow_run      $M
pr false false "an unlisted event builds only"           schedule          $M
pr false false "an empty event builds only"              ""                $M
# PRs never build an image: the build job reads the guard's build output, false only for pull_request(_target).
bd() { # want name EVENT
  : > "$T/gout"; EVENT=$3 REF=$M DEFAULT_BRANCH=main PDBO=false DEPLOY=true VALUES=helm/values.yaml GITHUB_OUTPUT="$T/gout" bash "$T/pr.sh" >/dev/null 2>&1
  if [ "$(sed -n 's/^build=//p' "$T/gout")" = "$1" ]; then ok "build guard: $2"; else bad "build guard: $2"; fi
}
bd false "pull_request builds nothing"         pull_request
bd false "pull_request_target builds nothing" pull_request_target
bd true  "push builds"                         push
bd true  "workflow_dispatch builds"            workflow_dispatch
bd true  "workflow_run builds"                 workflow_run
if [ "$(yq '.jobs.build.if' "$WF")" = "needs.guard.outputs.build == 'true'" ]; then ok "build job reads the guard's build"; else bad "build job if is not the guard's build"; fi
# Every step that logs in, reads Infisical or pushes, and the deploy job, also ask the guard.
for sn in "Pick the Infisical login" "Read the registry password from Infisical" "Read the registry password over Forgejo OIDC" "Keep only the registry password" "Registry login" "Push" "Registry logout"; do
  if [[ "$(yq ".jobs.build.steps[] | select(.name == \"$sn\") | .if" "$WF")" == *"needs.guard.outputs.publish == 'true'"* ]]; then ok "publish gate on '$sn'"; else bad "no guard gate on '$sn'"; fi
done
if [ "$(yq '.jobs.deploy.if' "$WF")" = "always() && needs.build.result == 'success' && needs.guard.outputs.deploy == 'true'" ]; then ok "deploy job reads the guard's deploy only"; else bad "deploy job if is not the guard's deploy"; fi
# No job names a GitHub-hosted image (no hosted runner is paid for). The one
# exception is the bare label ubuntu-latest: on Forgejo it is the self-hosted
# container runner, and it is a JSON default or ci.yml's own label only.
if grep -rniE 'ubuntu-|macos-|windows-' "$(dirname "$WF")" | grep -v '^\S*:[0-9]*:\s*#' \
  | grep -vE "^[^:]*:[0-9]+:\s*(default: '\[\"(k8s-)?ubuntu-latest\"\]'|runs-on: (k8s-)?ubuntu-latest|\(ephemeral unprivileged pods.*|.*ukubi-ci-runner.*)$"; then
  bad "a workflow names a GitHub-hosted runner"
else ok "no GitHub-hosted runner in the workflows"; fi
# The build job's runner comes from the caller: buildah runs only where it is granted.
# shellcheck disable=SC2016 # a literal ${{, not a shell expansion
if [ "$(yq '.jobs.build."runs-on"' "$WF")" = '${{ fromJSON(inputs.runs-on) }}' ]; then ok "build job runs on inputs.runs-on"; else bad "build job runs-on is not inputs.runs-on"; fi

# 2a. The Infisical login: oidc on github.com, Forgejo OIDC elsewhere, universal on request.
step build "Pick the Infisical login" > "$T/auth.sh"
[ -s "$T/auth.sh" ] || { echo "FAIL extract Infisical login block"; exit 1; }
auth() { # want_rc want_method name [VAR=value ...]
  local rc=0 got want_rc=$1 want=$2 name=$3; shift 3; : > "$T/aout"
  env -u FORGEJO_ACTIONS -u GITEA_ACTIONS -u GITHUB_SERVER_URL AUTH=auto HAVE_CLIENT=true GITHUB_OUTPUT="$T/aout" "$@" \
    bash "$T/auth.sh" >/dev/null 2>&1 || rc=$?
  got=$(sed -n 's/^method=//p' "$T/aout")
  if [ "$rc" = "$want_rc" ] && [ "$got" = "$want" ]; then ok "infisical login: $name"; else bad "infisical login: $name (rc=$rc, method=$got)"; fi
}
auth 0 oidc      "auto on github.com is oidc" GITHUB_SERVER_URL=https://github.com
auth 0 oidc      "auto with no server url is oidc"
auth 0 forgejo   "auto on Forgejo (FORGEJO_ACTIONS) is forgejo" FORGEJO_ACTIONS=true GITHUB_SERVER_URL=https://git.bnei.dev
auth 0 forgejo   "auto on Gitea (GITEA_ACTIONS) is forgejo" GITEA_ACTIONS=true
auth 0 forgejo   "auto on another server url is forgejo" GITHUB_SERVER_URL=https://git.bnei.dev
auth 0 universal "universal forced on Forgejo" AUTH=universal FORGEJO_ACTIONS=true
auth 0 oidc      "oidc forced on Forgejo" AUTH=oidc FORGEJO_ACTIONS=true
auth 0 universal "universal forced on github.com" AUTH=universal GITHUB_SERVER_URL=https://github.com
auth 1 ""        "universal without the client pair fails" AUTH=universal HAVE_CLIENT=false
auth 0 oidc      "oidc needs no client pair" AUTH=oidc HAVE_CLIENT=false
auth 1 ""        "a bad infisical-auth value fails" AUTH=token
# shellcheck disable=SC2016 # a literal ${{, not a shell expansion
if [ "$(yq '.jobs.build.steps[] | select(.name == "Read the registry password from Infisical") | .with.method' "$WF")" = '${{ steps.infisical.outputs.method }}' ]; then
  ok "the Infisical action takes the picked method"; else bad "the Infisical action ignores the picked method"; fi
# Exactly one of the two readers runs: the action off forgejo, the curl step on it.
if [[ "$(yq '.jobs.build.steps[] | select(.name == "Read the registry password from Infisical") | .if' "$WF")" == *"steps.infisical.outputs.method != 'forgejo'"* ]] \
  && [[ "$(yq '.jobs.build.steps[] | select(.name == "Read the registry password over Forgejo OIDC") | .if' "$WF")" == *"steps.infisical.outputs.method == 'forgejo'"* ]]; then
  ok "one Infisical reader per method"; else bad "the two Infisical readers overlap or neither runs"; fi
if [ "$(yq '."enable-openid-connect"' "$WF")" = true ]; then ok "image.yml asks Forgejo for an OIDC token (workflow level)"; else bad "image.yml lacks workflow-level enable-openid-connect"; fi

# 2b. The Forgejo OIDC reader against a fake curl: argv never carries a token,
#     a failed read still revokes, and only REGISTRY_PASSWORD lands in the file.
step build "Read the registry password over Forgejo OIDC" > "$T/fj.sh"
[ -s "$T/fj.sh" ] || { echo "FAIL extract Forgejo OIDC block"; exit 1; }
mkdir -p "$T/fjbin"
cat > "$T/fjbin/curl" <<'CURL'
#!/usr/bin/env bash
# Fake curl: logs argv and stdin config, answers by URL.
printf '%s\n' "$*" >> "$FJ_LOG.argv"; cfg=$(cat); printf '%s\n' "$cfg" >> "$FJ_LOG.stdin"
url=${!#}
case $url in
  *audience=infisical*) echo '{"value":"FORGEJO-JWT-xyz"}' ;;
  */jwt-auth/login) [ "${FJ_LOGIN:-ok}" = ok ] && echo '{"accessToken":"INF-TOKEN-abc"}' || echo '{"message":"denied"}' ;;
  */secrets/raw/REGISTRY_PASSWORD*) [ "${FJ_GET:-ok}" = ok ] || exit 22; echo '{"secret":{"secretValue":"pw-0123456789abcdef"}}' ;;
  */token/revoke) echo revoked >> "$FJ_LOG.revoke" ;;
esac
CURL
chmod +x "$T/fjbin/curl"
# jq too: a token on its argv is as visible in ps as on curl's.
cat > "$T/fjbin/jq" <<JQ
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FJ_LOG.argv"
exec $(command -v jq) "\$@"
JQ
chmod +x "$T/fjbin/jq"
fj() { # name want_rc [VAR=value ...]
  local rc=0 name=$1 want=$2; shift 2; rm -f "$T"/fjlog.* "$T/ws/.infisical-secrets"; mkdir -p "$T/ws"
  env PATH="$T/fjbin:$PATH" FJ_LOG="$T/fjlog" GITHUB_WORKSPACE="$T/ws" IDENTITY=id INFISICAL_DOMAIN=https://inf.example \
    INFISICAL_PROJECT_SLUG=p INFISICAL_ENV=dev SECRET_PATH=/ ACTIONS_ID_TOKEN_REQUEST_URL='https://fj.example/token?x=1' \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=REQ-TOKEN-def "$@" bash "$T/fj.sh" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "$want" ] || { bad "forgejo reader: $name (rc=$rc)"; return; }
  if grep -qE 'REQ-TOKEN|FORGEJO-JWT|INF-TOKEN' "$T/fjlog.argv" 2>/dev/null; then bad "forgejo reader: $name: a token on curl's argv"; return; fi
  ok "forgejo reader: $name"
}
fj "happy path writes the password" 0
if [ "$(cat "$T/ws/.infisical-secrets" 2>/dev/null)" = "REGISTRY_PASSWORD='pw-0123456789abcdef'" ] && [ -s "$T/fjlog.revoke" ]; then ok "forgejo reader: file holds the password only, token revoked"; else bad "forgejo reader: file or revoke"; fi
fj "a failed read fails" 1 FJ_GET=fail
if [ -s "$T/fjlog.revoke" ] && [ ! -e "$T/ws/.infisical-secrets" ]; then ok "forgejo reader: a failed read still revokes, writes nothing"; else bad "forgejo reader: failed read left the token live or wrote a file"; fi
fj "a refused login fails" 1 FJ_LOGIN=refused
fj "no OIDC request url fails" 1 ACTIONS_ID_TOKEN_REQUEST_URL=

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
  if ! { [ "$(yq .image.tag "$d/a.yaml")" = "$PIN" ] && [ "$(yq .image.tag "$d/b.yaml")" = "$PIN" ]; }; then bad "multi $1: a file not pinned"; return; fi
  (cd "$d" && AUTHOR=app-ci MESSAGE="chore(deploy): bump app image to $PIN" PINS=$pins BRANCH=main bash "$T/commit.sh" >/dev/null 2>&1) || { bad "multi $1: commit step failed"; return; }
  local n f; n=$(git -C "$d" rev-list --count HEAD); f=$(git -C "$d" show --format= --name-only HEAD | grep -c yaml)
  if [ "$n" != "$2" ] || { [ "$2" = 2 ] && [ "$f" != "$3" ]; }; then bad "multi $1: $n commits, last touches $f files; want $2, $3"; return; fi
  if [ "$2" = 2 ] && [ "$(git -C "$d" log -1 --format=%an%n%s)" != "app-ci"$'\n'"chore(deploy): bump app image to $PIN" ]; then bad "multi $1: author or subject"; return; fi
  ok "multi $1"
}
# 3c. Option B: bumps go to a deploy branch. Switch (orphan on first use, then
#     the remote branch), bump (creating the pin file from the key), commit and
#     push; the default branch is never written.
step deploy "Switch to the deploy branch" > "$T/switch.sh"
[ -s "$T/switch.sh" ] || { echo "FAIL extract switch block"; exit 1; }
db() { # name key -- one deploy round; leaves $T/db
  local d="$T/db" r="$T/db-remote.git" out; rm -rf "$d" "$r"; mkdir -p "$d"; git init -q --bare -b main "$r"
  printf 'image:\n  tag: "keepme"\n' > "$d/values.yaml"
  git -C "$d" init -q -b main; git -C "$d" remote add origin "$r"; git -C "$d" add .
  git -C "$d" -c user.name=t -c user.email=t@t commit -qm init; git -C "$d" push -q origin main
  local main0; main0=$(git -C "$r" rev-parse main)
  for round in 1 2; do
    out=$(cd "$d" && git checkout -q main && DEPLOY_BRANCH=deploy BRANCH=main bash "$T/switch.sh" 2>&1) || { bad "deploy branch $1: switch failed round $round ($out)"; return; }
    out=$(cd "$d" && PINS="app/image.yaml $PIN" VALUES_KEY=$2 DEPLOY_BRANCH=deploy BRANCH=main bash "$T/bump.sh" 2>&1) || { bad "deploy branch $1: bump failed round $round ($out)"; return; }
    out=$(cd "$d" && AUTHOR=app-ci MESSAGE="chore(deploy): bump app image to $PIN" PINS="app/image.yaml $PIN" DEPLOY_BRANCH=deploy BRANCH=main bash "$T/commit.sh" 2>&1) || { bad "deploy branch $1: commit failed round $round ($out)"; return; }
  done
  [ "$(git -C "$r" rev-parse main)" = "$main0" ] || { bad "deploy branch $1: the default branch was written"; return; }
  [ "$(git -C "$r" show "deploy:app/image.yaml" | yq "$2")" = "$PIN" ] || { bad "deploy branch $1: pin not on deploy"; return; }
  [ "$(git -C "$r" ls-tree -r --name-only deploy)" = app/image.yaml ] || { bad "deploy branch $1: deploy holds more than the pin file"; return; }
  [ "$(git -C "$r" rev-list --count deploy)" = 1 ] || { bad "deploy branch $1: second round should be a no-op"; return; }
  [ "$(git -C "$r" log -1 --format=%s deploy)" = "chore(deploy): bump app image to $PIN" ] || { bad "deploy branch $1: subject"; return; }
  ok "deploy branch $1"
}
db "key .image.tag: orphan branch, pin file only, main untouched, re-run no-op" .image.tag
db "nested key .api.image.tag" .api.image.tag
# An existing deploy branch with an older pin: the pin moves, one commit on top.
d="$T/db"; r="$T/db-remote.git"
P2="fedcba987654@sha256:$(printf 'b%.0s' {1..64})"
(cd "$d" && git checkout -q main && DEPLOY_BRANCH=deploy BRANCH=main bash "$T/switch.sh" >/dev/null 2>&1 \
  && PINS="app/image.yaml $P2" VALUES_KEY=.api.image.tag DEPLOY_BRANCH=deploy BRANCH=main BUILT=fedcba987654fedcba987654fedcba987654fedc bash "$T/bump.sh" >/dev/null 2>&1 \
  && AUTHOR=app-ci MESSAGE="chore(deploy): bump app image to $P2" PINS="app/image.yaml $P2" DEPLOY_BRANCH=deploy BRANCH=main bash "$T/commit.sh" >/dev/null 2>&1)
if [ "$(git -C "$r" show deploy:app/image.yaml | yq .api.image.tag)" = "$P2" ] && [ "$(git -C "$r" rev-list --count deploy)" = 2 ]; then
  ok "deploy branch: an existing pin moves, one more commit"; else bad "deploy branch: existing pin did not move"; fi
# Only a lookalike branch (ci/deploy) on origin: still an orphan deploy, not a failed fetch.
git -C "$r" branch -q ci/deploy deploy && git -C "$r" branch -q -D deploy
if (cd "$d" && git checkout -q main && git branch -q -D deploy && DEPLOY_BRANCH=deploy BRANCH=main bash "$T/switch.sh" >/dev/null 2>&1) \
  && [ "$(git -C "$d" ls-files)" = "" ]; then ok "deploy branch: a lookalike ref is not taken for the branch"; else bad "deploy branch: lookalike ref misread"; fi
for n in -x 'a..b' 'x.lock' 'x/'; do
  if DEPLOY_BRANCH=$n BRANCH=main bash "$T/switch.sh" >/dev/null 2>&1; then bad "deploy branch: '$n' must be refused"; else ok "deploy branch: '$n' refused"; fi
done
if DEPLOY_BRANCH='bad branch' BRANCH=main bash "$T/switch.sh" >/dev/null 2>&1; then bad "deploy branch: a bad name must fail"; else ok "deploy branch: a bad name fails"; fi
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
  if ! { [ "$(yq .image.tag "$d/a.yaml")" = "$GAME" ] && [ "$(yq .image.tag "$d/b.yaml")" = "$REALM" ]; }; then bad "deploy.yml $1: a file not at its own pin"; return; fi
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
# shellcheck disable=SC2016 # a literal ${{, not a shell expansion
if [ "$(yq '.jobs.guard.steps[0].env.DEPLOY' "$WF")" = '${{ inputs.deploy }}' ]; then ok "image.yml guard reads inputs.deploy"; else bad "image.yml guard ignores inputs.deploy"; fi
for o in tag commit digest; do
  if [ "$(yq ".on.workflow_call.outputs.$o.value" "$WF")" = "\${{ jobs.build.outputs.$o }}" ]; then ok "image.yml output $o comes from the build job"; else bad "image.yml output $o"; fi
done
# deploy.yml decides like image.yml's deploy output.
yq '.jobs.guard.steps[] | select(.name == "Decide whether this run may deploy") | .run' "$DWF" > "$T/dg.sh"
dg() { # want name EVENT REF
  : > "$T/dgout"; EVENT=$3 REF=$4 DEFAULT_BRANCH=main GITHUB_OUTPUT="$T/dgout" bash "$T/dg.sh" >/dev/null 2>&1
  if [ "$(sed -n 's/^deploy=//p' "$T/dgout")" = "$1" ]; then ok "deploy.yml guard: $2"; else bad "deploy.yml guard: $2"; fi
}
dg true  "push on main deploys"        push              refs/heads/main
dg true  "dispatch on main deploys"    workflow_dispatch refs/heads/main
dg false "push on a branch does not"   push              refs/heads/feat
dg false "pull_request does not"       pull_request      refs/heads/main
dg false "workflow_run does not"       workflow_run      refs/heads/main
if [ "$(yq '.jobs.deploy.if' "$DWF")" = "needs.guard.outputs.deploy == 'true'" ]; then ok "deploy.yml deploy job reads the guard only"; else bad "deploy.yml deploy job if"; fi

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
# Each gated step reads the guard alone (Forgejo mis-evaluates long ifs that mix ! and &&).
for sn in "Pick the Infisical login" "Read the registry password from Infisical" "Read the registry password over Forgejo OIDC" "Keep only the registry password" "Registry login" "Push" "Registry logout"; do
  case $sn in
    "Read the registry password from Infisical") want="needs.guard.outputs.publish == 'true' && steps.infisical.outputs.method != 'forgejo'" ;;
    "Read the registry password over Forgejo OIDC") want="needs.guard.outputs.publish == 'true' && steps.infisical.outputs.method == 'forgejo'" ;;
    "Registry logout") want="always() && needs.guard.outputs.publish == 'true'" ;;
    *) want="needs.guard.outputs.publish == 'true'" ;;
  esac
  if [ "$(yq ".jobs.build.steps[] | select(.name == \"$sn\") | .if" "$WF")" = "$want" ]; then ok "gate on '$sn' is the guard"; else bad "gate on '$sn' is not exactly the guard"; fi
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
f=$WF # image-build.yml is gone (#28): one file left, no loop
for j in $(yq '.jobs | keys | .[]' "$f"); do
  if [ "$(yq ".jobs.$j.timeout-minutes // \"\"" "$f")" != "" ]; then ok "$(basename "$f") job $j has timeout-minutes"; else bad "$(basename "$f") job $j has no timeout-minutes"; fi
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

# Forgejo runs a called workflow's jobs with event_name workflow_call; the
# caller's event survives only in the payload, and long if: expressions that
# mix ! and && come out wrong there. So the four reusable workflows read
# github.event_name only through the EVENT map below (scripts decide), and no
# if: in them reads github.event except trailers' pull_request check.
emap="\${{ github.event_name != 'workflow_call' && github.event_name || github.event.pull_request && 'pull_request' || github.event.workflow_run && 'workflow_run' || github.event.pusher && 'push' || github.event.workflow && 'workflow_dispatch' || 'workflow_call' }}"
for f in release image deploy trailers; do
  w=.github/workflows/$f.yml
  left=$(E=$emap python3 -c 'import os,sys; s=open(sys.argv[1]).read().replace(os.environ["E"],""); print(s.count("github.event_name"))' "$w")
  if [ "$left" = 0 ]; then ok "$f.yml: github.event_name only through the EVENT map"; else bad "$f.yml: $left github.event_name read(s) outside the EVENT map"; fi
  ifs=$(yq '.. | select(has("if")) | .if' "$w" 2>/dev/null | grep -F 'github.event' | grep -vxF 'github.event.pull_request' || true)
  if [ -z "$ifs" ]; then ok "$f.yml: no if: reads github.event"; else bad "$f.yml: if: reads github.event: $ifs"; fi
done

# ci.yml's self-test picker: each self-test runs only for its own files; ci.yml
# changes and pushes (no base) run all.
yq '.jobs.changes.steps[] | select(.name == "Pick the self-tests") | .run' "$(dirname "$WF")/ci.yml" > "$T/pick.sh"
[ -s "$T/pick.sh" ] || { echo "FAIL extract self-test picker"; exit 1; }
pick() { # name want(go,status,bun,rust,image as 0/1 string) files...
  local name=$1 want=$2 d base got; shift 2
  d=$(mktemp -d "$T/pick.XXXX"); git init -q "$d"; git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  base=$(git -C "$d" rev-parse HEAD)
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; echo x > "$d/$f"; done
  if [ $# -gt 0 ]; then git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m change; fi
  [ "$name" = "push runs all" ] && base=''
  : > "$T/pout"; (cd "$d" && BASE=$base GITHUB_OUTPUT="$T/pout" bash "$T/pick.sh") || { bad "self-test picker: $name: failed"; return; }
  got=$(for k in go status bun rust image; do [ "$(sed -n "s/^$k=//p" "$T/pout")" = true ] && printf 1 || printf 0; done)
  if [ "$got" = "$want" ]; then ok "self-test picker: $name"; else bad "self-test picker: $name (got $got want $want)"; fi
}
pick "go-checks.yml runs go and status" 11000 .github/workflows/go-checks.yml
pick "a rust fixture runs rust only" 00010 test/fixture-rust/src/lib.rs
pick "image.yml runs the image tests" 00001 .github/workflows/image.yml
pick "release.yml runs the image tests" 00001 .github/workflows/release.yml
pick "README runs nothing" 00000 README.md
pick "ci.yml runs all" 11111 .github/workflows/ci.yml
pick "push runs all" 11111 README.md
pick "cliff.toml runs the image tests" 00001 cliff.toml
# A move out of a covered path still runs that self-test (--no-renames).
d=$(mktemp -d "$T/pick.XXXX"); git init -q "$d"; mkdir -p "$d/standard-status"; echo x > "$d/standard-status/a.go"
git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m base; b=$(git -C "$d" rev-parse HEAD)
mkdir -p "$d/elsewhere"; git -C "$d" mv standard-status/a.go elsewhere/a.go; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m move
: > "$T/pout"; (cd "$d" && BASE=$b GITHUB_OUTPUT="$T/pout" bash "$T/pick.sh")
if [ "$(sed -n 's/^status=//p' "$T/pout")" = true ]; then ok "self-test picker: a move out of standard-status runs status"; else bad "self-test picker: a rename hid the old path"; fi
# A failing diff runs everything.
: > "$T/pout"; (cd "$d" && BASE=0000000000000000000000000000000000000000 GITHUB_OUTPUT="$T/pout" bash "$T/pick.sh" 2>/dev/null)
if [ "$(grep -c '=true$' "$T/pout")" = 5 ]; then ok "self-test picker: an unknown base runs all"; else bad "self-test picker: an unknown base must run all"; fi
# Every gate reads an output the changes job sets, and needs it.
CI=$(dirname "$WF")/ci.yml
for j in $(yq -r '.jobs | to_entries[] | select((.value.if // "") | test("needs.changes.outputs")) | .key' "$CI"); do
  k=$(yq -r ".jobs.\"$j\".if" "$CI" | sed -nE 's/.*needs\.changes\.outputs\.([a-z]+).*/\1/p')
  if [ "$(yq -r ".jobs.changes.outputs.$k // \"\"" "$CI")" != "" ] && yq -r ".jobs.\"$j\".needs" "$CI" | grep -qw changes; then ok "ci.yml $j gate wired to changes.$k"; else bad "ci.yml $j gate not wired ($k)"; fi
done

echo "failures: $fails"
[ "$fails" = 0 ]
