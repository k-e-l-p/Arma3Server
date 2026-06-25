FROM docker.io/debian:bookworm-slim@sha256:1def178129dfb5f24db43afbf2fcac04530012e3264ba4ff81c71184e17a9ee4

RUN export DEBIAN_FRONTEND=noninteractive \
    && groupadd -g 1100 arma3 2>/dev/null || groupadd -r arma3 \
    && useradd -m -d /arma3 -u 1100 -g 1100 arma3 2>/dev/null \
        || useradd -m -d /arma3 -g "$(getent group arma3 | cut -d: -f3)" arma3 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        lib32stdc++6 \
        lib32gcc-s1 \
        libsdl2-2.0-0 \
        wget \
        ca-certificates \
        tar \
        xz-utils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && mkdir -p /arma3/server /arma3/server/presets \
    && chown arma3:arma3 /arma3/server /arma3/server/presets

USER arma3:arma3
WORKDIR /arma3

ENV HOME=/arma3

EXPOSE 2302/udp
EXPOSE 2303/udp
EXPOSE 2304/udp
EXPOSE 2305/udp
EXPOSE 2306/udp

STOPSIGNAL SIGINT

COPY --chown=arma3:arma3 --chmod=755 entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
