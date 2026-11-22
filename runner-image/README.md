# runner-image

The CI job image: `catthehacker/ubuntu:act-24.04` (pinned by digest) plus Go
in `/opt/hostedtoolcache/go/<version>/x64` with its `x64.complete` marker, so
`actions/setup-go` with a matching `go-version` finds it and downloads nothing.

`.github/workflows/runner-image.yml` builds and pushes it from main only, as
`registry.bnei.lan:5000/ukubi-ci-runner:<sha12>`. The podman runner label and
the Talos runner will pin that image by digest (a later step, not done here).

Bump Go: change `GO_VERSION` and `GO_SHA256` (from https://go.dev/dl/) in the
Dockerfile, keep the `go-version` in the workflows in step, and re-pin the digest.
