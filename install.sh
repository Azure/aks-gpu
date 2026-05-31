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

if [ "${AKSGPU_SKIP_KERNEL_BUILD}" = "1" ]; then
    # Node boot, prebuilt module valid for this kernel+driver: skip recompilation, ensure the
    # baked module is loadable, then run the device-dependent steps only.
    echo "aks-gpu: skip-kernel-build mode (using module prebuilt in VHD for kernel ${KERNEL_NAME})"
    ldconfig
    dkms status
    modinfo -k "$KERNEL_NAME" nvidia
else
    build_kernel_module
fi

device_init

rm -r /opt/gpu
