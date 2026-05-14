#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: build_package.sh --driver-kind <cuda|grid> --driver-version <version> [options]

Options:
  --driver-url <url>      Required for GRID packages.
  --target-arch <arch>    Target architecture: amd64 or arm64. Defaults to the build host arch.
  --distro <version>      Ubuntu distro version. Defaults to the current host VERSION_ID.
  --output-dir <path>     Directory for generated tar.gz artifacts. Defaults to ./dist.
EOF
}

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

detect_host_arch() {
    normalize_arch "$(uname -m)"
}

copy_static_assets() {
    local package_root="${1}"
    local asset

    for asset in \
        10-nvidia-runtime.toml \
        71-nvidia-char-dev.rules \
        blacklist-nouveau.conf \
        compile_package.sh \
        fm_run_package_installer.sh \
        install_package.sh \
        package_manager_helpers.sh
    do
        cp "${SCRIPT_DIR}/${asset}" "${package_root}/${asset}"
    done
}

write_config() {
    local package_root="${1}"

    cat > "${package_root}/config.sh" <<EOF
DRIVER_VERSION="${DRIVER_VERSION}"
DRIVER_KIND="${DRIVER_KIND}"
NVIDIA_CONTAINER_TOOLKIT_VER="1.19.0"
NVIDIA_PACKAGES="libnvidia-container1 libnvidia-container-tools nvidia-container-toolkit-base nvidia-container-toolkit"
GPU_DEST="/usr/bin"
EOF
}

DRIVER_KIND=""
DRIVER_VERSION=""
DRIVER_URL=""
TARGET_ARCH=""
OUTPUT_DIR="${SCRIPT_DIR}/dist"
DISTRO=""

while [[ $# -gt 0 ]]; do
    case "${1}" in
        --driver-kind)
            DRIVER_KIND="${2}"
            shift 2
            ;;
        --driver-version)
            DRIVER_VERSION="${2}"
            shift 2
            ;;
        --driver-url)
            DRIVER_URL="${2}"
            shift 2
            ;;
        --target-arch)
            TARGET_ARCH="$(normalize_arch "${2}")"
            shift 2
            ;;
        --distro)
            DISTRO="${2}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: ${1}" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${DRIVER_KIND}" || -z "${DRIVER_VERSION}" ]]; then
    echo "--driver-kind and --driver-version are required" >&2
    usage
    exit 1
fi

if [[ "${DRIVER_KIND}" != "cuda" && "${DRIVER_KIND}" != "grid" ]]; then
    echo "Unsupported driver kind: ${DRIVER_KIND}" >&2
    exit 1
fi

if [[ "${DRIVER_KIND}" == "grid" && -z "${DRIVER_URL}" ]]; then
    echo "--driver-url is required for GRID packages" >&2
    exit 1
fi

TARGET_ARCH="${TARGET_ARCH:-$(detect_host_arch)}"

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
fi

HOST_DISTRO="${VERSION_ID:-}"

if [[ -z "${HOST_DISTRO}" ]]; then
    echo "Package builds must run on an Ubuntu host with /etc/os-release available." >&2
    exit 1
fi

DISTRO="${DISTRO:-${HOST_DISTRO}}"

if [[ "${DISTRO}" != "${HOST_DISTRO}" ]]; then
    echo "Package builds must run on the target Ubuntu release. Host is ${HOST_DISTRO}, requested ${DISTRO}." >&2
    exit 1
fi

if [[ "${TARGET_ARCH}" != "$(detect_host_arch)" ]]; then
    echo "Package builds must run on the target architecture. Host is $(detect_host_arch), requested ${TARGET_ARCH}." >&2
    exit 1
fi

if [[ "${DRIVER_KIND}" == "grid" && "${TARGET_ARCH}" != "amd64" ]]; then
    echo "GRID packages are only supported on amd64" >&2
    exit 1
fi

artifact_name="aks-gpu-${DRIVER_KIND}-${DRIVER_VERSION}-ubuntu-${DISTRO}-${TARGET_ARCH}"
workdir="$(mktemp -d)"
package_root="${workdir}/${artifact_name}"

cleanup() {
    rm -rf "${workdir}"
}

trap cleanup EXIT

mkdir -p "${package_root}" "${OUTPUT_DIR}"

copy_static_assets "${package_root}"
write_config "${package_root}"

TARGETARCH="${TARGET_ARCH}" GPU_ROOT="${package_root}" DRIVER_URL="${DRIVER_URL}" bash "${SCRIPT_DIR}/download.sh"

tar -C "${workdir}" -czf "${OUTPUT_DIR}/${artifact_name}.tar.gz" "${artifact_name}"

echo "Created ${OUTPUT_DIR}/${artifact_name}.tar.gz"
