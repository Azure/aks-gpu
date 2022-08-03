#!/usr/bin/env bash
set -euxo pipefail

source /opt/gpu/config.sh

KERNEL_NAME=$(uname -r)
LOG_FILE_NAME="/var/log/nvidia-installer-$(date +%s).log"

# host needs these tools to build and load kernel module, can remove ca-certificates, was only for testing
apt update && apt install -y kmod gcc make dkms initramfs-tools linux-headers-$(uname -r) ca-certificates --no-install-recommends

# install cached nvidia debian packages for container runtime compatibility
for apt_package in $NVIDIA_PACKAGES; do
    dpkg -i /opt/gpu/${apt_package}*
done
dpkg -i /opt/gpu/nvidia-container-runtime*

# blacklist nouveau driver, nvidia driver dependency
cp /opt/gpu/blacklist-nouveau.conf /etc/modprobe.d/blacklist-nouveau.conf
update-initramfs -u

# clean up lingering files from previous install
set +e
umount -l /usr/lib/x86_64-linux-gnu || true
umount -l /tmp/overlay || true
rm -r /tmp/overlay
rm -r /opt/gpu/NVIDIA-Linux-x86_64-${DRIVER_VERSION}
set -e

# set up overlayfs to change install location of nvidia libs from /usr/lib/x86_64-linux-gnu to /usr/local/nvidia
# add an extra layer of indirection via tmpfs because it's not possible to have an overlayfs on an overlayfs (i.e., inside a container)
mkdir /tmp/overlay
mount -t tmpfs tmpfs /tmp/overlay
mkdir /tmp/overlay/{workdir,lib64}
mkdir -p ${GPU_DEST}/lib64
mount -t overlay overlay -o lowerdir=/usr/lib/x86_64-linux-gnu,upperdir=/tmp/overlay/lib64,workdir=/tmp/overlay/workdir /usr/lib/x86_64-linux-gnu

# clean up previously uncompressed driver, if it exists
# causes driver installer to fail if it exists
pushd /opt/gpu
# extract runfile, takes some time, so do ahead of time
sh /opt/gpu/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run -x
popd

# install nvidia drivers
/opt/gpu/NVIDIA-Linux-x86_64-${DRIVER_VERSION}/nvidia-installer -s -k=$KERNEL_NAME --log-file-name=${LOG_FILE_NAME} -a --no-drm --dkms --utility-prefix="${GPU_DEST}" --opengl-prefix="${GPU_DEST}"

# move nvidia libs to correct location from temporary overlayfs
cp -a /tmp/overlay/lib64 ${GPU_DEST}/lib64

# move nvidia binaries to /usr/bin...because we like that?
cp -rvT ${GPU_DEST}/bin /usr/bin

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
nvidia-smi
