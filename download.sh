#!/usr/bin/env bash
set -euo pipefail

source /etc/os-release
source /opt/gpu/config.sh

workdir="$(mktemp -d)"
pushd "$workdir" || exit

if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    RUNFILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}"
    curl -fsSLO https://us.download.nvidia.com/tesla/${DRIVER_VERSION}/${RUNFILE}.run 
elif [[ "${DRIVER_KIND}" == "grid" ]]; then
    RUNFILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}-grid-azure"
    curl -fsSLO "${DRIVER_URL}"
else
    echo "Invalid driver kind: ${DRIVER_KIND}"
    exit 1
fi

# download nvidia drivers, move to permanent cache
mv ${RUNFILE}.run /opt/gpu/${RUNFILE}.run
pushd /opt/gpu
# extract runfile, takes some time, so do ahead of time
sh /opt/gpu/${RUNFILE}.run -x
rm /opt/gpu/${RUNFILE}.run
popd


install_fabric_manager () {
    curl -fsSLO https://developer.download.nvidia.com/compute/nvidia-driver/redist/fabricmanager/linux-x86_64/fabricmanager-linux-x86_64-${DRIVER_VERSION}-archive.tar.xz
    tar -xvf fabricmanager-linux-x86_64-${DRIVER_VERSION}-archive.tar.xz
    mv fabricmanager-linux-x86_64-${DRIVER_VERSION}-archive /opt/gpu/fabricmanager-linux-x86_64-${DRIVER_VERSION}
    mv /opt/gpu/fm_run_package_installer.sh /opt/gpu/fabricmanager-linux-x86_64-${DRIVER_VERSION}/sbin/fm_run_package_installer.sh
}

if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    # download fabricmanager for nvlink based systems, e.g. multi instance gpu vms.
   install_fabric_manager
fi


# configure nvidia apt repo to cache packages
curl -fsSLO https://nvidia.github.io/libnvidia-container/gpgkey
gpg --dearmor -o aptnvidia.gpg gpgkey
mv aptnvidia.gpg /etc/apt/trusted.gpg.d/aptnvidia.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -o /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt update

for apt_package in $NVIDIA_PACKAGES; do
    apt-get download ${apt_package}=${NVIDIA_CONTAINER_TOOLKIT_VER}*
    mv ${apt_package}_${NVIDIA_CONTAINER_TOOLKIT_VER}* /opt/gpu
done

# download nvidia debian packages for nvidia-container-runtime compat

for apt_package in $LIBNVIDIA_PACKAGES; do
    apt-get download ${apt_package}=${LIBNVIDIA_VER}*
    mv ${apt_package}_${LIBNVIDIA_VER}* /opt/gpu
done

for apt_package in $NVIDIA_PACKAGES; do
    apt-get download ${apt_package}=${NVIDIA_CONTAINER_TOOLKIT_VER}*
    mv ${apt_package}_${NVIDIA_CONTAINER_TOOLKIT_VER}* /opt/gpu
done
#apt-get download nvidia-container-runtime=${NVIDIA_CONTAINER_RUNTIME_VERSION}*

# move debs to permanent cache
#mv nvidia-container-runtime_${NVIDIA_CONTAINER_RUNTIME_VERSION}* /opt/gpu

# nvidia-docker2 for docker runtime
# apt-get download nvidia-docker2=${NVIDIA_DOCKER_VERSION}
# mkdir -p /tmp/nvidia-docker2
# dpkg-deb -R ./nvidia-docker2_${NVIDIA_DOCKER_VERSION}_all.deb /tmp/nvidia-docker2
# mkdir -p /opt/gpu/nvidia-docker2_${NVIDIA_DOCKER_VERSION}
# cp -r /tmp/nvidia-docker2/usr/* /opt/gpu/nvidia-docker2_${NVIDIA_DOCKER_VERSION}/

popd || exit
rm -r "$workdir"
