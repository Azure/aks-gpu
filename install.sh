#!/usr/bin/env bash

# NOTE: `set -euxo pipefail` and the `source`s of the gpu config + package-manager helpers are
# applied inside main() rather than at top level, so this script can be sourced by the unit tests
# (test/install.bats) to exercise the individual functions on a GPU-less host without running the
# install or requiring /opt/gpu to exist. main() is invoked only when the script is executed
# directly (see the guard at the bottom).

PS4='+ $(date -u -I"seconds" | cut -c1-19) '

# Install mode flags (set by entrypoint.sh based on the requested action):
#   AKSGPU_BUILD_ONLY=1        -> compile/cache the kernel module + userspace libs only.
#                                 Runs on a GPU-less host (e.g. the Packer VHD builder).
#                                 Skips every device-dependent step (modprobe, nvidia-smi,
#                                 fabric manager, persistence) and writes a marker.
#   AKSGPU_SKIP_KERNEL_BUILD=1 -> the kernel module + libs were prebuilt into the VHD for
#                                 this exact kernel+driver; skip recompilation and only run
#                                 the device-dependent steps at node boot.
#   (neither set)              -> legacy behaviour: full compile + node initialization in one shot.
AKSGPU_BUILD_ONLY="${AKSGPU_BUILD_ONLY:-0}"
AKSGPU_SKIP_KERNEL_BUILD="${AKSGPU_SKIP_KERNEL_BUILD:-0}"

# Host-side marker describing what was baked into the VHD at build time. AgentBaker reads
# this (plus its own image-digest record) to decide whether the boot-time fast path is safe.
DKMS_MARKER_FILE="/opt/azure/aks-gpu/dkms-marker"

KERNEL_NAME=$(uname -r)
LOG_FILE_NAME="/var/log/nvidia-installer-$(date +%s).log"
ARCH=$(uname -m)

# target_build_kernel returns the kernel the VHD will actually boot. At VHD build time the Packer
# builder is still running the image's PREVIOUS kernel, while the build has already upgraded the
# image to a NEWER kernel and installed only that target kernel's headers (the builder kernel's
# headers are purged). Compiling against `uname -r` would therefore fail (no headers) and, even if
# it succeeded, the dkms-marker would not match the kernel the node boots. Select the newest kernel
# that has a usable headers/build tree; fall back to the running kernel when none is found (e.g. a
# normal node boot, where uname -r is already correct).
target_build_kernel() {
    local d k
    # newest installed kernel that has a headers/build tree (the VHD's target kernel). The modules
    # root is overridable (AKSGPU_MODULES_ROOT) so the unit tests can point it at a fixture dir.
    local modules_root="${AKSGPU_MODULES_ROOT:-/lib/modules}"
    k=$(for d in "${modules_root}"/*/build; do
            [ -d "$d" ] || continue
            d=${d%/build}
            echo "${d#"${modules_root}"/}"
        done | sort -V | tail -n1)
    if [ -n "$k" ]; then echo "$k"; else uname -r; fi
}

# cleanup_overlay tears down the tmpfs+overlay scaffold. It is driven entirely by the live mount
# state (mountpoint -q) rather than a flag, so it is idempotent and correct no matter where a
# failure occurred -- including a partial setup where only the tmpfs mounted but the
# overlay-on-/usr/lib mount failed. This guarantees a build-time exit never freezes a dangling
# mount into the VHD, and never clears state while a mount is still live.
cleanup_overlay() {
    set +e
    if mountpoint -q "/usr/lib/${ARCH}-linux-gnu"; then
        umount -l "/usr/lib/${ARCH}-linux-gnu"
    fi
    if mountpoint -q /tmp/overlay; then
        umount /tmp/overlay
    fi
    if ! mountpoint -q /tmp/overlay 2>/dev/null; then
        rm -rf /tmp/overlay
    fi
    set -e
}
# The EXIT trap that runs cleanup_overlay (and resets PS4) is installed at the start of main(),
# not here, so that sourcing this script for unit tests neither registers a trap nor tears down
# mounts when the test process exits.

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

    # clear any lingering mounts from a previous attempt (idempotent, mount-state driven)
    cleanup_overlay

    # set up overlayfs to relocate nvidia libs from /usr/lib/$ARCH-linux-gnu into GPU_DEST/lib64.
    # add an extra layer of indirection via tmpfs because it's not possible to have an overlayfs on an overlayfs (i.e., inside a container)
    mkdir -p /tmp/overlay
    mount -t tmpfs tmpfs /tmp/overlay
    mkdir -p /tmp/overlay/workdir /tmp/overlay/lib64
    mkdir -p ${GPU_DEST}/lib64
    mount -t overlay overlay -o lowerdir="/usr/lib/${ARCH}-linux-gnu",upperdir=/tmp/overlay/lib64,workdir=/tmp/overlay/workdir "/usr/lib/${ARCH}-linux-gnu"

    resolve_runfile

    # install nvidia drivers (DKMS build is the dominant cost we are hoisting to VHD build time)
    pushd /opt/gpu
    local installer_rc=0
    /opt/gpu/${RUNFILE}/nvidia-installer -s -k=$KERNEL_NAME --log-file-name=${LOG_FILE_NAME} -a --no-drm --dkms || installer_rc=$?
    popd
    if [ "${installer_rc}" -ne 0 ]; then
        echo "aks-gpu: nvidia-installer failed (rc=${installer_rc}) for kernel ${KERNEL_NAME}; installer log follows:"
        cat "${LOG_FILE_NAME}" 2>/dev/null || true
        return "${installer_rc}"
    fi

    # move nvidia libs to correct location from temporary overlayfs. Clear any pre-existing libs
    # first: when a full build runs over a prebaked VHD whose driver kind/version differs (e.g. a
    # GRID node booting a CUDA-prebaked image, routed here by the driver_kind guard), the baked
    # driver's userspace libs are already staged under ${GPU_DEST}/lib64. A plain copy would MERGE
    # both versions (e.g. libnvidia-ml.so.570.* and .580.*), which breaks NVML for consumers like the
    # device plugin ("Driver/library version mismatch"). Removing the directory first makes the
    # staged libs authoritative for exactly the driver we just built. (The skip-build fast path never
    # reaches here, so a matching prebaked VHD keeps its baked libs untouched.)
    rm -rf "${GPU_DEST}/lib64/lib64"
    cp -a /tmp/overlay/lib64 ${GPU_DEST}/lib64

    # configure system to know about nvidia lib paths
    echo "${GPU_DEST}/lib64" > /etc/ld.so.conf.d/nvidia.conf
    ldconfig

    cleanup_overlay

    # validate that the kernel module was built and registered (no device access required)
    dkms status
    modinfo -k "$KERNEL_NAME" nvidia
}

# initialize_nvidia_driver runs the steps that require the physical GPU and therefore must
# execute at node boot, regardless of whether the kernel module was prebuilt into the VHD.
# Keep this ahead of the container toolkit install: the toolkit package immediately starts
# nvidia-cdi-refresh, whose nvidia-smi readiness check requires these userspace libraries.
initialize_nvidia_driver() {
    nvidia-modprobe -u -c0

    # configure persistence daemon
    # decreases latency for later driver loads
    # reduces nvidia-smi invocation time 10x from 30 to 2 sec
    # notable on large VM sizes with multiple GPUs
    # especially when nvidia-smi process is in CPU cgroup
    cp -r /usr/bin/lib64/lib64/* "/usr/lib/${ARCH}-linux-gnu/"
    ldconfig
    nvidia-smi

    # install fabricmanager for nvlink based systems, but skip it on arm64:
    # arm64 = Grace-Blackwell (GB200/GB300), which uses IMEX, not a node-local FM.
    # (uname -m reports "aarch64" for arm64.)
    if [[ "${DRIVER_KIND}" == "cuda" && "${ARCH}" != "aarch64" ]]; then
        bash /opt/gpu/fabricmanager-linux-${ARCH}-${DRIVER_VERSION}/sbin/fm_run_package_installer.sh
    fi
}

configure_nvidia_container_runtime() {
    local nvidia_ctk_bin="${AKSGPU_NVIDIA_CTK_BIN:-/usr/bin/nvidia-ctk}"

    install_nvidia_container_toolkit

    # install nvidia-imex on arm64 (Grace-Blackwell): the cross-node NVLink (MNNVL)
    # coordinator that GB uses in place of a node-local fabric manager. The binary must be
    # present on the host so the NVIDIA DRA driver (ComputeDomains) can inject it into its
    # per-workload IMEX daemon pods. --force-depends: the deb declares nvidia-modprobe,
    # which is provided by the runfile driver (present on disk) rather than as a deb.
    # The node-wide nvidia-imex.service stays OFF -- IMEX is orchestrated per ComputeDomain
    # by DRA, not run cluster-wide from the host.
    if [[ "${DRIVER_KIND}" == "cuda" && "${ARCH}" == "aarch64" ]]; then
        dpkg -i --force-depends /opt/gpu/nvidia-imex_*_arm64.deb
        systemctl disable --now nvidia-imex.service 2>/dev/null || true
    fi

    mkdir -p /etc/containerd/config.d
    cp /opt/gpu/10-nvidia-runtime.toml /etc/containerd/config.d/10-nvidia-runtime.toml

    mkdir -p "$(dirname /lib/udev/rules.d/71-nvidia-dev-char.rules)"
    cp /opt/gpu/71-nvidia-char-dev.rules /lib/udev/rules.d/71-nvidia-dev-char.rules
    "$nvidia_ctk_bin" system create-dev-char-symlinks --create-all

    # The package post-install starts this oneshot too, but require a final successful run after
    # all runtime/device setup. A successful oneshot is inactive afterward, so its exit status
    # rather than `is-active` is the health signal. Clear the package-time start counter first:
    # the post-install and path unit can otherwise consume the service's five-start budget.
    systemctl reset-failed nvidia-cdi-refresh.service nvidia-cdi-refresh.path 2>/dev/null || true
    systemctl restart nvidia-cdi-refresh.service
}

write_dkms_marker() {
    mkdir -p "$(dirname "${DKMS_MARKER_FILE}")"
    local tmp_marker="${DKMS_MARKER_FILE}.tmp.$$"
    cat > "${tmp_marker}" <<EOF
kernel=${KERNEL_NAME}
driver_version=${DRIVER_VERSION}
driver_kind=${DRIVER_KIND}
arch=${ARCH}
EOF
    # atomic publish: a partially-written marker must never be observed by the boot-time check
    mv -f "${tmp_marker}" "${DKMS_MARKER_FILE}"
}

# baked_marker_matches returns success only when the VHD's baked driver exactly matches what
# this node needs (kernel + driver_version + driver_kind). AgentBaker requests skip-build based
# only on the marker's presence and delegates the actual match check here, so a CUDA-baked VHD
# booting a GRID node -- or a driver-version bump since bake -- fails this check and falls back
# to a full build.
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

# build_and_mark compiles + DKMS-registers the module, then records exactly what was built so
# the marker always reflects on-disk reality. Writing the marker after every build (not just at
# VHD-bake time) means a boot-time fallback build also refreshes the marker, so the *next* boot
# takes the fast path instead of rebuilding forever.
build_and_mark() {
    build_kernel_module
    write_dkms_marker
}

# fast_path_ok opportunistically validates a prebaked module without recompiling. It returns
# non-zero (instead of aborting under `set -e`) so a corrupt or incomplete prebake falls back to
# a full build rather than bricking the node. The authoritative device check still happens later
# in initialize_nvidia_driver (nvidia-modprobe + nvidia-smi).
fast_path_ok() {
    ldconfig || return 1
    dkms status >/dev/null 2>&1 || return 1
    modinfo -k "${KERNEL_NAME}" nvidia >/dev/null 2>&1 || return 1
}

# purge_gpu_cache removes the gpu cache that entrypoint.sh staged under /opt/gpu once install.sh
# has consumed it. Factored out of the two former inline `rm -r /opt/gpu` calls so the unit tests
# can stub it when exercising main()'s dispatch.
purge_gpu_cache() {
    rm -r /opt/gpu
}

# main is the install entrypoint. It is run only when the script is executed directly (the guard
# at the bottom), so sourcing the script for unit tests loads the functions above without running
# any install steps. The set-flags and the gpu config/helper sources live here (not at top level)
# for the same reason.
main() {
    set -euxo pipefail
    # shellcheck source=/dev/null
    source "${AKSGPU_CONFIG_PATH:-/opt/gpu/config.sh}"
    # shellcheck source=/dev/null
    source "${AKSGPU_PMH_PATH:-/opt/gpu/package_manager_helpers.sh}"
    trap 'cleanup_overlay; PS4="+ "' EXIT

    set +euo pipefail
    open_devices="$(lsof /dev/nvidia* 2>/dev/null)"
    echo "Open devices: $open_devices"

    open_gridd="$(lsof /usr/bin/nvidia-gridd 2>/dev/null)"
    echo "Open gridd: $open_gridd"
    set -euo pipefail

    if [ "${AKSGPU_BUILD_ONLY}" = "1" ]; then
        # VHD build time: compile + cache + marker only, no device access. Target the kernel the VHD
        # will boot (not the builder's running kernel) so the prebuilt module + marker match at boot.
        KERNEL_NAME="$(target_build_kernel)"
        echo "aks-gpu: build-only mode (prebuilding kernel module for kernel ${KERNEL_NAME}; builder running $(uname -r))"
        echo "aks-gpu: kernels with installed headers (build trees):"; ls -ld "${AKSGPU_MODULES_ROOT:-/lib/modules}"/*/build 2>/dev/null || echo "  (none found)"
        build_and_mark
        purge_gpu_cache
        exit 0
    fi

    if [ "${AKSGPU_SKIP_KERNEL_BUILD}" = "1" ] && baked_marker_matches && fast_path_ok; then
        # Prebuilt module is present and valid for this kernel+driver: skip the ~100s recompile.
        echo "aks-gpu: using kernel module prebuilt in the VHD for kernel ${KERNEL_NAME} (recompile skipped)"
    else
        if [ "${AKSGPU_SKIP_KERNEL_BUILD}" = "1" ]; then
            echo "aks-gpu: prebuilt module missing/invalid for ${DRIVER_KIND} ${DRIVER_VERSION} on ${KERNEL_NAME}; building from source"
        fi
        # No bespoke stale-driver teardown is needed: `nvidia-installer -s` automatically uninstalls
        # any previously runfile-installed driver -- including a mismatched prebaked one -- and its
        # DKMS registration before installing the new one. build_and_mark then refreshes the marker
        # to match what we just built, so subsequent boots take the fast path.
        build_and_mark
    fi

    initialize_nvidia_driver
    configure_nvidia_container_runtime

    purge_gpu_cache
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
