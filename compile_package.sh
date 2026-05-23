#!/usr/bin/env bash
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPU_ROOT="${GPU_ROOT:-${SCRIPT_DIR}}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: compile_package.sh

Builds a kernel-specific NVIDIA custom installer tree for the currently
running kernel and saves it as ./nvidia-custom inside the package root.
EOF
    exit 0
fi

source "${GPU_ROOT}/config.sh"

PS4='+ $(date -u -I"seconds" | cut -c1-19) '

get_driver_runfile_name() {
    local arch="${1:-$(uname -m)}"

    if [[ "${DRIVER_KIND}" == "cuda" ]]; then
        echo "NVIDIA-Linux-${arch}-${DRIVER_VERSION}"
        return 0
    fi

    if [[ "${DRIVER_KIND}" == "grid" ]]; then
        if [[ "${arch}" != "x86_64" ]]; then
            echo "GRID driver is only supported on x86_64 architecture" >&2
            exit 1
        fi

        echo "NVIDIA-Linux-x86_64-${DRIVER_VERSION}-grid-azure"
        return 0
    fi

    echo "Invalid driver kind: ${DRIVER_KIND}" >&2
    exit 1
}

get_fabric_manager_arch() {
    case "$(uname -m)" in
        arm64|aarch64)
            echo "sbsa"
            ;;
        amd64|x86_64)
            echo "x86_64"
            ;;
        *)
            uname -m
            ;;
    esac
}

KERNEL_NAME="$(uname -r)"
LOG_FILE_NAME="/var/log/nvidia-precompile-$(date +%s).log"
KERNEL_SOURCE_PATH="/lib/modules/${KERNEL_NAME}/build"
RUNFILE="$(get_driver_runfile_name)"
SOURCE_RUNFILE="${GPU_ROOT}/${RUNFILE}.run"
PRECOMPILED_METADATA="${GPU_ROOT}/nvidia-custom.metadata"
PRECOMPILED_INSTALLER_DIR_NAME="nvidia-custom"
PRECOMPILED_INSTALLER_DIR="${GPU_ROOT}/${PRECOMPILED_INSTALLER_DIR_NAME}"
BUILD_WORKDIR="$(mktemp -d)"
EXTRACT_WORKDIR="$(mktemp -d)"

cleanup() {
    rm -rf "${BUILD_WORKDIR}" "${EXTRACT_WORKDIR}"
}

trap cleanup EXIT

is_runtime_entry() {
    local entry_name="${1}"
    local fm_arch apt_package

    case "${entry_name}" in
        10-nvidia-runtime.toml|71-nvidia-char-dev.rules|blacklist-nouveau.conf|config.sh|install_package.sh|package_manager_helpers.sh|nvidia-custom|nvidia-custom.metadata)
            return 0
            ;;
    esac

    if [[ "${DRIVER_KIND}" == "cuda" ]]; then
        fm_arch="$(get_fabric_manager_arch)"
        if [[ "${entry_name}" == "fabricmanager-linux-${fm_arch}-${DRIVER_VERSION}" ]]; then
            return 0
        fi
    fi

    for apt_package in $NVIDIA_PACKAGES; do
        if [[ "${entry_name}" == ${apt_package}_${NVIDIA_CONTAINER_TOOLKIT_VER}* ]]; then
            return 0
        fi
    done

    return 1
}

prune_runtime_payload() {
    local path entry_name

    shopt -s nullglob dotglob
    for path in "${GPU_ROOT}"/*; do
        entry_name="$(basename "${path}")"
        if ! is_runtime_entry "${entry_name}"; then
            rm -rf "${path}"
        fi
    done
    shopt -u nullglob dotglob
}

if [[ ! -f "${SOURCE_RUNFILE}" ]]; then
    echo "Expected to find source runfile '${SOURCE_RUNFILE}', but it does not exist" >&2
    exit 1
fi

if [[ ! -d "${KERNEL_SOURCE_PATH}" ]]; then
    echo "Expected to find kernel headers at '${KERNEL_SOURCE_PATH}', but they do not exist" >&2
    exit 1
fi

rm -f "${PRECOMPILED_METADATA}"
rm -rf "${PRECOMPILED_INSTALLER_DIR}"

pushd "${BUILD_WORKDIR}"
sh "${SOURCE_RUNFILE}" \
    --ui=none \
    --no-questions \
    --accept-license \
    --no-dkms \
    --add-this-kernel \
    --kernel-source-path="${KERNEL_SOURCE_PATH}" \
    --log-file-name="${LOG_FILE_NAME}"
popd

GENERATED_RUNFILE="${BUILD_WORKDIR}/${RUNFILE}-custom.run"

if [[ ! -f "${GENERATED_RUNFILE}" ]]; then
    echo "Expected to find generated precompiled runfile '${GENERATED_RUNFILE}', but it does not exist" >&2
    exit 1
fi

pushd "${EXTRACT_WORKDIR}"
sh "${GENERATED_RUNFILE}" -x
popd

GENERATED_INSTALLER_DIR=""
for candidate in "${EXTRACT_WORKDIR}"/*; do
    if [[ -d "${candidate}" && -x "${candidate}/nvidia-installer" ]]; then
        GENERATED_INSTALLER_DIR="${candidate}"
        break
    fi
done

if [[ -z "${GENERATED_INSTALLER_DIR}" ]]; then
    echo "Expected to find an extracted precompiled installer tree in '${EXTRACT_WORKDIR}', but none was created" >&2
    exit 1
fi

mv "${GENERATED_INSTALLER_DIR}" "${PRECOMPILED_INSTALLER_DIR}"
cat > "${PRECOMPILED_METADATA}" <<EOF
PRECOMPILED_KERNEL_NAME="${KERNEL_NAME}"
PRECOMPILED_DRIVER_VERSION="${DRIVER_VERSION}"
PRECOMPILED_DRIVER_KIND="${DRIVER_KIND}"
PRECOMPILED_ARCH="$(uname -m)"
PRECOMPILED_INSTALLER_DIR_NAME="${PRECOMPILED_INSTALLER_DIR_NAME}"
EOF

rm -rf "${GPU_ROOT}/${RUNFILE}"
rm -f "${SOURCE_RUNFILE}"
prune_runtime_payload

echo "Generated precompiled installer tree at ${PRECOMPILED_INSTALLER_DIR}"
