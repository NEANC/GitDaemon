FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS deps
USER 10001:10001
RUN test "$(id -ru)" = 10001 && test "$(id -u)" = 10001 && mkdir -p /tmp/root /tmp/cache && apk --root /tmp/root --keys-dir /etc/apk/keys --repositories-file /etc/apk/repositories --cache-dir /tmp/cache add --initdb --usermode --scripts=no dnsmasq=2.92_p2-r0 bind-tools=9.20.29-r0 && apk --root /tmp/root info -v
FROM git-daemon:test@sha256:e32fd04d00d1c8b394d21121badec2de6df48b171f8a9889ca2cf771960c9a8c
COPY --from=deps /tmp/root/ /
USER 10001:10001
ENTRYPOINT []
