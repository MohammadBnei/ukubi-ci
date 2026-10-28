# Self-test image for image.yml (ci.yml): the build fails unless the
# build-arg and the build secret both arrive. Nothing is pushed.
FROM docker.io/library/busybox:1.37
ARG PROBE
RUN test "$PROBE" = from-build-args
RUN --mount=type=secret,id=probe test "$(cat /run/secrets/probe)" = from-build-secrets
COPY probe.txt /probe.txt
RUN test "$(cat /probe.txt)" = context
