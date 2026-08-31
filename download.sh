#!/usr/bin/env bash
set -euox pipefail

source /etc/os-release
source /opt/gpu/config.sh

workdir="$(mktemp -d)"
pushd "$workdir" || exit

NVIDIA_DRIVER_ARCH=$TARGETARCH
if [ $TARGETARCH = "arm64" ]; then
    NVIDIA_DRIVER_ARCH="aarch64"
elif [ $TARGETARCH = "amd64" ]; then
    NVIDIA_DRIVER_ARCH="x86_64"
fi

NVIDIA_FM_ARCH=$TARGETARCH
if [ $TARGETARCH = "arm64" ]; then
    # NVIDIA uses the name "SBSA" for ARM64 platforms for the fabric manager. See https://en.wikipedia.org/wiki/Server_Base_System_Architecture
    NVIDIA_FM_ARCH="sbsa"
elif [ $TARGETARCH = "amd64" ]; then
    NVIDIA_FM_ARCH="x86_64"
fi

if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    RUNFILE="NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${DRIVER_VERSION}"
    curl -fsSLO https://us.download.nvidia.com/tesla/${DRIVER_VERSION}/${RUNFILE}.run 
elif [[ "${DRIVER_KIND}" == "grid" ]]; then
    RUNFILE="NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${DRIVER_VERSION}-grid-azure"
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
    curl -fsSLO https://developer.download.nvidia.com/compute/nvidia-driver/redist/fabricmanager/linux-${NVIDIA_FM_ARCH}/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}-archive.tar.xz
    tar -xvf fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}-archive.tar.xz
    mv fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}-archive /opt/gpu/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}
    mv /opt/gpu/fm_run_package_installer.sh /opt/gpu/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}/sbin/fm_run_package_installer.sh
}

install_imex () {
    # nvidia-imex is the cross-node NVLink (MNNVL / ComputeDomains) coordinator for
    # Grace-Blackwell. It is NOT in the driver .run or the fabric-manager redist -- it
    # ships only as a separate deb in the CUDA repo. Bundle the version-matched deb into
    # the image; it is installed at node boot (see install.sh device_init). The exact deb
    # revision suffix (e.g. -1ubuntu1) varies by version, so resolve the filename from the
    # repo Packages index rather than hard-coding it.
    local repo="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${VERSION_ID//./}/sbsa"
    local deb
    # NB: awk must read to EOF (no early `exit`) -- exiting mid-stream closes the pipe and
    # SIGPIPEs curl, which `set -o pipefail` would turn into a build failure. Gate on a flag
    # to keep only the first match instead.
    deb="$(curl -fsSL "${repo}/Packages" \
        | awk -v p="nvidia-imex_${DRIVER_VERSION}-" '$1=="Filename:" && index($2,p) && !f{print $2; f=1}')"
    if [[ -z "${deb}" ]]; then
        echo "nvidia-imex ${DRIVER_VERSION} not found in ${repo}"
        exit 1
    fi
    curl -fsSLO "${repo}/${deb#./}"
    mv "$(basename "${deb}")" /opt/gpu/
}

# download fabricmanager for nvlink based systems, but skip it on arm64:
# arm64 = Grace-Blackwell (GB200/GB300), which uses IMEX, not a node-local FM.
if [[ "${DRIVER_KIND}" == "cuda" && "${TARGETARCH}" != "arm64" ]]; then
   install_fabric_manager
fi

# download nvidia-imex for nvlink based arm64 systems (Grace-Blackwell GB200/GB300):
# GB uses IMEX (not a node-local fabric manager) to coordinate cross-node NVLink.
if [[ "${DRIVER_KIND}" == "cuda" && "${TARGETARCH}" == "arm64" ]]; then
   install_imex
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
