#!/usr/bin/env bash
set -o pipefail
set -o nounset

set -x

sleep="${2:-}"

# clean up any existing gpu files
# can happen if using a different version than cached
rm -r /mnt/gpu/* || true

set -o errexit
if [[ -z "${1}" ]]; then
    echo "Must provide a non-empty action as first argument"
    exit 1
fi

if [[ "${1}" == "copy" ]]; then
    echo "copying gpu cache files and exiting"
    cp -a /opt/gpu/. /mnt/gpu/
    echo "Completed successfully!"
    exit 0
fi

# Map the requested action to the install mode passed to install.sh. All three install
# variants stage the same gpu cache files; only the env var handed to install.sh differs.
#   install            -> full compile + node initialization (legacy behaviour)
#   build-only         -> compile/cache the kernel module only (VHD build, no GPU)
#   install-skip-build -> node initialization only, reusing the module prebuilt into the VHD
GPU_INSTALL_MODE_ENV=""
case "${1}" in
    build-only)         GPU_INSTALL_MODE_ENV="AKSGPU_BUILD_ONLY=1" ;;
    install-skip-build) GPU_INSTALL_MODE_ENV="AKSGPU_SKIP_KERNEL_BUILD=1" ;;
esac

if [[ "${1}" == "install" || -n "${GPU_INSTALL_MODE_ENV}" ]]; then
    echo "copying gpu cache files (${1})"
    cp -a /opt/gpu/. /mnt/gpu/
    echo "copied successfully!"
fi

ACTION_FILE="/opt/actions/install.sh"

if [[ ! -f "$ACTION_FILE" ]]; then
    echo "Expected to find action file '$ACTION_FILE', but did not exist"
    exit 1
fi

echo "Cleaning up stale actions"

rm -rf /mnt/actions/*

echo "Copying fresh actions"

cp -R /opt/actions/. /mnt/actions

echo "Executing nsenter"

if [[ -n "${GPU_INSTALL_MODE_ENV}" ]]; then
    nsenter -t 1 -m env "${GPU_INSTALL_MODE_ENV}" bash "${ACTION_FILE}"
else
    nsenter -t 1 -m bash "${ACTION_FILE}"
fi
RESULT="${PIPESTATUS[0]}"

if [ $RESULT -eq 0 ]; then
    # Success.
    rm -rf /mnt/actions/*
    echo "Completed successfully!"
else
    echo "Failed during nsenter command execution"
    exit 1
fi

if [[ -z "${sleep}" ]]; then
  exit 0
fi

echo "Sleeping forever"

sleep infinity
