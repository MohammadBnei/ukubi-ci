> Historical: written for the GitHub to Forgejo move (v0.8.0, 2026-11). Forgejo (https://git.bnei.dev) is now the primary forge for every active repo and GitHub is a push mirror; read the GitHub Actions remarks below as that period.

# Moving a caller to Forgejo Actions

From v0.8.0 the workflows run on Forgejo Actions and on GitHub Actions. This
page lists what each caller repo has to change once its git and CI live on
Forgejo. The workflow files stay in `.github/workflows/`: Forgejo reads that
folder when the repo has no `.forgejo/workflows/`, so do not add one.

## Before any repo moves (once, on the platform)

- **Actions are pulled from github.com.** Set `[actions] DEFAULT_ACTIONS_URL =
  https://github.com` in Forgejo's `app.ini`. Then the pinned
  `actions/checkout@<sha>`, `actions/setup-go`, `actions/setup-node`,
  `Swatinem/rust-cache` and `Infisical/secrets-action` resolve unchanged.
  data.forgejo.org does not mirror Infisical or Swatinem.
- **ukubi-ci is on Forgejo with the same commits, and public.** It must be a
  migrated mirror, not a fresh push, so the `@<sha>` pins still resolve.
  Forgejo calls a reusable workflow from another repo only when that repo is
  public. ukubi-ci holds no secrets.
- **Two runner labels:**
  - `ukubi-build` runs on the build LXC in host mode. It needs `sudo -n buildah`
    as today, and `node` on PATH, because JavaScript actions (checkout, the
    Infisical action) run on the host's node.
  - `ubuntu-latest` runs in a podman container. The image needs bash, git,
    curl, jq, tar, xz and sha256sum, gcc (`go test -race` uses cgo) and `cc` for
    Rust.
- **Infisical login over Forgejo's OIDC token.** Off github.com image.yml
  logs in with `infisical-auth: auto` = `forgejo`: image.yml sets
  `enable-openid-connect: true` at workflow level (Forgejo ignores it on a
  called job and on the caller's `uses:` job), asks Forgejo for a token with audience
  `infisical`, and trades it at Infisical's JWT auth for identity
  `ci-forgejo-tier1` (`e49781b3-9cf2-4964-be5b-da50ce8007a2`). That identity
  holds Forgejo's Actions signing key (Infisical refuses to discover a LAN
  issuer, so the key is pasted in) and is bound to issuer
  `https://git.bnei.dev/api/actions`, `repository_owner` MohammadBnei and
  `event_name` push, workflow_dispatch or workflow_call plus `ref_type`
  branch or tag. Inside a call Forgejo's token says `workflow_call`; a PR run
  has `ref_type` empty (`ref` refs/pull/N/head), so Infisical refuses it, not
  just the workflow. A `pull_request_target` caller runs base-branch code and
  would be let in; no caller uses that event. It is a viewer on platform-commons (custom,
  narrower roles need Infisical Enterprise). No secret is stored in Forgejo.
  If Forgejo's signing key ever changes (an upgrade, a restore onto a fresh
  CT, a regenerated key), every publishing run fails at once with
  `Infisical login refused`: paste the new public key from
  `https://git.bnei.dev/api/actions/.well-known/keys` into the identity. Do
  this as part of every Forgejo upgrade or restore. `universal` stays available
  with the `infisical-client-id`/`infisical-client-secret` secrets.

## In each caller repo

1. **Re-pin** every `uses: MohammadBnei/ukubi-ci/.github/workflows/<x>.yml@<sha>`
   to the v0.8.0 sha. The path stays the same, because Forgejo resolves
   `owner/repo` on its own instance.
2. **image.yml callers** (drop, hq, mountain, ukubi-bridge, ukubi-game, ukubi-meet,
   ukubi-stt, wird):
   ```yaml
   uses: MohammadBnei/ukubi-ci/.github/workflows/image.yml@<v0.8.0 sha>
   with:
     runs-on: '["ukubi-build"]'          # was ["self-hosted","ukubi-build"]
     image: drop
   ```
   Keep the `permissions:` blocks. GitHub needs them and Forgejo ignores them.
3. **Checks and release callers** (go-checks, bun-checks, rust-checks,
   trailers, release) default `runs-on` to `["k8s-ubuntu-latest"]`, the Talos
   runner (unprivileged pod, no services:, no container:, no image builds);
   pass `'["ubuntu-latest"]'` to stay on CT 103. deploy defaults to
   `["ubuntu-latest"]` and image to what you pass. image-build is gone: PRs lint
   Dockerfiles with dockerfile-lint.yml and never build. A caller still on GitHub passes
   `runs-on: '["self-hosted","ukubi-build"]'` to keep today's runner.
4. **Do not set `runs-on` on a `uses:` job.** GitHub refuses it. On Forgejo,
   leaving it out lets the server expand the called workflow into its own
   jobs, each with its own `runs-on`. With `runs-on` set, the whole called
   workflow runs inside the one caller job.
5. **Concurrency:** Forgejo honours only the workflow-level `concurrency:`
   and ignores the job-level groups inside image.yml, deploy.yml and
   release.yml. With no workflow-level setting, a new push or PR update
   cancels the older run of the same workflow. The release and deploy pushes
   are atomic and retried, so a cancelled run loses nothing and the newer run
   publishes. If a release must never be cut short, the caller adds
   `concurrency: {group: release-${{ github.ref }}, cancel-in-progress: false}`
   at the top of its own workflow.
6. **Your own jobs:** change `runs-on: [self-hosted, ukubi-build]` to
   `runs-on: ukubi-build` for jobs that need buildah or the box's caches, or to
   `ubuntu-latest` for jobs that do not. `ukubi-race` (ukubi-game) has no
   Forgejo runner yet. `ubuntu-latest` jobs stay as they are.
7. **Databases in tests:** replace `pre-test: docker compose up -d --wait
   postgres` (wird) with the `dev-db` action from ukubi-ci (branch
   `feat/dev-db-action`, which merges separately). It is a composite action, so
   it goes in your own job and not inside go-checks:
   ```yaml
   go-db:
     runs-on: ubuntu-latest
     steps:
       - uses: actions/checkout@<sha>
       - uses: MohammadBnei/ukubi-ci/actions/dev-db@<sha>
         with:
           integresql-url: https://integresql.dev.example
           token: ${{ secrets.DEV_DB_TOKEN }}
           seed-command: ./scripts/migrate-and-seed.sh
       - run: go test -race -count=1 ./...       # DATABASE_URL is exported
       - if: always()
         uses: MohammadBnei/ukubi-ci/actions/dev-db-release@<sha>
         with:
           token: ${{ secrets.DEV_DB_TOKEN }}
   ```
8. **Inline Infisical OIDC outside ukubi-ci** fails on Forgejo. Move each of
   these to `method: universal` with the org secrets (or to image.yml):
   editable-website, editable-website-article, editable-website-article2
   (`release.yml`), has-journal (`build.yml`), pi-lab (`app.yml`), and wird
   (`.github/actions/infisical-keep`, `apk.yml`, `ipa.yml`).
9. **gh CLI:** wird `release-app.yml` calls `gh run list`. On Forgejo, call
   `$GITHUB_SERVER_URL/api/v1/repos/$GITHUB_REPOSITORY/actions/...` with curl
   and `Authorization: token ${{ github.token }}`, or drop that guard. No
   ukubi-ci workflow uses gh.
10. **Pushes with the job token** (release.yml's release commit and tag,
   image.yml and deploy.yml's tag bump) need the Forgejo Actions token to be
   allowed to push to the default branch. Branch protection on Forgejo must
   leave that open, as it does on GitHub today. On both, those pushes start no
   new run, so they cannot loop.

## Check on the pilot before the first real repo

The workflows pass actionlint and their self-tests. These Forgejo behaviours
could only be checked on a live instance, so run ukubi-ci's own `ci.yml` on the
pilot first:

- A reusable workflow's `outputs` reach the caller's later jobs
  (ukubi-game: image.yml's `tag`, `digest` and `commit` feed deploy.yml).
- `secrets:` passed to a reusable workflow reach its steps.
- A `uses: ...@<40-char sha>` ref resolves (the docs only show branch refs).
- The `ubuntu-latest` image has every tool listed above (ukubi-ci's own
  `actionlint` and `check` jobs run there).
- `github.event.repository.default_branch` is set on push and dispatch, since
  every publish and deploy gate compares against it.

## Known Forgejo 15 behaviour

- **A called workflow sees `github.event_name == 'workflow_call'`**, not the
  caller's event. The caller's payload is passed through unchanged, so the
  event gates in release.yml, image.yml, deploy.yml and trailers.yml read it
  from there: `pull_request` in the payload means a PR, `pusher` a push,
  `workflow` a dispatch, `workflow_run` never publishes. Anything else (schedule
  sends only `action`) is treated as build-only. On GitHub
  `event_name` is already the caller's event and the extra clause never
  applies. `test/check.sh` fails on any `github.event_name` read in these files that is
  not one of the two canonical expressions.
- **image.yml shows as failing runs in this repo.** Forgejo
  does not parse `on.workflow_call.secrets` (forgejo#14674) and reports the
  file as a broken top-level workflow. The calls themselves work. The block
  stays, because GitHub needs it for callers that map secrets by name.

## 0.11: bumps on a deploy branch, releases as tags (option B)

The default branch only takes reviewed merges, so it can be protected.

- **release.yml** pushes only an annotated tag on the triggering commit; the
  notes are the tag message. No `chore(release)` commit, no CHANGELOG edit
  (`changelog` is ignored). An existing CHANGELOG.md stays as history.
- **image.yml and deploy.yml** commit the bump to `deploy-branch` (default
  `deploy`). `values-file(s)` name pin files on that branch, not the default
  branch's values: use a path of its own, e.g. `app/helm/image.yaml`. The
  first run creates the branch (orphan) and the file from `values-key`. The
  bump subject stays `chore(deploy): bump <app> image to <tag>@<digest>`.
- **ArgoCD** must layer the pin file over the default branch's values
  (infra-bootstrap ApplicationSet: a source at `targetRevision: deploy`, the
  pin file last in `valueFiles`). Order per repo: switch the caller to 0.11,
  let its first main run create `deploy`, then point the app's registry entry
  at it. Until then new images build and push but do not deploy.
- `deploy-branch: ''` keeps the old behaviour (bump on the default branch).

