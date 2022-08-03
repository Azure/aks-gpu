#!/usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset

set -x

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

ACTION_FILE="/opt/actions/${1}"

if [[ ! -f "$ACTION_FILE" ]]; then
    echo "Expected to find action file '$ACTION_FILE', but did not exist"
    exit 1
fi

echo "Cleaning up stale actions"

rm -rf /mnt/actions/*

echo "Copying fresh actions"

cp -R /opt/actions/. /mnt/actions

echo "Executing nsenter"

cp -a /opt/gpu/. /mnt/gpu/
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
