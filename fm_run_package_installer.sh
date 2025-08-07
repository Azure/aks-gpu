#!/bin/sh
set -uxo pipefail

echo "Staring NVIDIA Fabric Manager installation"

ROOTDIR="$(dirname $(realpath "${BASH_SOURCE[0]}"))/.."

# currently support only Ubuntu and Debian
linuxdistro=`grep -w ID /etc/*-release | awk -F '=' '{print $2}'`
if [ "$linuxdistro" != "ubuntu" ] && [ "$linuxdistro" != "debian" ]; then
  echo "Error: .RUN based installation is supported only for Ubuntu and Debian distributions"
  #exit
fi

echo "Checking for running Fabric Manager service"

STATUS=`systemctl is-active nvidia-fabricmanager`
  if [ "${STATUS}" == 'active' ]; then
    echo "Fabric Manager service is running, stopping the same....."
    systemctl stop nvidia-fabricmanager
  else
    echo "Fabric Manager service is not running....."
  fi

# copy all the files
echo "Copying files to desired location"
cp ${ROOTDIR}/lib/libnvfm.so.1 /usr/lib/$(uname -m)-linux-gnu
cp -P ${ROOTDIR}/lib/libnvfm.so   /usr/lib/$(uname -m)-linux-gnu

cp ${ROOTDIR}/bin/nv-fabricmanager  /usr/bin
cp ${ROOTDIR}/bin/nvswitch-audit  /usr/bin
cp ${ROOTDIR}/bin/nvidia-fabricmanager-start.sh /usr/bin

cp ${ROOTDIR}/systemd/nvidia-fabricmanager.service  /lib/systemd/system

mkdir /usr/share/nvidia  > /dev/null 2>&1
mkdir /usr/share/nvidia/nvswitch/  > /dev/null 2>&1
cp ${ROOTDIR}/share/nvidia/nvswitch/dgx2_hgx2_topology    /usr/share/nvidia/nvswitch/
# Copy all topology files at once
cp ${ROOTDIR}/share/nvidia/nvswitch/* /usr/share/nvidia/nvswitch/

cp ${ROOTDIR}/etc/fabricmanager.cfg  /usr/share/nvidia/nvswitch/

cp ${ROOTDIR}/include/nv_fm_agent.h     /usr/include
cp ${ROOTDIR}/include/nv_fm_types.h     /usr/include

mkdir /usr/share/doc/nvidia-fabricmanager > /dev/null 2>&1
cp ${ROOTDIR}/LICENSE  /usr/share/doc/nvidia-fabricmanager
cp ${ROOTDIR}/third-party-notices.txt  /usr/share/doc/nvidia-fabricmanager

# enable Fabric Manager service
systemctl enable nvidia-fabricmanager

# let the user start FM service manually.
echo "Fabric Manager installation completed."
echo "Note: Fabric Manager service is not started. Start it using systemctl commands (like systemctl start nvidia-fabricmanager)"
