ARG distro=18.04

FROM mcr.microsoft.com/mirror/docker/library/ubuntu:${distro} as gpu

RUN apt update && apt install -y curl xz-utils gnupg2 ca-certificates gettext-base --no-install-recommends

ARG DRIVER_VERSION

WORKDIR /opt/gpu
COPY 10-nvidia-runtime.toml 10-nvidia-runtime.toml 
COPY blacklist-nouveau.conf blacklist-nouveau.conf
COPY fm_run_package_installer.sh fm_run_package_installer.sh
COPY config.sh config.sh 
RUN envsubst < config.sh > config.sh.tmp && mv config.sh.tmp config.sh
COPY download.sh download.sh 
RUN bash download.sh

FROM mcr.microsoft.com/mirror/docker/library/ubuntu:${distro}

COPY --from=gpu /opt/gpu/ /opt/gpu/
COPY entrypoint.sh /entrypoint.sh 
COPY install.sh /opt/actions/install.sh

RUN mkdir -p /mnt

ENTRYPOINT ["/entrypoint.sh"]
