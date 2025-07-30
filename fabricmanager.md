# Fabric manager installation notes

The layout of the fabric manager archive now looks like this:
```bash
root@518f7df53862:/opt/gpu/fabricmanager-linux-x86_64-470.57.02# tree
.
|-- LICENSE
|-- bin
|   |-- nv-fabricmanager
|   |-- nvidia-fabricmanager-start.sh
|   `-- nvswitch-audit
|-- etc
|   `-- fabricmanager.cfg
|-- include
|   |-- nv_fm_agent.h
|   `-- nv_fm_types.h
|-- lib
|   |-- libnvfm.so -> libnvfm.so.1
|   `-- libnvfm.so.1
|-- sbin
|   `-- fm_run_package_installer.sh
|-- share
|   `-- nvidia
|       `-- nvswitch
|           |-- dgx2_hgx2_topology
|           `-- dgxa100_hgxa100_topology
|-- systemd
|   `-- nvidia-fabricmanager.service
`-- third-party-notices.txt
```

But the installer expects all these files to be in the same directory as itself:
```bash
#!/bin/sh

echo "Staring NVIDIA Fabric Manager installation"

# currently support only Ubuntu and Debian
linuxdisto=`grep -w ID /etc/*-release | awk -F '=' '{print $2}'`
if [ "$linuxdisto" != "ubuntu" ] && [ "$linuxdisto" != "debian" ]; then
  echo "Error: .RUN based installation is supported only for Ubuntu and Debian distributions"
  #exit
fi

echo "Checking for running Fabric Manager service"

STATUS=`systemctl is-active nvidia-fabricmanager`
  if [ ${STATUS} = 'active' ]; then
    echo "Fabric Manager service is running, stopping the same....."
    systemctl stop nvidia-fabricmanager
  else
    echo "Fabric Manager service is not running....."
  fi

# copy all the files
echo "Copying files to desired location"
cp ${PWD}/libnvfm.so.1 /usr/lib/x86_64-linux-gnu
cp -P ${PWD}/libnvfm.so   /usr/lib/x86_64-linux-gnu

cp ${PWD}/nv-fabricmanager  /usr/bin
cp ${PWD}/nvswitch-audit  /usr/bin
cp ${PWD}/nvidia-fabricmanager.service  /lib/systemd/system

mkdir /usr/share/nvidia  > /dev/null 2>&1
mkdir /usr/share/nvidia/nvswitch/  > /dev/null 2>&1
cp ${PWD}/dgx2_hgx2_topology    /usr/share/nvidia/nvswitch/
cp ${PWD}/dgxa100_hgxa100_topology    /usr/share/nvidia/nvswitch/
cp ${PWD}/fabricmanager.cfg  /usr/share/nvidia/nvswitch/

cp ${PWD}/nv_fm_agent.h     /usr/include
cp ${PWD}/nv_fm_types.h     /usr/include

mkdir /usr/share/doc/nvidia-fabricmanager > /dev/null 2>&1
cp ${PWD}/LICENSE  /usr/share/doc/nvidia-fabricmanager
cp ${PWD}/third-party-notices.txt  /usr/share/doc/nvidia-fabricmanager

# enable Fabric Manager service
systemctl enable nvidia-fabricmanager

# let the user start FM service manually.
echo "Fabric Manager installation completed."
echo "Note: Fabric Manager service is not started. Start it using systemctl commands (like systemctl start nvidia-fabricmanager)"
```

All the source directories for the `cp` commands are wrong.
We modify the script to use relative directories from the source of the tarball.

```bash
cp ${ROOTDIR}/lib/libnvfm.so.1 /usr/lib/x86_64-linux-gnu
cp -P ${ROOTDIR}/lib/libnvfm.so   /usr/lib/x86_64-linux-gnu

cp ${ROOTDIR}/bin/nv-fabricmanager  /usr/bin
cp ${ROOTDIR}/bin/nvswitch-audit  /usr/bin
cp ${ROOTDIR}/systemd/nvidia-fabricmanager.service  /lib/systemd/system

mkdir /usr/share/nvidia  > /dev/null 2>&1
mkdir /usr/share/nvidia/nvswitch/  > /dev/null 2>&1
cp ${ROOTDIR}/share/nvidia/nvswitch/dgx2_hgx2_topology    /usr/share/nvidia/nvswitch/
cp ${ROOTDIR}/share/nvidia/nvswitch/dgxa100_hgxa100_topology    /usr/share/nvidia/nvswitch/
cp ${ROOTDIR}/etc/fabricmanager.cfg  /usr/share/nvidia/nvswitch/

cp ${ROOTDIR}/include/nv_fm_agent.h     /usr/include
cp ${ROOTDIR}/include/nv_fm_types.h     /usr/include

mkdir /usr/share/doc/nvidia-fabricmanager > /dev/null 2>&1
cp ${ROOTDIR}/LICENSE  /usr/share/doc/nvidia-fabricmanager
cp ${ROOTDIR}/third-party-notices.txt  /usr/share/doc/nvidia-fabricmanager
```
