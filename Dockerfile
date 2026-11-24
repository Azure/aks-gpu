ARG distro=26.04

FROM mcr.microsoft.com/mirror/docker/library/ubuntu:${distro} as gpu

RUN apt update && apt upgrade -y && apt install -y curl xz-utils gnupg2 ca-certificates gettext-base --no-install-recommends && rm -rf /var/lib/apt/lists/*

ARG DRIVER_VERSION
ARG DRIVER_URL
ARG DRIVER_KIND="cuda"
ARG TARGETARCH

WORKDIR /opt/gpu
COPY 10-nvidia-runtime.toml 10-nvidia-runtime.toml 
COPY 71-nvidia-char-dev.rules 71-nvidia-char-dev.rules
COPY blacklist-nouveau.conf blacklist-nouveau.conf
COPY nvidia-persistenced.service nvidia-persistenced.service

COPY fm_run_package_installer.sh fm_run_package_installer.sh
COPY config.sh config.sh
RUN envsubst < config.sh > config.sh.tmp && mv config.sh.tmp config.sh
COPY package_manager_helpers.sh package_manager_helpers.sh
COPY download.sh download.sh 
RUN bash download.sh

FROM mcr.microsoft.com/mirror/docker/library/ubuntu:${distro}

# Pull in the latest Ubuntu security patches (e.g. gpgv, libssl3t64) on top of
# the base image so shipped VHD images don't carry stale, vulnerable packages.
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

COPY --from=gpu /opt/gpu/ /opt/gpu/
COPY entrypoint.sh /entrypoint.sh 
COPY install.sh /opt/actions/install.sh

RUN mkdir -p /mnt

ENTRYPOINT ["/entrypoint.sh"]
