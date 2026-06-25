FROM docker.io/ubuntu:24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN export DEBIAN_FRONTEND=noninteractive \
    && groupadd -g 1100 arma3 \
    && useradd -m -d /arma3 -u 1100 -g 1100 arma3 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        lib32stdc++6 \
        lib32gcc-s1 \
        libsdl2-2.0-0 \
        wget \
        ca-certificates \
        tar \
        xz-utils \
        rename \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && mkdir -p /arma3/server \
    && chown arma3:arma3 /arma3/server

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
