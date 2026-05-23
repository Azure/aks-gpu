#!/usr/bin/env bash
set -euox pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPU_ROOT="${GPU_ROOT:-${SCRIPT_DIR}}"

source "${GPU_ROOT}/config.sh"

if [[ -z "${DRIVER_VERSION:-}" ]]; then
    echo "DRIVER_VERSION must be set in ${GPU_ROOT}/config.sh" >&2
    exit 1
fi

if [[ -z "${DRIVER_KIND:-}" ]]; then
    echo "DRIVER_KIND must be set in ${GPU_ROOT}/config.sh" >&2
    exit 1
fi

normalize_arch() {
    case "${1}" in
        amd64|x86_64)
            echo "amd64"
            ;;
        arm64|aarch64)
            echo "arm64"
            ;;
        *)
            echo "Unsupported architecture: ${1}" >&2
            exit 1
            ;;
    esac
}

TARGETARCH="${TARGETARCH:-$(normalize_arch "$(uname -m)")}"

workdir="$(mktemp -d)"
apt_root="${workdir}/apt"

cleanup() {
    rm -rf "${workdir}"
}

trap cleanup EXIT

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
    if [[ -z "${DRIVER_URL:-}" ]]; then
        echo "DRIVER_URL must be set when DRIVER_KIND=grid" >&2
        exit 1
    fi
    RUNFILE="NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${DRIVER_VERSION}-grid-azure"
    curl -fsSLO "${DRIVER_URL}"
else
    echo "Invalid driver kind: ${DRIVER_KIND}"
    exit 1
fi

# download nvidia drivers, move to permanent cache
mv ${RUNFILE}.run "${GPU_ROOT}/${RUNFILE}.run"
pushd "${GPU_ROOT}"
# extract runfile, takes some time, so do ahead of time
sh "${GPU_ROOT}/${RUNFILE}.run" -x
popd

install_fabric_manager () {
    curl -fsSLO https://developer.download.nvidia.com/compute/nvidia-driver/redist/fabricmanager/linux-${NVIDIA_FM_ARCH}/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}-archive.tar.xz
    tar -xvf fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}-archive.tar.xz
    mv fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}-archive "${GPU_ROOT}/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}"
    cp "${GPU_ROOT}/fm_run_package_installer.sh" "${GPU_ROOT}/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}/sbin/fm_run_package_installer.sh"
}

if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    # download fabricmanager for nvlink based systems, e.g. multi instance gpu vms.
   install_fabric_manager
fi

apt_get_with_temp_root() {
    apt-get \
        -o Dir::Etc::sourcelist=/dev/null \
        -o Dir::Etc::sourceparts="${apt_root}/etc/apt/sources.list.d" \
        -o Dir::Etc::trusted=/dev/null \
        -o Dir::Etc::trustedparts="${apt_root}/etc/apt/trusted.gpg.d" \
        -o Dir::State::status="${apt_root}/var/lib/dpkg/status" \
        -o Dir::State::lists="${apt_root}/var/lib/apt/lists" \
        -o Dir::Cache::archives="${apt_root}/var/cache/apt/archives" \
        "$@"
}

mkdir -p \
    "${apt_root}/etc/apt/sources.list.d" \
    "${apt_root}/etc/apt/trusted.gpg.d" \
    "${apt_root}/var/lib/apt/lists/partial" \
    "${apt_root}/var/cache/apt/archives/partial" \
    "${apt_root}/var/lib/dpkg"
touch "${apt_root}/var/lib/dpkg/status"

# configure nvidia apt repo to cache packages
curl -fsSLO https://nvidia.github.io/libnvidia-container/gpgkey
gpg --dearmor -o "${apt_root}/etc/apt/trusted.gpg.d/aptnvidia.gpg" gpgkey
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -o "${apt_root}/etc/apt/sources.list.d/nvidia-container-toolkit.list"

apt_get_with_temp_root update
chmod 644 "${apt_root}/etc/apt/trusted.gpg.d/"*

# download nvidia debian packages for nvidia-container-runtime compat
for apt_package in $NVIDIA_PACKAGES; do
    apt_get_with_temp_root download ${apt_package}=${NVIDIA_CONTAINER_TOOLKIT_VER}*
    mv ${apt_package}_${NVIDIA_CONTAINER_TOOLKIT_VER}* "${GPU_ROOT}"
done

popd || exit
