# ukubi-ci

Reusable workflows (`on: workflow_call`) and composite actions shared by the
ukubi app repos: image build, push and tag bump; Go, Bun and Rust checks; the
commit-trailer check; releases. They run on Forgejo Actions and GitHub Actions
alike; moving a caller to Forgejo is [MIGRATION.md](MIGRATION.md).

App repos call them pinned by commit sha:

```yaml
uses: MohammadBnei/ukubi-ci/.github/workflows/<name>.yml@<40-char sha>
```

Each workflow documents its inputs below as it lands.

## image.yml

Builds one image with buildah, pushes `<registry>/<image>:<12-char sha>`, then
bumps the tag in the caller's helm values on its default branch (ArgoCD rolls
it out). On `pull_request` it only builds: no Infisical, login, push or bump.

```yaml
# .github/workflows/app.yml in the app repo
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

jobs:
  image:
    # Required on every event, pull_request too: GitHub checks the nested
    # jobs' permissions before any job starts (startup_failure otherwise).
    permissions:
      contents: write   # the deploy job's bump commit
      id-token: write   # the Infisical OIDC login
    uses: MohammadBnei/ukubi-ci/.github/workflows/image.yml@<40-char sha>
    with:
      # Every job runs on the build runner, PRs included; on a
      # pull_request nothing logs in, reads Infisical, pushes or bumps.
      runs-on: '["ukubi-build"]'
      image: drop
```

hq-style layout (Dockerfile and context in a subdirectory):

```yaml
    with:
      image: hq
      context: app
      dockerfile: app/Dockerfile        # relative to the repo root, not to context
      values-file: app/helm/values.yaml
```

| input | default | |
|---|---|---|
| `runs-on` | required | JSON list of runner labels |
| `image` | required | name under the registry, `^[a-z0-9][a-z0-9._/-]*$` |
| `ref` | triggering commit | a release tag to build instead |
| `context` | `.` | relative to the repo root |
| `dockerfile` | `Dockerfile` | relative to the repo root |
| `target` | | multi-stage `--target` |
| `build-args` | | multiline `KEY=VALUE`; logged, never a secret |
| `layers` | `true` | `--layers` (large images may want `false`: layers stay on the shared disk until the weekly prune) |
| `pull-newer` | `true` | `--pull=newer` |
| `values-file` | `helm/values.yaml` | empty (with `values-files` empty) skips the deploy job |
| `values-files` | | several values files, newline or space separated, each pinning `values-key` for this same image only (one call per image: wird's adminweb file does not go in the api call), each once; one bump commit. Several images in one commit: `deploy: false` plus [deploy.yml](#deployyml). Replaces `values-file` when set. The stale-run guard skips when any file's pin descends from the built commit; a file already at the pin is skipped, and no file changed means no commit |
| `version-arg` | `false` | pass `--build-arg VERSION`: `X.Y.Z` when `ref` is a release tag, else `X.Y.Z+<sha12>` on the default branch, else `X.Y.Z-dev+<sha12>` (`0.0.0` before the first release) |
| `version` | | release.yml's `version` output; needs `version-arg`. Must be `X.Y.Z`, or empty with an empty `ref` |
| `build-timeout-minutes` | `60` | build job cap (callers cannot set `timeout-minutes` on a `uses:` job; guard is 5, deploy 10). Slowest observed build is about 7 min |
| `registry-secret-path` | `/` | Infisical folder of `REGISTRY_PASSWORD`. Only that key reaches the build job's env, but the action fetches the whole folder; point this at a folder holding just the password (e.g. `/registry`) to stop app secrets being fetched at all |
| `cancel-in-progress` | `true` | build concurrency; `false` never cancels a running build (release callers: a cancel leaves a pushed tag with no image); GitHub still keeps one pending run per group, and a newer push replaces a pending one. The deploy group never cancels |
| `push-default-branch-only` | `false` | `true` builds on any ref but skips the registry login, push and deploy off the default branch, tag refs included (a release caller using it pushes nothing; the password is never read there). For a registry that keeps few tags per repo (zot keeps 2 for ukubi-stt), where a branch dispatch would evict the rollback image. Off the default branch `digest` is empty |
| `extra-tags` | | multiline extra tags (e.g. `latest`), each `[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}`, pushed after the sha tag from the same local image, so with the same digest, and only on the default branch (a branch build never moves `latest`). A mismatch or a failed extra push only warns: the sha tag and digest are already pushed and the deploy runs. The deploy job still pins `sha@digest`, never an extra tag |
| `values-key` | `.image.tag` | yq path; the value must be double-quoted, two-space indented |
| `deploy-branch` | `deploy` | branch the bump commits to; the files in `values-file(s)` are pin files on that branch (created from `values-key` on first use, the branch as an orphan). ArgoCD layers them over the default branch's values. Set to `''` to commit to the default branch, as before 0.11 (branch protection then blocks it) |
| `deploy` | `true` | `false` skips the deploy job (build and push only); bump with [deploy.yml](#deployyml) instead, to roll several images out in one commit |
| `registry` | `registry.bnei.lan:5000` | |
| `infisical-auth` | `auto` | the Infisical login: `oidc` (GitHub OIDC, `id-token: write`), `forgejo` (Forgejo's Actions OIDC token traded at Infisical's JWT auth, identity `ci-forgejo-tier1`; image.yml sets `enable-openid-connect` at workflow level; see MIGRATION.md), `universal` (secrets `infisical-client-id` and `infisical-client-secret`), `auto` = `oidc` on github.com, `forgejo` elsewhere (Forgejo sets `FORGEJO_ACTIONS` and its own `GITHUB_SERVER_URL`). Checked only on a publishing run, so PRs need neither |

Secret `build-secrets` (optional): multiline `id=value`. Each becomes
`--secret id=<id>`, read in the Dockerfile with
`RUN --mount=type=secret,id=<id>`. Example: `build-secrets: github_token=${{ github.token }}`.
Secrets `infisical-client-id` and `infisical-client-secret` (optional): the
universal-auth login; a publishing run with `universal` and either missing fails.
Outputs: `tag`, the pushed tag; `digest`, the pushed manifest digest;
`commit`, the full built sha (set with `deploy: false` too).

Rules:

- The `guard` job runs on the passed `runs-on` runner and decides `publish` from an
  allowlist: only `push` and `workflow_dispatch` publish. On `pull_request`,
  `pull_request_target` or any other event the build runs but the Infisical,
  login, push and logout steps and the deploy job are skipped. It is not the
  security boundary: a PR can edit the caller's own workflow and skip image.yml.
  The boundary is the runner and repo configuration (per-repo build runners, no
  fork PR runs on private repos, the Infisical identity bound to `push` and
  `workflow_dispatch`). Unlike before, PR code now runs on the same box as
  releases: a PR's build can reach whatever the runner user can.

- Secrets go in `build-secrets`, never in `build-args` (those land in the
  log and the image history).
- No `:latest` is pushed; the helm values pin the sha. Zot keeps the 3 most
  recently pushed tags per image (2 for ukubi-stt), so a rebuild of an old
  commit can evict the deployed tag.
- A version label: pass `version-arg: true` (not a hand-written `VERSION=` build-arg; that combination fails) and set `ARG VERSION` +
  `LABEL org.opencontainers.image.version=$VERSION` in the Dockerfile.
- The deploy job runs on `push` and `workflow_dispatch` on the default
  branch only. It pins `<sha>@sha256:<digest>` (the chart renders
  `repository:<value>`, which the kubelet pulls by digest), so a rebuild of
  the same commit (base image CVE fix) rolls out. Builds are not
  reproducible, so every rebuild (re-run all jobs, a second dispatch) gets a
  new digest and redeploys; only re-running the deploy job alone, where the
  values already hold that value, is a green no-op. An empty digest fails the
  deploy. On a re-run (attempt > 1) the deploy is skipped (green, with a notice) when the commit already pinned in the values is a strict descendant of the built commit, so re-running an old run cannot roll back; a fresh dispatch always deploys, so a deliberate rollback is a dispatch with `ref`; an unknown pin deploys. Rare case: a stale re-run can displace a pending newer deploy in the concurrency group; dispatch again. Output `commit` is the full built sha. The bump changes exactly one line (no `yq -i`, which reformats).

Prerequisites per caller repo (infra-bootstrap
`.claude/skills/build-runner-ops/SKILL.md`):

- A build runner registered for the repo (`build_runner_repos` in
  `build-runner-configure.yml`); runners are per repo. Its sudoers grants
  `/usr/bin/buildah` only, so image.yml calls `sudo -n buildah` and nothing
  else.
- The repo on the `ci-oidc` identity's bound `repository` list. Under
  `workflow_call` the OIDC claims are the caller's. ukubi-ci itself must
  never be added there, and must never get a build runner.

## deploy.yml

Pins several images in the caller's helm values in **one** commit, so ArgoCD
rolls them out together. For a repo that ships images that must match (ukubi-game's
game and realm speak one protocol): build each with image.yml `deploy: false`,
then one deploy.yml job pins them all. Its stale-run guard, bump and commit
steps are image.yml's deploy steps byte for byte (`test/reusable.sh` checks),
so the rules above hold: `<sha>@sha256:<digest>` pins, one line changed per
file, a re-run of an old run is skipped, no commit when every file already
holds its pin, `git pull --rebase` retries. Runs on `push` and
`workflow_dispatch` on the default branch only, like image.yml's deploy job.

```yaml
# .github/workflows/app.yml in ukubi-game
jobs:
  game:
    permissions:
      contents: write   # checked on nested jobs even with deploy: false
      id-token: write
    uses: MohammadBnei/ukubi-ci/.github/workflows/image.yml@<40-char sha>
    with:
      runs-on: '["ukubi-build"]'
      image: ukubi-game
      build-args: BIN=game
      deploy: false
    secrets:
      build-secrets: mountain_token=${{ secrets.MOUNTAIN_READ_TOKEN }}
  realm:
    permissions:
      contents: write
      id-token: write
    uses: MohammadBnei/ukubi-ci/.github/workflows/image.yml@<40-char sha>
    with:
      runs-on: '["ukubi-build"]'
      image: ukubi-realm
      build-args: BIN=realm
      deploy: false
    secrets:
      build-secrets: mountain_token=${{ secrets.MOUNTAIN_READ_TOKEN }}
  deploy:
    # Skipped unless both builds succeed: never one image without the other.
    needs: [game, realm]
    permissions:
      contents: write
    uses: MohammadBnei/ukubi-ci/.github/workflows/deploy.yml@<40-char sha>
    with:
      built-commit: ${{ needs.game.outputs.commit }}
      pins: |
        helm/values.yaml ${{ needs.game.outputs.tag }}@${{ needs.game.outputs.digest }}
        helm/public.yaml ${{ needs.game.outputs.tag }}@${{ needs.game.outputs.digest }}
        helm/realm.yaml ${{ needs.realm.outputs.tag }}@${{ needs.realm.outputs.digest }}
```

| input | default | |
|---|---|---|
| `pins` | required | one `<values file> <sha12>@sha256:<64 hex>` per line; each file once, every file must exist (no skip-if-missing), paths relative to the repo root, no `..`, no symlink |
| `built-commit` | required | full sha the images were built from (image.yml's `commit`); all images come from one commit |
| `values-key` | `.image.tag` | yq path in every file, as in image.yml |
| `deploy-branch` | `deploy` | as in image.yml |
| `runs-on` | `["ubuntu-latest"]` | JSON list; the runner needs bash, git and curl (yq is installed by a step) |
| `commit-author` | `<repo>-ci` | bump commit author name |

The commit subject is `chore(deploy): bump <repo> images`; its body lists the
pins. A malformed line (bare sha, empty digest on a PR build, a third field)
fails before any file is edited.

## release.yml

Cuts a release from Conventional Commits with git-cliff 2.14.2 (sha256-pinned):
the next semver since the last `X.Y.Z` or `vX.Y.Z` tag, pushed as an annotated
tag by `release-ci` on the commit that triggered the run, its message the
version's section (`git tag -n99 <tag>`). Nothing is committed to the default
branch, so it can be protected (3 push attempts). Only `push` and `workflow_dispatch` on
the default branch release; any other event, `pull_request` included, is a dry
run that writes the would-be section to the step summary and pushes nothing.

Chain it before image.yml: the image builds the release tag and carries the
version as a label. The SHA tag still drives deploys.

```yaml
# .github/workflows/app.yml in the app repo
jobs:
  release:
    permissions:
      contents: write   # the CHANGELOG commit and the tag; needed on every event
    uses: MohammadBnei/ukubi-ci/.github/workflows/release.yml@<40-char sha>
  image:
    needs: release
    permissions:
      contents: write
      id-token: write
    uses: MohammadBnei/ukubi-ci/.github/workflows/image.yml@<40-char sha>
    with:
      runs-on: '["ukubi-build"]'
      image: drop
      ref: ${{ needs.release.outputs.tag }}            # empty on a dry run: the triggering commit
      version-arg: true
      version: ${{ needs.release.outputs.version }}
```

```dockerfile
ARG VERSION
LABEL org.opencontainers.image.version=$VERSION
```

| input | default | |
|---|---|---|
| `runs-on` | `["k8s-ubuntu-latest"]` | JSON list of runner labels; the default is the Talos runner (ephemeral unprivileged pod, image `ukubi-ci-runner`). CT 103 callers pass `["ubuntu-latest"]` |
| `config` | | git-cliff config. Empty: `cliff.toml` at the repo root if present, else this repo's [`cliff.toml`](cliff.toml) (embedded in release.yml). A non-empty path must exist |
| `changelog` | `CHANGELOG.md` | created on the first release |

| output | |
|---|---|
| `version` | `X.Y.Z`, no `v`: the release cut, or on a dry run the one that would be; with nothing to release, the last one |
| `tag` | the tag at the released commit; empty on a dry run, or when nothing was released and the triggering commit is untagged. A real release tags the triggering commit (plus any bot commits pushed on top of it), never newer work: if the default branch has moved past it by other commits, nothing is released and the run for those commits releases them |
| `released` | `true` when this run pushed a new tag |

Rules:

- One version line per repo. The tag pattern `^v?[0-9]+\.[0-9]+\.[0-9]+$` is
  always passed on the command line; a caller's `tag_pattern` cannot change
  it. The next tag keeps the last tag's prefix (`0.10.2` -> `0.10.3`); a repo
  with no tag starts at `v0.1.0`. wird's app tags `vX.Y.Z` itself today: its
  lane must make `release-app.yml` read this version instead of tagging, or
  the two flows fight over one tag line.
- Bumps: `feat` minor, anything else patch; a breaking change is a minor
  bump at `0.x` and a major one from `1.0.0`. A Go module must not cross
  `v1` -> `v2` this way without first changing its module path to `/v2`.
- Not counted (and not listed): `chore(release)`, image.yml's
  `chore(deploy)`, release-it's `chore: update helm image tag`, and merge
  commits. Only those since the last tag: `released=false`, no commit.
- Each commit is one line, its subject: never a body or trailers.
- A caller's own template must print the version in its section; the step
  fails if the version is not in the CHANGELOG diff (git-cliff exits 0 on a
  write error).
- A direct commit, not a PR: no caller protects its default branch. If one
  does later, the atomic push fails with nothing pushed.
- `GITHUB_TOKEN` pushes never trigger a run, so the release commit cannot
  loop. The token reaches git only on the fetch and the push
  (`http.extraheader`, masked) and is removed from the environment before
  git-cliff runs; the checkout keeps no credentials.
- Runs queue per repo and ref (`cancel-in-progress: false`), so dry runs
  never displace a real release. GitHub keeps one pending run per group: a
  third push to the default branch cancels the pending second one, whose
  commits the third run then releases (each run releases up to its own
  commit, so a run whose commit is no longer the tip releases nothing).
- `test/release.sh` runs the Release block against local repos only, and
  ukubi-ci is public: real mode on a private repo is first proven by the first
  private caller's run on its default branch.

## standard-status

Reports which Code Standard mechanisms each repo's origin default branch has,
as the markdown tables for standard §18 (one row per mechanism) and §19 (one
row per repo: tier, head, n/10). Stdlib Go; it shallow-clones each repo with
`gh repo clone`, so it needs `gh` authenticated for the repos (private ones
included) and runs only in local sessions, not in agent-fleet. It reads, prints
and writes no token.

```sh
go run github.com/MohammadBnei/ukubi-ci/standard-status@<40-char sha> \
  MohammadBnei/hq MohammadBnei/drop MohammadBnei/ukubi-bridge MohammadBnei/mountain \
  MohammadBnei/ukubi-game MohammadBnei/agent-fleet MohammadBnei/pi-lab
```

The output depends only on the repos' heads, so the same heads print the same
bytes. A repo that cannot be cloned gets an `unreadable` row and the exit code
is 1. "Not found" means the pattern search found nothing, not that the
mechanism is absent. Patterns live in `standard-status/main.go`.

The tier is read from the repo-root `CLAUDE.md`: a line that starts with
`Tier:`, then spaces or tabs, then one word, e.g. `Tier: service`. Other
spellings (`**Tier**: service`, the word on the next line) are reported as not
found.

Intended call convention: hq's weekly-review should call it once in its
Sources step and paste the output under a `## Standard status` heading in
`reviews/YYYY-MM-DD.md`, and the standard's §18 and §19 are updated from that.
When `gh` is not authenticated the review should write `Standard status not
generated`. That hq change is not part of this repo.

## Checks: go-checks, bun-checks, rust-checks, dockerfile-lint, trailers

Least-privilege checks for a caller's `checks.yml`. Each takes a `runs-on`
input (a JSON list) that defaults to `["k8s-ubuntu-latest"]`: the Talos runner,
an ephemeral one-job pod running as uid 1001 (no root, no apt, no sudo, no
`services:`, no `container:`, no image builds) on the `ukubi-ci-runner` image,
which bakes Go, Node 22, bun, Rust, protoc, buf, golangci-lint, hadolint, helm,
uv, yq and Playwright's Chromium (see `runner-image/README.md`). release.yml has
the same default. image.yml and deploy.yml keep the CT 103 labels: images build
and deploy only on main and tags. Every job is `contents: read`, and none
touches Infisical, OIDC or the registry. Inputs reach scripts through env only.
`test/reusable.sh` runs their run blocks against throwaway repos, and `ci.yml`
calls each one on a fixture under `test/`.

Caches (go-checks, rust-checks): a pull request restores and saves; main, push,
tag, schedule and dispatch never restore, they only save. The key is
`${{ vars.CACHE_EPOCH || 'e1' }}-<tool>-<os>-<lockfile hash>-<run id>`, restored by
prefix, so the newest entry wins and the cache refreshes on every run.

PRs never build images: image.yml's build job is skipped on `pull_request`, and
`dockerfile-lint.yml` lints Dockerfiles with hadolint instead (image-build.yml,
the PR build, is removed).

DB-backed tests: the Talos runner has no `services:` and no container engine.
Run them in the caller's own job with the `dev-db` action (below), against the
dev IntegreSQL, and keep them out of the go-checks call.

```yaml
# .github/workflows/checks.yml in the app repo
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  go:
    uses: MohammadBnei/ukubi-ci/.github/workflows/go-checks.yml@<40-char sha>
    with:
      working-directory: app
  web:
    uses: MohammadBnei/ukubi-ci/.github/workflows/bun-checks.yml@<40-char sha>
    with:
      working-directory: app/web
  dockerfiles:
    uses: MohammadBnei/ukubi-ci/.github/workflows/dockerfile-lint.yml@<40-char sha>
    with:
      dockerfiles: app/Dockerfile
```

```yaml
# .github/workflows/trailers.yml in the app repo: its own file, so a title or
# body edit re-runs only this cheap job, not the builds above.
on:
  pull_request:
    types: [opened, edited, synchronize, reopened]   # edited: re-check a title edit

permissions:
  contents: read

jobs:
  trailers:
    uses: MohammadBnei/ukubi-ci/.github/workflows/trailers.yml@<40-char sha>
    with:
      conventional: true
      agent-trailers: pair
```

### go-checks.yml

gofmt (over `git ls-files '*.go'`, minus `vendor/` and `testdata/`), `go vet ./...`, `go test -race -count=1 ./...`,
with Go from the module's `go.mod`.

| input | default | |
|---|---|---|
| `runs-on` | `["k8s-ubuntu-latest"]` | JSON list of runner labels; the default is the Talos runner (ephemeral unprivileged pod, image `ukubi-ci-runner`). CT 103 callers pass `["ubuntu-latest"]` |
| `working-directory` | `.` | a module directory (holds `go.mod`); a `go.work` root that is not a module rejects `./...` |
| `golangci-lint-version` | | `vX.Y.Z`; empty skips. Built with `go install` |
| `vettool` | | `pkg@vX.Y.Z` (never `@latest`), run as `go vet -vettool`; empty skips. The hook for ukubicheck |
| `test-flags` | | extra `go test` flags, e.g. `-p 1` when tests share one database; `[A-Za-z0-9 ._=,/:-]` only |
| `pre-test` | | a command run at the repo root before the tests, e.g. `docker compose up -d --wait postgres` |
| `govulncheck` | `false` | run `govulncheck ./...` (v1.9.0, built with the module's toolchain). Fails only on vulnerabilities the code calls; unreachable module advisories pass. Default is off because every current caller fails today on stdlib fixes (go1.27.3/1.27.4) and `golang.org/x/net` v0.60.0; bump `go.mod`, then enable |

Caching (go-checks and rust-checks): a pull request restores the module/build (Go) or cargo
(Rust) cache and saves it; a push, tag, dispatch or schedule never restores, it runs cold and only saves
(`actions/cache/save`). A PR job can forge the runner cache's write key, so an entry read on main would be
untrusted. Key: `<CACHE_EPOCH>-<go|rust>-<os>-<hash of go.mod+go.sum | Cargo.lock+rust-toolchain.toml>`; restore-keys
(PR only) match the prefix. `CACHE_EPOCH` is a user-level Forgejo variable (default `e1`): bump it to purge every
cache at once. The cache is never restored in CD.

### bun-checks.yml

Bun is pinned exactly from `package.json` `packageManager` (`bun@X.Y.Z`; a
missing pin, a range or a tag fails), then `bun install --frozen-lockfile`,
typecheck, test and the package's real build script.

| input | default | |
|---|---|---|
| `runs-on` | `["k8s-ubuntu-latest"]` | JSON list of runner labels; the default is the Talos runner (ephemeral unprivileged pod, image `ukubi-ci-runner`). CT 103 callers pass `["ubuntu-latest"]` |
| `working-directory` | `.` | holds `package.json` and `bun.lock` |
| `typecheck-script` | `typecheck` | empty skips |
| `lint-script` | | package.json script run after the typecheck; empty skips |
| `test-script` | `test` | empty skips |
| `build-script` | `build` | the real build; empty skips (a package with no build) |
| `dist` | | committed build output, relative to `working-directory`. After the build `git status --porcelain -- <dist>` must be empty (untracked files count). Must track files, and needs a `build-script` |

### rust-checks.yml

Two jobs. `check`: the toolchain `rust-toolchain.toml` names (required; asserted
active), `cargo fmt --all --check`, `cargo clippy --locked --workspace --all-targets -- -D warnings`,
`cargo test --locked --workspace`. `audit`: the cargo-audit 0.22.2 release binary, sha256-pinned,
run without any toolchain (it reads only `Cargo.lock`), blocking. The fixture crate has no
dependencies, so no advisory is ever hit in CI: the blocking exit and the
`--ignore` arguments are verified only by `test/reusable.sh` against a fake `cargo-audit`.

| input | default | |
|---|---|---|
| `runs-on` | `["k8s-ubuntu-latest"]` | JSON list of runner labels; the default is the Talos runner (ephemeral unprivileged pod, image `ukubi-ci-runner`). CT 103 callers pass `["ubuntu-latest"]` |
| `working-directory` | `.` | holds `Cargo.toml`, `Cargo.lock` and `rust-toolchain.toml` |
| `apt-packages` | | space-separated, e.g. `protobuf-compiler`; checked with `dpkg -s`, not installed: they must be baked into the runner image (or the build-runner playbook for a host runner) |
| `audit-ignore` | | multiline `RUSTSEC-YYYY-NNNN`, each passed as `--ignore`. `.cargo/audit.toml` is read too; keep the reasons there |

### dockerfile-lint.yml

hadolint over the named Dockerfiles, or every tracked `Dockerfile` and
`*.Dockerfile` when none are named. No build, no registry.

| input | default | |
|---|---|---|
| `runs-on` | `["k8s-ubuntu-latest"]` | JSON list of runner labels; needs hadolint on PATH (the runner image has it) |
| `dockerfiles` | | multiline paths relative to the repo root; empty lints every tracked Dockerfile |
| `failure-threshold` | `warning` | lowest severity that fails: error, warning, info, style |

### trailers.yml

Runs on `pull_request` and `pull_request_target` only; any other event is a
green no-op. It scans the PR's own commits (reachable from the head, not from
the base sha or the current base branch), merges included, and never older
history. A range it cannot list, or an empty one, fails.

Always refused, in each commit's message, author and committer, and in the PR
title and body: the vendor noreply address, claude.ai and claude.com URLs,
`Claude-Session:` lines, `Generated with` / `Generated by` footers, and
`Co-Authored-By` lines containing claude, anthropic or a model name (opus,
sonnet, haiku, gpt) anywhere, except exactly `Co-Authored-By: ukubi-agent <noreply@bnei.dev>` or `ukubi-agent-<host>`, where the host names no vendor or model (the old `ukubi-claude-<host>` form is refused, and so is any host containing one of those words, such as `ukubi-agent-claude` or `ukubi-agent-gptbox`).
The forms are anchored, so prose about the rule passes.

| input | default | |
|---|---|---|
| `runs-on` | `["k8s-ubuntu-latest"]` | JSON list of runner labels; the default is the Talos runner (ephemeral unprivileged pod, image `ukubi-ci-runner`). CT 103 callers pass `["ubuntu-latest"]` |
| `conventional` | `false` | Conventional Commit subjects on non-merge commits (git's `Revert "..."` passes, `fixup!` does not), and the PR title (a trailing ` (#N)` is ignored), since a squash lands the title |
| `allow-prefixes` | | multiline literal subject prefixes exempt from the Conventional rule only, never from the ban |
| `agent-trailers` | `any` | `forbid`: no agent `Co-Authored-By` or `Agent-Session` at all. `pair`: an agent commit carries both `Co-Authored-By: ukubi-agent[-<host>] <noreply@bnei.dev>` and `Agent-Session: <id>`, a human one neither |
| `extra-banned` | | an extra case-insensitive ERE, e.g. `generated with` for a repo that bans the words anywhere |

## dev-db and dev-db-release

Composite actions (shell, curl, jq; psql for the expiry comment) that give a job
a disposable, seeded Postgres database from the dev IntegreSQL (ADR-0088), on
GitHub Actions and Forgejo Actions alike. Pin them by commit sha like the
workflows: `MohammadBnei/ukubi-ci/actions/dev-db@<sha>`.

```yaml
steps:
  - uses: actions/checkout@<sha>
  - uses: MohammadBnei/ukubi-ci/actions/dev-db@<sha>
    with:
      integresql-url: https://integresql.dev.example
      token: ${{ secrets.DEV_DB_TOKEN }}
      # the template is keyed by a hash of migrations/ and seeds/ (and this command)
      seed-command: ./scripts/migrate-and-seed.sh   # sees DATABASE_URL
  - run: go test ./...                              # DATABASE_URL is exported
  - if: always()
    uses: MohammadBnei/ukubi-ci/actions/dev-db-release@<sha>
    with:
      token: ${{ secrets.DEV_DB_TOKEN }}
```

What `dev-db` does: `POST /templates {key}`, where the key is the first 32 hex
of sha256(`GITHUB_REPOSITORY`, hash), so two repos never share a template by
accident. A 200 means this job builds the template: it runs `seed-command`
against the template database, then `PUT /templates/<key>`.

Only that builder ever deletes the template, from its exit trap, and only while
it knows the template is not final: the seed failed, or the step got SIGINT or
SIGTERM during the seed. It forgets the template just before sending the PUT,
because a PUT can land on IntegreSQL and still look failed to the client (a
timeout or a lost answer). The PUT is retried on 000 and 5xx (a PUT on a final
template answers 204 too), a 404 fails the step (someone deleted the key), and
an answer that stays ambiguous fails the step with the recovery below. None of
these delete.

A 423 means another job built it or is building it: the action loops on
`GET /templates/<key>/tests`, which IntegreSQL holds open until the template is
final. A waiter never deletes. Any 500 keeps it polling until
`timeout-seconds`, then fails the step: IntegreSQL's not-final
`unexpected template state`, or another such as `timeout when waiting for ready
db` when the template's pool (`INTEGRESQL_TEST_MAX_POOL_SIZE`) is all handed
out. A refused connection or a 503 (IntegreSQL not up yet) is retried until
`timeout-seconds` too, for `POST` as for `GET`. On success it writes
`DATABASE_URL` (password masked) and `DEV_DB_*` to `GITHUB_ENV`, and sets the
expiry with `COMMENT ON DATABASE`
(`{"ttl":"<RFC 3339 UTC>","repo":..,"run":..,"keep":..}`), the format
infra-bootstrap's TTL sweeper reads.

### Stuck templates

**On Forgejo Actions, a cancelled or timed-out build leaves the template stuck.**
forgejo-runner (v13.2.2, podman) sends the step no signal on a run cancel or a
step `timeout-minutes`: it drops the exec and removes the container, so the trap
never runs. Tested on this repo: a cancel mid-seed ended the job within a
second with no trap output, and after a step timeout a probe step found the
template still there (`POST` answered 423). On GitHub Actions the runner sends
SIGINT, then SIGTERM, before killing the step, so the trap discards the
template there; that path is the one `test/dev-db/run.sh` tests, not tested on
GitHub itself. A SIGKILL, or a cancel while the PUT is in flight, leaves the
template unfinished on either platform.

A stuck template fails every job with that key at `timeout-seconds`, with an
error naming the key and this recovery. **Only if no job is building it now**,
delete it and rerun:

```sh
curl -X DELETE <integresql-url>/api/v1/templates/<key>
# add -H 'Authorization: Bearer <token>' behind the auth proxy
```

The action does not reclaim a stuck template itself: two waiters reclaiming
the same dead template race, and the later one deletes the other's fresh build
and the database it already handed out.

`INTEGRESQL_TEMPLATE_FINALIZE_TIMEOUT_MS` (how long IntegreSQL holds a GET on
an unfinished template, 60 s by default) must stay below the action's 90 s curl
`--max-time`, or every such GET times out on the client.

`keep: true` is best effort on IntegreSQL v1.1.0. A kept database stays handed
out in the template's pool; once that pool is full and short of ready
databases, IntegreSQL recreates the oldest handed-out one after 250 ms
(`pool.autoCleanDirty`, `INTEGRESQL_TEST_DB_MINIMAL_LIFETIME_MS`), kept ones
included, and the recreated database is a fresh copy without the ttl comment.
Inspect a kept database soon, or copy what you need out of it.

The credentials come from IntegreSQL. IntegreSQL v1.1.0 hands every caller,
seeder and test alike, its own manager role, so that role must not be a
superuser (on the dev Postgres it is `integresql`: NOSUPERUSER, CREATEDB). Until
an auth proxy sits in front of IntegreSQL, any job can still reach another job's
database with it, and can compute another repo's key; the proxy has to bind each
token to its repo's keys and hand out a per-database role.

| input | default | |
|---|---|---|
| `integresql-url` | required | base URL; its host is also the Postgres host unless `postgres-host` is set |
| `token` | | bearer token for the auth proxy; empty sends no header |
| `template-hash` | | `[A-Za-z0-9_-]{1,64}`; empty hashes `hash-paths` plus `seed-command`; hashed again with the repo name |
| `hash-paths` | `migrations seeds` | space-separated files or directories hashed when `template-hash` is empty; missing ones are skipped, none found is an error |
| `seed-command` | | runs only when the template is built, with `DATABASE_URL` set to it |
| `postgres-host` | `''` | Postgres host when it is not on the IntegreSQL host (ukubi: `dev-postgres.bnei.lan`) |
| `postgres-port` | `5432` | 1-65535; IntegreSQL reports its in-cluster address, so both host and port come from the caller |
| `sslmode` | `disable` | `sslmode` in `DATABASE_URL`; the dev Postgres is LAN-only without TLS |
| `ttl` | `2` | hours until the sweeper may drop the database; `0` skips the comment; no psql on the runner warns and skips |
| `keep` | `false` | copy of the release input, stored in the comment; `true` needs `ttl` above 0 and psql; not durable, see above |
| `timeout-seconds` | `600` | wait for IntegreSQL and a template build; at least `120` and longer than `seed-command` takes |

`dev-db-release` (inputs `token`, `keep`) is a separate action because composite
actions have no post step. It recreates the database unless `keep` is `true`; a
failed recreate only warns, the sweeper cleans up at the ttl. With no `dev-db`
step in the job it does nothing.

Self-test: `test/dev-db/run.sh` runs both actions' blocks against
`test/dev-db/compose.yml` (IntegreSQL + Postgres 18 by digest, both roles
non-superusers as on the dev Postgres, no new Docker network): build, recreate,
reuse, keep, the waiter, a failed and a cancelled seed, a killed builder with
two waiters that delete nothing and the manual recovery, a PUT whose answer is
lost, an exhausted pool, two repos with one hash, bad inputs and an IntegreSQL
that is not up yet. `.github/workflows/dev-db-selftest.yml` runs IntegreSQL and
Postgres as job services and covers build, recreate, reuse and keep only,
through `uses: ./actions/...`. It reaches them by service name (`postgres`,
`integresql`), which works on a container job (the Forgejo podman runner,
`ubuntu-latest`); the cancel, kill, lost-PUT, exhausted-pool and two-repo
cases run locally with `test/dev-db/run.sh`.
