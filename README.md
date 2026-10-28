# ukubi-ci

Reusable GitHub Actions workflows (`on: workflow_call`) and composite actions
shared by the ukubi app repos: image build, push and tag bump; Go, Bun and Rust
checks; the commit-trailer check.

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
      # PRs build on GitHub-hosted runners; image.yml refuses self-hosted on PRs.
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
