# CI job image for the Talos runners (uid 1001: no root, no apt, no sudo) and the
# podman runner. Everything a pull-request job needs is baked in, pinned and
# checksummed (except apt packages and Playwright, which are version-pinned only),
# so no job installs anything: base + Go + Node + bun + Rust + the
# lint/codegen binaries + Playwright's Chromium and its OS libraries.
FROM catthehacker/ubuntu:act-24.04@sha256:f68a2abac9c927421fd5a38e23d3610c7804916ffdb2491d7e669fe0ebbe1979

ARG GO_VERSION=1.27.4
# From https://go.dev/dl/ (go1.27.4.linux-amd64.tar.gz). Bump with GO_VERSION.
ARG GO_SHA256=7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840
ARG NODE_VERSION=22.23.5
ARG NODE_SHA256=cdeb8670a0c81f51b4dc4ac61919f9b1ad917b304bf8221eb939570663d240f8
ARG BUN_VERSION=1.4.2
ARG BUN_SHA256=36368faef7527875d5ffa52e53cd48021741f2a83eb6208a8dd64068d422a913
ARG BUF_VERSION=1.72.0
ARG BUF_SHA256=8720830e26a733da55bb89bcd3cb44849c0965fc0c44fb5d691cccdc64dca5af
ARG GOLANGCI_VERSION=2.14.0
ARG GOLANGCI_SHA256=ab90aeb7b066f92a33415b638a50fe5344bbb75a0d32ad30cc248d88f81032ab
ARG HADOLINT_VERSION=2.15.1
ARG HADOLINT_SHA256=c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507
ARG HELM_VERSION=4.2.3
ARG HELM_SHA256=e9b88b4ee95b18c706839c28d3a0220e5bc470e9cd9262410c90793c45ff8b7c
ARG UV_VERSION=0.13.9
ARG UV_SHA256=a7fbaff2b9a271d85c1bdb540941090fd1ce011797b4abeb48e4dcd39c2471d5
ARG YQ_VERSION=4.44.3
ARG YQ_SHA256=a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7
ARG SHELLCHECK_VERSION=0.10.0
ARG SHELLCHECK_SHA256=6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87
ARG ACTIONLINT_VERSION=1.7.12
ARG ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
ARG LYCHEE_VERSION=0.24.2
ARG LYCHEE_SHA256=1f4e0ef7f6554a6ed33dd7ac144fb2e1bbed98598e7af973042fc5cd43951c9a
ARG RUSTUP_VERSION=1.28.2
ARG RUSTUP_SHA256=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c
# The toolchains the repos pin in rust-toolchain.toml (ukubi-stt, ukubi-meet).
# A job asking for another one downloads it into the writable RUSTUP_HOME.
ARG RUST_TOOLCHAINS="1.99.1 1.98.0"
ARG PLAYWRIGHT_VERSION=1.62.1

# @actions/tool-cache find(toolName, versionSpec, arch) looks for
#   <RUNNER_TOOL_CACHE>/<tool>/<version>/<arch>   and   <that path>.complete
# (tool-cache.ts: found only if cachePath and `${cachePath}.complete` both exist).
# setup-go and setup-node ask for tool "go"/"node", arch x64 on amd64, so a
# matching version is found and never downloaded. forgejo-runner does not derive
# RUNNER_TOOL_CACHE from AGENT_TOOLSDIRECTORY: set it explicitly to
# /opt/hostedtoolcache (runner.envs in config.yml for a host executor).
ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    PATH=/opt/cargo/bin:/usr/local/bin:$PATH

# Layer order is cache order: heavy, rarely changing layers first, small and often edited ones last.
# A change rebuilds its own layer and every layer after it. A one-line apt change used to sit before
# Playwright and Rust, so it rebuilt both and hit a mirror stall (2026-11-23). Keep new small things at the end.
# apt must not hang a build: 2026-11-23 an IPv6 fetch from the Ubuntu mirror stalled for 17 min inside
# playwright install-deps (which calls apt itself, so the options live in apt.conf, not on one command line).
# This file must stay before any apt use.
RUN printf '%s\n' 'Acquire::ForceIPv4 "true";' 'Acquire::Retries "5";' 'Acquire::http::Timeout "30";' 'Acquire::https::Timeout "30";' \
      > /etc/apt/apt.conf.d/99ci-network

# Playwright's Chromium (full and headless shell) and the OS libraries
# it links (install-deps needs root, so it happens here, not in a job). Browsers
# sit in PLAYWRIGHT_BROWSERS_PATH, owned by uid 1001 because `playwright install`
# takes a lock and writes .links there even when nothing needs downloading;
# callers run it without --with-deps and pin the same version.
# Each tree is chowned in the RUN that creates it (a later chown -R would copy
# every file into a new overlay layer). uid 1001 is the Talos runner job user, so
# setup-* actions can add tool versions and rustup can add toolchains.
RUN set -eux; \
    npm install --no-save --no-package-lock --prefix /tmp/pw "playwright@${PLAYWRIGHT_VERSION}"; \
    /tmp/pw/node_modules/.bin/playwright install --with-deps chromium chromium-headless-shell; \
    rm -rf /tmp/pw /var/lib/apt/lists/* /root/.npm /root/.cache; \
    chown -R 1001:1001 /opt/ms-playwright

# Rust. rustup under RUSTUP_HOME/CARGO_HOME, the pinned toolchains with
# clippy and rustfmt, and rustup's proxies on /usr/local/bin in case a runner
# resets PATH. rust-checks finds rustup on PATH and skips its own install.
RUN set -eux; \
    curl -fsSL -o /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init"; \
    echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c -; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y --profile minimal --default-toolchain none --no-modify-path; \
    rm /tmp/rustup-init; \
    for tc in ${RUST_TOOLCHAINS}; do rustup toolchain install "$tc" --profile minimal -c clippy -c rustfmt; done; \
    rustup default "${RUST_TOOLCHAINS%% *}"; \
    for b in rustup cargo rustc rustfmt cargo-fmt cargo-clippy clippy-driver; do ln -s "/opt/cargo/bin/$b" "/usr/local/bin/$b"; done; \
    chown -R 1001:1001 /opt/rustup /opt/cargo; \
    cargo --version

# Go in the toolcache.
RUN set -eux; \
    t=$(mktemp -d); cd "$t"; \
    dl() { curl -fsSL -o "$1" "$2"; echo "$3  $1" | sha256sum -c -; }; \
    d=/opt/hostedtoolcache/go/${GO_VERSION}/x64; mkdir -p "$d"; \
    dl go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" "$GO_SHA256"; \
    tar -xzf go.tgz -C "$d" --strip-components=1; touch "$d.complete"; \
    dl ly.tgz "https://github.com/lycheeverse/lychee/releases/download/lychee-v${LYCHEE_VERSION}/lychee-x86_64-unknown-linux-gnu.tar.gz" "$LYCHEE_SHA256"; \
    tar -xzf ly.tgz --strip-components=1 lychee-x86_64-unknown-linux-gnu/lychee; install -m 0755 lychee /usr/local/bin/lychee; \
    cd /; rm -rf "$t"; \
    chown -R 1001:1001 /opt/hostedtoolcache; \
    /opt/hostedtoolcache/go/${GO_VERSION}/x64/bin/go version

# Node (toolcache + /usr/local/bin links) and bun.
RUN set -eux; \
    t=$(mktemp -d); cd "$t"; \
    dl() { curl -fsSL -o "$1" "$2"; echo "$3  $1" | sha256sum -c -; }; \
    d=/opt/hostedtoolcache/node/${NODE_VERSION}/x64; mkdir -p "$d"; \
    dl node.txz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" "$NODE_SHA256"; \
    tar -xJf node.txz -C "$d" --strip-components=1; touch "$d.complete"; \
    ln -s "$d/bin/node" "$d/bin/npm" "$d/bin/npx" /usr/local/bin/; \
    dl bun.zip "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip" "$BUN_SHA256"; \
    unzip -q bun.zip; install -m 0755 bun-linux-x64/bun /usr/local/bin/bun; \
    cd /; rm -rf "$t"; \
    chown -R 1001:1001 /opt/hostedtoolcache; \
    node --version; bun --version

# Last: small apt packages (protoc for tonic/prost, psql for the dev-db roles, rsync, ...) and the pinned binaries.
RUN set -eux; \
    apt-get update -qq; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      protobuf-compiler xz-utils unzip rsync python3 python3-venv pkg-config libssl-dev postgresql-client; \
    rm -rf /var/lib/apt/lists/*; \
    t=$(mktemp -d); cd "$t"; \
    dl() { curl -fsSL -o "$1" "$2"; echo "$3  $1" | sha256sum -c -; }; \
    dl buf "https://github.com/bufbuild/buf/releases/download/v${BUF_VERSION}/buf-Linux-x86_64" "$BUF_SHA256"; \
    install -m 0755 buf /usr/local/bin/buf; \
    dl gl.tgz "https://github.com/golangci/golangci-lint/releases/download/v${GOLANGCI_VERSION}/golangci-lint-${GOLANGCI_VERSION}-linux-amd64.tar.gz" "$GOLANGCI_SHA256"; \
    tar -xzf gl.tgz --strip-components=1 "golangci-lint-${GOLANGCI_VERSION}-linux-amd64/golangci-lint"; \
    install -m 0755 golangci-lint /usr/local/bin/golangci-lint; \
    dl hadolint "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-x86_64" "$HADOLINT_SHA256"; \
    install -m 0755 hadolint /usr/local/bin/hadolint; \
    dl helm.tgz "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" "$HELM_SHA256"; \
    tar -xzf helm.tgz --strip-components=1 linux-amd64/helm; install -m 0755 helm /usr/local/bin/helm; \
    dl uv.tgz "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" "$UV_SHA256"; \
    tar -xzf uv.tgz --strip-components=1; install -m 0755 uv uvx /usr/local/bin/; \
    dl yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" "$YQ_SHA256"; \
    install -m 0755 yq /usr/local/bin/yq; \
    dl sc.txz "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" "$SHELLCHECK_SHA256"; \
    tar -xJf sc.txz --strip-components=1 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"; \
    install -m 0755 shellcheck /usr/local/bin/shellcheck; \
    dl al.tgz "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" "$ACTIONLINT_SHA256"; \
    tar -xzf al.tgz actionlint; install -m 0755 actionlint /usr/local/bin/actionlint; \
    cd /; rm -rf "$t"; \
    /opt/hostedtoolcache/go/${GO_VERSION}/x64/bin/go version; cargo --version; \
    node --version; bun --version; buf --version; golangci-lint --version; hadolint --version; \
    helm version --short; uv --version; yq --version; shellcheck --version | head -2; actionlint -version | head -1; lychee --version; \
    protoc --version; psql --version

