# runner-image

The CI job image: `catthehacker/ubuntu:act-24.04` (pinned by digest) plus
everything a pull-request job needs on an unprivileged Talos pod (uid 1001: no
root, no apt, no sudo), each tool pinned and sha256-checked in the Dockerfile:

- Go in `/opt/hostedtoolcache/go/<version>/x64` and Node 22 in
  `/opt/hostedtoolcache/node/<version>/x64`, each with its `x64.complete`
  marker, so `actions/setup-go` / `actions/setup-node` with a matching version
  find them and download nothing.
- bun 1.4.2 (bun-checks still installs the exact `packageManager` pin from npm).
- Rust: rustup in `/opt/rustup` + `/opt/cargo` (`RUSTUP_HOME`, `CARGO_HOME`),
  toolchains 1.99.1 and 1.98.0 with clippy and rustfmt (the pins in
  rust-toolchain.toml); any other toolchain downloads into the writable home.
- apt: protobuf-compiler (protoc), pkg-config, libssl-dev, python3, unzip, xz.
- buf 1.72.0, golangci-lint v2.14.0, hadolint, helm, uv, yq, shellcheck, actionlint.
- Playwright 1.62.1 Chromium (full and headless shell) and its OS libraries,
  browsers in `/opt/ms-playwright` (`PLAYWRIGHT_BROWSERS_PATH`). Callers run
  `playwright install` WITHOUT `--with-deps` (that needs root) and pin the same
  Playwright version, or the browser revision will not match.

`/opt/hostedtoolcache`, `/opt/rustup` and `/opt/cargo` are owned by uid 1001 so
`setup-*` actions and rustup can add versions.

`.github/workflows/runner-image.yml` builds and pushes it from main only, as
`registry.bnei.lan:5000/ukubi-ci-runner:<sha12>`. The podman runner label and
the Talos runner pin that image by digest (a separate step).

Bump a tool: change its `*_VERSION` and `*_SHA256` ARGs (hashes come from the
release's checksum file; hadolint publishes none, so its hash was computed on
download) and re-pin the digest. Keep the Go version in step with the workflows.
