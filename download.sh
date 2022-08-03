#!/usr/bin/env bash
set -euo pipefail

source /etc/os-release
source /opt/gpu/config.sh

NVIDIA_CONTAINER_RUNTIME_VERSION="3.6.0"
NVIDIA_CONTAINER_TOOLKIT_VER="1.6.0"
NVIDIA_PACKAGES="libnvidia-container1 libnvidia-container-tools nvidia-container-toolkit"
GPU_DEST="/usr/local/nvidia"

workdir="$(mktemp -d)"
pushd "$workdir" || exit

# download nvidia drivers, move to permanent cache
curl -fsSLO https://us.download.nvidia.com/tesla/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run 
mv NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run /opt/gpu/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run

# download fabricmanager for nvlink based systems, e.g. multi instance gpu vms.
curl -fsSLO https://developer.download.nvidia.com/compute/cuda/redist/fabricmanager/linux-x86_64/fabricmanager-linux-x86_64-${DRIVER_VERSION}-archive.tar.xz
tar -xvf fabricmanager-linux-x86_64-${DRIVER_VERSION}-archive.tar.xz
mv fabricmanager-linux-x86_64-${DRIVER_VERSION}-archive /opt/gpu/fabricmanager-linux-x86_64-${DRIVER_VERSION}

# configure nvidia apt repo to cache packages
curl -fsSLO https://nvidia.github.io/nvidia-docker/gpgkey
gpg --dearmor -o aptnvidia.gpg gpgkey
mv aptnvidia.gpg /etc/apt/trusted.gpg.d/aptnvidia.gpg
curl -fsSL https://nvidia.github.io/nvidia-docker/ubuntu${VERSION_ID}/nvidia-docker.list -o /etc/apt/sources.list.d/nvidia-docker.list

apt update

# download nvidia debian packages for nvidia-container-runtime compat
for apt_package in $NVIDIA_PACKAGES; do
    apt-get download ${apt_package}=${NVIDIA_CONTAINER_TOOLKIT_VER}*
    mv ${apt_package}_${NVIDIA_CONTAINER_TOOLKIT_VER}* /opt/gpu
done
apt-get download nvidia-container-runtime=${NVIDIA_CONTAINER_RUNTIME_VERSION}*

# move debs to permanent cache
mv nvidia-container-runtime_${NVIDIA_CONTAINER_RUNTIME_VERSION}* /opt/gpu

popd || exit
rm -r "$workdir"
