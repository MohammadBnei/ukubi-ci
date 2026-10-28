# ukubi-ci

Reusable GitHub Actions workflows (`on: workflow_call`) and composite actions
shared by the ukubi app repos: image build, push and tag bump; Go, Bun and Rust
checks; the commit-trailer check; releases.

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
      # PRs build on GitHub-hosted runners; on pull_request image.yml refuses
      # any runs-on label that is not ubuntu-*.
      runs-on: ${{ github.event_name == 'pull_request' && '["ubuntu-latest"]' || '["self-hosted","ukubi-build"]' }}
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
| `values-file` | `helm/values.yaml` | empty skips the deploy job |
| `values-key` | `.image.tag` | yq path; the value must be double-quoted, two-space indented |
| `registry` | `registry.bnei.lan:5000` | |

Secret `build-secrets` (optional): multiline `id=value`. Each becomes
`--secret id=<id>`, read in the Dockerfile with
`RUN --mount=type=secret,id=<id>`. Example: `build-secrets: github_token=${{ github.token }}`.
Output `tag`: the pushed tag.

Rules:

- On `pull_request` and `pull_request_target`, a GitHub-hosted `guard` job refuses any `runs-on` label
  that is not `ubuntu-*` before the build job is scheduled. It is a tripwire
  against a wrong `runs-on`, not the security boundary: a PR can edit the
  caller's own workflow and skip image.yml. The boundary is the runner and
  repo configuration (per-repo build runners, fork PR approval).

- Secrets go in `build-secrets`, never in `build-args` (those land in the
  log and the image history).
- No `:latest` is pushed; the helm values pin the sha. Zot keeps the 3 most
  recently pushed tags per image (2 for ukubi-stt), so a rebuild of an old
  commit can evict the deployed tag.
- A version label: pass it as a build-arg and set `ARG VERSION` +
  `LABEL org.opencontainers.image.version=$VERSION` in the Dockerfile.
- The deploy job runs on `push` and `workflow_dispatch` on the default
  branch only. A re-run where the values already hold the tag is a green
  no-op. The bump changes exactly one line (no `yq -i`, which reformats).

Prerequisites per caller repo (infra-bootstrap
`.claude/skills/build-runner-ops/SKILL.md`):

- A build runner registered for the repo (`build_runner_repos` in
  `build-runner-configure.yml`); runners are per repo. Its sudoers grants
  `/usr/bin/buildah` only, so image.yml calls `sudo -n buildah` and nothing
  else.
- The repo on the `ci-oidc` identity's bound `repository` list. Under
  `workflow_call` the OIDC claims are the caller's. ukubi-ci itself must
  never be added there, and must never get a build runner.

## release.yml

Cuts a release from Conventional Commits with git-cliff 2.14.2 (sha256-pinned):
the next semver since the last `X.Y.Z` or `vX.Y.Z` tag, its section prepended
to the CHANGELOG, a `chore(release): <tag>` commit by `release-ci` on the
default branch and an annotated tag, pushed together with `git push --atomic`
(3 attempts, each from the fresh tip). Only `push` and `workflow_dispatch` on
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
      runs-on: ${{ github.event_name == 'pull_request' && '["ubuntu-latest"]' || '["self-hosted","ukubi-build"]' }}
      image: drop
      ref: ${{ needs.release.outputs.tag }}            # empty on a dry run: the triggering commit
      build-args: VERSION=${{ needs.release.outputs.version }}
```

```dockerfile
ARG VERSION
LABEL org.opencontainers.image.version=$VERSION
```

| input | default | |
|---|---|---|
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

## Checks: go-checks, bun-checks, rust-checks, image-build, trailers

Five least-privilege checks for a caller's `checks.yml`. Each runs on
`ubuntu-latest`, every job is `contents: read`, and none touches Infisical,
OIDC, the registry or a self-hosted runner. Inputs reach scripts through env
only. `test/reusable.sh` runs their run blocks against throwaway repos, and
`ci.yml` calls each one on a fixture under `test/`.

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
  image:
    uses: MohammadBnei/ukubi-ci/.github/workflows/image-build.yml@<40-char sha>
    with:
      image: hq
      context: app
      dockerfile: app/Dockerfile
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
| `working-directory` | `.` | a module directory (holds `go.mod`); a `go.work` root that is not a module rejects `./...` |
| `golangci-lint-version` | | `vX.Y.Z`; empty skips. Built with `go install` |
| `vettool` | | `pkg@vX.Y.Z` (never `@latest`), run as `go vet -vettool`; empty skips. The hook for ukubicheck |
| `test-flags` | | extra `go test` flags, e.g. `-p 1` when tests share one database; `[A-Za-z0-9 ._=,/:-]` only |
| `pre-test` | | a command run at the repo root before the tests, e.g. `docker compose up -d --wait postgres` |

### bun-checks.yml

Bun is pinned exactly from `package.json` `packageManager` (`bun@X.Y.Z`; a
missing pin, a range or a tag fails), then `bun install --frozen-lockfile`,
typecheck, test and the package's real build script.

| input | default | |
|---|---|---|
| `working-directory` | `.` | holds `package.json` and `bun.lock` |
| `typecheck-script` | `typecheck` | empty skips |
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
| `working-directory` | `.` | holds `Cargo.toml`, `Cargo.lock` and `rust-toolchain.toml` |
| `apt-packages` | | space-separated, e.g. `protobuf-compiler` |
| `audit-ignore` | | multiline `RUSTSEC-YYYY-NNNN`, each passed as `--ignore`. `.cargo/audit.toml` is read too; keep the reasons there |

### image-build.yml

The image build as a PR check: image.yml's tag and Build steps byte for byte
(`sudo -n buildah bud --isolation chroot`, build-args, build-secrets), tagged
`localhost/<image>:<sha>`, with no login and no push. Inputs `image`
(required), `context`, `dockerfile`, `target`, `build-args`, `layers`,
`pull-newer` and secret `build-secrets`, as in image.yml.

### trailers.yml

Runs on `pull_request` and `pull_request_target` only; any other event is a
green no-op. It scans the PR's own commits (reachable from the head, not from
the base sha or the current base branch), merges included, and never older
history. A range it cannot list, or an empty one, fails.

Always refused, in each commit's message, author and committer, and in the PR
title and body: the vendor noreply address, claude.ai and claude.com URLs,
`Claude-Session:` lines, `Generated with` / `Generated by` footers, and
`Co-Authored-By` lines containing claude, anthropic or a model name (opus,
sonnet, haiku, gpt) anywhere, except exactly `Co-Authored-By: ukubi-claude-<host> <noreply@bnei.dev>`.
The forms are anchored, so prose about the rule passes.

| input | default | |
|---|---|---|
| `conventional` | `false` | Conventional Commit subjects on non-merge commits (git's `Revert "..."` passes, `fixup!` does not), and the PR title (a trailing ` (#N)` is ignored), since a squash lands the title |
| `allow-prefixes` | | multiline literal subject prefixes exempt from the Conventional rule only, never from the ban |
| `agent-trailers` | `any` | `forbid`: no agent `Co-Authored-By` or `Agent-Session` at all. `pair`: an agent commit carries both `Co-Authored-By: ukubi-claude-<host> <noreply@bnei.dev>` and `Agent-Session: <id>`, a human one neither |
| `extra-banned` | | an extra case-insensitive ERE, e.g. `generated with` for a repo that bans the words anywhere |
