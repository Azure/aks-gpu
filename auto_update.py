import os
import re
import requests
from ruamel.yaml import YAML

# Source of truth for Azure-mirrored NVIDIA GRID drivers. resources.json
# contains all currently-supported NVIDIA driver branches (we previously
# read Nvidia-GPU-Linux-Resources.json, but that file is no longer updated
# past 550.144.06 / vGPU 17.55).
RESOURCES_JSON_URL = (
    "https://raw.githubusercontent.com/Azure/azhpc-extensions/"
    "refs/heads/master/NvidiaGPU/resources.json"
)

# Driver versions look like "570.211.01" — major.minor.patch. The MAJOR
# component corresponds to NVIDIA's driver branch (R570, R580, …) and is
# the ABI-stable boundary: within one major, NVIDIA only ships
# bug-fix / patch releases. Crossing a major (e.g. 570 -> 580) can
# introduce kernel-module ABI changes, install-script differences, and
# vGPU licensing changes, so it requires deliberate validation.
DRIVER_VERSION_PATTERN = re.compile(r"^\d+(?:\.\d+){1,2}$")


def _driver_sort_key(version_str):
    """Convert "570.211.01" -> (570, 211, 1) so version comparisons are numeric."""
    return tuple(int(p) for p in version_str.split(".") if p.isdigit())


def _current_driver_major(config):
    """Return the driver major (e.g. '570') of the currently-pinned grid version."""
    current = str(config.get("grid", {}).get("version", "")).strip()
    if not DRIVER_VERSION_PATTERN.match(current):
        raise RuntimeError(
            f"Cannot determine driver major from grid.version={current!r} "
            f"in driver_config.yml (expected like '570.211.01')."
        )
    return current.split(".")[0]


def get_latest_grid_driver_for_major(target_major):
    """Return (driver_version, download_url) for the highest version in
    resources.json whose driver major matches target_major.

    Walks OS.Linux.Version[*].Driver[*] for Type='GRID' blocks and keeps any
    entry whose Num starts with f"{target_major}.". Falls back from DirLink
    to FwLink so we still get a usable URL when the manifest puts the
    download in FwLink (the v18.5 entry is one such example).
    """
    response = requests.get(RESOURCES_JSON_URL, timeout=30)
    response.raise_for_status()
    data = response.json()

    linux_block = next(
        (o for o in data.get("OS", []) if o.get("Name") == "Linux"), None
    )
    if linux_block is None:
        raise RuntimeError("No 'Linux' OS block in NvidiaGPU/resources.json")

    prefix = f"{target_major}."
    candidates = {}
    for distro in linux_block.get("Version", []):
        for drv_block in distro.get("Driver", []):
            if drv_block.get("Type") != "GRID":
                continue
            for v in drv_block.get("Version", []):
                num = str(v.get("Num", "")).strip()
                if not num.startswith(prefix):
                    continue
                url = v.get("DirLink") or v.get("FwLink")
                if not url:
                    continue
                # Same driver may appear in multiple distro blocks; first wins.
                candidates.setdefault(num, url)

    if not candidates:
        raise RuntimeError(
            f"No GRID driver {target_major}.x entries found in "
            f"{RESOURCES_JSON_URL}. If NVIDIA has ended patches for this "
            f"branch, bump driver_config.yml to the next major manually."
        )

    best = max(candidates, key=_driver_sort_key)
    return best, candidates[best]


def update_driver_config():
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2, sequence=4, offset=2)

    if not os.path.exists("driver_config.yml"):
        raise FileNotFoundError("driver_config.yml not found in the current directory.")

    with open("driver_config.yml", "r") as f:
        config = yaml.load(f)

    target_major = _current_driver_major(config)
    latest_version, latest_url = get_latest_grid_driver_for_major(target_major)

    config['grid']['version'] = latest_version
    config['grid']['url'] = latest_url

    with open("driver_config.yml", "w") as f:
        yaml.dump(config, f)


if __name__ == "__main__":
    update_driver_config()
