#!/usr/bin/env bash
set -euo pipefail

source /etc/os-release
source /opt/gpu/config.sh

workdir="$(mktemp -d)"
pushd "$workdir" || exit

# download nvidia drivers, move to permanent cache
curl -fsSLO https://us.download.nvidia.com/tesla/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run 
mv NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run /opt/gpu/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run
# TODO: reenable this, it saves like 30sec. but it pushes vhd to capacity and starts to fail image pulls :(
# pushd /opt/gpu
# # extract runfile, takes some time, so do ahead of time
# sh /opt/gpu/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run -x
# rm /opt/gpu/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run
# popd

# download fabricmanager for nvlink based systems, e.g. multi instance gpu vms.
curl -fsSLO https://developer.download.nvidia.com/compute/cuda/redist/fabricmanager/linux-x86_64/fabricmanager-linux-x86_64-${DRIVER_VERSION}-archive.tar.xz
tar -xvf fabricmanager-linux-x86_64-${DRIVER_VERSION}-archive.tar.xz
mv fabricmanager-linux-x86_64-${DRIVER_VERSION}-archive /opt/gpu/fabricmanager-linux-x86_64-${DRIVER_VERSION}
mv /opt/gpu/fm_run_package_installer.sh /opt/gpu/fabricmanager-linux-x86_64-${DRIVER_VERSION}/sbin/fm_run_package_installer.sh

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

# nvidia-docker2 for docker runtime
apt-get download nvidia-docker2=${NVIDIA_DOCKER_VERSION}
mkdir -p /tmp/nvidia-docker2
dpkg-deb -R ./nvidia-docker2_${NVIDIA_DOCKER_VERSION}_all.deb /tmp/nvidia-docker2
mkdir -p /opt/gpu/nvidia-docker2_${NVIDIA_DOCKER_VERSION}
cp -r /tmp/nvidia-docker2/usr/* /opt/gpu/nvidia-docker2_${NVIDIA_DOCKER_VERSION}/

popd || exit
rm -r "$workdir"
