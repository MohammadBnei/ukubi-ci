#!/usr/bin/env bash
# Runs release.yml's own Release block (extracted with yq, never copied)
# against throwaway repos, each with a local bare "origin". Needs bash, yq v4,
# git, jq and the pinned git-cliff on PATH (ci.yml installs it with
# release.yml's own install block; locally put the release binary on PATH).
# Usage: test/release.sh [path/to/.github/workflows]
# Checks are strings run by eval, and hooks/configs hold literal $:
# shellcheck disable=SC2016,SC2034
set -uo pipefail
W=${1:-$(dirname "$0")/../.github/workflows}
R=$(cd "$W/../.." && pwd)
WF=$W/release.yml
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; } # name condition

step() { yq ".jobs.release.steps[] | select(.name == \"$1\") | .run" "$WF"; }
step Release > "$T/rel.sh"
[ -s "$T/rel.sh" ] || { echo "FAIL extract Release from $WF"; exit 1; }
pin=$(step 'Install git-cliff' | sed -n 's/^v=//p')
[ "$(git-cliff --version 2>/dev/null)" = "git-cliff $pin" ] \
  || { echo "FAIL need git-cliff $pin on PATH (got: $(git-cliff --version 2>&1))"; exit 1; }

# Shims: no real sleeps between push attempts.
mkdir -p "$T/bin"; printf '#!/bin/sh\n:\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"
REALGIT=$(command -v git)
as() { GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid "$@"; }
# repo <name>: a bare origin and a clone of it on main. Sets D (clone) and O (origin).
repo() {
  O=$T/$1.git D=$T/$1
  git init -q --bare -b main "$O"; git clone -q "$O" "$D" 2>/dev/null
  git -C "$D" checkout -q -b main 2>/dev/null || true
}
c() { as git -C "$D" commit -q --allow-empty -m "$1"; } # commit an empty change
pushall() { git -C "$D" push -q --follow-tags origin HEAD:main 2>/dev/null; git -C "$D" push -q --tags origin 2>/dev/null; }
remote() { git -C "$O" for-each-ref --format='%(refname) %(objectname)' | sort; }
# rel [VAR=value ...]: run the block in $D; sets rc, out, version, tag, released.
rel() {
  : > "$T/gh-out"; : > "$T/summary"
  out=$(cd "$D" && env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    PATH="$T/bin:$PATH" TOKEN=s3cr3t-token EVENT=push REF=refs/heads/main BRANCH=main CONFIG='' CHANGELOG=CHANGELOG.md \
    GITHUB_OUTPUT="$T/gh-out" GITHUB_STEP_SUMMARY="$T/summary" "$@" bash "$T/rel.sh" 2>&1); rc=$?
  version=$(sed -n 's/^version=//p' "$T/gh-out"); tag=$(sed -n 's/^tag=//p' "$T/gh-out")
  released=$(sed -n 's/^released=//p' "$T/gh-out")
}
outs() { [ "$rc" = 0 ] && [ "$version|$tag|$released" = "$1" ] || { echo "     rc=$rc outputs '$version|$tag|$released' want '$1'"; echo "$out" | tail -5 | sed 's/^/     /'; return 1; }; }
at_origin() { git -C "$O" show "main:${1:-CHANGELOG.md}" 2>/dev/null; }

# (a) First release: no tags, a feat -> v0.1.0, commit + annotated tag on origin.
repo a; c 'chore: init'; c 'feat: first thing'; pushall
rel
check "a: no tags + feat -> 0.1.0 released" "outs '0.1.0|v0.1.0|true'"
check "a: origin main is chore(release): v0.1.0 by release-ci" \
  "[ \"\$(git -C '$O' log -1 --format='%s|%an|%ae' main)\" = 'chore(release): v0.1.0|release-ci|noreply@bnei.dev' ]"
check "a: v0.1.0 is an annotated tag on that commit" \
  "[ \"\$(git -C '$O' cat-file -t v0.1.0)\" = tag ] && [ \"\$(git -C '$O' rev-parse 'v0.1.0^{commit}')\" = \"\$(git -C '$O' rev-parse main)\" ]"
check "a: CHANGELOG created with header and section" \
  "at_origin | head -1 | grep -qx '# Changelog' && at_origin | grep -q '^## 0.1.0 - ' && at_origin | grep -qx -- '- First thing'"
before=$(remote); rel
check "a: re-run is a no-op that reports the tip's tag" "outs '0.1.0|v0.1.0|false' && [ \"\$(remote)\" = \"\$before\" ]"

# (b) Bare last tag keeps its prefix; release-it entries survive byte for byte.
repo b; c 'chore: init'
old='## [0.10.2](https://github.com/x/y/compare/0.10.1...0.10.2) (2026-10-20)

### Bug Fixes

* keep this line ([abc1234](https://github.com/x/y/commit/abc1234))
'
printf '# Changelog\n\n%s' "$old" > "$D/CHANGELOG.md"; git -C "$D" add CHANGELOG.md; c 'chore: release 0.10.2'
git -C "$D" tag 0.10.2; c 'fix: a fix'; pushall
rel
check "b: 0.10.2 + fix -> 0.10.3 (bare prefix kept)" "outs '0.10.3|0.10.3|true'"
check "b: header first, new section, old entries kept as the tail" \
  "at_origin | head -1 | grep -qx '# Changelog' && at_origin | grep -q '^## 0.10.3 - ' && [ \"\$(at_origin | tail -n $(printf '%s' "$old" | wc -l | tr -d ' '))\" = \"\$(printf '%s' \"\$old\")\" ]"

# (c) Bump table (dry runs).
bump() { # name start-tag subject want-version
  repo "c$RANDOM"; c 'chore: init'; [ -n "$2" ] && git -C "$D" tag "$2"; c "$3"; pushall
  rel EVENT=pull_request REF=refs/pull/1/merge
  check "c: $1" "outs '$4||false'"
}
bump "0.x feat -> minor" 0.3.0 'feat: x' 0.4.0
bump "0.x feat! -> minor" 0.3.0 'feat!: x' 0.4.0
bump "1.x feat! -> major" v1.2.0 'feat!: x' 2.0.0
bump "1.x feat -> minor" v1.2.0 'feat: x' 1.3.0
bump "fix -> patch" 0.3.0 'fix: x' 0.3.1
bump "docs -> patch" 0.3.0 'docs: x' 0.3.1
bump "non-conventional -> patch" 0.3.0 'Update the journal' 0.3.1
bump "random and rc tags are not releases" 0.3.0 'fix: x' 0.3.1
git -C "$D" tag random; git -C "$D" tag v9.9.9-rc1; rel EVENT=pull_request REF=refs/pull/1/merge
check "c: tags 'random' and 'v9.9.9-rc1' ignored" "outs '0.3.1||false'"

# (d) Only bot commits since the tag: nothing released, origin unchanged.
repo d; c 'chore: init'; c 'feat: x'; git -C "$D" tag -a 0.3.0 -m 0.3.0
c 'chore(deploy): bump d image to 0123456789ab'; c 'chore(release): v0.9.9'; c 'chore: update helm image tag'
c "Merge 1111111 into 2222222"; pushall; before=$(remote)
rel
check "d: only skipped commits -> released=false, untagged tip" "outs '0.3.0||false' && [ \"\$(remote)\" = \"\$before\" ]"

# (e) Dry runs never touch origin or local tags.
repo e; c 'chore: init'; c 'feat: x'; pushall
for x in 'pull_request refs/pull/1/merge' 'push refs/heads/feature' 'workflow_dispatch refs/heads/other' 'pull_request_target refs/heads/main'; do
  read -r ev ref <<<"$x"; before=$(remote); lt=$(git -C "$D" tag)
  rel EVENT="$ev" REF="$ref"
  check "e: $ev on $ref is a dry run" "outs '0.1.0||false' && [ \"\$(remote)\" = \"\$before\" ] && [ \"\$(git -C '$D' tag)\" = '$lt' ] && grep -q 'would release v0.1.0' '$T/summary' && grep -qx -- '- X' '$T/summary'"
done

repo e2; c 'chore: init'; c 'feat: x'; pushall
rel EVENT=workflow_dispatch
check "e: workflow_dispatch on the default branch releases" "outs '0.1.0|v0.1.0|true'"
# A non-conventional commit with a body and trailers renders as its subject only.
repo e3; c 'chore: init'; c "$(printf 'Update the journal\n\nprivate line\nAgent-Session: x')"; pushall
rel EVENT=pull_request REF=refs/pull/1/merge
check "e: multi-line commit -> one list line, no body or trailers" \
  "[ \"\$(grep -c 'Update the journal' '$T/summary')\" = 1 ] && grep -qx -- '- Update the journal' '$T/summary' && ! grep -qE 'private line|Agent-Session' '$T/summary'"

# (f) Origin moves between attempt 1's fetch and its push: retry from the new tip.
repo f; c 'chore: init'; git -C "$D" tag 0.1.0; c 'fix: already unreleased'; pushall
git clone -q "$O" "$T/f2" 2>/dev/null
printf '#!/bin/sh\ncase " $* " in *" push "*) if [ ! -e %s ]; then : > %s; ( cd %s && GIT_AUTHOR_NAME=o GIT_AUTHOR_EMAIL=o@o GIT_COMMITTER_NAME=o GIT_COMMITTER_EMAIL=o@o %s commit -q --allow-empty -m "fix: injected" && %s push -q origin HEAD:main ); fi;; esac\nexec %s "$@"\n' \
  "$T/raced" "$T/raced" "$T/f2" "$REALGIT" "$REALGIT" "$REALGIT" > "$T/bin/git"; chmod +x "$T/bin/git"
rel
rm "$T/bin/git"
check "f: race -> released on attempt 2" "outs '0.1.1|0.1.1|true' && grep -q 'attempt 1' <<<\"\$out\""
check "f: changelog lists the unreleased and the injected commit" \
  "at_origin | grep -qx -- '- Already unreleased' && at_origin | grep -qx -- '- Injected'"
check "f: tag on the release commit, above the injected one" \
  "[ \"\$(git -C '$O' rev-parse '0.1.1^{commit}')\" = \"\$(git -C '$O' rev-parse main)\" ] && [ \"\$(git -C '$O' log -1 --format=%s main~1)\" = 'fix: injected' ]"
# Reject once without origin moving: attempt 2 must not trip on its own local tag.
repo f3; c 'chore: init'; c 'feat: x'; pushall
printf '#!/bin/sh\nif [ ! -e %s ]; then : > %s; exit 1; fi\n' "$T/rej1" "$T/rej1" > "$O/hooks/pre-receive"; chmod +x "$O/hooks/pre-receive"
rel
check "f: rejected once -> released on attempt 2" "outs '0.1.0|v0.1.0|true'"

# (g) Origin rejects the branch only: atomic, so the tag must not land either.
repo g; c 'chore: init'; c 'feat: x'; pushall; before=$(remote)
printf '#!/bin/sh\ncase "$1" in refs/heads/*) exit 1;; esac\n' > "$O/hooks/update"; chmod +x "$O/hooks/update"
rel
check "g: branch rejected -> step fails, origin unchanged (no tag)" "[ '$rc' != 0 ] && [ \"\$(remote)\" = \"\$before\" ]"
rm "$O/hooks/update"

# (h) Config selection; the CLI tag pattern always wins.
caller='[changelog]
header = "# Caller log\n\n"
body = "## {{ version }}\n"
[git]
conventional_commits = true
tag_pattern = "^release-.*"
'
repo h; c 'chore: init'; git -C "$D" tag 0.3.0; git -C "$D" tag release-9; c 'fix: x'
printf '%s' "$caller" > "$D/cliff.toml"; git -C "$D" add cliff.toml; c 'chore: caller config'; pushall
rel EVENT=pull_request REF=refs/pull/1/merge
check "h: caller cliff.toml used, its tag_pattern overridden" "outs '0.3.1||false' && grep -qx '## 0.3.1' '$T/summary'"
git -C "$D" rm -q cliff.toml; c 'chore: drop config'
rel EVENT=pull_request REF=refs/pull/1/merge
check "h: no cliff.toml -> embedded default" "outs '0.3.1||false' && grep -q '^## 0.3.1 - ' '$T/summary'"
rel EVENT=pull_request REF=refs/pull/1/merge CONFIG=ci/missing.toml
check "h: explicit missing config fails" "[ '$rc' != 0 ] && grep -q 'not found' <<<\"\$out\""
mkdir -p "$D/ci"; printf '%s' "$caller" > "$D/ci/cliff.toml"
rel EVENT=pull_request REF=refs/pull/1/merge CONFIG=ci/cliff.toml
check "h: explicit config path used" "outs '0.3.1||false' && grep -qx '## 0.3.1' '$T/summary'"

# (i) A template whose section lacks the version fails, though git-cliff exits 0.
repo i; c 'chore: init'; c 'feat: x'
printf '[changelog]\nbody = "- something\\n"\n[git]\nconventional_commits = true\n' > "$D/cliff.toml"
git -C "$D" add cliff.toml; c 'chore: config'; pushall; before=$(remote)
rel
check "i: version not in the changelog diff -> fails, origin unchanged" \
  "[ '$rc' != 0 ] && grep -q 'did not land' <<<\"\$out\" && [ \"\$(remote)\" = \"\$before\" ]"

# (l) The token is out of git-cliff's environment (postprocessors run commands).
repo l; c 'chore: init'; c 'feat: x'
printf '[changelog]\nbody = "## {{ version }}\\n"\npostprocessors = [{ pattern = "##", replace_command = "printf %%s \\"${TOKEN:-}\\" > %s; cat" }]\n[git]\nconventional_commits = true\n' "$T/leak" > "$D/cliff.toml"
git -C "$D" add cliff.toml; c 'chore: config'; pushall
rel
check "l: postprocessor ran and saw no TOKEN" "outs '0.1.0|0.1.0|true' && [ -e '$T/leak' ] && [ ! -s '$T/leak' ]"

# (j) The embedded default is the root cliff.toml byte for byte.
check "j: embedded config == cliff.toml" "diff <(awk \"/<<'CLIFF'/{f=1;next} /^CLIFF\\\$/{f=0} f\" '$T/rel.sh') '$R/cliff.toml' >/dev/null"

# (k) Shape.
check "k: job permissions exactly contents: write" "[ \"\$(yq -o=json -I0 '.jobs.release.permissions' '$WF')\" = '{\"contents\":\"write\"}' ]"
check "k: concurrency queues per ref, never cancels" "[ \"\$(yq -o=json -I0 '.jobs.release.concurrency' '$WF')\" = '{\"group\":\"ukubi-ci-release-\${{ github.repository }}-\${{ github.ref }}\",\"cancel-in-progress\":false}' ]"
# shellcheck disable=SC2016 # a literal ${{, not a shell expansion
check "k: no expression inside a run block" "! yq '.jobs[].steps[].run | select(. != null)' '$WF' | grep -qF '\${{'"
check "k: checkout full history, persist-credentials false" \
  "[ \"\$(yq -o=json -I0 '.jobs.release.steps[0].with' '$WF')\" = '{\"fetch-depth\":0,\"persist-credentials\":false}' ]"
check "k: install checks sha256" "step 'Install git-cliff' | grep -q 'sha256sum -c'"
check "k: TOKEN only in the Release step" "[ \"\$(yq '[.jobs.release.steps[] | select(.env.TOKEN) | .name] | join(\",\")' '$WF')\" = Release ]"
check "k: every fetch and push carries the auth header" \
  "[ \"\$(grep -cE 'git .*(fetch|push) ' '$T/rel.sh')\" = 2 ] && ! grep -E 'git .*(fetch|push) ' '$T/rel.sh' | grep -vq 'http.extraheader=\"\$hdr\"'"
sha=$(step 'Install git-cliff' | sed -n 's/^sha=//p')
check "k: the git-cliff pin lives only in release.yml" \
  "[ -n '$sha' ] && [ -z \"\$(grep -rlF '$sha' '$R' --exclude-dir=.git | grep -v '/release.yml\$')\" ]"

echo "failures: $fails"
[ "$fails" = 0 ]
