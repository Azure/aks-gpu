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

# TODO - try exit 1 vs return 1, see how behavior changes, see if check: if $2; then works
# TODO - would be NICE - CI check to add for real vm that runs this
# TODO - ncv3 vm for testing

use_package_manager_avoid_race() {
  local wait_for_locks=$1
  local install_dependencies=$2
  local retries=$3
  local sleep_duration=$4

  export DEBIAN_FRONTEND=noninteractive
  for i in $(seq 1 "$3"); do
    $wait_for_locks
    dpkg --configure -a --force-confdef
    if $install_dependencies; then
      return
    fi
    if [ "$i" -eq "$retries" ]; then
      return 1
    else sleep "$sleep_duration"
    fi
  done
}

use_package_manager_avoid_race wait_for_apt_locks install_nvidia_packages 10 3