wait_for_apt_locks() {
    while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        echo 'Waiting for release of apt locks'
        sleep 3
    done
}

wait_for_dpkg_lock() {
   while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
     echo 'Waiting for release of dpkg locks'
     sleep 3
   done
}

get_fabric_manager_arch() {
  case "$(uname -m)" in
    arm64|aarch64)
      echo "sbsa"
      ;;
    amd64|x86_64)
      echo "x86_64"
      ;;
    *)
      uname -m
      ;;
  esac
}

use_package_manager_with_retries() {
  local wait_for_locks=$1
  local install_dependencies=$2
  local retries=$3
  local sleep_duration=$4

  export DEBIAN_FRONTEND=noninteractive
  for i in $(seq 1 "$3"); do
    $wait_for_locks
    dpkg --configure -a --force-confdef
    ($install_dependencies) && break
    if [ "$i" -eq "$retries" ]; then
      return 1
    else sleep "$sleep_duration"
    fi
  done
}

update_initramfs_for_nouveau_blacklist() {
  local kernel_name initrd_path

  kernel_name="$(uname -r)"
  initrd_path="/boot/initrd.img-${kernel_name}"

  if ! command -v update-initramfs >/dev/null 2>&1; then
    echo "Skipping initramfs update because update-initramfs is unavailable"
    return 0
  fi

  if ! command -v lsinitramfs >/dev/null 2>&1; then
    echo "lsinitramfs is unavailable; updating initramfs conservatively"
    update-initramfs -u -k "${kernel_name}"
    return 0
  fi

  if [[ ! -f "${initrd_path}" ]]; then
    echo "Skipping initramfs update because ${initrd_path} does not exist"
    return 0
  fi

  if lsinitramfs "${initrd_path}" | grep -Eq '(^|/)kernel/.*/nouveau\.ko(\.[^.]+)?$'; then
    echo "Updating initramfs to apply nouveau blacklist for ${kernel_name}"
    update-initramfs -u -k "${kernel_name}"
    return 0
  fi

  echo "Skipping initramfs update because nouveau is not present in ${initrd_path}"
}
