#!/usr/bin/env bash
set -euox pipefail

source /etc/os-release
source /opt/gpu/config.sh

workdir="$(mktemp -d)"
pushd "$workdir" || exit

download_amd_packages() {
    if [[ "${TARGETARCH}" != "amd64" ]]; then
        echo "ROCm driver images are only supported on amd64"
        exit 1
    fi
    if [[ "${VERSION_ID}" != "22.04" ]]; then
        echo "ROCm ${DRIVER_VERSION} requires Ubuntu 22.04; found ${VERSION_ID}"
        exit 1
    fi

    install -d -m 0755 /etc/apt/keyrings /opt/gpu/amd-packages/partial
    curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key |
        gpg --dearmor -o /etc/apt/keyrings/rocm.gpg
    chmod 0644 /etc/apt/keyrings/rocm.gpg

    cat > /etc/apt/sources.list.d/amdgpu.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/amdgpu/${DRIVER_VERSION}/ubuntu jammy main
EOF
    cat > /etc/apt/sources.list.d/rocm.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${DRIVER_VERSION} jammy main
EOF
    cat > /etc/apt/preferences.d/rocm-pin-600 <<'EOF'
Package: *
Pin: origin "repo.radeon.com"
Pin-Priority: 600
EOF

    apt-get update

    # Ubuntu also publishes a package named rocminfo. Prefer AMD's version so its hsa-rocr
    # runtime and AMD libdrm dependencies are included in the cache.
    local rocm_package_version rocm_version_major rocm_version_minor rocm_version_patch rocm_build
    IFS=. read -r rocm_version_major rocm_version_minor rocm_version_patch <<< "${DRIVER_VERSION}"
    printf -v rocm_build '%d%02d%02d' \
        "${rocm_version_major}" "${rocm_version_minor}" "${rocm_version_patch}"
    rocm_package_version="$(apt-cache policy rocminfo | sed -n 's/^[[:space:]]*Candidate: //p')"
    if [[ "${rocm_package_version}" != *"${rocm_build}"* ]]; then
        echo "Expected AMD ROCm ${DRIVER_VERSION} rocminfo package, found ${rocm_package_version}"
        exit 1
    fi

    # Resolve against an empty status database. Without this, apt omits dependencies already
    # installed in the image-build stage even though the target host may not have them.
    local empty_status
    empty_status="$(mktemp)"
    apt-get install --download-only -y --no-install-recommends \
        -o Dir::State::status="${empty_status}" \
        -o Dir::Cache::archives=/opt/gpu/amd-packages \
        ${AMD_PACKAGES}
    rm -f "${empty_status}"
    rm -rf /opt/gpu/amd-packages/partial

    local package
    for package in ${AMD_REQUIRED_PACKAGES}; do
        if ! find /opt/gpu/amd-packages -maxdepth 1 -name "${package}_*.deb" -print -quit |
            grep -q .; then
            echo "Required AMD package was not cached: ${package}"
            exit 1
        fi
    done

    : > /opt/gpu/amd-packages/PACKAGE-MANIFEST.txt
    for package_file in /opt/gpu/amd-packages/*.deb; do
        printf '%s\t%s\t%s\n' \
            "$(dpkg-deb -f "${package_file}" Package)" \
            "$(dpkg-deb -f "${package_file}" Version)" \
            "$(dpkg-deb -f "${package_file}" Architecture)" \
            >> /opt/gpu/amd-packages/PACKAGE-MANIFEST.txt
    done
    sort -u -o /opt/gpu/amd-packages/PACKAGE-MANIFEST.txt \
        /opt/gpu/amd-packages/PACKAGE-MANIFEST.txt
    (
        cd /opt/gpu/amd-packages
        sha256sum ./*.deb > SHA256SUMS
        sha256sum -c SHA256SUMS
    )
}

if [[ "${DRIVER_KIND}" == "rocm" ]]; then
    download_amd_packages
    popd || exit
    rm -r "$workdir"
    exit 0
fi

NVIDIA_DRIVER_ARCH=$TARGETARCH
if [ $TARGETARCH = "arm64" ]; then
    NVIDIA_DRIVER_ARCH="aarch64"
elif [ $TARGETARCH = "amd64" ]; then
    NVIDIA_DRIVER_ARCH="x86_64"
fi

NVIDIA_FM_ARCH=$TARGETARCH
if [ $TARGETARCH = "arm64" ]; then
    # NVIDIA uses the name "SBSA" for ARM64 platforms for the fabric manager. See https://en.wikipedia.org/wiki/Server_Base_System_Architecture
    NVIDIA_FM_ARCH="sbsa"
elif [ $TARGETARCH = "amd64" ]; then
    NVIDIA_FM_ARCH="x86_64"
fi

if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    RUNFILE="NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${DRIVER_VERSION}"
    curl -fsSLO https://us.download.nvidia.com/tesla/${DRIVER_VERSION}/${RUNFILE}.run 
elif [[ "${DRIVER_KIND}" == "grid" ]]; then
    RUNFILE="NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${DRIVER_VERSION}-grid-azure"
    curl -fsSLO "${DRIVER_URL}"
else
    echo "Invalid driver kind: ${DRIVER_KIND}"
    exit 1
fi

# download nvidia drivers, move to permanent cache
mv ${RUNFILE}.run /opt/gpu/${RUNFILE}.run
pushd /opt/gpu
# extract runfile, takes some time, so do ahead of time
sh /opt/gpu/${RUNFILE}.run -x
rm /opt/gpu/${RUNFILE}.run
popd

install_fabric_manager () {
    curl -fsSLO https://developer.download.nvidia.com/compute/nvidia-driver/redist/fabricmanager/linux-${NVIDIA_FM_ARCH}/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}-archive.tar.xz
    tar -xvf fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}-archive.tar.xz
    mv fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}-archive /opt/gpu/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}
    mv /opt/gpu/fm_run_package_installer.sh /opt/gpu/fabricmanager-linux-${NVIDIA_FM_ARCH}-${DRIVER_VERSION}/sbin/fm_run_package_installer.sh
}

if [[ "${DRIVER_KIND}" == "cuda" ]]; then
    # download fabricmanager for nvlink based systems, e.g. multi instance gpu vms.
   install_fabric_manager
fi


# configure nvidia apt repo to cache packages
curl -fsSLO https://nvidia.github.io/libnvidia-container/gpgkey
gpg --dearmor -o aptnvidia.gpg gpgkey
mv aptnvidia.gpg /etc/apt/trusted.gpg.d/aptnvidia.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -o /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt update
chmod 644 /etc/apt/trusted.gpg.d/*

# download nvidia debian packages for nvidia-container-runtime compat
for apt_package in $NVIDIA_PACKAGES; do
    apt-get download ${apt_package}=${NVIDIA_CONTAINER_TOOLKIT_VER}*
    mv ${apt_package}_${NVIDIA_CONTAINER_TOOLKIT_VER}* /opt/gpu
done

popd || exit
rm -r "$workdir"
