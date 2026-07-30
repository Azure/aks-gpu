#!/usr/bin/env bats
#
# Unit tests for install.sh: the prebake mode dispatch (build-only / install-skip-build /
# install), the dkms marker write+parse+validate, the opportunistic fast-path fallback, and
# the target-kernel selection. These run on a GPU-less host: install.sh is sourced (its main()
# is guarded by BASH_SOURCE so nothing executes on source) and the device/host-dependent steps
# are stubbed. Covers the runtime branching that previously had no automated guard (only the
# cross-repo AgentBaker e2e exercised it).

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "${TEST_TMP}/bin"

    # Fixture module root for target_build_kernel.
    export AKSGPU_MODULES_ROOT="${TEST_TMP}/modules"
    mkdir -p "${AKSGPU_MODULES_ROOT}"

    # Fake gpu config + package-manager helpers so install.sh can be sourced without /opt/gpu.
    export AKSGPU_CONFIG_PATH="${TEST_TMP}/config.sh"
    export AKSGPU_PMH_PATH="${TEST_TMP}/pmh.sh"
    cat > "${AKSGPU_CONFIG_PATH}" <<'EOF'
DRIVER_VERSION="${DRIVER_VERSION:-580.0.0}"
DRIVER_KIND="${DRIVER_KIND:-cuda}"
GPU_DEST="${GPU_DEST:-/usr/bin}"
NVIDIA_CONTAINER_TOOLKIT_VER="1.19.1"
NVIDIA_PACKAGES="pkg"
EOF
    printf ':\n' > "${AKSGPU_PMH_PATH}"

    # Load the functions under test. main() is guarded, so sourcing runs no install steps.
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../install.sh"

    # Stable identity for the marker tests (individual tests override as needed).
    KERNEL_NAME="5.15.0-1114-azure"
    DRIVER_VERSION="580.0.0"
    DRIVER_KIND="cuda"
    ARCH="x86_64"
    DKMS_MARKER_FILE="${TEST_TMP}/dkms-marker"
}

teardown() {
    rm -rf "${TEST_TMP}"
}

# --- helpers ---------------------------------------------------------------

# _stub_bin <name> <exit_code>: put an executable stub with the given exit code on the test PATH.
_stub_bin() {
    cat > "${TEST_TMP}/bin/${1}" <<EOF
#!/usr/bin/env bash
exit ${2}
EOF
    chmod +x "${TEST_TMP}/bin/${1}"
}

# _has_sort_v: GNU sort with -V (version sort). Absent on BSD/macOS, present on the CI runner.
_has_sort_v() { printf '1\n2\n' | sort -V >/dev/null 2>&1; }

# _stub_dispatch: replace the device/host-dependent steps so main()'s dispatch can run GPU-less.
# Each stub records that it ran via a sentinel file.
_stub_dispatch() {
    cleanup_overlay() { :; }
    build_and_mark() { echo "BUILD_AND_MARK"; touch "${TEST_TMP}/build_and_mark.ran"; }
    initialize_nvidia_driver() {
        echo "INITIALIZE_NVIDIA_DRIVER"
        echo "initialize_nvidia_driver" >> "${TEST_TMP}/dispatch-order"
        touch "${TEST_TMP}/initialize_nvidia_driver.ran"
    }
    configure_nvidia_container_runtime() {
        echo "CONFIGURE_NVIDIA_CONTAINER_RUNTIME"
        echo "configure_nvidia_container_runtime" >> "${TEST_TMP}/dispatch-order"
        touch "${TEST_TMP}/configure_nvidia_container_runtime.ran"
    }
    purge_gpu_cache() { :; }
}

# --- marker: write -------------------------------------------------------

@test "write_dkms_marker records kernel/version/kind/arch" {
    KERNEL_NAME="6.8.0-1059-azure"; DRIVER_VERSION="580.126.09"; DRIVER_KIND="cuda"; ARCH="x86_64"
    write_dkms_marker
    run cat "${DKMS_MARKER_FILE}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"kernel=6.8.0-1059-azure"* ]]
    [[ "$output" == *"driver_version=580.126.09"* ]]
    [[ "$output" == *"driver_kind=cuda"* ]]
    [[ "$output" == *"arch=x86_64"* ]]
}

@test "write_dkms_marker publishes atomically (no .tmp left behind)" {
    write_dkms_marker
    run bash -c "ls ${TEST_TMP}/dkms-marker.tmp.* 2>/dev/null"
    [ "$status" -ne 0 ]
}

# --- marker: parse + validate -------------------------------------------

@test "baked_marker_matches succeeds on exact kernel+version+kind match" {
    write_dkms_marker
    run baked_marker_matches
    [ "$status" -eq 0 ]
}

@test "baked_marker_matches fails on kernel mismatch (kernel drift since bake)" {
    write_dkms_marker
    KERNEL_NAME="6.11.0-1000-azure"
    run baked_marker_matches
    [ "$status" -ne 0 ]
}

@test "baked_marker_matches fails on driver_version mismatch" {
    write_dkms_marker
    DRIVER_VERSION="999.99.99"
    run baked_marker_matches
    [ "$status" -ne 0 ]
}

@test "baked_marker_matches fails on driver_kind mismatch (cuda marker on grid node)" {
    write_dkms_marker
    DRIVER_KIND="grid"
    run baked_marker_matches
    [ "$status" -ne 0 ]
}

@test "baked_marker_matches fails when the marker file is absent" {
    rm -f "${DKMS_MARKER_FILE}"
    run baked_marker_matches
    [ "$status" -ne 0 ]
}

# --- fast-path fallback --------------------------------------------------

@test "fast_path_ok succeeds when ldconfig+dkms+modinfo all pass" {
    _stub_bin ldconfig 0; _stub_bin dkms 0; _stub_bin modinfo 0
    PATH="${TEST_TMP}/bin:$PATH"
    run fast_path_ok
    [ "$status" -eq 0 ]
}

@test "fast_path_ok fails (-> full build) when modinfo reports the module is unusable" {
    _stub_bin ldconfig 0; _stub_bin dkms 0; _stub_bin modinfo 1
    PATH="${TEST_TMP}/bin:$PATH"
    run fast_path_ok
    [ "$status" -ne 0 ]
}

@test "fast_path_ok fails (-> full build) when dkms status fails" {
    _stub_bin ldconfig 0; _stub_bin dkms 1; _stub_bin modinfo 0
    PATH="${TEST_TMP}/bin:$PATH"
    run fast_path_ok
    [ "$status" -ne 0 ]
}

# --- target kernel selection --------------------------------------------

@test "target_build_kernel picks the newest kernel that has a build tree" {
    _has_sort_v || skip "requires GNU sort -V (runs on the Linux CI)"
    mkdir -p "${AKSGPU_MODULES_ROOT}/5.15.0-1114-azure/build"
    mkdir -p "${AKSGPU_MODULES_ROOT}/6.8.0-1059-azure/build"
    mkdir -p "${AKSGPU_MODULES_ROOT}/6.8.0-1200-azure"   # no build tree -> must be ignored
    run target_build_kernel
    [ "$status" -eq 0 ]
    [ "$output" = "6.8.0-1059-azure" ]
}

@test "target_build_kernel falls back to uname -r when no build trees exist" {
    run target_build_kernel
    [ "$status" -eq 0 ]
    [ "$output" = "$(uname -r)" ]
}

# --- mode dispatch -------------------------------------------------------

@test "dispatch build-only: builds+marks then skips node-time driver and runtime initialization" {
    _has_sort_v || skip "build-only resolves target kernel via GNU sort -V (runs on the Linux CI)"
    _stub_dispatch
    mkdir -p "${AKSGPU_MODULES_ROOT}/6.8.0-1059-azure/build"
    AKSGPU_BUILD_ONLY=1; AKSGPU_SKIP_KERNEL_BUILD=0
    run main
    [ "$status" -eq 0 ]
    [[ "$output" == *"build-only mode"* ]]
    [ -f "${TEST_TMP}/build_and_mark.ran" ]
    [ ! -f "${TEST_TMP}/initialize_nvidia_driver.ran" ]
    [ ! -f "${TEST_TMP}/configure_nvidia_container_runtime.ran" ]
}

@test "dispatch install-skip-build with matching marker: initializes the driver before the runtime" {
    _stub_dispatch
    _stub_bin ldconfig 0; _stub_bin dkms 0; _stub_bin modinfo 0
    PATH="${TEST_TMP}/bin:$PATH"
    KERNEL_NAME="5.15.0-1114-azure"; DRIVER_VERSION="580.0.0"; DRIVER_KIND="cuda"; ARCH="x86_64"
    write_dkms_marker
    AKSGPU_BUILD_ONLY=0; AKSGPU_SKIP_KERNEL_BUILD=1
    run main
    [ "$status" -eq 0 ]
    [[ "$output" == *"recompile skipped"* ]]
    [ ! -f "${TEST_TMP}/build_and_mark.ran" ]
    [ -f "${TEST_TMP}/initialize_nvidia_driver.ran" ]
    [ -f "${TEST_TMP}/configure_nvidia_container_runtime.ran" ]
    run cat "${TEST_TMP}/dispatch-order"
    [ "$status" -eq 0 ]
    [ "$output" = $'initialize_nvidia_driver\nconfigure_nvidia_container_runtime' ]
}

@test "dispatch install-skip-build with mismatched marker: falls back to a full build" {
    _stub_dispatch
    _stub_bin ldconfig 0; _stub_bin dkms 0; _stub_bin modinfo 0
    PATH="${TEST_TMP}/bin:$PATH"
    KERNEL_NAME="5.15.0-1114-azure"; DRIVER_VERSION="580.0.0"; DRIVER_KIND="cuda"; ARCH="x86_64"
    write_dkms_marker
    DRIVER_VERSION="999.0.0"   # node now needs a different version than the baked marker
    AKSGPU_BUILD_ONLY=0; AKSGPU_SKIP_KERNEL_BUILD=1
    run main
    [ "$status" -eq 0 ]
    [[ "$output" == *"building from source"* ]]
    [ -f "${TEST_TMP}/build_and_mark.ran" ]
    [ -f "${TEST_TMP}/initialize_nvidia_driver.ran" ]
    [ -f "${TEST_TMP}/configure_nvidia_container_runtime.ran" ]
}

# --- CDI lifecycle ordering ---------------------------------------------

@test "initialize_nvidia_driver refreshes the linker cache before nvidia-smi" {
    DRIVER_KIND="grid"
    nvidia-modprobe() { echo "nvidia-modprobe" >> "${TEST_TMP}/driver-order"; }
    cp() { echo "copy-libraries" >> "${TEST_TMP}/driver-order"; }
    ldconfig() { echo "ldconfig" >> "${TEST_TMP}/driver-order"; }
    nvidia-smi() { echo "nvidia-smi" >> "${TEST_TMP}/driver-order"; }

    run initialize_nvidia_driver

    [ "$status" -eq 0 ]
    run cat "${TEST_TMP}/driver-order"
    [ "$status" -eq 0 ]
    [ "$output" = $'nvidia-modprobe\ncopy-libraries\nldconfig\nnvidia-smi' ]
}

@test "configure_nvidia_container_runtime installs the toolkit before the final CDI refresh" {
    install_nvidia_container_toolkit() { echo "install-toolkit" >> "${TEST_TMP}/runtime-order"; }
    mkdir() { :; }
    cp() {
        case "$1" in
            */10-nvidia-runtime.toml) echo "containerd-config" >> "${TEST_TMP}/runtime-order" ;;
            */71-nvidia-char-dev.rules) echo "udev-rule" >> "${TEST_TMP}/runtime-order" ;;
        esac
    }
    dirname() { command dirname "$@"; }
    systemctl() { echo "systemctl $*" >> "${TEST_TMP}/runtime-order"; }
    export AKSGPU_NVIDIA_CTK_BIN="${TEST_TMP}/bin/nvidia-ctk"
    cat > "${AKSGPU_NVIDIA_CTK_BIN}" <<EOF
#!/usr/bin/env bash
echo "nvidia-ctk" >> "${TEST_TMP}/runtime-order"
EOF
    chmod +x "${AKSGPU_NVIDIA_CTK_BIN}"

    run configure_nvidia_container_runtime

    [ "$status" -eq 0 ]
    run cat "${TEST_TMP}/runtime-order"
    [ "$status" -eq 0 ]
    [ "$output" = $'install-toolkit\ncontainerd-config\nudev-rule\nnvidia-ctk\nsystemctl reset-failed nvidia-cdi-refresh.service nvidia-cdi-refresh.path\nsystemctl restart nvidia-cdi-refresh.service' ]
}

@test "configure_nvidia_container_runtime propagates a failed final CDI refresh" {
    install_nvidia_container_toolkit() { :; }
    mkdir() { :; }
    cp() { :; }
    dirname() { command dirname "$@"; }
    systemctl() { return 1; }
    export AKSGPU_NVIDIA_CTK_BIN="${TEST_TMP}/bin/nvidia-ctk"
    _stub_bin nvidia-ctk 0

    run configure_nvidia_container_runtime

    [ "$status" -ne 0 ]
}
