#!/usr/bin/env bash
set -euxo pipefail

source /opt/gpu/config.sh
source /opt/gpu/package_manager_helpers.sh

trap 'PS4="+ "' exit
PS4='+ $(date -u -I"seconds" | cut -c1-19) '

KERNEL_NAME=$(uname -r)
LOG_FILE_NAME="/var/log/nvidia-installer-$(date +%s).log"

set +euo pipefail
open_devices="$(lsof /dev/nvidia* 2>/dev/null)"
echo "Open devices: $open_devices"

open_gridd="$(lsof /usr/bin/nvidia-gridd 2>/dev/null)"
echo "Open gridd: $open_gridd"

set -euo pipefail

# install cached nvidia debian packages for container runtime compatibility
install_cached_nvidia_packages() {
for apt_package in $NVIDIA_PACKAGES; do
    dpkg -i --force-overwrite /opt/gpu/${apt_package}_${NVIDIA_CONTAINER_TOOLKIT_VER}*
done
}

use_package_manager_with_retries wait_for_dpkg_lock install_cached_nvidia_packages 10 3

# blacklist nouveau driver, nvidia driver dependency
cp /opt/gpu/blacklist-nouveau.conf /etc/modprobe.d/blacklist-nouveau.conf
update-initramfs -u

# clean up lingering files from previous install
set +e
umount -l /usr/lib/x86_64-linux-gnu || true
umount -l /tmp/overlay || true
rm -r /tmp/overlay || true
set -e

# set up overlayfs to change install location of nvidia libs from /usr/lib/x86_64-linux-gnu to /usr/local/nvidia
# add an extra layer of indirection via tmpfs because it's not possible to have an overlayfs on an overlayfs (i.e., inside a container)
mkdir /tmp/overlay
mount -t tmpfs tmpfs /tmp/overlay
mkdir /tmp/overlay/{workdir,lib64}
mkdir -p ${GPU_DEST}/lib64
mount -t overlay overlay -o lowerdir=/usr/lib/x86_64-linux-gnu,upperdir=/tmp/overlay/lib64,workdir=/tmp/overlay/workdir /usr/lib/x86_64-linux-gnu

if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    RUNFILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}"
elif [[ "${DRIVER_KIND}" == "grid" ]]; then
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
umount -l /usr/lib/x86_64-linux-gnu
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
cp -r /usr/bin/lib64/lib64/* /usr/lib/x86_64-linux-gnu/
nvidia-smi

# install fabricmanager for nvlink based systems
if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    bash /opt/gpu/fabricmanager-linux-x86_64-${DRIVER_VERSION}/sbin/fm_run_package_installer.sh
fi

mkdir -p /etc/containerd/config.d
cp /opt/gpu/10-nvidia-runtime.toml /etc/containerd/config.d/10-nvidia-runtime.toml

mkdir -p "$(dirname /lib/udev/rules.d/71-nvidia-dev-char.rules)"
cp /opt/gpu/71-nvidia-char-dev.rules /lib/udev/rules.d/71-nvidia-dev-char.rules
/usr/bin/nvidia-ctk system create-dev-char-symlinks --create-all

rm -r /opt/gpu
