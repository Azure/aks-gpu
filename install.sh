#!/usr/bin/env bash
set -euxo pipefail

source /opt/gpu/config.sh
source /opt/gpu/package_manager_helpers.sh

trap 'PS4="+ "' exit
PS4='+ $(date -u -I"seconds" | cut -c1-19) '

KERNEL_NAME=$(uname -r)
LOG_FILE_NAME="/var/log/nvidia-installer-$(date +%s).log"
ARCH=$(uname -m)

set +euo pipefail
open_devices="$(lsof /dev/nvidia* 2>/dev/null)"
echo "Open devices: $open_devices"

open_gridd="$(lsof /usr/bin/nvidia-gridd 2>/dev/null)"
echo "Open gridd: $open_gridd"

set -euo pipefail

# install cached nvidia debian packages for container runtime compatibility
ensure_cdi_refresh_units() {
    local missing_units=()
    local units=("nvidia-cdi-refresh.path" "nvidia-cdi-refresh.service")

    for unit in "${units[@]}"; do
        if systemctl cat "${unit}" >/dev/null 2>&1; then
            systemctl enable "${unit}"
        else
            missing_units+=("${unit}")
        fi
    done

    if [[ ${#missing_units[@]} -gt 0 ]]; then
        echo "Missing expected systemd units: ${missing_units[*]}."
        echo "Proceeding without automatic CDI refresh; containers may fail without manual nvidia-ctk cdi generate."
        return 1
    fi

    return 0
}

ensure_runtime_cdi_spec() {
    local tmpfile
    tmpfile=$(mktemp)

    if ! nvidia-ctk cdi list >"${tmpfile}" 2>&1; then
        echo "nvidia-ctk cdi list failed; attempting regeneration."
        mkdir -p /var/run/cdi
        if ! nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml; then
            echo "Unable to generate CDI specification; see above logs."
            cat "${tmpfile}"
            rm -f "${tmpfile}"
            return 1
        fi
        if ! nvidia-ctk cdi list >"${tmpfile}"; then
            echo "nvidia-ctk cdi list still failing after regeneration."
            cat "${tmpfile}"
            rm -f "${tmpfile}"
            return 1
        fi
    fi

    if ! grep -q "runtime.nvidia.com/gpu" "${tmpfile}"; then
        echo "runtime.nvidia.com/gpu devices not found; forcing CDI spec regeneration."
        mkdir -p /var/run/cdi
        if ! nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml; then
            echo "Unable to generate CDI specification containing runtime.nvidia.com aliases."
            cat "${tmpfile}"
            rm -f "${tmpfile}"
            return 1
        fi
        if ! nvidia-ctk cdi list >"${tmpfile}" || ! grep -q "runtime.nvidia.com/gpu" "${tmpfile}"; then
            echo "CDI specification still missing runtime.nvidia.com devices after regeneration."
            cat "${tmpfile}"
            rm -f "${tmpfile}"
            return 1
        fi
    fi

    rm -f "${tmpfile}"
}

start_cdi_refresh_units() {
    local units=("nvidia-cdi-refresh.path" "nvidia-cdi-refresh.service")
    local started=false

    for unit in "${units[@]}"; do
        if systemctl cat "${unit}" >/dev/null 2>&1; then
            if systemctl start "${unit}"; then
                started=true
            else
                echo "Warning: failed to start ${unit}; will fall back to nvidia-ctk cdi generate."
            fi
        fi
    done

    if ! $started; then
        echo "Warning: unable to start any nvidia-cdi-refresh units; falling back to manual CDI generation."
    fi

    ensure_runtime_cdi_spec
}

install_cached_nvidia_packages() {
for apt_package in $NVIDIA_PACKAGES; do
    dpkg -i --force-overwrite /opt/gpu/${apt_package}_${NVIDIA_CONTAINER_TOOLKIT_VER}*
done
}

use_package_manager_with_retries wait_for_dpkg_lock install_cached_nvidia_packages 10 3
ensure_cdi_refresh_units

# blacklist nouveau driver, nvidia driver dependency
cp /opt/gpu/blacklist-nouveau.conf /etc/modprobe.d/blacklist-nouveau.conf
update-initramfs -u

# clean up lingering files from previous install
set +e
umount -l /usr/lib/$(uname -m)-linux-gnu || true
umount -l /tmp/overlay || true
rm -r /tmp/overlay || true
set -e

# set up overlayfs to change install location of nvidia libs from /usr/lib/$ARCH-linux-gnu to /usr/local/nvidia
# add an extra layer of indirection via tmpfs because it's not possible to have an overlayfs on an overlayfs (i.e., inside a container)
mkdir /tmp/overlay
mount -t tmpfs tmpfs /tmp/overlay
mkdir /tmp/overlay/{workdir,lib64}
mkdir -p ${GPU_DEST}/lib64
mount -t overlay overlay -o lowerdir=/usr/lib/$(uname -m)-linux-gnu,upperdir=/tmp/overlay/lib64,workdir=/tmp/overlay/workdir /usr/lib/$(uname -m)-linux-gnu

if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    RUNFILE="NVIDIA-Linux-$(uname -m)-${DRIVER_VERSION}"
elif [[ "${DRIVER_KIND}" == "grid" ]]; then
    if [[ $(uname -m) != "x86_64" ]]; then
        echo "GRID driver is only supported on x86_64 architecture"
        exit 1
    fi
    RUNFILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}-grid-azure"
else
    echo "Invalid driver kind: ${DRIVER_KIND}"
    exit 1
fi

# install nvidia drivers
pushd /opt/gpu
/opt/gpu/${RUNFILE}/nvidia-installer -s -k=$KERNEL_NAME --log-file-name=${LOG_FILE_NAME} -a --no-drm --dkms
nvidia-smi
popd

# move nvidia libs to correct location from temporary overlayfs
cp -a /tmp/overlay/lib64 ${GPU_DEST}/lib64

# configure system to know about nvidia lib paths
echo "${GPU_DEST}/lib64" > /etc/ld.so.conf.d/nvidia.conf
ldconfig 

# unmount, cleanup
set +e
umount -l /usr/lib/$(uname -m)-linux-gnu
umount /tmp/overlay
rm -r /tmp/overlay
set -e

# validate that nvidia driver is working
dkms status
nvidia-modprobe -u -c0

# configure persistence daemon
# decreases latency for later driver loads
# reduces nvidia-smi invocation time 10x from 30 to 2 sec 
# notable on large VM sizes with multiple GPUs
# especially when nvidia-smi process is in CPU cgroup
cp -r /usr/bin/lib64/lib64/* /usr/lib/$(uname -m)-linux-gnu/
nvidia-smi

# install fabricmanager for nvlink based systems
if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    NVIDIA_FM_ARCH=$(uname -m)
    if [ $NVIDIA_FM_ARCH = "arm64" ]; then
        # NVIDIA uses the name "SBSA" for ARM64 platforms for the fabric manager. See https://en.wikipedia.org/wiki/Server_Base_System_Architecture
        NVIDIA_FM_ARCH="sbsa"
    fi
    bash /opt/gpu/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}/sbin/fm_run_package_installer.sh
fi

start_cdi_refresh_units

mkdir -p /etc/containerd/config.d
cp /opt/gpu/10-nvidia-runtime.toml /etc/containerd/config.d/10-nvidia-runtime.toml

mkdir -p "$(dirname /lib/udev/rules.d/71-nvidia-dev-char.rules)"
cp /opt/gpu/71-nvidia-char-dev.rules /lib/udev/rules.d/71-nvidia-dev-char.rules
/usr/bin/nvidia-ctk system create-dev-char-symlinks --create-all

rm -r /opt/gpu
