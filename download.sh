#!/usr/bin/env bash
set -euox pipefail

source /etc/os-release
source /opt/gpu/config.sh

workdir="$(mktemp -d)"
pushd "$workdir" || exit

NVIDIA_ARCH=$ARCH
if [[ "${ARCH}" == "arm64" ]]; then
    # NVIDIA uses the name "SBSA" for ARM64 platforms. See https://en.wikipedia.org/wiki/Server_Base_System_Architecture
    NVIDIA_ARCH="sbsa"
fi

if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    RUNFILE="NVIDIA-Linux-${NVIDIA_ARCH}-${DRIVER_VERSION}"
    curl -fsSLO https://us.download.nvidia.com/tesla/${DRIVER_VERSION}/${RUNFILE}.run 
elif [[ "${DRIVER_KIND}" == "grid" ]]; then
    RUNFILE="NVIDIA-Linux-${NVIDIA_ARCH}-${DRIVER_VERSION}-grid-azure"
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
    curl -fsSLO https://developer.download.nvidia.com/compute/nvidia-driver/redist/fabricmanager/linux-${NVIDIA_ARCH}/fabricmanager-linux-${NVIDIA_ARCH}-${DRIVER_VERSION}-archive.tar.xz
    tar -xvf fabricmanager-linux-${NVIDIA_ARCH}-${DRIVER_VERSION}-archive.tar.xz
    mv fabricmanager-linux-${NVIDIA_ARCH}-${DRIVER_VERSION}-archive /opt/gpu/fabricmanager-linux-${NVIDIA_ARCH}-${DRIVER_VERSION}
    mv /opt/gpu/fm_run_package_installer.sh /opt/gpu/fabricmanager-linux-${NVIDIA_ARCH}-${DRIVER_VERSION}/sbin/fm_run_package_installer.sh
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
chmod 644 /etc/apt/trusted.gpg.d/*

# download nvidia debian packages for nvidia-container-runtime compat
for apt_package in $NVIDIA_PACKAGES; do
    apt-get download ${apt_package}=${NVIDIA_CONTAINER_TOOLKIT_VER}*
    mv ${apt_package}_${NVIDIA_CONTAINER_TOOLKIT_VER}* /opt/gpu
done

popd || exit
rm -r "$workdir"
