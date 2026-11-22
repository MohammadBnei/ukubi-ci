# Thin CI job image: the podman runner's base plus Go in actions/setup-go's
# tool cache, so setup-go finds it and never downloads. Nothing else is added.
FROM catthehacker/ubuntu:act-24.04@sha256:f68a2abac9c927421fd5a38e23d3610c7804916ffdb2491d7e669fe0ebbe1979

ARG GO_VERSION=1.27.4
# From https://go.dev/dl/ (go1.27.4.linux-amd64.tar.gz). Bump with GO_VERSION.
ARG GO_SHA256=7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840

# @actions/tool-cache find(toolName, versionSpec, arch) looks for
#   <RUNNER_TOOL_CACHE>/<tool>/<version>/<arch>   and   <that path>.complete
# (tool-cache.ts: cachePath = path.join(_getCacheDirectory(), toolName, version, arch);
# found only if cachePath and `${cachePath}.complete` both exist). setup-go asks for
# tool "go", arch x64 on amd64. The catthehacker image sets RUNNER_TOOL_CACHE=/opt/hostedtoolcache.
RUN set -eux; \
    d=/opt/hostedtoolcache/go/${GO_VERSION}/x64; \
    mkdir -p "$d"; \
    curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"; \
    echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c -; \
    tar -xzf /tmp/go.tgz -C "$d" --strip-components=1; \
    rm /tmp/go.tgz; \
    touch "$d.complete"; \
    "$d/bin/go" version
