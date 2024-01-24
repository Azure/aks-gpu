ARG distro=22.04

FROM mcr.microsoft.com/mirror/docker/library/ubuntu:${distro} as gpu

RUN apt update && apt install -y curl xz-utils gnupg2 ca-certificates gettext-base --no-install-recommends

ARG DRIVER_VERSION
ARG DRIVER_URL
ARG DRIVER_KIND="cuda"

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

COPY --from=gpu /opt/gpu/ /opt/gpu/
COPY entrypoint.sh /entrypoint.sh 
COPY install.sh /opt/actions/install.sh

RUN mkdir -p /mnt

ENTRYPOINT ["/entrypoint.sh"]
