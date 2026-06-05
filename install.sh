#!/usr/bin/env bash
set -euxo pipefail

source /opt/gpu/config.sh
source /opt/gpu/package_manager_helpers.sh

trap 'PS4="+ "' exit
PS4='+ $(date -u -I"seconds" | cut -c1-19) '

# Install mode flags (set by entrypoint.sh based on the requested action):
#   AKSGPU_BUILD_ONLY=1        -> compile/cache the kernel module + userspace libs only.
#                                 Runs on a GPU-less host (e.g. the Packer VHD builder).
#                                 Skips every device-dependent step (modprobe, nvidia-smi,
#                                 fabric manager, persistence) and writes a marker.
#   AKSGPU_SKIP_KERNEL_BUILD=1 -> the kernel module + libs were prebuilt into the VHD for
#                                 this exact kernel+driver; skip recompilation and only run
#                                 the device-dependent steps at node boot.
#   (neither set)              -> legacy behaviour: full compile + device init in one shot.
AKSGPU_BUILD_ONLY="${AKSGPU_BUILD_ONLY:-0}"
AKSGPU_SKIP_KERNEL_BUILD="${AKSGPU_SKIP_KERNEL_BUILD:-0}"

# Host-side marker describing what was baked into the VHD at build time. AgentBaker reads
# this (plus its own image-digest record) to decide whether the boot-time fast path is safe.
DKMS_MARKER_FILE="/opt/azure/aks-gpu/dkms-marker"

KERNEL_NAME=$(uname -r)
LOG_FILE_NAME="/var/log/nvidia-installer-$(date +%s).log"
ARCH=$(uname -m)

# Track overlay/tmpfs state so a build-time exit can never leave dangling mounts in the VHD.
OVERLAY_MOUNTED=0
cleanup_overlay() {
    set +e
    if [ "${OVERLAY_MOUNTED}" = "1" ]; then
        umount -l "/usr/lib/${ARCH}-linux-gnu" || true
        umount /tmp/overlay || true
        rm -r /tmp/overlay || true
        OVERLAY_MOUNTED=0
    fi
    set -e
}
trap cleanup_overlay EXIT

resolve_runfile() {
    if [[ "${DRIVER_KIND}" == "cuda" ]]; then
        RUNFILE="NVIDIA-Linux-${ARCH}-${DRIVER_VERSION}"
    elif [[ "${DRIVER_KIND}" == "grid" ]]; then
        if [[ "${ARCH}" != "x86_64" ]]; then
            echo "GRID driver is only supported on x86_64 architecture"
            exit 1
        fi
        RUNFILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}-grid-azure"
    else
        echo "Invalid driver kind: ${DRIVER_KIND}"
        exit 1
    fi
}

# install cached nvidia debian packages for container runtime compatibility
install_cached_nvidia_packages() {
for apt_package in $NVIDIA_PACKAGES; do
    dpkg -i --force-overwrite /opt/gpu/${apt_package}_${NVIDIA_CONTAINER_TOOLKIT_VER}*
done
}

install_nvidia_container_toolkit() {
    use_package_manager_with_retries wait_for_dpkg_lock install_cached_nvidia_packages 10 3
}

# build_kernel_module compiles the NVIDIA kernel module (the expensive step) and stages the
# userspace libraries. It performs NO device access, so it is safe to run at VHD build time on
# a host without a GPU.
build_kernel_module() {
    # blacklist nouveau driver, nvidia driver dependency
    cp /opt/gpu/blacklist-nouveau.conf /etc/modprobe.d/blacklist-nouveau.conf
    update-initramfs -u

    # clean up lingering files from previous install
    set +e
    umount -l "/usr/lib/${ARCH}-linux-gnu" || true
    umount -l /tmp/overlay || true
    rm -r /tmp/overlay || true
    set -e

    # set up overlayfs to change install location of nvidia libs from /usr/lib/$ARCH-linux-gnu to /usr/local/nvidia
    # add an extra layer of indirection via tmpfs because it's not possible to have an overlayfs on an overlayfs (i.e., inside a container)
    mkdir /tmp/overlay
    mount -t tmpfs tmpfs /tmp/overlay
    mkdir /tmp/overlay/{workdir,lib64}
    mkdir -p ${GPU_DEST}/lib64
    mount -t overlay overlay -o lowerdir="/usr/lib/${ARCH}-linux-gnu",upperdir=/tmp/overlay/lib64,workdir=/tmp/overlay/workdir "/usr/lib/${ARCH}-linux-gnu"
    OVERLAY_MOUNTED=1

    resolve_runfile

    # install nvidia drivers (DKMS build is the dominant cost we are hoisting to VHD build time)
    pushd /opt/gpu
    /opt/gpu/${RUNFILE}/nvidia-installer -s -k=$KERNEL_NAME --log-file-name=${LOG_FILE_NAME} -a --no-drm --dkms
    popd

    # move nvidia libs to correct location from temporary overlayfs
    cp -a /tmp/overlay/lib64 ${GPU_DEST}/lib64

    # configure system to know about nvidia lib paths
    echo "${GPU_DEST}/lib64" > /etc/ld.so.conf.d/nvidia.conf
    ldconfig

    cleanup_overlay

    # validate that the kernel module was built and registered (no device access required)
    dkms status
    modinfo -k "$KERNEL_NAME" nvidia
}

# device_init runs the steps that require the physical GPU and therefore must execute at node
# boot, regardless of whether the kernel module was prebuilt into the VHD.
device_init() {
    nvidia-modprobe -u -c0

    # configure persistence daemon
    # decreases latency for later driver loads
    # reduces nvidia-smi invocation time 10x from 30 to 2 sec
    # notable on large VM sizes with multiple GPUs
    # especially when nvidia-smi process is in CPU cgroup
    cp -r /usr/bin/lib64/lib64/* "/usr/lib/${ARCH}-linux-gnu/"
    nvidia-smi

    # install fabricmanager for nvlink based systems
    if [[ "${DRIVER_KIND}" == "cuda" ]]; then
        NVIDIA_FM_ARCH=$ARCH
        if [ "$NVIDIA_FM_ARCH" = "arm64" ]; then
            # NVIDIA uses the name "SBSA" for ARM64 platforms for the fabric manager. See https://en.wikipedia.org/wiki/Server_Base_System_Architecture
            NVIDIA_FM_ARCH="sbsa"
        fi
        bash /opt/gpu/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}/sbin/fm_run_package_installer.sh
    fi

    mkdir -p /etc/containerd/config.d
    cp /opt/gpu/10-nvidia-runtime.toml /etc/containerd/config.d/10-nvidia-runtime.toml

    mkdir -p "$(dirname /lib/udev/rules.d/71-nvidia-dev-char.rules)"
    cp /opt/gpu/71-nvidia-char-dev.rules /lib/udev/rules.d/71-nvidia-dev-char.rules
    /usr/bin/nvidia-ctk system create-dev-char-symlinks --create-all
}

write_dkms_marker() {
    mkdir -p "$(dirname "${DKMS_MARKER_FILE}")"
    cat > "${DKMS_MARKER_FILE}" <<EOF
kernel=${KERNEL_NAME}
driver_version=${DRIVER_VERSION}
driver_kind=${DRIVER_KIND}
arch=${ARCH}
EOF
}

# baked_marker_matches returns success only when the VHD baked a driver that exactly matches
# what this image installs (kernel + driver_version + driver_kind). It gates the skip-build
# fast path defensively: even if AgentBaker mistakenly requests skip-build for the wrong
# driver kind (e.g. GRID on a CUDA-baked VHD), a mismatch here forces the safe full rebuild.
baked_marker_matches() {
    [ -f "${DKMS_MARKER_FILE}" ] || return 1
    local m_kernel m_version m_kind
    m_kernel="$(sed -n 's/^kernel=//p'        "${DKMS_MARKER_FILE}" | head -n1)"
    m_version="$(sed -n 's/^driver_version=//p' "${DKMS_MARKER_FILE}" | head -n1)"
    m_kind="$(sed -n 's/^driver_kind=//p'       "${DKMS_MARKER_FILE}" | head -n1)"
    [ "${m_kernel}" = "${KERNEL_NAME}" ] && \
    [ "${m_version}" = "${DRIVER_VERSION}" ] && \
    [ "${m_kind}" = "${DRIVER_KIND}" ]
}

# unload_nvidia_modules best-effort unloads any currently-loaded NVIDIA kernel modules in
# dependency order. dkms remove only unregisters/deletes files; it will NOT rmmod a loaded
# module, and installing a new driver over a still-loaded stale one yields a kernel/userspace
# version mismatch. Best-effort: nvidia-installer (run later in build_kernel_module) is the
# backstop and will hard-fail if devices are genuinely in use.
unload_nvidia_modules() {
    local mod
    for mod in nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia; do
        if lsmod 2>/dev/null | grep -q "^${mod} "; then
            echo "aks-gpu: unloading stale module ${mod}"
            rmmod "${mod}" 2>/dev/null || modprobe -r "${mod}" 2>/dev/null || true
        fi
    done
}

# remove_stale_baked_driver wipes any pre-existing nvidia DKMS state + relocated userspace
# libs before a full (re)build. It exists for the shared-VHD case where a driver of a
# DIFFERENT kind/version was prebuilt into the image at VHD build time (e.g. CUDA is baked,
# but this node is a GRID SKU, or the VHD's baked driver is older than the one CSE requests).
#
# Reaching the full-build path at all means we are NOT trusting the baked artifact, so any
# registered nvidia DKMS tree is stale by definition and must go: otherwise the boot-time
# `nvidia-installer --dkms` collides with it (two trees target the same
# /lib/modules/<kernel>/updates/dkms/nvidia.ko, and `dkms add` errors on an already-registered
# version), and the baked install's relocated libs (${GPU_DEST}/lib64 +
# /etc/ld.so.conf.d/nvidia.conf) stay on the loader path at the wrong version, breaking
# nvidia-smi / library loads.
#
# It is a no-op on today's VHDs (nothing baked / nothing registered), so default behaviour is
# unchanged.
remove_stale_baked_driver() {
    command -v dkms >/dev/null 2>&1 || return 0

    # Versions of the nvidia DKMS module currently registered on the host, parsed from
    # `dkms status` (handles both "nvidia/<ver>," and legacy "nvidia, <ver>," formats).
    local registered_versions
    registered_versions="$(dkms status 2>/dev/null \
        | sed -n 's#^nvidia[,/][[:space:]]*\([^,]*\).*#\1#p' \
        | sort -u || true)"
    [ -z "${registered_versions}" ] && return 0

    unload_nvidia_modules

    local v
    for v in ${registered_versions}; do
        echo "aks-gpu: removing stale baked nvidia DKMS module ${v} (node needs ${DRIVER_KIND} ${DRIVER_VERSION})"
        dkms remove "nvidia/${v}" --all || true
    done

    # Drop the baked install's relocated libs + loader config + marker so only the driver we
    # are about to build ends up on the path. build_kernel_module recreates the libs/conf.
    rm -f /etc/ld.so.conf.d/nvidia.conf || true
    rm -rf "${GPU_DEST:?}/lib64" || true
    rm -f "${DKMS_MARKER_FILE}" || true
    ldconfig || true
}

set +euo pipefail
open_devices="$(lsof /dev/nvidia* 2>/dev/null)"
echo "Open devices: $open_devices"

open_gridd="$(lsof /usr/bin/nvidia-gridd 2>/dev/null)"
echo "Open gridd: $open_gridd"
set -euo pipefail

if [ "${AKSGPU_BUILD_ONLY}" = "1" ]; then
    # VHD build time: compile + cache only, no device access.
    echo "aks-gpu: build-only mode (prebuilding kernel module for kernel ${KERNEL_NAME})"
    build_kernel_module
    write_dkms_marker
    rm -r /opt/gpu
    exit 0
fi

install_nvidia_container_toolkit

if [ "${AKSGPU_SKIP_KERNEL_BUILD}" = "1" ] && baked_marker_matches; then
    # Node boot, prebuilt module valid for this kernel+driver: skip recompilation, ensure the
    # baked module is loadable, then run the device-dependent steps only.
    echo "aks-gpu: skip-kernel-build mode (using module prebuilt in VHD for kernel ${KERNEL_NAME})"
    ldconfig
    dkms status
    modinfo -k "$KERNEL_NAME" nvidia
else
    # Full build at boot: either skip-build wasn't requested, or the baked marker doesn't match
    # what this image installs (different kind/version — e.g. a GRID node booting a CUDA-baked
    # VHD). Wipe any stale baked driver first so the fresh install doesn't collide with it.
    if [ "${AKSGPU_SKIP_KERNEL_BUILD}" = "1" ]; then
        echo "aks-gpu: skip-kernel-build requested but baked marker does not match ${DRIVER_KIND} ${DRIVER_VERSION} on ${KERNEL_NAME}; falling back to full build"
    fi
    remove_stale_baked_driver
    build_kernel_module
fi

device_init

rm -r /opt/gpu
