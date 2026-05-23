#!/usr/bin/env bash
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPU_ROOT="${GPU_ROOT:-${SCRIPT_DIR}}"

source "${GPU_ROOT}/config.sh"
source "${GPU_ROOT}/package_manager_helpers.sh"

trap 'PS4="+ "' exit
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

KERNEL_NAME="$(uname -r)"
LOG_FILE_NAME="/var/log/nvidia-installer-$(date +%s).log"
RUNFILE="$(get_driver_runfile_name)"
PRECOMPILED_RUNFILE="${GPU_ROOT}/nvidia-custom.run"
PRECOMPILED_METADATA="${GPU_ROOT}/nvidia-custom.metadata"
PRECOMPILED_INSTALLER_DIR_NAME="nvidia-custom"
PRECOMPILED_INSTALLER_DIR="${GPU_ROOT}/${PRECOMPILED_INSTALLER_DIR_NAME}"
USED_PRECOMPILED_ARTIFACT=0

set +euo pipefail
open_devices="$(lsof /dev/nvidia* 2>/dev/null)"
echo "Open devices: $open_devices"

open_gridd="$(lsof /usr/bin/nvidia-gridd 2>/dev/null)"
echo "Open gridd: $open_gridd"

set -euo pipefail

install_cached_nvidia_packages() {
for apt_package in $NVIDIA_PACKAGES; do
    dpkg -i --force-overwrite "${GPU_ROOT}/${apt_package}_${NVIDIA_CONTAINER_TOOLKIT_VER}"*
done
}

find_installed_nvidia_module() {
    local file_name="${1}"

    find "/lib/modules/${KERNEL_NAME}" -type f -name "${file_name}" | head -n1
}

is_nvidia_module_loaded() {
    local module_name="${1}"

    lsmod | awk '{print $1}' | grep -qx "${module_name}"
}

insmod_installed_nvidia_module() {
    local module_name="${1}"
    local file_name="${2}"
    local required="${3:-0}"
    local module_path=""

    if is_nvidia_module_loaded "${module_name}"; then
        return 0
    fi

    module_path="$(find_installed_nvidia_module "${file_name}")"
    if [[ -z "${module_path}" ]]; then
        if [[ "${required}" == "1" ]]; then
            echo "Expected to find installed NVIDIA module '${file_name}' under /lib/modules/${KERNEL_NAME}, but it does not exist" >&2
            exit 1
        fi

        return 0
    fi

    insmod "${module_path}"
}

load_installed_nvidia_modules() {
    insmod_installed_nvidia_module "nvidia" "nvidia.ko" 1
    insmod_installed_nvidia_module "nvidia_modeset" "nvidia-modeset.ko"
    insmod_installed_nvidia_module "nvidia_uvm" "nvidia-uvm.ko"
}

use_package_manager_with_retries wait_for_dpkg_lock install_cached_nvidia_packages 10 3

cp "${GPU_ROOT}/blacklist-nouveau.conf" /etc/modprobe.d/blacklist-nouveau.conf
update_initramfs_for_nouveau_blacklist

set +e
umount -l /usr/lib/$(uname -m)-linux-gnu || true
umount -l /tmp/overlay || true
rm -r /tmp/overlay || true
set -e

mkdir /tmp/overlay
mount -t tmpfs tmpfs /tmp/overlay
mkdir /tmp/overlay/{workdir,lib64}
mkdir -p ${GPU_DEST}/lib64
mount -t overlay overlay -o lowerdir=/usr/lib/$(uname -m)-linux-gnu,upperdir=/tmp/overlay/lib64,workdir=/tmp/overlay/workdir /usr/lib/$(uname -m)-linux-gnu

if [[ -f "${PRECOMPILED_METADATA}" ]]; then
    # shellcheck disable=SC1090
    source "${PRECOMPILED_METADATA}"

    PRECOMPILED_INSTALLER_DIR_NAME="${PRECOMPILED_INSTALLER_DIR_NAME:-nvidia-custom}"
    PRECOMPILED_INSTALLER_DIR="${GPU_ROOT}/${PRECOMPILED_INSTALLER_DIR_NAME}"

    if [[ "${PRECOMPILED_KERNEL_NAME}" != "${KERNEL_NAME}" ]]; then
        echo "Precompiled installer targets kernel '${PRECOMPILED_KERNEL_NAME}', but current kernel is '${KERNEL_NAME}'" >&2
        exit 1
    fi

    if [[ "${PRECOMPILED_DRIVER_VERSION}" != "${DRIVER_VERSION}" || "${PRECOMPILED_DRIVER_KIND}" != "${DRIVER_KIND}" || "${PRECOMPILED_ARCH}" != "$(uname -m)" ]]; then
        echo "Precompiled installer metadata does not match the current package configuration" >&2
        exit 1
    fi
elif [[ -d "${PRECOMPILED_INSTALLER_DIR}" || -f "${PRECOMPILED_RUNFILE}" ]]; then
    echo "Expected to find precompiled metadata '${PRECOMPILED_METADATA}', but it does not exist" >&2
    exit 1
fi

if [[ -d "${PRECOMPILED_INSTALLER_DIR}" ]]; then
    echo "Installing from precompiled installer directory ${PRECOMPILED_INSTALLER_DIR}"
    pushd "${PRECOMPILED_INSTALLER_DIR}"
    ./nvidia-installer -s --skip-depmod --no-opengl-files --no-install-libglvnd --log-file-name="${LOG_FILE_NAME}" -a --no-drm --no-dkms
    popd
    USED_PRECOMPILED_ARTIFACT=1
elif [[ -f "${PRECOMPILED_RUNFILE}" ]]; then
    echo "Installing from precompiled runfile ${PRECOMPILED_RUNFILE}"
    sh "${PRECOMPILED_RUNFILE}" -s --skip-depmod --no-opengl-files --no-install-libglvnd --log-file-name="${LOG_FILE_NAME}" -a --no-drm --no-dkms
    USED_PRECOMPILED_ARTIFACT=1
elif [[ -d "${GPU_ROOT}/${RUNFILE}" ]]; then
    echo "Precompiled runfile not found, falling back to local compilation"
    pushd "${GPU_ROOT}"
    "${GPU_ROOT}/${RUNFILE}/nvidia-installer" -s -k="${KERNEL_NAME}" --skip-depmod --no-opengl-files --no-install-libglvnd --log-file-name="${LOG_FILE_NAME}" -a --no-drm --dkms
    popd
else
    echo "Neither a precompiled installer, precompiled runfile, nor extracted installer sources are available in '${GPU_ROOT}'" >&2
    exit 1
fi

load_installed_nvidia_modules
nvidia-smi

cp -a /tmp/overlay/lib64 ${GPU_DEST}/lib64

echo "${GPU_DEST}/lib64" > /etc/ld.so.conf.d/nvidia.conf
ldconfig

set +e
umount -l /usr/lib/$(uname -m)-linux-gnu
umount /tmp/overlay
rm -r /tmp/overlay
set -e

if [[ "${USED_PRECOMPILED_ARTIFACT}" -eq 0 ]]; then
    dkms status
fi
nvidia-modprobe -u -c0

cp -r /usr/bin/lib64/lib64/* /usr/lib/$(uname -m)-linux-gnu/
nvidia-smi

if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    NVIDIA_FM_ARCH="$(get_fabric_manager_arch)"
    bash "${GPU_ROOT}/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}/sbin/fm_run_package_installer.sh"
fi

mkdir -p /etc/containerd/config.d
cp "${GPU_ROOT}/10-nvidia-runtime.toml" /etc/containerd/config.d/10-nvidia-runtime.toml

mkdir -p "$(dirname /lib/udev/rules.d/71-nvidia-dev-char.rules)"
cp "${GPU_ROOT}/71-nvidia-char-dev.rules" /lib/udev/rules.d/71-nvidia-dev-char.rules
/usr/bin/nvidia-ctk system create-dev-char-symlinks --create-all

rm -r "${GPU_ROOT}"
