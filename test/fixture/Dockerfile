# Self-test image for image.yml (ci.yml): the build fails unless the
# build-arg, the release VERSION and the build secret all arrive. Nothing is pushed.
FROM docker.io/library/busybox:1.37
ARG PROBE
RUN test "$PROBE" = from-build-args
ARG VERSION
RUN case "$VERSION" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "VERSION=$VERSION is not X.Y.Z"; exit 1;; esac
LABEL org.opencontainers.image.version=$VERSION
RUN --mount=type=secret,id=probe test "$(cat /run/secrets/probe)" = from-build-secrets
COPY probe.txt /probe.txt
RUN test "$(cat /probe.txt)" = context
