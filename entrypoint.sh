#!/usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset

set -x

sleep="${2:-}"

# clean up any existing gpu files
# can happen if using a different version than cached
rm -r /mnt/gpu/*

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

if [[ "${1}" == "install" ]]; then
    echo "copying gpu cache files"
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

nsenter -t 1 -m bash "${ACTION_FILE}"
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
